import CZebkit
import Foundation

/// The application as the system sees it: its menu, its icon in the Dock or
/// on the taskbar, the files it is asked to open, and the person's request
/// to quit. On the engine's thread, while it runs.
///
/// A menu is JSON: `[{"title": "File", "items": [...]}, ...]`, where an item
/// is
/// - `{"title": "Open…", "id": "open", "key": "o", "modifiers": ["shift"]}`:
///   the menu's closure gets `"open"` when it is chosen;
/// - `{"role": "undo"}`: a standard command, which also takes `"title"`
///   (roles: undo, redo, cut, copy, paste, pasteAndMatchStyle, selectAll,
///   minimize, zoom, close, fullscreen, front, quit, hide, hideOthers,
///   showAll, about, services);
/// - `{"title": "Zoom", "items": [...]}`: a submenu; or
/// - `{"separator": true}`.
///
/// Items also take `"enabled"` (default true), `"checked"` (default false)
/// and `"radioGroup"` (one checked item in a group). `"key"` is with the
/// command key, ⌘ on macOS and Ctrl elsewhere: a character, or `"f1"` to
/// `"f24"`; `"modifiers"` adds `"shift"`, `"alt"` and `"ctrl"` (Control, on
/// macOS).
@ZebkitActor
public enum Application {
    // MARK: The menu

    /// Makes `json` the application's menu, and calls `onChoose` with the id
    /// of an item chosen from it; again to change it. Throws for a menu the
    /// engine refuses.
    ///
    /// On macOS it is the menu bar, after the application menu zebkit makes
    /// (About, Services, Hide, Quit), unless the first menu is
    /// `{"role": "appMenu", "items": [...]}`, which takes its place; the
    /// window menu is the menu titled "Window". Elsewhere, where windows have
    /// no menu bar, the items' keys work the same in the application's
    /// windows when the page does not take them.
    public static func setMenu(json: String, onChoose: (@ZebkitActor (String) -> Void)? = nil) throws {
        let previous = menuHandler
        menuHandler = onChoose
        do {
            try checked("the menu was refused") {
                zebkit_app_set_menu(json, { id, _ in
                    let id = string(borrowing: id) ?? ""
                    onEngineThread { Application.menuHandler?(id) }
                }, nil, $0)
            }
        } catch {
            menuHandler = previous
            throw error
        }
    }

    private static var menuHandler: (@ZebkitActor (String) -> Void)?

    /// Changes every item of the menu with `id`, without a new menu: `json`
    /// is `{"enabled", "checked", "title"}`, any of them. Checking one of a
    /// radio group unchecks the others. A disabled item is not chosen, nor
    /// its key taken. Throws for an unknown item or malformed JSON.
    public static func updateMenuItem(id: String, json: String) throws {
        try checked("the menu item \(id) could not be changed") { zebkit_app_update_menu_item(id, json, $0) }
    }

    /// The menu with its items' current state, as JSON; `nil` when there is
    /// none.
    public static var menuJSON: String? {
        string(taking: zebkit_app_get_menu())
    }

    // MARK: Files and the person

    /// Called with files the system asks the running application to open:
    /// on macOS from the Finder or the Dock, also the ones it was started
    /// with, which are kept until this is set. Elsewhere they are program
    /// arguments.
    public static var onOpenFiles: (@ZebkitActor ([URL]) -> Void)? {
        didSet {
            guard onOpenFiles != nil else { return zebkit_app_on_open_files(nil, nil) }
            zebkit_app_on_open_files({ json, _ in
                let paths = string(borrowing: json).flatMap { try? JSON.decode([String].self, from: $0) } ?? []
                let files = paths.map { URL(fileURLWithPath: $0) }
                onEngineThread { Application.onOpenFiles?(files) }
            }, nil)
        }
    }

    /// Called when the application's icon in the Dock is clicked while no
    /// window is shown (macOS).
    public static var onReopen: (@ZebkitActor () -> Void)? {
        didSet {
            guard onReopen != nil else { return zebkit_app_on_reopen(nil, nil) }
            zebkit_app_on_reopen({ _ in
                onEngineThread { Application.onReopen?() }
            }, nil)
        }
    }

    /// Called when the person asks the application to quit (⌘Q, the Dock,
    /// logging out, on macOS): the closure decides, calling `Engine.quit()`
    /// or not. With `nil` zebkit quits.
    public static var onQuitRequest: (@ZebkitActor () -> Void)? {
        didSet {
            guard onQuitRequest != nil else { return zebkit_app_on_quit_request(nil, nil) }
            zebkit_app_on_quit_request({ _ in
                onEngineThread { Application.onQuitRequest?() }
            }, nil)
        }
    }

    // MARK: The icon in the Dock or on the taskbar

    // On macOS the Dock; on Windows the taskbar; on Linux a dock that knows
    // the launcher API (com.canonical.Unity.LauncherEntry, with a desktop
    // file named after the program).

    /// The badge on the application's icon; `nil` (or `""`) for none. A
    /// number on Linux. False where the system has no place for it.
    @discardableResult
    public static func setBadge(_ text: String?) -> Bool {
        zebkit_app_set_badge(text ?? "")
    }

    /// A progress on the application's icon, from 0 to 1; `nil` for none.
    /// False where the system has no place for it.
    @discardableResult
    public static func setProgress(_ progress: Double?) -> Bool {
        zebkit_app_set_progress(progress ?? -1)
    }

    /// Asks for the person's attention: the Dock's bounce, the taskbar
    /// button's flash; `critical` until the application is active.
    public static func requestAttention(critical: Bool = false) {
        zebkit_app_request_attention(critical)
    }

    /// Makes `json` the Dock's menu (macOS only), with the items of
    /// `setMenu(json:onChoose:)`; `onChoose` gets a chosen item's id. Throws
    /// for a menu the engine refuses, and where there is no Dock.
    public static func setDockMenu(json: String, onChoose: (@ZebkitActor (String) -> Void)? = nil) throws {
        let previous = dockMenuHandler
        dockMenuHandler = onChoose
        do {
            try checked("the Dock's menu was refused") {
                zebkit_app_set_dock_menu(json, { id, _ in
                    let id = string(borrowing: id) ?? ""
                    onEngineThread { Application.dockMenuHandler?(id) }
                }, nil, $0)
            }
        } catch {
            dockMenuHandler = previous
            throw error
        }
    }

    private static var dockMenuHandler: (@ZebkitActor (String) -> Void)?
}

/// The application's icon in the system's tray: the menu bar on macOS, the
/// notification area on Windows, a StatusNotifierItem on Linux (a desktop
/// without a host for those shows none). On the engine's thread.
///
/// It stays until `close()`. One that is let go of open is closed then, on
/// the engine's thread.
@ZebkitActor
public final class Tray {
    // Read by `deinit`, which is the last to have the object.
    private nonisolated(unsafe) var raw: OpaquePointer?

    /// What the engine calls, kept for as long as it may.
    private final class Handlers {
        var onClick: (@ZebkitActor () -> Void)?
        var onChoose: (@ZebkitActor (String) -> Void)?
    }

    private nonisolated(unsafe) let handlers = Handlers()

    /// An icon from `png`, a PNG of at most 1024 by 1024 (a template image on
    /// macOS: its shape, in the menu bar's colour), with `tooltip`. Throws
    /// for a picture the engine cannot use.
    public init(png: Data, tooltip: String? = nil) throws {
        var message: UnsafeMutablePointer<CChar>?
        let raw = png.withUnsafeBytes { bytes in
            zebkit_tray_new(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, tooltip, &message)
        }
        guard let raw else { throw error(taking: message, otherwise: "the tray icon could not be made") }
        zebkit_free(message)
        self.raw = raw
    }

    deinit {
        guard let raw else { return }
        // The handlers go after the icon that calls them.
        nonisolated(unsafe) let handle = raw
        nonisolated(unsafe) let handlers = handlers
        Engine.post {
            zebkit_tray_close(handle)
            _ = handlers
        }
    }

    /// Whether `close()` has been called.
    public var isClosed: Bool { raw == nil }

    /// Removes the icon from the tray.
    public func close() {
        guard let raw else { return }
        self.raw = nil
        zebkit_tray_close(raw)
    }

    /// Changes the picture, a PNG as for `init`. Throws for a picture the
    /// engine cannot use, and once closed.
    public func setIcon(png: Data) throws {
        guard let raw else { throw ZebkitError("the tray icon is closed") }
        try checked("the tray icon could not be changed") { message in
            png.withUnsafeBytes { bytes in
                zebkit_tray_set_icon(raw, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, message)
            }
        }
    }

    /// Changes the tooltip; `nil` for none.
    public func setTooltip(_ tooltip: String?) {
        guard let raw else { return }
        zebkit_tray_set_tooltip(raw, tooltip)
    }

    /// Makes `json` the icon's menu, with the items of
    /// `Application.setMenu(json:onChoose:)`, `enabled`, `checked` and
    /// `radioGroup` included; `onChoose` gets a chosen item's id. On macOS,
    /// with a menu, a click on the icon opens it. Throws for a menu the
    /// engine refuses, and once closed.
    public func setMenu(json: String, onChoose: (@ZebkitActor (String) -> Void)? = nil) throws {
        guard let raw else { throw ZebkitError("the tray icon is closed") }
        let previous = handlers.onChoose
        handlers.onChoose = onChoose
        do {
            try checked("the tray's menu was refused") {
                zebkit_tray_set_menu(raw, json, { id, data in
                    let id = string(borrowing: id) ?? ""
                    let handlers = Tray.handlers(data)
                    onEngineThread { handlers?.onChoose?(id) }
                }, Unmanaged.passUnretained(handlers).toOpaque(), $0)
            }
        } catch {
            handlers.onChoose = previous
            throw error
        }
    }

    /// Called when the icon is clicked; on macOS, with a menu, a click opens
    /// the menu instead.
    public var onClick: (@ZebkitActor () -> Void)? {
        get { handlers.onClick }
        set {
            handlers.onClick = newValue
            guard let raw else { return }
            guard newValue != nil else { return zebkit_tray_on_click(raw, nil, nil) }
            zebkit_tray_on_click(raw, { data in
                let handlers = Tray.handlers(data)
                onEngineThread { handlers?.onClick?() }
            }, Unmanaged.passUnretained(handlers).toOpaque())
        }
    }

    private nonisolated static func handlers(_ data: UnsafeMutableRawPointer?) -> Handlers? {
        data.map { Unmanaged<Handlers>.fromOpaque($0).takeUnretainedValue() }
    }
}
