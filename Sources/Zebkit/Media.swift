import CZebkit
import Foundation

// MARK: - Listing a page's media

extension Engine {
    /// Has players keep, from the engine's start, what a capture starts from:
    /// the video since their last keyframe, up to about 16 MiB for each video
    /// stream, so that a capture of a file an element loads starts at the
    /// frame on screen even when nothing has listed media yet. Off by
    /// default: then players keep it only once `WebView.mediaJSON()` or
    /// `WebView.mediaJSON(atX:y:)` ran in their page's process. Before `run`, on
    /// the thread that calls it; the same as `--zebkit-media-history`.
    public static func keepMediaHistory(_ keep: Bool) {
        zebkit_media_keep_history(keep)
    }
}

extension WebView {
    /// The live `<audio>` and `<video>` elements of every frame of the page,
    /// detached `Audio` objects and shadow trees included, as a JSON array:
    ///
    ///     [{"id": "4.12.3", "element": 3, "tag": "video", "path": "...",
    ///       "frame": {"url": "...", "main": true, "name": ""},
    ///       "src": "...", "kind": "file", "duration": 60.0,
    ///       "currentTime": 12.5, "buffered": [[0, 30.2]],
    ///       "codecs": {"video": "h264", "audio": "aac"},
    ///       "hasVideo": true, "hasAudio": true, "width": 1280,
    ///       "height": 720, "playing": true, "encrypted": false,
    ///       "capturable": true, "capturing": false}]
    ///
    /// `"kind"` is `"file"` (`src=`), `"mse"`, `"hls"`, `"stream"` (a camera
    /// or WebRTC: not capturable) or `"none"`. `"id"` is what a capture or a
    /// tap takes; it stays the same while the element lives. The first
    /// listing in a page's process readies its players for captures (see
    /// `Engine.keepMediaHistory(_:)`).
    public func mediaJSON() async throws -> String {
        guard let raw else { throw ZebkitError("the view is closed") }
        return try await withResult { zebkit_view_media_list(raw, $0, $1) }
    }

    /// The media element at (`x`, `y`) of the view, in its input events'
    /// coordinates (CSS pixels times the page's zoom): the element the point
    /// hits or is inside of, or else the smallest whose box holds it
    /// (players draw their controls over the video). Its entry as
    /// `mediaJSON()` has it, or `nil` when there is none. Frames of other
    /// sites are searched too.
    public func mediaJSON(atX x: Double, y: Double) async throws -> String? {
        guard let raw else { throw ZebkitError("the view is closed") }
        let json = try await withResult { zebkit_view_media_at(raw, Float(x), Float(y), $0, $1) }
        return json == "null" ? nil : json
    }

    /// Starts copying what media `mediaID` (an `"id"` of `mediaJSON()`)
    /// plays to `file`, without decoding or encoding; see `MediaCapture`.
    /// `json` is an object of options (`nil` for the defaults): `"format"`
    /// (`"mp4"`, `"webm"`, `"mkv"` or `"auto"`), `"includeBuffered"`,
    /// `"closeGaps"` (seconds, or false), `"wallClock"`, `"maxBytes"`,
    /// `"maxDuration"`. Throws when the media or the path cannot be used;
    /// what is found later ends the capture with an error, in its done JSON.
    public func startMediaCapture(mediaID: String, to file: URL, json: String? = nil) throws -> MediaCapture {
        guard let raw else { throw ZebkitError("the view is closed") }
        var message: UnsafeMutablePointer<CChar>?
        guard let capture = zebkit_media_capture_start(raw, mediaID, file.path, json, &message) else {
            throw error(taking: message, otherwise: "the capture did not start")
        }
        return MediaCapture(raw: capture)
    }

    /// Starts a tap of media `mediaID` (an `"id"` of `mediaJSON()`): its
    /// encoded packets, sampled video frames and PCM come to `handler` as
    /// they play; see `MediaTap`. `json` is an object of options (`nil` for
    /// the defaults). Throws for options or media it refuses; failures found
    /// later come as a `"done"` event with an `"error"`.
    public func startMediaTap(
        mediaID: String, json: String? = nil, handler: @escaping @ZebkitActor (MediaTap.Event) -> Void
    ) throws -> MediaTap {
        guard let raw else { throw ZebkitError("the view is closed") }
        let sink = MediaTap.Sink(handler)
        var message: UnsafeMutablePointer<CChar>?
        let tap = zebkit_media_tap_start(raw, mediaID, json ?? "{}", { _, json, bytes, size, data in
            let event = MediaTap.Event(
                json: string(borrowing: json) ?? "{}", bytes: Zebkit.data(borrowing: bytes, count: size))
            guard let data else { return }
            let sink = Unmanaged<MediaTap.Sink>.fromOpaque(data).takeUnretainedValue()
            onEngineThread { sink.receive(event) }
        }, Unmanaged.passUnretained(sink).toOpaque(), &message)
        guard let tap else { throw error(taking: message, otherwise: "the media tap did not start") }
        return MediaTap(raw: tap, sink: sink)
    }
}

// MARK: - Captures

/// What a page's `<audio>` or `<video>` plays, copied to a file while it
/// plays: the encoded audio and video its demuxer gives its decoders, put in
/// an MP4, WebM or Matroska file without decoding or encoding anything. The
/// same for a file the element loads, for what a player appends through Media
/// Source Extensions, and for HLS the engine plays itself. A capture has what
/// the player has from the playhead on; it loads nothing itself. Encrypted
/// media cannot be captured.
///
/// The files are written when the capture stops: by `stop()`, or when the
/// page goes or the element loads other media; `onDone` and `finished()` then
/// get the result. Keep the object until then: letting it go stops the
/// capture, writes its files, and calls nothing more. A capture still running
/// when the engine quits is not written, and `finished()` does not return for
/// it: stop it and wait before the engine quits.
@ZebkitActor
public final class MediaCapture {
    /// What the engine calls with: the capture's handlers and its end. An
    /// object of its own, which lasts until the engine has freed the capture
    /// when that is after the capture itself has gone.
    @ZebkitActor
    final class Sink {
        var onProgress: (@ZebkitActor (String) -> Void)?
        var onDone: (@ZebkitActor (String) -> Void)?
        var doneJSON: String?
        var waiters: [CheckedContinuation<String, Never>] = []

        func finish(_ json: String) {
            doneJSON = json
            onDone?(json)
            onDone = nil
            let waiters = self.waiters
            self.waiters = []
            waiters.forEach { $0.resume(returning: json) }
        }

        nonisolated static func from(_ data: UnsafeMutableRawPointer?) -> Sink? {
            data.map { Unmanaged<Sink>.fromOpaque($0).takeUnretainedValue() }
        }
    }

    // Read by `deinit`, which is the last to have the object.
    private nonisolated(unsafe) let raw: OpaquePointer
    private let sink = Sink()

    init(raw: OpaquePointer) {
        self.raw = raw
        zebkit_media_capture_on_done(raw, { _, json, data in
            let json = string(borrowing: json) ?? "{}"
            let sink = Sink.from(data)
            onEngineThread { sink?.finish(json) }
        }, Unmanaged.passUnretained(sink).toOpaque())
    }

    deinit {
        // Whatever thread lets go of the capture last, the engine's frees
        // it; nothing of the capture's is called after that, and until then
        // the sink is there for what is.
        nonisolated(unsafe) let capture = raw
        let sink = sink
        onEngineThreadEventually {
            zebkit_media_capture_free(capture)
            _ = sink
        }
    }

    /// Called about twice a second while the capture runs, with its state:
    /// `{"state": "capturing", "bytes": ..., "packets": ..., "duration": ...,
    /// "ranges": [[10.0, 22.0]], "tracks": [...]}`. `"ranges"` are the times
    /// captured, in the media's own timeline.
    public var onProgress: (@ZebkitActor (String) -> Void)? {
        get { sink.onProgress }
        set {
            sink.onProgress = newValue
            guard newValue != nil else { return zebkit_media_capture_on_progress(raw, nil, nil) }
            zebkit_media_capture_on_progress(raw, { _, json, data in
                let json = string(borrowing: json) ?? "{}"
                let sink = Sink.from(data)
                onEngineThread { sink?.onProgress?(json) }
            }, Unmanaged.passUnretained(sink).toOpaque())
        }
    }

    /// Called once, when the capture's files are written, with its end:
    /// `{"state": "done", "reason": "stopped", "error": "...", "bytes": ...,
    /// "duration": ..., "ranges": [...], "tracks": [...], "files": [{"path",
    /// "format", "start", "duration", "bytes", "gaps", "tracks"}, ...]}`.
    /// `"reason"` is `"stopped"`, `"the page went away"`, `"the element
    /// loaded other media"`, `"the player stopped"` or `"error"`; `"error"`
    /// is there only when it failed or found nothing. A change of codec,
    /// track or the like starts another file; `"files"` lists them in order.
    public var onDone: (@ZebkitActor (String) -> Void)? {
        get { sink.onDone }
        set { sink.onDone = newValue }
    }

    /// Returns the capture's end, its done JSON (see `onDone`), once its
    /// files are written; at once if they are.
    public func finished() async -> String {
        if let json = sink.doneJSON { return json }
        return await withCheckedContinuation { sink.waiters.append($0) }
    }

    /// Stops the capture and writes its files; `onDone` follows.
    public func stop() {
        zebkit_media_capture_stop(raw)
    }

    /// The capture's state now, as `onProgress` and `onDone` have it, with
    /// `"state"` `"starting"`, `"capturing"`, `"finishing"` or `"done"`, and
    /// `"media"`, the element's entry when it started.
    public var statusJSON: String {
        string(taking: zebkit_media_capture_status(raw)) ?? "{}"
    }
}

// MARK: - Taps

/// A media element's output, as it plays: its encoded packets, its displayed
/// video sampled as RGBA, its PCM, and optionally a recording of the packets
/// in a file. One tap per element. File, Media Source Extensions and HLS
/// players give all of it; a `MediaStream` (a camera, WebRTC) gives video and
/// PCM only (`"packets": false`, no path). Encrypted media is refused.
///
/// Events come to the handler on the engine's thread, as `Event`s. Stop it
/// with `stop()` and wait for its `"done"` event (`finished()`) before the
/// engine quits, for a recording to be written. Letting the object go stops
/// the tap and calls nothing more; a file is still written while the engine
/// runs.
@ZebkitActor
public final class MediaTap {
    /// One event of a tap.
    public struct Event: Equatable, Sendable {
        /// The event, as JSON. Its `"type"` is `"audioConfig"`,
        /// `"videoConfig"`, `"packet"`, `"video"`, `"audio"`, `"timeline"`,
        /// `"progress"` or `"done"`. Timestamps are microseconds (packets'
        /// as decimal strings), unknown is -9223372036854775807; PCM has a
        /// monotonic `"captureTimeUs"`.
        public let json: String
        /// The event's bytes, copied: a config's codec initialization bytes,
        /// a packet's data, a video frame's RGBA8 pixels, audio's planar
        /// native-endian float32 samples; empty for the others.
        public let bytes: Data
        /// The event's `"type"`; `""` when it has none.
        public let type: String

        init(json: String, bytes: Data) {
            self.json = json
            self.bytes = bytes
            let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            type = object?["type"] as? String ?? ""
        }
    }

    /// What the engine calls: the handler, and the end of the tap.
    @ZebkitActor
    final class Sink {
        let handler: @ZebkitActor (Event) -> Void
        var doneJSON: String?
        var waiters: [CheckedContinuation<String, Never>] = []

        init(_ handler: @escaping @ZebkitActor (Event) -> Void) {
            self.handler = handler
        }

        func receive(_ event: Event) {
            handler(event)
            guard event.type == "done" else { return }
            doneJSON = event.json
            let waiters = self.waiters
            self.waiters = []
            waiters.forEach { $0.resume(returning: event.json) }
        }
    }

    // Read by `deinit`, which is the last to have the object.
    private nonisolated(unsafe) let raw: OpaquePointer
    // The engine's `data` for the tap's events: kept as long as the tap.
    private let sink: Sink

    init(raw: OpaquePointer, sink: Sink) {
        self.raw = raw
        self.sink = sink
    }

    deinit {
        // Whatever thread lets go of the tap last, the engine's frees it; no
        // event comes after that, and until then the sink is there for one.
        nonisolated(unsafe) let tap = raw
        let sink = sink
        onEngineThreadEventually {
            zebkit_media_tap_free(tap)
            _ = sink
        }
    }

    /// Stops the tap's samples and writes its file, if it has one; the
    /// `"done"` event follows. Calling it again does nothing.
    public func stop() {
        zebkit_media_tap_stop(raw)
    }

    /// Returns the tap's `"done"` event's JSON, with its files and any
    /// error, once it comes; at once if it came.
    public func finished() async -> String {
        if let json = sink.doneJSON { return json }
        return await withCheckedContinuation { sink.waiters.append($0) }
    }
}
