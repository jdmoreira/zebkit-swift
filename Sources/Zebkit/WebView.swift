import CZebkit
import Foundation

/// How far a page load has got.
public enum LoadEvent: Sendable {
    /// A load of the page was asked for.
    case started
    /// The new document replaced the old one.
    case committed
    /// The page and its resources have loaded.
    case finished
    /// The load failed or was stopped.
    case failed

    init?(_ event: zebkit_load_event) {
        switch event {
        case ZEBKIT_LOAD_STARTED: self = .started
        case ZEBKIT_LOAD_COMMITTED: self = .committed
        case ZEBKIT_LOAD_FINISHED: self = .finished
        case ZEBKIT_LOAD_FAILED: self = .failed
        default: return nil
        }
    }
}

extension WebView {
    /// What a page may use of the global object `zebkit`, for
    /// `WebView.grant(_:to:filesRoot:)`. A page has none of it unless granted.
    public struct Allow: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// `zebkit.app.<name>()`: the functions `WebView.bind` gives.
        public static let app = Allow(rawValue: ZEBKIT_ALLOW_APP.rawValue)
        /// `zebkit.fetch()`: HTTP through the engine, without CORS.
        public static let fetch = Allow(rawValue: ZEBKIT_ALLOW_FETCH.rawValue)
        /// `zebkit.fs`, inside the directory the grant names.
        public static let files = Allow(rawValue: ZEBKIT_ALLOW_FILES.rawValue)
        /// `zebkit.compress()` and `zebkit.decompress()`.
        public static let compress = Allow(rawValue: ZEBKIT_ALLOW_COMPRESS.rawValue)
        /// `zebkit.crypto`.
        public static let crypto = Allow(rawValue: ZEBKIT_ALLOW_CRYPTO.rawValue)
        /// `zebkit.image`.
        public static let image = Allow(rawValue: ZEBKIT_ALLOW_IMAGE.rawValue)
        /// `zebkit.url`.
        public static let url = Allow(rawValue: ZEBKIT_ALLOW_URL.rawValue)
        /// `zebkit.pdf`: documents the page opens, in the browser process.
        public static let pdf = Allow(rawValue: ZEBKIT_ALLOW_PDF.rawValue)
        /// All of it.
        public static let all = Allow(rawValue: ZEBKIT_ALLOW_ALL.rawValue)
    }
}

/// The system's window a view's page is in, borrowed: nothing of it is the
/// application's to destroy or release. Ask again after attaching or
/// detaching the view; the handle is of no use once that window closes.
public enum NativeWindow: Hashable, Sendable {
    /// An X11 window id.
    case x11(UInt)
    /// A Windows `HWND`.
    case win32(UInt)
    /// An AppKit `NSWindow *` (not the `NSView *` a view is attached to).
    case appKit(UInt)
}

/// A profile of its own, in memory, as an incognito window's: its cookies,
/// storage, cache and permissions are its own and go with it.
@ZebkitActor
public final class WebContext {
    /// The engine's context; `nil` once it is closed.
    private(set) var raw: OpaquePointer?

    public init() {
        raw = zebkit_context_new()
    }

    /// Whether the context is closed.
    public var isClosed: Bool { raw == nil }

    /// Closes the context and its views. The profile itself is freed when
    /// the engine stops. No view can be made in a closed context: one asked
    /// for is closed from the start.
    public func close() {
        guard let raw else { return }
        self.raw = nil
        zebkit_context_close(raw)
    }
}

/// State that another file of this package keeps on a view: one object of
/// each type per view, made on first use and dropped when the view closes.
@ZebkitActor
protocol WebViewState: AnyObject {
    init()

    /// The view has closed: the last this state hears of it.
    func viewClosed()
}

extension WebViewState {
    func viewClosed() {}
}

/// A page, as Chromium shows it: in a window when the machine has a display,
/// and without one otherwise, or with `--headless`. It loads, runs and can be
/// driven over CDP either way.
///
/// A view lives until it is closed: by `close()`, by the person closing its
/// window, by the page's `window.close()`, or by `Engine.quit()`. `onClose`
/// is the last a view does. What a closed view is asked to do is not done.
@ZebkitActor
public final class WebView {
    /// The engine's view; `nil` once it is closed.
    private(set) var raw: OpaquePointer?

    /// This view as the `data` of the engine's callbacks. The engine keeps
    /// one reference to the view until it closes, so the pointer is good for
    /// as long as the engine calls with it.
    var callbackData: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    /// The view a callback's `data` is of.
    nonisolated static func from(_ data: UnsafeMutableRawPointer?) -> WebView? {
        data.map { Unmanaged<WebView>.fromOpaque($0).takeUnretainedValue() }
    }

    // MARK: Making one

    /// A view loading `url` (`nil` for none, until `load(_:)`), `width` by
    /// `height` pixels, or of a default size when either is 0; in `context`,
    /// or in the engine's own profile. Throws for a closed context, and
    /// when the engine gives no view.
    public convenience init(url: String? = nil, width: Int = 0, height: Int = 0, context: WebContext? = nil) throws {
        // Not in the engine's own profile, which a NULL context would mean.
        if let context, context.isClosed { throw ZebkitError("the context is closed") }
        guard let raw = zebkit_view_new_in(context?.raw, url, Int32(clamping: width), Int32(clamping: height)) else {
            throw ZebkitError("the view could not be made")
        }
        self.init(wrapping: raw)
    }

    /// The open views, by the engine's view. The engine has one place for
    /// each callback of a view, so a view has one `WebView`: a second would
    /// take the callbacks from the first, which would then never hear that
    /// the view closed.
    private static var open: [OpaquePointer: WebView] = [:]

    /// The `WebView` of a view the engine hands over: the one it has, or a
    /// new one for a view not seen before.
    static func of(_ raw: OpaquePointer) -> WebView {
        open[raw] ?? WebView(wrapping: raw)
    }

    /// The view the engine made, with the callbacks every view has. For a
    /// view certain to be new; `of(_:)` for any other.
    init(wrapping raw: OpaquePointer?) {
        self.raw = raw
        guard let raw else { return }
        WebView.open[raw] = self
        // The engine's reference, given back when the view closes.
        let data = Unmanaged.passRetained(self).toOpaque()
        zebkit_view_on_load(raw, { _, event, url, data in
            guard let event = LoadEvent(event) else { return }
            let url = string(borrowing: url) ?? ""
            let view = WebView.from(data)
            onEngineThread { view?.loadChanged(event, url: url) }
        }, data)
        zebkit_view_on_title(raw, { _, title, data in
            let title = string(borrowing: title) ?? ""
            let view = WebView.from(data)
            onEngineThread { view?.onTitle?(title) }
        }, data)
        zebkit_view_on_close(raw, { _, data in
            guard let data else { return }
            let view = Unmanaged<WebView>.fromOpaque(data).takeRetainedValue()
            onEngineThread {
                view.closed()
                // The engine is taking the view apart, and what it still
                // tells of on the way (a popup of an off-screen view going)
                // comes with the view as its `data`: kept until this call
                // of the engine's is over.
                Task { @ZebkitActor in _ = view }
            }
        }, data)
    }

    /// Whether the view is closed.
    public var isClosed: Bool { raw == nil }

    // MARK: State of other files

    private var states: [ObjectIdentifier: any WebViewState] = [:]

    /// This view's state of `type`, made on first use.
    func state<State: WebViewState>(_ type: State.Type) -> State {
        if let existing = states[ObjectIdentifier(type)] as? State { return existing }
        let state = State()
        states[ObjectIdentifier(type)] = state
        return state
    }

    // MARK: Loading

    /// Loads `url`.
    public func load(_ url: String) {
        guard let raw else { return }
        zebkit_view_load_url(raw, url)
    }

    public func reload() {
        guard let raw else { return }
        zebkit_view_reload(raw)
    }

    public func goBack() {
        guard let raw else { return }
        zebkit_view_go_back(raw)
    }

    public func goForward() {
        guard let raw else { return }
        zebkit_view_go_forward(raw)
    }

    /// Stops the page's load.
    public func stop() {
        guard let raw else { return }
        zebkit_view_stop(raw)
    }

    /// Whether the page is loading.
    public var isLoading: Bool {
        guard let raw else { return false }
        return zebkit_view_is_loading(raw)
    }

    /// The page's URL; `nil` for a closed view.
    public var url: String? {
        guard let raw else { return nil }
        return string(taking: zebkit_view_get_url(raw))
    }

    /// The page's title; `nil` for a closed view.
    public var title: String? {
        guard let raw else { return nil }
        return string(taking: zebkit_view_get_title(raw))
    }

    /// The view's identifier as a CDP target; `nil` for a closed view.
    public var targetID: String? {
        guard let raw else { return nil }
        return string(taking: zebkit_view_get_target_id(raw))
    }

    /// Called with each step of every load, and the URL it is of.
    public var onLoad: (@ZebkitActor (LoadEvent, String) -> Void)?

    /// Called with the page's title whenever it changes.
    public var onTitle: (@ZebkitActor (String) -> Void)?

    /// Called when the view closes, whatever closed it: the last the view
    /// does.
    public var onClose: (@ZebkitActor () -> Void)?

    private var loadWaiters: [CheckedContinuation<Void, any Error>] = []

    /// Returns when a load finishes; throws when one fails or is stopped, or
    /// when the view closes first. For the load a new view starts, or one
    /// asked for just before:
    ///
    ///     view.load("https://example.com/")
    ///     try await view.loadFinished()
    public func loadFinished() async throws {
        guard raw != nil else { throw ZebkitError("the view is closed") }
        try await withCheckedThrowingContinuation { loadWaiters.append($0) }
    }

    private func loadChanged(_ event: LoadEvent, url: String) {
        onLoad?(event, url)
        guard event == .finished || event == .failed else { return }
        let waiters = loadWaiters
        loadWaiters = []
        for waiter in waiters {
            if event == .finished {
                waiter.resume()
            } else {
                waiter.resume(throwing: ZebkitError("the load of \(url) failed"))
            }
        }
    }

    private func closed() {
        if let raw { WebView.open[raw] = nil }
        raw = nil
        onClose?()
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0.resume(throwing: ZebkitError("the view closed")) }
        // What the closures hold may hold the view: let go of all of it.
        onLoad = nil
        onTitle = nil
        onClose = nil
        onNewWindow = nil
        onWindowOpen = nil
        onFilesDropped = nil
        bindings = [:]
        let states = self.states
        self.states = [:]
        states.values.forEach { $0.viewClosed() }
    }

    // MARK: The window

    /// Closes the view, once the current callback has returned.
    public func close() {
        guard let raw else { return }
        zebkit_view_close(raw)
    }

    /// Makes the view's content `width` by `height` pixels: its window
    /// follows. (`setSize(width:height:scale:)` is the off-screen view's.)
    public func resize(width: Int, height: Int) {
        guard let raw else { return }
        zebkit_view_resize(raw, Int32(clamping: width), Int32(clamping: height))
    }

    /// The smallest the view's window may be made, its content `minWidth` by
    /// `minHeight` (0 for no limit), and whether it may be resized at all.
    public func setSizeLimits(minWidth: Int, minHeight: Int, resizable: Bool) {
        guard let raw else { return }
        zebkit_view_set_size_limits(raw, Int32(clamping: minWidth), Int32(clamping: minHeight), resizable)
    }

    /// The title of the view's window; `nil` for the page's, which it is by
    /// default.
    public func setWindowTitle(_ title: String?) {
        guard let raw else { return }
        zebkit_view_set_title(raw, title)
    }

    /// Brings the view's window to the front and gives it the keyboard.
    public func focus() {
        guard let raw else { return }
        zebkit_view_focus(raw)
    }

    /// Places the view inside `parent`'s window, over `parent`'s page, in
    /// `parent`'s coordinates (CSS pixels at zoom 1); its own window is
    /// hidden. A browser inside an application's window. The view goes with
    /// `parent`'s window when that closes.
    public func attach(to parent: WebView, x: Int, y: Int, width: Int, height: Int) {
        guard let raw, let parent = parent.raw else { return }
        zebkit_view_attach(raw, parent, Int32(clamping: x), Int32(clamping: y), Int32(clamping: width), Int32(clamping: height))
    }

    /// Puts the view's window inside a window of the application's own:
    /// `nativeParent` is an X11 window id, on macOS an `NSView *`. The units
    /// are the parent's: X11 pixels, AppKit points. Call it right after
    /// making the view, which is shown as a window of its own until then.
    ///
    /// Throws for a parent that is not there, and where a window cannot be
    /// put in another: on Wayland, under `--headless`, and for an off-screen
    /// view.
    public func attach(toNative nativeParent: UInt, x: Int, y: Int, width: Int, height: Int) throws {
        guard let raw else { throw ZebkitError("the view is closed") }
        try checked("the view could not be attached") {
            zebkit_view_attach_native(
                raw, nativeParent, Int32(clamping: x), Int32(clamping: y), Int32(clamping: width),
                Int32(clamping: height), $0)
        }
    }

    /// Makes the view its own window again, shown. False when it is in no
    /// window of the application's.
    @discardableResult
    public func detachFromNative() -> Bool {
        guard let raw else { return false }
        return zebkit_view_detach_native(raw)
    }

    /// Where an attached view is in its parent's window.
    public func setBounds(x: Int, y: Int, width: Int, height: Int) {
        guard let raw else { return }
        zebkit_view_set_bounds(raw, Int32(clamping: x), Int32(clamping: y), Int32(clamping: width), Int32(clamping: height))
    }

    /// Shows or hides an attached view.
    public func setVisible(_ visible: Bool) {
        guard let raw else { return }
        zebkit_view_set_visible(raw, visible)
    }

    /// The system's window the page is in, for the parent of a dialog of the
    /// application's; `nil` for a closed, off-screen or headless view, and on
    /// Wayland (`exportedNativeWindow()`).
    public var nativeWindow: NativeWindow? {
        guard let raw else { return nil }
        var window = zebkit_native_window()
        guard zebkit_view_get_native_window(raw, &window) else { return nil }
        switch window.kind {
        case ZEBKIT_NATIVE_WINDOW_X11: return .x11(window.handle)
        case ZEBKIT_NATIVE_WINDOW_WIN32: return .win32(window.handle)
        case ZEBKIT_NATIVE_WINDOW_APPKIT: return .appKit(window.handle)
        default: return nil
        }
    }

    /// The page's window as XDG Desktop Portal names a parent window:
    /// `"x11:<XID>"`, or on Wayland `"wayland:<handle>"`; `nil` when there is
    /// none (headless, off-screen, the view closed meanwhile, and always on
    /// macOS, where `nativeWindow` is the handle).
    public func exportedNativeWindow() async -> String? {
        guard let raw else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let data = Box<CheckedContinuation<String?, Never>>.retained(continuation)
            let asked = zebkit_view_export_native_window(raw, { data, handle in
                Box<CheckedContinuation<String?, Never>>.take(data)?.resume(returning: string(borrowing: handle))
            }, data)
            if !asked { Box<CheckedContinuation<String?, Never>>.take(data)?.resume(returning: nil) }
        }
    }

    // MARK: Script

    /// Runs `script` in the page's main frame, as the page's own script
    /// would run, and returns its value as JSON; throws what it threw. A
    /// promise is waited for. A value JSON has nothing for (`undefined`) is
    /// `"null"`.
    @discardableResult
    public func evaluate(_ script: String) async throws -> String {
        guard let raw else { throw ZebkitError("the view is closed") }
        return try await withResult { zebkit_view_evaluate(raw, script, $0, $1) }
    }

    /// Runs `script` and decodes its value.
    ///
    ///     let title = try await view.evaluate("document.title", as: String.self)
    public func evaluate<Value: Decodable>(_ script: String, as type: Value.Type = Value.self) async throws -> Value {
        try JSON.decode(type, from: try await evaluate(script))
    }

    /// Runs `source` in every document the view loads from now on, in each
    /// frame's main world, before the page's own script: what Electron calls
    /// a preload.
    public func addScript(_ source: String) {
        guard let raw else { return }
        zebkit_view_add_script(raw, source)
    }

    /// The User-Agent of the view's requests and documents; `nil` for the
    /// engine's.
    public func setUserAgent(_ userAgent: String?) {
        guard let raw else { return }
        zebkit_view_set_user_agent(raw, userAgent)
    }

    /// The User-Agent and, optionally, its client hints, set together:
    /// `json` is as CDP's `Emulation.setUserAgentOverride` takes it
    /// (`userAgent` is required; `acceptLanguage`, `platform` and
    /// `userAgentMetadata` are optional). Loads wait for it.
    public func setUserAgentOverride(json: String) async throws {
        guard let raw else { throw ZebkitError("the view is closed") }
        // What it refuses also comes through the function, so false says
        // nothing more.
        _ = try await withResult { function, data in
            _ = zebkit_view_set_user_agent_override(raw, json, function, data)
        }
    }

    /// A picture of what the view shows, as a PNG: with or without a window.
    public func capture() async throws -> Data {
        guard let raw else { throw ZebkitError("the view is closed") }
        typealias Continuation = CheckedContinuation<Data, any Error>
        return try await withCheckedThrowingContinuation { (continuation: Continuation) in
            zebkit_view_capture(raw, { _, png, size, error, data in
                let result: Result<Data, any Error> =
                    if let message = string(borrowing: error) {
                        .failure(ZebkitError(message))
                    } else {
                        .success(Zebkit.data(borrowing: png, count: size))
                    }
                Box<Continuation>.take(data)?.resume(with: result)
            }, Box<Continuation>.retained(continuation))
        }
    }

    // MARK: New windows and drops

    /// What a page of this view opens in a new window (`window.open`, a
    /// link with `target=_blank`) comes here as its URL, and no window is
    /// made: the application opens it where it wants. With `nil` the engine
    /// opens a window of its own, which the application has no view of.
    public var onNewWindow: (@ZebkitActor (String) -> Void)? {
        didSet {
            guard let raw else { return }
            guard onNewWindow != nil else { return zebkit_view_on_new_window(raw, nil, nil) }
            zebkit_view_on_new_window(raw, { _, url, data in
                let url = string(borrowing: url) ?? ""
                let view = WebView.from(data)
                onEngineThread { view?.onNewWindow?(url) }
            }, callbackData)
        }
    }

    /// A window a page of this view opens is made as a view of its own and
    /// comes here with its URL, still linked to the page that opened it:
    /// `window.opener`, `postMessage()` and `window.closed` work between the
    /// two, as a site's sign-in through a popup needs. It is the
    /// application's to show and to close. `onNewWindow`, when set, takes
    /// the URL instead, and no popup is made.
    public var onWindowOpen: (@ZebkitActor (WebView, String) -> Void)? {
        didSet {
            guard let raw else { return }
            guard onWindowOpen != nil else { return zebkit_view_on_window_open(raw, nil, nil) }
            zebkit_view_on_window_open(raw, { _, opened, url, data in
                let url = string(borrowing: url) ?? ""
                let view = WebView.from(data)
                nonisolated(unsafe) let opened = opened
                onEngineThread {
                    guard let handler = view?.onWindowOpen, let opened else { return }
                    handler(WebView.of(opened), url)
                }
            }, callbackData)
        }
    }

    /// The files dropped on the view, from the desktop or another
    /// application, before the page gets the drop: what a page cannot learn
    /// of a dropped file. With it set, the page's `zebkit.pathForFile(file)`
    /// gives a dropped `File`'s path too.
    public var onFilesDropped: (@ZebkitActor ([URL]) -> Void)? {
        didSet {
            guard let raw else { return }
            guard onFilesDropped != nil else { return zebkit_view_on_drop(raw, nil, nil) }
            zebkit_view_on_drop(raw, { _, paths, data in
                let paths = string(borrowing: paths).flatMap { try? JSON.decode([String].self, from: $0) } ?? []
                let files = paths.map { URL(fileURLWithPath: $0) }
                let view = WebView.from(data)
                onEngineThread { view?.onFilesDropped?(files) }
            }, callbackData)
        }
    }

    // MARK: The page and the application

    /// Gives pages of `origin` in this view what `allow` says of `zebkit.*`
    /// (`[]` takes it back). `origin` is as a browser writes it, as in
    /// `"https://app.example"`, or `"file://"`, or `"*"` for every origin,
    /// which is for pages the application wrote itself and nothing else.
    /// `filesRoot` is the directory `zebkit.fs` works in, for `.files`.
    public func grant(_ allow: Allow, to origin: String, filesRoot: URL? = nil) {
        guard let raw else { return }
        zebkit_view_grant(raw, origin, allow.rawValue, filesRoot?.path)
    }

    private var bindings: [String: Box<@ZebkitActor (Call) -> Void>] = [:]

    /// Makes `zebkit.app.<name>(...)` in pages granted `.app` call
    /// `handler`, which answers the page's promise through the `Call`, then
    /// or later: for an answer that comes from a callback, or from no answer
    /// at all. `bind(_:answering:)` is the simpler form for the rest.
    public func bind(_ name: String, _ handler: @escaping @ZebkitActor (Call) -> Void) {
        guard let raw else { return }
        // The box is what the engine calls with: kept for as long as the
        // name is bound to it.
        let box = Box<@ZebkitActor (Call) -> Void>(handler)
        zebkit_view_bind(raw, name, { _, origin, arguments, call, data in
            let origin = string(borrowing: origin) ?? ""
            let arguments = string(borrowing: arguments) ?? "[]"
            let handler = Box<@ZebkitActor (Call) -> Void>.borrow(data)
            nonisolated(unsafe) let call = call
            onEngineThread { handler?(Call(raw: call, origin: origin, argumentsJSON: arguments)) }
        }, box.unretained)
        bindings[name] = box
    }

    /// Makes `zebkit.app.<name>(...)` call `handler` and answer the page's
    /// promise with what it returns, or reject it with what it throws.
    ///
    ///     view.bind("greet") { call in
    ///         "hello, \(try call.arguments(as: [String].self)[0])"
    ///     }
    public func bind<Answer: Encodable>(
        _ name: String, answering handler: @escaping @ZebkitActor (Call) async throws -> Answer
    ) {
        bind(name) { call in
            Task { @ZebkitActor in
                do {
                    try call.resolve(try await handler(call))
                } catch {
                    call.reject("\(error)")
                }
            }
        }
    }

    /// Takes `zebkit.app.<name>` away.
    public func unbind(_ name: String) {
        guard let raw else { return }
        zebkit_view_bind(raw, name, nil, nil)
        bindings[name] = nil
    }
}

extension WebView {
    /// A call from a page: `zebkit.app.<name>(...args)`. Answer it, then or
    /// later, with one of `resolve` and `reject`; one that is let go of
    /// unanswered rejects the page's promise.
    @ZebkitActor
    public final class Call {
        // Read by `deinit`, which is the last to have the object.
        private nonisolated(unsafe) var raw: OpaquePointer?

        /// The origin of the page that called.
        public let origin: String

        /// The arguments, as a JSON array.
        public let argumentsJSON: String

        init(raw: OpaquePointer?, origin: String, argumentsJSON: String) {
            self.raw = raw
            self.origin = origin
            self.argumentsJSON = argumentsJSON
        }

        deinit {
            guard let raw else { return }
            // Whatever thread lets go of the call last, the engine's answers it.
            nonisolated(unsafe) let call = raw
            onEngineThreadEventually { zebkit_call_reject(call, "the application did not answer") }
        }

        /// The arguments, decoded: `[String].self` for a call with strings,
        /// a `Decodable` type of the application's own for anything else.
        public func arguments<Arguments: Decodable>(as type: Arguments.Type = Arguments.self) throws -> Arguments {
            try JSON.decode(type, from: argumentsJSON)
        }

        /// Whether the call has been answered.
        public var isAnswered: Bool { raw == nil }

        private func take() -> OpaquePointer? {
            defer { raw = nil }
            return raw
        }

        /// Resolves the page's promise with `json`, a JSON value.
        public func resolve(json: String) {
            guard let raw = take() else { return }
            // With its length: no copy of it to end it in a NUL.
            var json = json
            json.withUTF8 { $0.withMemoryRebound(to: CChar.self) { zebkit_call_resolve_json(raw, $0.baseAddress, $0.count) } }
        }

        /// Resolves the page's promise with `value`, as JSON.
        public func resolve<Value: Encodable>(_ value: Value) throws {
            resolve(json: try JSON.encode(value))
        }

        /// Resolves the page's promise with `undefined`.
        public func resolve() {
            guard let raw = take() else { return }
            zebkit_call_resolve(raw, nil)
        }

        /// Rejects the page's promise with an `Error` of `message`.
        public func reject(_ message: String) {
            guard let raw = take() else { return }
            zebkit_call_reject(raw, message)
        }
    }
}

/// Calls `start` with a callback of the engine's result kind and its data,
/// and returns what the engine then gives that callback: the JSON, or the
/// error thrown. For the functions that take a `zebkit_result_func` and call
/// it exactly once.
@ZebkitActor
func withResult(_ start: (zebkit_result_func, UnsafeMutableRawPointer) -> Void) async throws -> String {
    typealias Continuation = CheckedContinuation<String, any Error>
    return try await withCheckedThrowingContinuation { (continuation: Continuation) in
        start({ _, json, error, data in
            Box<Continuation>.take(data)?.resume(with: scriptResult(json: json, error: error).mapError { $0 })
        }, Box<Continuation>.retained(continuation))
    }
}
