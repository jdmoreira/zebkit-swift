import CZebkit
import Foundation

/// URL schemes of the application's own: `register(_:options:)` before the
/// engine starts, then `handle(_:with:)` answers their requests, page loads,
/// subresources, `fetch()` and media alike.
///
///     URLScheme.register("app", options: [.standard, .secure, .fetch])
///     exit(Engine.run {
///         URLScheme.handle("app") { request in
///             request.respond(status: 200, headers: [HTTPHeader(name: "Content-Type", value: "text/html")],
///                             body: Data("<h1>Hi</h1>".utf8))
///         }
///         _ = try WebView(url: "app://main/index.html")
///     })
public enum URLScheme {
    /// What a scheme of the application's is like.
    public struct Options: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// Like `https:`, with a host and a path: an origin of its own,
        /// relative URLs, cookies and storage.
        public static let standard = Options(rawValue: ZEBKIT_SCHEME_STANDARD.rawValue)
        /// A secure context, as `https:` is.
        public static let secure = Options(rawValue: ZEBKIT_SCHEME_SECURE.rawValue)
        /// `fetch()` and `XMLHttpRequest` from pages, with CORS.
        public static let fetch = Options(rawValue: ZEBKIT_SCHEME_FETCH.rawValue)
        /// Pages' Content-Security-Policy does not restrict loads from it.
        public static let bypassCSP = Options(rawValue: ZEBKIT_SCHEME_BYPASS_CSP.rawValue)
    }

    /// Makes `scheme` (as in `"app"`, lower case) a URL scheme of the
    /// application's, as `options` say; every process of the engine learns
    /// of it. Before the engine starts, on the thread that starts it. The same
    /// from the command line:
    /// `--zebkit-scheme=app,standard,secure,fetch,bypass-csp`. False for a
    /// scheme the engine has already.
    @discardableResult
    public static func register(_ scheme: String, options: Options) -> Bool {
        zebkit_scheme_register(scheme, options.rawValue)
    }

    /// Answers the requests for `scheme`'s URLs with `handler`, on the
    /// engine's thread; `nil` stops. Requests nobody answers fail as not
    /// found. The handler may answer then, or later from any thread.
    @ZebkitActor
    public static func handle(_ scheme: String, with handler: (@ZebkitActor (Request) -> Void)?) {
        guard let handler else {
            zebkit_scheme_handle(scheme, nil, nil)
            handlers[scheme] = nil
            return
        }
        // The box is what the engine calls with: kept for as long as the
        // scheme is handled by it.
        let box = Box<@ZebkitActor (Request) -> Void>(handler)
        zebkit_scheme_handle(scheme, { raw, data in
            guard let raw else { return }
            let request = Request(raw: raw)
            let handler = Box<@ZebkitActor (Request) -> Void>.borrow(data)
            onEngineThread { handler?(request) }
        }, box.unretained)
        handlers[scheme] = box
    }

    @ZebkitActor private static var handlers: [String: Box<@ZebkitActor (Request) -> Void>] = [:]

    /// A request for a URL of the application's scheme. Its URL, method,
    /// headers and body are copied when it arrives, so it may be read and
    /// answered from any thread.
    ///
    /// Answer it once, with `respond(status:headers:body:)` or
    /// `respond(file:headers:)`; what comes after the first answer is not
    /// done. One that is let go of unanswered is answered 404 then.
    public final class Request: @unchecked Sendable {
        // Taken, under the lock, by the one answer.
        private let lock = NSLock()
        private var raw: OpaquePointer?

        /// The URL asked for.
        public let url: String

        /// The request's method, as in `"GET"`.
        public let method: String

        /// The request's headers, each as it came.
        public let headers: [HTTPHeader]

        /// The body sent with it; `nil` when there is none.
        public let body: Data?

        init(raw: OpaquePointer) {
            self.raw = raw
            url = string(borrowing: zebkit_request_url(raw)) ?? ""
            method = string(borrowing: zebkit_request_method(raw)) ?? ""
            headers = HTTPHeader.parse(string(borrowing: zebkit_request_headers(raw)) ?? "")
            var size = 0
            body = zebkit_request_body(raw, &size).map { Data(bytes: $0, count: size) }
        }

        deinit {
            if let raw { zebkit_request_respond(raw, 404, nil, nil, 0) }
        }

        /// The value of the first header named `name`, in any case.
        public func header(_ name: String) -> String? {
            headers.value(named: name)
        }

        /// Whether the request has been answered.
        public var isAnswered: Bool {
            lock.lock()
            defer { lock.unlock() }
            return raw == nil
        }

        private func take() -> OpaquePointer? {
            lock.lock()
            defer { lock.unlock() }
            defer { raw = nil }
            return raw
        }

        /// Answers with `status`, `headers` (`Content-Type` is worth giving)
        /// and `body`, which is copied. From any thread. False when the
        /// request was answered already.
        @discardableResult
        public func respond(status: Int, headers: [HTTPHeader] = [], body: Data = Data()) -> Bool {
            guard let raw = take() else { return false }
            headers.lines.withOptionalCString { headers in
                body.withUnsafeBytes { zebkit_request_respond(raw, Int32(clamping: status), headers, $0.baseAddress, $0.count) }
            }
            return true
        }

        /// Answers with the file at `file`, read as it is sent, in the range
        /// a Range header asks for (206), as a player seeking in a video
        /// asks; 404 when it is not there. `Content-Type` is taken from the
        /// file's extension unless `headers` give one. A path with a `".."`
        /// component is answered 404 and not opened: an application that
        /// makes the path from the request's URL keeps the page inside its
        /// directory, but should still check that the path it made is there.
        /// From any thread. False when the request was answered already.
        @discardableResult
        public func respond(file: URL, headers: [HTTPHeader] = []) -> Bool {
            guard let raw = take() else { return false }
            headers.lines.withOptionalCString { zebkit_request_respond_file(raw, file.path, $0) }
            return true
        }
    }
}
