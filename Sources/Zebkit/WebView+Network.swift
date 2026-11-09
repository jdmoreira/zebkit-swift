import CZebkit
import Foundation

// <zebkit/hooks.h>'s network: a filter of rules in front of a view's loader,
// the requests and responses its hold rules hold (`NetworkRequest`), what its
// observe rules tell, and the bodies of responses as they pass.

/// A header of a request or a response: of `Engine.fetch`, and as the
/// network filter's JSON has it.
public struct HTTPHeader: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    /// The headers in `lines`, `"Name: value"` lines separated by `"\r\n"`,
    /// as the engine gives them.
    static func parse(_ lines: String) -> [HTTPHeader] {
        lines.components(separatedBy: "\r\n").compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return HTTPHeader(name: name, value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
    }
}

extension [HTTPHeader] {
    /// The value of the first header named `name`, in any case.
    func value(named name: String) -> String? {
        first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The headers as the engine takes them; `nil` for none.
    var lines: String? {
        isEmpty ? nil : map { "\($0.name): \($0.value)" }.joined(separator: "\r\n")
    }
}

/// A part of a response's body, as it passes to the page
/// (`WebView.onNetworkBody`).
public struct NetworkBodyChunk: Equatable, Sendable {
    /// The `requestId` of the response's events.
    public let requestID: String
    /// At most 64 KiB; empty in the last chunk.
    public let bytes: Data
    /// Whether this ends the response's chunks: its body ended, the network
    /// failed or the page went (the next event says which), or
    /// `isTruncated`.
    public let isEnd: Bool
    /// With `isEnd`: 64 MiB were told, and the rest of the body passes
    /// untold.
    public let isTruncated: Bool
}

extension WebView {
    /// Sets the view's network filter, replacing the last: a JSON array of
    /// at most 256 rules, `{url, mode, stage, resourceTypes, frames, body}`.
    /// `url` is a Playwright glob (every URL by default); `mode` `"hold"`
    /// (the default: asked to `onNetwork`) or `"observe"` (told to
    /// `onNetworkEvent`); `stage` `"request"` (the default),
    /// `"sendHeaders"`, `"sent"`, `"headersReceived"` or `"response"`;
    /// `resourceTypes` of `"document"`, `"stylesheet"`, `"image"`,
    /// `"media"`, `"font"`, `"script"`, `"manifest"`, `"fetch"`,
    /// `"websocket"`; `frames` `"all"`, `"main"`, `"sub"`; `body` true for
    /// `onNetworkBody`. Invalid input changes nothing and throws.
    ///
    /// It covers the view's frames and their dedicated workers from then
    /// on, and WebSocket handshakes. Requests a service worker answers never
    /// reach it. A rule at `sendHeaders`, `sent` or `headersReceived` fails
    /// closed: a request it holds that nothing answers ends with
    /// `ERR_BLOCKED_BY_CLIENT`. Past 1024 held requests of a view, further
    /// matches fail the same way. A rule must be set before a request starts
    /// to reach it.
    public func setNetworkFilter(json: String) throws {
        guard let raw else { throw ZebkitError("the view is closed") }
        try checked("the network filter was refused") { zebkit_view_set_network_filter(raw, json, $0) }
    }

    /// Whether this view's filter also decides for the shared and service
    /// workers of its profile, those running included. False without a
    /// filter set (`[]` is one). A later call of another view takes over.
    /// While on, its requests fail with `ERR_BLOCKED_BY_CLIENT` once this
    /// view has gone, until another view takes over or one turns it off;
    /// closing the view does not turn it off. False also when another view
    /// has it on and this turns it off.
    @discardableResult
    public func setNetworkFilterForWorkers(_ on: Bool) -> Bool {
        guard let raw else { return false }
        return zebkit_view_set_network_filter_for_workers(raw, on)
    }

    /// Called with what a hold rule holds. Unanswered, or with its handler
    /// replaced, a request goes on, except at the stages that fail closed.
    /// A closed view ends its requests.
    public var onNetwork: (@ZebkitActor (NetworkRequest) -> Void)? {
        get { handler(.network) }
        set { setRequest(.network, newValue, zebkit_view_on_network) }
    }

    /// Told what an observe rule matches, holding nothing: `kind`
    /// (`request`, `response`, `redirect`, `finished`, `failed` with
    /// `error`, `sent`) and the fields of `NetworkRequest`'s metadata;
    /// `dropped` counts reports over 4096 waiting. Also how held requests
    /// settled: `state`, `reason`. A WebSocket is told at its request only.
    public var onNetworkEvent: (@ZebkitActor (String) -> Void)? {
        get { handler(.networkEvent) }
        set { setEvent(.networkEvent, newValue, zebkit_view_on_network_event) }
    }

    /// Told the bodies of the responses a rule with `body: true` matches,
    /// as they pass to the page, and never kept. The next chunk is read
    /// when the page has taken this one. Each response ends with one chunk
    /// whose `isEnd` is true. Not told for a response that started before
    /// this was set.
    public var onNetworkBody: (@ZebkitActor (NetworkBodyChunk) -> Void)? {
        get { handler(.networkBody) }
        set {
            let box = newValue.map { Box<@ZebkitActor (NetworkBodyChunk) -> Void>($0) }
            setHook(.networkBody, handler: newValue, box: box) { raw, box in
                guard let box else { return zebkit_view_on_network_body(raw, nil, nil) }
                zebkit_view_on_network_body(raw, { _, id, bytes, size, end, truncated, data in
                    let chunk = NetworkBodyChunk(
                        requestID: string(borrowing: id) ?? "",
                        bytes: bytes.map { Data(bytes: $0, count: size) } ?? Data(),
                        isEnd: end, isTruncated: truncated)
                    let handler = Box<@ZebkitActor (NetworkBodyChunk) -> Void>.borrow(data)
                    onEngineThread { handler?(chunk) }
                }, box.unretained)
            }
        }
    }
}

/// A request or a response a hold rule holds (`WebView.onNetwork`). The
/// metadata has `stage`, `requestId` (the same across redirects), `url`,
/// `method`, `headers` (at the request stage, before the network adds
/// Cookie, Origin, Referer and more), `resourceType`, `frameId`,
/// `mainFrame`, `worker`, `workerType`, `navigation`, `initiator`,
/// `hasBody`, `bodySize`, `body` (base64, up to 64 KiB), `bodyComplete`;
/// for a response `status`, `statusText`, `responseHeaders`, `mimeType`;
/// `timeoutMs`, `deadlineUnixMs`.
@ZebkitActor
public final class NetworkRequest: RequestToken {
    let raw: OpaquePointer
    public let metadataJSON: String

    init(raw: OpaquePointer, metadataJSON: String) {
        self.raw = raw
        self.metadataJSON = metadataJSON
    }

    public var infoJSON: String? { string(taking: zebkit_network_request_info(raw)) }

    public enum Answer: Sendable, Equatable {
        /// Lets it go on; with `headers`, with exactly those. Headers the
        /// network refuses a page are refused. A response's change undoes
        /// neither a cookie stored nor CORS.
        case proceed(headers: [HTTPHeader]? = nil)
        /// Fails it with `error`, a Playwright error name
        /// (`"blockedbyclient"` when `nil`).
        case block(error: String? = nil)
        /// Redirects it to `url`, http or https. Refused for a WebSocket.
        case redirect(to: String)
        /// Answers it with this response; `body` at most 64 MiB. CORS is not
        /// applied, and Set-Cookie is not stored. Refused for a WebSocket.
        case fulfill(status: Int, headers: [HTTPHeader] = [], body: Data = Data())
        /// Answers it with this response, the body read from `file` (an
        /// absolute file URL, the application's choice) off the engine's
        /// thread, of any size; Range is not applied, Content-Type is
        /// sniffed when absent. A file that cannot be read fails the request
        /// afterwards with `ERR_FILE_NOT_FOUND`.
        case fulfillFile(status: Int, headers: [HTTPHeader] = [], file: URL)
    }

    private struct Reply: Encodable {
        var action: String?
        var status: Int?
        var headers: [HTTPHeader]?
        var error: String?
        var url: String?
    }

    /// Answers the request. Throws when the answer is not taken: an invalid
    /// one leaves the request pending.
    public func respond(_ answer: Answer) throws {
        switch answer {
        case .proceed(let headers):
            try respond(json: JSON.encode(Reply(action: "continue", headers: headers)))
        case .block(let error):
            try respond(json: JSON.encode(Reply(action: "block", error: error)))
        case .redirect(let url):
            try respond(json: JSON.encode(Reply(action: "redirect", url: url)))
        case .fulfill(let status, let headers, let body):
            try respond(json: JSON.encode(Reply(action: "fulfill", status: status, headers: headers)), body: body)
        case .fulfillFile(let status, let headers, let file):
            try respondFile(json: JSON.encode(Reply(status: status, headers: headers)), file: file)
        }
    }

    /// Answers the request with a reply as the engine's JSON: `{action:
    /// "continue", headers}`, `{action: "block", error}`, `{action:
    /// "redirect", url}`, or `{action: "fulfill", status, headers}` with `body`.
    func respond(json: String, body: Data = Data()) throws {
        try checked("the answer was not taken: the request is settled, or the answer is invalid") { message in
            body.withUnsafeBytes { zebkit_network_respond(raw, json, $0.baseAddress, $0.count, message) }
        }
    }

    /// Fulfills the request from `file`: `json` is `{status, headers}`.
    func respondFile(json: String, file: URL) throws {
        try checked("the answer was not taken: the request is settled, or the answer is invalid") {
            zebkit_network_respond_file(raw, json, file.path, $0)
        }
    }

    /// Fulfills the request with what the application then writes to the
    /// stream returned, the response going at once. Give a Content-Type:
    /// there are no bytes to sniff. No deadline applies from here: a stream
    /// not ended leaves the page waiting.
    public func respondStream(status: Int, headers: [HTTPHeader] = []) throws -> NetworkResponseStream {
        try respondStream(json: JSON.encode(Reply(status: status, headers: headers)))
    }

    /// `respondStream(status:headers:)` with `json`, `{status, headers}`.
    func respondStream(json: String) throws -> NetworkResponseStream {
        var message: UnsafeMutablePointer<CChar>?
        guard let stream = zebkit_network_respond_stream(raw, json, &message) else {
            throw error(taking: message, otherwise: "the answer was not taken: the request is settled, or the answer is invalid")
        }
        zebkit_free(message)
        return NetworkResponseStream(raw: stream)
    }
}

/// The body of a response the application writes as it goes
/// (`NetworkRequest.respondStream`). Call `end` when it is complete; one let
/// go of before that ends as failed, so that a body cut short does not look
/// whole to the page. An `onWritable` that holds the stream keeps it until
/// `end`: hold it weakly there, or always call `end`.
@ZebkitActor
public final class NetworkResponseStream {
    // Read by `deinit`, which is the last to have the object.
    private nonisolated(unsafe) var raw: OpaquePointer?
    private nonisolated(unsafe) var writable: Box<@ZebkitActor () -> Void>?

    init(raw: OpaquePointer) {
        self.raw = raw
    }

    deinit {
        guard let raw else { return }
        // Whatever thread lets go of the stream last, the engine's ends it;
        // what the engine calls with is kept until it has.
        nonisolated(unsafe) let stream = raw
        nonisolated(unsafe) let writable = writable
        onEngineThreadEventually {
            zebkit_network_stream_end(stream, true)
            _ = writable
        }
    }

    /// Queues all of `bytes` or none: false when they do not fit in what
    /// waits (at most 1 MiB), when the page has gone or stopped reading, and
    /// after `end`. After a false for bytes of at most 1 MiB on a stream
    /// that `isOpen`, `onWritable` is called; for more than 1 MiB at once it
    /// never is (write a larger body in parts), nor once the page has gone.
    @discardableResult
    public func write(_ bytes: Data) -> Bool {
        guard let raw else { return false }
        return bytes.withUnsafeBytes { zebkit_network_stream_write(raw, $0.baseAddress, $0.count) }
    }

    /// Called once after a write of at most 1 MiB that returned false on an
    /// open stream: when that write would fit, or when nothing will (`isOpen`
    /// says which). Let go of at `end`.
    public var onWritable: (@ZebkitActor () -> Void)? {
        get { writable?.value }
        set {
            guard let raw else { return }
            guard let newValue else {
                zebkit_network_stream_on_writable(raw, nil, nil)
                writable = nil
                return
            }
            let box = Box<@ZebkitActor () -> Void>(newValue)
            zebkit_network_stream_on_writable(raw, { _, data in
                let handler = Box<@ZebkitActor () -> Void>.borrow(data)
                onEngineThread { handler?() }
            }, box.unretained)
            writable = box
        }
    }

    /// Whether the page still reads.
    public var isOpen: Bool {
        guard let raw else { return false }
        return zebkit_network_stream_is_open(raw)
    }

    /// Ends the response after what waits, or, `failed`, as failed at once.
    /// What is done to the stream after it does nothing.
    public func end(failed: Bool = false) {
        guard let raw else { return }
        self.raw = nil
        zebkit_network_stream_end(raw, failed)
        writable = nil
    }
}
