import CZebkit
import Foundation

/// Synchronous tools for local media files with the FFmpeg inside the engine
/// (`<zebkit/media_tools.h>`): a documented subset of `ffprobe` and `ffmpeg`
/// (`docs/MEDIA_TOOLS.md`), not the programs themselves. There are no
/// encoders and no filters: what is supported is probing, copying streams
/// into another container (MP4, MOV, Matroska, WebM), decoding audio to
/// PCM16 (WAV or raw) and decoding video to RGBA frames. Unsupported
/// switches and codecs fail; nothing falls back to a system FFmpeg.
///
/// Needs no running engine, shell or subprocess. Calls block: run long ones
/// on a worker thread. Calls with distinct outputs may run at the same time.
/// Inputs and outputs are local regular files. An output is written to a
/// temporary file beside it and appears only on success; an existing one
/// stays unless `-y`.
public enum MediaTools {
    /// How an `ffmpeg` run ended without failing.
    public enum Completion: Sendable {
        case completed
        /// The progress handler asked to stop: no output was written.
        case cancelled
    }

    /// Format and stream metadata of an input, as JSON in a subset of
    /// ffprobe's schema. `arguments`, without the program's name:
    /// `[-show_format] [-show_streams] [-of json | -print_format json] [-i] INPUT`.
    /// With neither show switch, both sections are given. Each argument is
    /// literal: there is no shell.
    public static func ffprobe(_ arguments: [String]) throws -> String {
        var json: UnsafeMutablePointer<CChar>?
        var message: UnsafeMutablePointer<CChar>?
        let code = try withArguments(arguments) { zebkit_ffprobe($0, $1, &json, &message) }
        let result = string(taking: json)
        guard code == 0 else { throw error(taking: message, otherwise: "the media probe failed") }
        zebkit_free(message)
        guard let result else { throw ZebkitError("the media probe returned no JSON") }
        return result
    }

    /// Format and stream metadata of `file`, as `ffprobe(["-i", path])`.
    public static func probe(_ file: URL) throws -> String {
        var json: UnsafeMutablePointer<CChar>?
        var message: UnsafeMutablePointer<CChar>?
        let code = try withArguments([file.path]) { _, argv in zebkit_media_probe(argv[0], &json, &message) }
        let result = string(taking: json)
        guard code == 0 else { throw error(taking: message, otherwise: "the media probe failed") }
        zebkit_free(message)
        guard let result else { throw ZebkitError("the media probe returned no JSON") }
        return result
    }

    /// Runs a supported `ffmpeg` operation. `arguments`, without the
    /// program's name:
    ///
    ///     [-y|-n] -i INPUT [-map 0:INDEX]... [-vn] [-an]
    ///     (-c copy | -c:a pcm_s16le | -c:v rawvideo) [-f FORMAT]
    ///     [-ar RATE] [-ac CHANNELS] [-s WIDTHxHEIGHT] [-frames:v COUNT]
    ///     [-pix_fmt rgba] OUTPUT
    ///
    /// `--` allows an output that starts with a hyphen. `progress` is called
    /// on this thread at the start and while packets are processed, with the
    /// packets read so far (of every stream) and the time of the latest
    /// (`nil` when unknown; not always going up). It returns false to
    /// cancel, between packets.
    @discardableResult
    public static func ffmpeg(
        _ arguments: [String], progress: ((_ packets: Int, _ time: Duration?) -> Bool)? = nil
    ) throws -> Completion {
        var message: UnsafeMutablePointer<CChar>?
        let code: Int32
        if let progress {
            code = try withoutActuallyEscaping(progress) { progress in
                let box = Box<(Int, Duration?) -> Bool>(progress)
                return try withExtendedLifetime(box) {
                    try withArguments(arguments) { argc, argv in
                        zebkit_ffmpeg(argc, argv, { packets, time, data in
                            guard let progress = Box<(Int, Duration?) -> Bool>.borrow(data) else { return 1 }
                            return progress(Int(packets), time == .min ? nil : .microseconds(time)) ? 1 : 0
                        }, box.unretained, &message)
                    }
                }
            }
        } else {
            code = try withArguments(arguments) { zebkit_ffmpeg($0, $1, nil, nil, &message) }
        }
        switch code {
        case 0:
            zebkit_free(message)
            return .completed
        case 1:
            zebkit_free(message)
            return .cancelled
        default:
            throw error(taking: message, otherwise: "the media processing failed")
        }
    }

    /// Copies the streams of `source` into the container `destination`'s
    /// extension names, without decoding: `-c copy`.
    public static func remux(from source: URL, to destination: URL, overwrite: Bool = false) throws {
        try ffmpeg([overwrite ? "-y" : "-n", "-i", source.path, "-c", "copy", "--", destination.path])
    }

    /// Decodes the audio of `source` to interleaved PCM16 in a WAV file, at
    /// `sampleRate` with `channels`.
    public static func extractAudio(
        from source: URL, to destination: URL, sampleRate: Int, channels: Int, overwrite: Bool = false
    ) throws {
        try ffmpeg([
            overwrite ? "-y" : "-n", "-i", source.path, "-c:a", "pcm_s16le", "-ar", String(sampleRate),
            "-ac", String(channels), "-f", "wav", "--", destination.path,
        ])
    }

    /// Decodes the first `frameCount` frames of the video of `source`, scaled
    /// to `width` by `height`, to packed RGBA frames one after another.
    public static func extractVideo(
        from source: URL, to destination: URL, width: Int, height: Int, frameCount: Int, overwrite: Bool = false
    ) throws {
        try ffmpeg([
            overwrite ? "-y" : "-n", "-i", source.path, "-c:v", "rawvideo", "-s", "\(width)x\(height)",
            "-frames:v", String(frameCount), "--", destination.path,
        ])
    }

    /// Calls `body` with `arguments` as C strings. A zero byte would end one
    /// early, so an argument with one is refused.
    private static func withArguments<Result>(
        _ arguments: [String], _ body: (Int32, UnsafePointer<UnsafePointer<CChar>?>) -> Result
    ) throws -> Result {
        guard !arguments.isEmpty else { throw ZebkitError("there are no arguments") }
        guard !arguments.contains(where: { $0.utf8.contains(0) }) else {
            throw ZebkitError("an argument contains a zero byte")
        }
        let copies = arguments.map { UnsafePointer(strdup($0)) }
        defer { copies.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        return copies.withUnsafeBufferPointer { body(Int32(clamping: $0.count), $0.baseAddress!) }
    }
}
