import CZebkit
import Foundation

// The hooks of <zebkit/hooks.h>: what a view's pages and its network ask the
// application (requests), and what the engine tells it (events).
//
// Every request is the same shape (`WebViewRequest`): the view calls a
// handler with it, and the application answers it once, then or later, with
// `respond(_:)`. An unanswered request is settled by the engine at its
// deadline (`setRequestTimeout(_:for:)`), each kind as its documentation
// says. Every event is JSON, given to a closure.

/// Something a view's page or its network asked, which the application
/// answers once with `respond(_:)`: at once in the handler, or later on the
/// engine's thread. The engine owns the request; the object may be kept.
///
/// The engine settles a request the application has not answered at its
/// deadline, when the handler is replaced or removed, and when the view
/// closes or navigates away, each kind in the way its documentation says.
/// After that, and after an answer, `infoJSON` is `nil` and `respond(_:)`
/// throws.
@ZebkitActor
public protocol WebViewRequest: AnyObject {
    /// What the request was when the handler got it, as JSON: kept after
    /// it is settled.
    var metadataJSON: String { get }

    /// What the request is now, as JSON; `nil` once it is settled.
    var infoJSON: String? { get }
}

extension WebViewRequest {
    /// Whether the request still waits for an answer.
    public var isPending: Bool { infoJSON != nil }

    /// `metadataJSON`, decoded.
    public func metadata<Metadata: Decodable>(as type: Metadata.Type = Metadata.self) throws -> Metadata {
        try JSON.decode(type, from: metadataJSON)
    }
}

/// A request type made from the engine's token and the JSON of its callback.
@ZebkitActor
protocol RequestToken: WebViewRequest {
    init(raw: OpaquePointer, metadataJSON: String)
}

/// Throws when the engine did not take an answer that has no error message.
func taken(_ accepted: Bool) throws {
    guard accepted else {
        throw ZebkitError("the answer was not taken: the request is settled, or the answer is invalid")
    }
}

/// The kinds of `WebViewRequest`, for `WebView.setRequestTimeout(_:for:)`.
public enum WebViewRequestKind: Sendable, CaseIterable {
    case permission
    case navigation
    case certificate
    case httpAuth
    case download
    case clientCertificate
    case fileChooser
    case eyeDropper
    case deviceChooser
    case share
    case mediaAccess
    case network
}

// MARK: - The application's functions, per view

/// A hook of the engine's that a view calls the application through.
enum Hook: Hashable {
    case permission, permissionResult
    case navigation, navigationResult
    case popupBlocked, windowOpenEvent, console
    case certificate, certificateResult
    case httpAuth, httpAuthResult
    case externalProtocol
    case download, downloadProgress
    case clientCertificate, clientCertificateResult
    case fileChooser, fileChooserResult
    case eyeDropper, eyeDropperResult
    case deviceChooser, deviceChooserResult
    case share, shareResult
    case mediaAccess, mediaAccessResult
    case reservedKey, contextMenu, fullscreen
    case network, networkEvent, networkBody
    case windowState
}

/// What the application set on a view's hooks.
@ZebkitActor
final class HookState: WebViewState {
    /// Each hook's function, as the application gave it: what the getters return.
    var handlers: [Hook: Any] = [:]
    /// Each hook's `data`, which the engine has: kept for as long as it is set.
    var boxes: [Hook: AnyObject] = [:]
    /// The functions of context menus shown and not yet chosen from.
    var menuChoices: [ObjectIdentifier: Box<@ZebkitActor (String) -> Void>] = [:]

    init() {}
}

typealias EventFunction = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
typealias RequestFunction = @convention(c) (
    OpaquePointer?, OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void

extension WebView {
    /// The function the application set on `hook`.
    func handler<Handler>(_ hook: Hook) -> Handler? {
        state(HookState.self).handlers[hook] as? Handler
    }

    /// Sets the function `register` gives the engine for an event of JSON,
    /// or removes it.
    func setEvent(
        _ hook: Hook, _ handler: (@ZebkitActor (String) -> Void)?,
        _ register: (OpaquePointer?, EventFunction?, UnsafeMutableRawPointer?) -> Void
    ) {
        setHook(hook, handler: handler, box: handler.map { Box<@ZebkitActor (String) -> Void>($0) }) { raw, box in
            guard let box else { return register(raw, nil, nil) }
            register(raw, { _, json, data in
                let json = string(borrowing: json) ?? "{}"
                let handler = Box<@ZebkitActor (String) -> Void>.borrow(data)
                onEngineThread { handler?(json) }
            }, box.unretained)
        }
    }

    /// Sets the function `register` gives the engine for a request, or
    /// removes it.
    func setRequest<Request: RequestToken>(
        _ hook: Hook, _ handler: (@ZebkitActor (Request) -> Void)?,
        _ register: (OpaquePointer?, RequestFunction?, UnsafeMutableRawPointer?) -> Void
    ) {
        typealias Asked = @ZebkitActor (OpaquePointer, String) -> Void
        let box = handler.map { handler in
            Box<Asked> { raw, json in handler(Request(raw: raw, metadataJSON: json)) }
        }
        setHook(hook, handler: handler, box: box) { raw, box in
            guard let box else { return register(raw, nil, nil) }
            register(raw, { _, request, json, data in
                guard let token = request else { return }
                let json = string(borrowing: json) ?? "{}"
                let handler = Box<Asked>.borrow(data)
                nonisolated(unsafe) let request = token
                onEngineThread { handler?(request, json) }
            }, box.unretained)
        }
    }

    /// Registers `box` (or nothing) through `register`, then keeps it and
    /// `handler` for as long as they are set: the previous ones go only
    /// once the engine has the new.
    func setHook<Value: AnyObject>(
        _ hook: Hook, handler: Any?, box: Value?, register: (OpaquePointer, Value?) -> Void
    ) {
        guard let raw else { return }
        register(raw, box)
        // Registering settles the requests the previous handler held, and
        // what answers one may close the view: nothing is kept for it then.
        guard !isClosed else { return }
        let hooks = state(HookState.self)
        hooks.handlers[hook] = handler
        hooks.boxes[hook] = box
    }

    // MARK: Deadlines

    /// How long a request of `kind` made from now on waits for an answer:
    /// 1 millisecond to 300 seconds; 30 seconds by default. False for a
    /// duration out of that range, and for a closed view.
    @discardableResult
    public func setRequestTimeout(_ timeout: Duration, for kind: WebViewRequestKind) -> Bool {
        guard let raw else { return false }
        let milliseconds = Zebkit.milliseconds(timeout)
        switch kind {
        case .permission: return zebkit_view_set_permission_timeout(raw, milliseconds)
        case .navigation: return zebkit_view_set_navigation_timeout(raw, milliseconds)
        case .certificate: return zebkit_view_set_certificate_timeout(raw, milliseconds)
        case .httpAuth: return zebkit_view_set_http_auth_timeout(raw, milliseconds)
        case .download: return zebkit_view_set_download_timeout(raw, milliseconds)
        case .clientCertificate: return zebkit_view_set_client_certificate_timeout(raw, milliseconds)
        case .fileChooser: return zebkit_view_set_file_chooser_timeout(raw, milliseconds)
        case .eyeDropper: return zebkit_view_set_eye_dropper_timeout(raw, milliseconds)
        case .deviceChooser: return zebkit_view_set_device_chooser_timeout(raw, milliseconds)
        case .share: return zebkit_view_set_share_timeout(raw, milliseconds)
        case .mediaAccess: return zebkit_view_set_media_access_timeout(raw, milliseconds)
        case .network: return zebkit_view_set_network_timeout(raw, milliseconds)
        }
    }

    // MARK: Permissions

    /// Called with each permission a page asks for that the view's rules
    /// (`setPermission`) leave to the application. Replacing or removing it
    /// settles the requests the previous one has not answered.
    public var onPermission: (@ZebkitActor (PermissionRequest) -> Void)? {
        get { handler(.permission) }
        set { setRequest(.permission, newValue, zebkit_view_on_permission) }
    }

    /// Told how each request the application was asked settled: the
    /// request's metadata with `state`, `reason` (`answered`, `timeout`,
    /// `cancelled`, `handler-changed`, `policy-changed`) and `remembered`.
    public var onPermissionResult: (@ZebkitActor (String) -> Void)? {
        get { handler(.permissionResult) }
        set { setEvent(.permissionResult, newValue, zebkit_view_on_permission_result) }
    }

    // MARK: Navigation

    /// Called with each document navigation, at its start, redirects,
    /// response, failure, or activation from the back-forward cache or a
    /// prerender. Same-document changes the renderer makes are not asked.
    /// Unanswered requests continue, unless `setNavigationFailClosed(true)`.
    /// Replacing or removing it settles the pending requests in that way.
    /// Over 1024 pending requests of a view are cancelled.
    public var onNavigation: (@ZebkitActor (NavigationRequest) -> Void)? {
        get { handler(.navigation) }
        set { setRequest(.navigation, newValue, zebkit_view_on_navigation) }
    }

    /// Told how each navigation request settled: its metadata with `action`
    /// (`continue`, `cancel`, `redirect`), `reason` (`answered`, `timeout`,
    /// `cancelled`, `handler-changed`, `shutdown`) and, for a redirect,
    /// `replacementUrl`.
    public var onNavigationResult: (@ZebkitActor (String) -> Void)? {
        get { handler(.navigationResult) }
        set { setEvent(.navigationResult, newValue, zebkit_view_on_navigation_result) }
    }

    /// Whether a navigation request left unanswered (by its deadline, or by
    /// a handler removed) is cancelled rather than continued: for an
    /// application that filters navigations for safety. A popup takes its
    /// opener's choice when it opens. False for a closed view.
    @discardableResult
    public func setNavigationFailClosed(_ failClosed: Bool) -> Bool {
        guard let raw else { return false }
        return zebkit_view_set_navigation_fail_closed(raw, failClosed)
    }

    // MARK: New windows and the console

    /// Told of each popup the popup policy blocked, after the decision:
    /// `{url, frameName, userGesture}`. The handler may close or navigate
    /// the view.
    public var onPopupBlocked: (@ZebkitActor (String) -> Void)? {
        get { handler(.popupBlocked) }
        set { setEvent(.popupBlocked, newValue, zebkit_view_on_popup_blocked) }
    }

    /// Told of every attempt to open a window, after the fact: `phase`
    /// `decision` (`allowed`, `url`, `frameName`, `userGesture`,
    /// `disposition`, the opener's URLs, `features` and more) or `created`
    /// (`targetId`, `hasOpener`, `openerOrigin` and more). It only observes:
    /// `onWindowOpen` takes the new view.
    public var onWindowOpenEvent: (@ZebkitActor (String) -> Void)? {
        get { handler(.windowOpenEvent) }
        set { setEvent(.windowOpenEvent, newValue, zebkit_view_on_window_open_event) }
    }

    /// How this view was opened, as JSON, for a popup (also inside
    /// `onWindowOpen`, and after it navigates); `"{}"` for a view the
    /// application made, `nil` for a closed one.
    public var windowOpenInfoJSON: String? {
        guard let raw else { return nil }
        return string(taking: zebkit_view_get_window_open_info(raw))
    }

    /// Told of the messages of the page's documents' consoles: `level`
    /// (`debug`, `info`, `warning`, `error`), `message`, `source`, `line`,
    /// `frameId`, `mainFrame`, `origin`, `stackTrace` (untrusted text, or
    /// null), `truncated`, and `dropped`, a decimal string of the reports
    /// skipped since the last (at most 256 wait). Workers' messages are not
    /// told.
    public var onConsole: (@ZebkitActor (String) -> Void)? {
        get { handler(.console) }
        set { setEvent(.console, newValue, zebkit_view_on_console) }
    }

    // MARK: Certificates and credentials

    /// Called with each certificate error of a document. Without a handler
    /// every one is denied. Chromium or CDP may handle an error before it
    /// comes here. There is no remembered exception. A top-level navigation,
    /// the view closing and a handler replaced deny pending requests.
    public var onCertificate: (@ZebkitActor (CertificateRequest) -> Void)? {
        get { handler(.certificate) }
        set { setRequest(.certificate, newValue, zebkit_view_on_certificate) }
    }

    /// Told how each certificate request settled, as JSON.
    public var onCertificateResult: (@ZebkitActor (String) -> Void)? {
        get { handler(.certificateResult) }
        set { setEvent(.certificateResult, newValue, zebkit_view_on_certificate_result) }
    }

    /// Called with each HTTP authentication challenge, proxies' included,
    /// ahead of credentials an automation client gives. Without a handler,
    /// the engine's own behaviour stays.
    public var onHTTPAuth: (@ZebkitActor (HTTPAuthRequest) -> Void)? {
        get { handler(.httpAuth) }
        set { setRequest(.httpAuth, newValue, zebkit_view_on_http_auth) }
    }

    /// Told how each authentication request settled, as JSON, without the
    /// credentials given.
    public var onHTTPAuthResult: (@ZebkitActor (String) -> Void)? {
        get { handler(.httpAuthResult) }
        set { setEvent(.httpAuthResult, newValue, zebkit_view_on_http_auth_result) }
    }

    /// Called with each client certificate a TLS server asks for. Without a
    /// handler, none is sent.
    public var onClientCertificate: (@ZebkitActor (ClientCertificateRequest) -> Void)? {
        get { handler(.clientCertificate) }
        set { setRequest(.clientCertificate, newValue, zebkit_view_on_client_certificate) }
    }

    /// Told how each client certificate request settled, as JSON.
    public var onClientCertificateResult: (@ZebkitActor (String) -> Void)? {
        get { handler(.clientCertificateResult) }
        set { setEvent(.clientCertificateResult, newValue, zebkit_view_on_client_certificate_result) }
    }

    // MARK: Other programs and downloads

    /// Told of each navigation to a scheme the engine does not load
    /// (`mailto:`, `zoommtg:`): `url`, `scheme`, `mainFrame`, `userGesture`,
    /// `initiatorOrigin` (null when none), `frameId`. The engine opens
    /// nothing, with or without a handler; the page stays where it is.
    public var onExternalProtocol: (@ZebkitActor (String) -> Void)? {
        get { handler(.externalProtocol) }
        set { setEvent(.externalProtocol, newValue, zebkit_view_on_external_protocol) }
    }

    /// Called with each download, to save it or cancel it. Without a
    /// handler, downloads are saved in `Downloads` in the profile's
    /// directory, an existing file kept. Unanswered requests, those of a
    /// replaced handler and those of a closed view are cancelled.
    public var onDownload: (@ZebkitActor (DownloadRequest) -> Void)? {
        get { handler(.download) }
        set { setRequest(.download, newValue, zebkit_view_on_download) }
    }

    /// Told of this view's downloads, asked or not: the decision, then
    /// `downloadId`, `url`, `state` (`in-progress`, `complete`, `cancelled`,
    /// `interrupted`), `path`, `receivedBytes`, `totalBytes`, `reason`,
    /// `done`. A download outlives its view, untold.
    public var onDownloadProgress: (@ZebkitActor (String) -> Void)? {
        get { handler(.downloadProgress) }
        set { setEvent(.downloadProgress, newValue, zebkit_view_on_download_progress) }
    }

    /// Cancels a download of this view by its `downloadId`. False when it
    /// has ended.
    @discardableResult
    public func cancelDownload(id: String) -> Bool {
        guard let raw else { return false }
        return zebkit_view_cancel_download(raw, id)
    }

    // MARK: Choosers and media

    /// Called with each file chooser a page opens: `<input type=file>` and
    /// the File System Access pickers. Without a handler, the system's
    /// dialog, or cancelled without a display.
    public var onFileChooser: (@ZebkitActor (FileChooserRequest) -> Void)? {
        get { handler(.fileChooser) }
        set { setRequest(.fileChooser, newValue, zebkit_view_on_file_chooser) }
    }

    /// Told how each file chooser request settled, as JSON.
    public var onFileChooserResult: (@ZebkitActor (String) -> Void)? {
        get { handler(.fileChooserResult) }
        set { setEvent(.fileChooserResult, newValue, zebkit_view_on_file_chooser_result) }
    }

    /// Called with each `EyeDropper.open()` of a page. Without a handler it
    /// is cancelled: the engine has no eye dropper.
    public var onEyeDropper: (@ZebkitActor (EyeDropperRequest) -> Void)? {
        get { handler(.eyeDropper) }
        set { setRequest(.eyeDropper, newValue, zebkit_view_on_eye_dropper) }
    }

    /// Told how each eye dropper request settled, as JSON.
    public var onEyeDropperResult: (@ZebkitActor (String) -> Void)? {
        get { handler(.eyeDropperResult) }
        set { setEvent(.eyeDropperResult, newValue, zebkit_view_on_eye_dropper_result) }
    }

    /// Called with each device chooser of a page: `navigator.usb`, `.hid`
    /// and `.serial`'s `requestDevice()` / `requestPort()`. Without a
    /// handler the page gets no device.
    public var onDeviceChooser: (@ZebkitActor (DeviceChooserRequest) -> Void)? {
        get { handler(.deviceChooser) }
        set { setRequest(.deviceChooser, newValue, zebkit_view_on_device_chooser) }
    }

    /// Told how each device chooser request settled, as JSON.
    public var onDeviceChooserResult: (@ZebkitActor (String) -> Void)? {
        get { handler(.deviceChooserResult) }
        set { setEvent(.deviceChooserResult, newValue, zebkit_view_on_device_chooser_result) }
    }

    /// Called with each `navigator.share()` of a page. Without a handler,
    /// the system's share sheet where there is one (macOS), otherwise
    /// cancelled.
    public var onShare: (@ZebkitActor (ShareRequest) -> Void)? {
        get { handler(.share) }
        set { setRequest(.share, newValue, zebkit_view_on_share) }
    }

    /// Told how each share request settled, as JSON.
    public var onShareResult: (@ZebkitActor (String) -> Void)? {
        get { handler(.shareResult) }
        set { setEvent(.shareResult, newValue, zebkit_view_on_share_result) }
    }

    /// Called with each camera or microphone request (`getUserMedia`), in
    /// place of the permission rules for that request; Permissions Policy
    /// still refuses first. Without a handler, the permission rules decide
    /// (`onPermission`). Unanswered requests are refused.
    public var onMediaAccess: (@ZebkitActor (MediaAccessRequest) -> Void)? {
        get { handler(.mediaAccess) }
        set { setRequest(.mediaAccess, newValue, zebkit_view_on_media_access) }
    }

    /// Told how each media access request settled, as JSON.
    public var onMediaAccessResult: (@ZebkitActor (String) -> Void)? {
        get { handler(.mediaAccessResult) }
        set { setEvent(.mediaAccessResult, newValue, zebkit_view_on_media_access_result) }
    }

    // MARK: Keys, menus, fullscreen

    /// Told of each key `setReservedKeys` keeps from the page: `combo`,
    /// `key`, `code`, `autoRepeat`.
    public var onReservedKey: (@ZebkitActor (String) -> Void)? {
        get { handler(.reservedKey) }
        set { setEvent(.reservedKey, newValue, zebkit_view_on_reserved_key) }
    }

    /// With a handler, the engine shows no context menu and tells what was
    /// asked: `x`, `y`, `linkUrl`, `linkText`, `srcUrl`, `mediaType`,
    /// `selectionText`, `editable`, `pageUrl`, `frameUrl`, `frameId`,
    /// `menuId` and `items`, the default menu's (`[{id, title, enabled}]` or
    /// `{separator: true}`). Without one, the engine's default menu where
    /// there is a window.
    public var onContextMenu: (@ZebkitActor (String) -> Void)? {
        get { handler(.contextMenu) }
        set { setEvent(.contextMenu, newValue, zebkit_view_on_context_menu) }
    }

    /// Runs a default item's `command` (its `id` in `onContextMenu`'s
    /// items) against what was right-clicked for menu `menuID`, as it was
    /// then. The last eight menus of a view are kept.
    public func runContextMenuCommand(_ command: String, menu menuID: UInt64) throws {
        guard let raw else { throw ZebkitError("the view is closed") }
        try checked("the context menu's command was refused") { zebkit_view_context_menu_run(raw, menuID, command, $0) }
    }

    /// Shows a menu where menu `menuID` was asked for: `itemsJSON` `nil`
    /// for the default items, or a JSON list mixing default ids (their own
    /// title and state unless given, never more enabled) with the
    /// application's own `{id, title, enabled}`. A default item chosen runs;
    /// one of the application's goes to `chosen` with its id, `""` when the
    /// menu closes with none. `onChoose` is called at most once, and not at
    /// all when a default item is chosen: it is then kept until the view
    /// closes. Throws without a window, and for invalid items.
    public func showContextMenu(
        menu menuID: UInt64, itemsJSON: String? = nil, onChoose chosen: (@ZebkitActor (String) -> Void)? = nil
    ) throws {
        guard let raw else { throw ZebkitError("the view is closed") }
        guard let chosen else {
            try checked("the context menu was refused") { message in
                itemsJSON.withOptionalCString { zebkit_view_context_menu_show(raw, menuID, $0, nil, nil, message) }
            }
            return
        }
        // Kept by the view until chosen from, or until the view closes: the
        // engine calls only while the view is there, and maybe never.
        let hooks = state(HookState.self)
        let box = Box<@ZebkitActor (String) -> Void>({ _ in })
        let key = ObjectIdentifier(box)
        box.value = { [weak hooks] item in
            hooks?.menuChoices[key] = nil
            chosen(item)
        }
        hooks.menuChoices[key] = box
        do {
            try checked("the context menu was refused") { message in
                itemsJSON.withOptionalCString { items in
                    zebkit_view_context_menu_show(raw, menuID, items, { _, item, data in
                        let item = string(borrowing: item) ?? ""
                        let chosen = Box<@ZebkitActor (String) -> Void>.borrow(data)
                        onEngineThread { chosen?(item) }
                    }, box.unretained, message)
                }
            }
        } catch {
            hooks.menuChoices[key] = nil
            throw error
        }
    }

    /// Told when the page enters or leaves fullscreen: `entered`.
    public var onFullscreen: (@ZebkitActor (String) -> Void)? {
        get { handler(.fullscreen) }
        set { setEvent(.fullscreen, newValue, zebkit_view_on_fullscreen) }
    }
}
