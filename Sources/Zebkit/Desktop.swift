import CZebkit
import Foundation

/// What the system says of itself and does for the application: its
/// appearance settings, power and screens, sleep, notifications, and the
/// programs that open URLs and show files. On the engine's thread, while it
/// runs.
///
/// The events are process-wide: one closure each, set again to replace it,
/// `nil` to stop. Their JSON is copied out of the engine's for the call.
@ZebkitActor
public enum Desktop {
    // MARK: Appearance

    /// What the system says of how things should look, as JSON:
    /// `{"colorScheme": "light" | "dark", "contrast": "no-preference" |
    /// "more" | "less" | "custom", "forcedColors", "reducedTransparency",
    /// "invertedColors", "locale", "following"}`. Pages follow the system
    /// with the startup setting `appearance.follow`. `nil` when the engine
    /// does not answer. The engine never changes the system's settings.
    public static var environmentJSON: String? {
        string(taking: zebkit_get_environment())
    }

    /// Called with `environmentJSON`'s new value when the system's
    /// settings change.
    public static var onEnvironmentChange: (@ZebkitActor (String) -> Void)? {
        didSet {
            guard onEnvironmentChange != nil else { return zebkit_on_environment_changed(nil, nil) }
            zebkit_on_environment_changed({ json, _ in
                let json = string(borrowing: json) ?? "{}"
                onEngineThread { Desktop.onEnvironmentChange?(json) }
            }, nil)
        }
    }

    // MARK: Other programs

    /// Has the system's handler open `url`: a browser for `https:`, the mail
    /// program for `mailto:`, the default program of a `file:` URL. The URL
    /// is one argument to the system, never a shell's. For the application:
    /// pages reach none of it.
    ///
    /// Throws for `javascript:`, `data:`, `blob:`, `about:` and invalid
    /// URLs, and where the system cannot.
    public static func openExternal(_ url: String) throws {
        try checked("\(url) could not be opened") { zebkit_open_external(url, $0) }
    }

    /// Has the file manager show `file` selected in its folder. Throws for a
    /// relative path, and where the system cannot.
    public static func showInFolder(_ file: URL) throws {
        try checked("\(file.path) could not be shown") { zebkit_show_in_folder(file.path, $0) }
    }

    // MARK: Power and screens

    /// Called with what the system tells of its power and the session's
    /// lock, as JSON: `{"event": "suspend"}`, `{"event": "resume"}`,
    /// `{"event": "power-source", "onBattery": true}`, `{"event": "lock"}`
    /// and `{"event": "unlock"}` (the lock is checked each second).
    public static var onPowerEvent: (@ZebkitActor (String) -> Void)? {
        didSet {
            guard onPowerEvent != nil else { return zebkit_on_power_event(nil, nil) }
            zebkit_on_power_event({ json, _ in
                let json = string(borrowing: json) ?? "{}"
                onEngineThread { Desktop.onPowerEvent?(json) }
            }, nil)
        }
    }

    /// The screens, as a JSON array: `[{id, bounds, workArea, scale,
    /// rotation, primary}]`, in DIPs. `nil` when the engine does not answer.
    public static var displaysJSON: String? {
        string(taking: zebkit_get_displays())
    }

    /// Called when the screens change, with
    /// `{"event": "displays", "displays": [...]}`.
    public static var onDisplaysChange: (@ZebkitActor (String) -> Void)? {
        didSet {
            guard onDisplaysChange != nil else { return zebkit_on_displays_changed(nil, nil) }
            zebkit_on_displays_changed({ json, _ in
                let json = string(borrowing: json) ?? "{}"
                onEngineThread { Desktop.onDisplaysChange?(json) }
            }, nil)
        }
    }

    // MARK: Sleep

    /// Keeps the system from sleeping, and with `keepDisplayOn` its display
    /// on, for the application, until the returned prevention is released
    /// or the engine ends. `reason` is what the system shows for it. Pages
    /// have the Wake Lock API for their own. Throws when the system refuses.
    public static func preventSleep(reason: String, keepDisplayOn: Bool = false) throws -> SleepPrevention {
        let token = zebkit_prevent_sleep(keepDisplayOn, reason)
        guard token != 0 else { throw ZebkitError("the system's sleep could not be prevented") }
        return SleepPrevention(token: token)
    }

    // MARK: Notifications

    /// Web notifications (`new Notification()`, a service worker's
    /// `showNotification()`) shown by the application in place of the
    /// system. A page needs the `"notifications"` permission for them,
    /// which is denied by default.
    ///
    /// The closure gets `{"event": "show", id, persistent, origin, title,
    /// body, icon, image, badge, tag, lang, silent, requireInteraction,
    /// renotify, actions: [{action, title}]}`, and `{"event": "close", id}`
    /// when the page closes one. The application tells what the person did
    /// with `notificationClicked(id:action:)` and
    /// `notificationClosed(id:byUser:)`.
    ///
    /// With `nil` the system shows them where it can:
    /// org.freedesktop.Notifications on Linux, the UserNotifications
    /// framework on macOS (for an application with a bundle identifier).
    public static var onNotification: (@ZebkitActor (String) -> Void)? {
        didSet {
            guard onNotification != nil else { return zebkit_on_notification(nil, nil) }
            zebkit_on_notification({ json, _ in
                let json = string(borrowing: json) ?? "{}"
                onEngineThread { Desktop.onNotification?(json) }
            }, nil)
        }
    }

    /// Tells the page that the person clicked notification `id`: on one of
    /// its actions (an index into its `actions`), or with `nil` on the
    /// notification itself. It reaches the page's `onclick` and its service
    /// worker's `notificationclick`. False for an unknown notification.
    @discardableResult
    public static func notificationClicked(id: String, action: Int? = nil) -> Bool {
        zebkit_notification_clicked(id, action.map { Int32(clamping: $0) } ?? -1)
    }

    /// Tells the page that notification `id` closed, by the person or not.
    /// It reaches the page's `onclose` and its service worker's
    /// `notificationclose`. False for an unknown notification.
    @discardableResult
    public static func notificationClosed(id: String, byUser: Bool) -> Bool {
        zebkit_notification_closed(id, byUser)
    }
}

/// The system kept from sleeping, from `Desktop.preventSleep`, until
/// `release()`. One that is let go of unreleased is released then, on the
/// engine's thread.
@ZebkitActor
public final class SleepPrevention {
    /// The engine's token for it.
    let token: UInt64

    // Read by `deinit`, which is the last to have the object.
    private nonisolated(unsafe) var released = false

    init(token: UInt64) {
        self.token = token
    }

    /// Whether `release()` has been called.
    public var isReleased: Bool { released }

    /// Lets the system sleep again, unless something else keeps it awake.
    /// False when it was already released, or the engine knew no such token.
    @discardableResult
    public func release() -> Bool {
        guard !released else { return false }
        released = true
        return zebkit_allow_sleep(token)
    }

    deinit {
        guard !released else { return }
        let token = token
        Engine.post { zebkit_allow_sleep(token) }
    }
}
