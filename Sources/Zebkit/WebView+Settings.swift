import CZebkit
import Foundation

// The policies of <zebkit/hooks.h> that the application sets on a view or on
// the engine: web preferences, runtime settings, permission rules, popups,
// fullscreen, reserved keys and world scripts.

/// Which `window.open` calls a view's pages may make.
public enum PopupPolicy: Sendable {
    /// Only from a user gesture, as Chrome: the default.
    case blockWithoutGesture
    case allow
    case block

    init?(_ policy: zebkit_popup_policy) {
        switch policy {
        case ZEBKIT_POPUP_POLICY_BLOCK_WITHOUT_GESTURE: self = .blockWithoutGesture
        case ZEBKIT_POPUP_POLICY_ALLOW: self = .allow
        case ZEBKIT_POPUP_POLICY_BLOCK: self = .block
        default: return nil
        }
    }

    var raw: zebkit_popup_policy {
        switch self {
        case .blockWithoutGesture: ZEBKIT_POPUP_POLICY_BLOCK_WITHOUT_GESTURE
        case .allow: ZEBKIT_POPUP_POLICY_ALLOW
        case .block: ZEBKIT_POPUP_POLICY_BLOCK
        }
    }
}

/// Whether a view's pages may go fullscreen.
public enum FullscreenPolicy: Sendable {
    /// The default.
    case allow
    case deny

    var raw: zebkit_fullscreen_policy {
        switch self {
        case .allow: ZEBKIT_FULLSCREEN_ALLOW
        case .deny: ZEBKIT_FULLSCREEN_DENY
        }
    }
}

extension WebView {
    // MARK: Web preferences

    /// Merges `json`, validated web preferences, into the view's: `null`
    /// removes an override, `{}` does nothing, and invalid input changes
    /// nothing and throws. They apply to every frame, to the documents there
    /// are and to later navigations. The fields are those of upstream's
    /// `docs/ROADMAP_HOOKS.md`.
    public func setSettings(json: String) throws {
        guard let raw else { throw ZebkitError("the view is closed") }
        try checked("the settings were refused") { zebkit_view_set_settings(raw, json, $0) }
    }

    /// The web preferences set with `setSettings(json:)`, as JSON (not CDP's
    /// temporary emulation); `nil` for a closed view.
    public var settingsJSON: String? {
        guard let raw else { return nil }
        return string(taking: zebkit_view_get_settings(raw))
    }

    // MARK: Runtime settings

    /// Merges `json` into the view's runtime settings, which go to its
    /// context, all the views in it, over the engine's
    /// (`Engine.setRuntimeSettings(json:)`): `thirdPartyCookies` (`"block"`,
    /// `"allow"`), `dialogs` (`"default"`, `"hold"`, `"accept"`,
    /// `"dismiss"`), `downloads` (`"save"`, `"deny"`), `newWindows`
    /// (`"block-without-gesture"`, `"allow"`, `"block"`). `null` removes a
    /// value, `{}` does nothing. An unknown key, a bad value or a wrong type
    /// throws, and nothing of the batch changes. A page never has these.
    public func setRuntimeSettings(json: String) throws {
        guard let raw else { throw ZebkitError("the view is closed") }
        try checked("the runtime settings were refused") { zebkit_view_set_runtime_settings(raw, json, $0) }
    }

    /// The view's runtime settings: `{"explicit": what was set,
    /// "effective": what holds}`, where `downloads` is also `"ask"` while
    /// `onDownload` decides, and `"deny"` for a popup whose opener has
    /// closed. `nil` for a closed view.
    public var runtimeSettingsJSON: String? {
        guard let raw else { return nil }
        return string(taking: zebkit_view_get_runtime_settings(raw))
    }

    // MARK: Permission rules

    /// Sets the view's rule for `permission` (`geolocation`,
    /// `notifications`, `camera`, `microphone`, `clipboard-read`,
    /// `clipboard-write`, `screen-wake-lock`, ...) for `origin`: a URL that
    /// is not opaque, of which the origin is taken, `"*"` for the view's
    /// default, or `nil` for the current document's origin. The page's
    /// `navigator.permissions` is told. Invalid input changes nothing and
    /// throws. A later change of the context's or CDP's takes precedence in
    /// its own scope.
    public func setPermission(_ permission: String, to state: PermissionState, for origin: String? = nil) throws {
        guard let raw else { throw ZebkitError("the view is closed") }
        try checked("the permission was refused") { message in
            origin.withOptionalCString { zebkit_view_set_permission(raw, $0, permission, state.raw, message) }
        }
    }

    /// The view's policy for `permission` for `origin`, a concrete origin,
    /// or `nil` for the current document's; `nil` for invalid input and a
    /// closed view. The document's own security and Permissions Policy
    /// still apply on top of it.
    public func permission(_ permission: String, for origin: String? = nil) -> PermissionState? {
        guard let raw else { return nil }
        return PermissionState(origin.withOptionalCString { zebkit_view_get_permission(raw, $0, permission) })
    }

    /// Clears the view's permission rules: all of them for `nil`, the
    /// defaults only for `"*"`, otherwise that origin's. Rules of the
    /// context or of CDP stay.
    public func resetPermissions(for origin: String? = nil) throws {
        guard let raw else { throw ZebkitError("the view is closed") }
        try checked("the permissions were not reset") { message in
            origin.withOptionalCString { zebkit_view_reset_permissions(raw, $0, message) }
        }
    }

    // MARK: Popups and fullscreen

    /// The policy for `window.open`. Setting it applies to later calls at
    /// once, over `--disable-popup-blocking`. A closed view reads
    /// `.blockWithoutGesture` and takes no change.
    public var popupPolicy: PopupPolicy {
        get { raw.flatMap { PopupPolicy(zebkit_view_get_popup_policy($0)) } ?? .blockWithoutGesture }
        set { if let raw { _ = zebkit_view_set_popup_policy(raw, newValue.raw) } }
    }

    /// Whether a page may go fullscreen. Denying takes a page that is
    /// fullscreen out of it. A popup takes its opener's policy until it has
    /// its own, and is denied once that opener has closed. A page goes
    /// fullscreen only from a user gesture in a view with focus. False for a
    /// closed view.
    @discardableResult
    public func setFullscreenPolicy(_ policy: FullscreenPolicy) -> Bool {
        guard let raw else { return false }
        return zebkit_view_set_fullscreen_policy(raw, policy.raw)
    }

    // MARK: Keys and scripts

    /// Keys the page does not get, as `"Ctrl+Shift+KeyI"`: modifiers `Ctrl`,
    /// `Alt`, `Shift`, `Meta` and a `KeyboardEvent.code`; `[]` clears. At
    /// most 256; invalid input changes nothing and throws. The page still
    /// sees the key's keyup. Each is told to `onReservedKey`. A popup takes
    /// its opener's keys until it has its own.
    public func setReservedKeys(_ keys: [String]) throws {
        guard let raw else { throw ZebkitError("the view is closed") }
        let json = try JSON.encode(keys)
        try checked("the reserved keys were refused") { zebkit_view_set_reserved_keys(raw, json, $0) }
    }

    /// Runs `source` before the page's own script in every new document, and
    /// at once in those there are. `world` `nil` or empty is the page's
    /// world; a name is an isolated world, one per name, sharing the DOM and
    /// not the globals. Chromium gives such a world universal access: it can
    /// read other origins. `mainFrameOnly` false runs it in every frame,
    /// other sites' too; true wraps it in a block, so that its top-level
    /// `let`, `const` and `class` are not global.
    public func addWorldScript(_ source: String, world: String? = nil, mainFrameOnly: Bool = true) throws {
        guard let raw else { throw ZebkitError("the view is closed") }
        try checked("the script was refused") { message in
            world.withOptionalCString { zebkit_view_add_world_script(raw, $0, source, mainFrameOnly, message) }
        }
    }
}

extension Engine {
    /// Merges `json` into the engine's runtime settings, which go to every
    /// context, now and later, under a view's own
    /// (`WebView.setRuntimeSettings(json:)`): the view's keys, and
    /// `spareRenderer` (`true`, `false`: a renderer made ready once a page
    /// has loaded, for the next navigation to another site) and
    /// `clientCertificateStores` (the system's certificate stores offered
    /// to `onClientCertificate`). `null` removes a value, `{}` does nothing.
    /// An unknown key, a bad value or a wrong type throws, and nothing of
    /// the batch changes.
    @ZebkitActor
    public static func setRuntimeSettings(json: String) throws {
        try checked("the engine's settings were refused") { zebkit_set_engine_settings(json, $0) }
    }

    /// The engine's runtime settings: `{"explicit", "effective"}`, and
    /// `spareRendererRunning`. `nil` when the engine is not running.
    @ZebkitActor
    public static var runtimeSettingsJSON: String? {
        string(taking: zebkit_get_engine_settings())
    }
}
