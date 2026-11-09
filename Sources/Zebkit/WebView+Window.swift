import CZebkit
import Foundation

// <zebkit/window.h>: a view's window made with options, its state, what it is
// asked to do, and where the person drags it from. Coordinates are DIPs: the
// content area's from its top left, the screen's for a window's position.

/// What a view's window is asked to do (`WebView.performWindowAction(_:)`).
public enum WindowAction: String, Sendable, CaseIterable {
    case show
    case hide
    case minimize
    case maximize
    case restore
    case fullscreen
    case exitFullscreen = "exit-fullscreen"
    /// Closes the view, `beforeunload` first, as `requestClose()` does.
    case close
}

/// A rectangle of a view's content the person drags its window by, or (with
/// `drag` false) does not, for `WebView.setDragRegions(_:)`.
public struct DragRegion: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Whether the window is dragged from here; false cuts a hole in an
    /// earlier region.
    public var drag: Bool

    public init(x: Double, y: Double, width: Double, height: Double, drag: Bool = true) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.drag = drag
    }
}

extension WebView {
    /// A view loading `url` (`nil` for none), in `context` or the engine's
    /// own profile, whose window is made with `windowOptionsJSON` before
    /// the system's window exists, so that its first frame is as
    /// configured. Every option is optional: `width`, `height`,
    /// `minWidth`, `minHeight`, `resizable`, `x`, `y`, `title`, `frame`
    /// (`"system"`, `"overlay"`, `"none"`), `controls` (`{height, color,
    /// symbolColor}`), `background` (`"#rrggbb"`), `appearance` (`"system"`,
    /// `"light"`, `"dark"`), `show`, `pageFullscreen` (`"window"`,
    /// `"content"`), `dragRegions` (`{source: "none" | "css" | "host",
    /// origins: [...]}`), `fallback` (`"error"`, `"system"`). `width`,
    /// `height`, `frame`, `show` and `fallback` are fixed once it is made.
    ///
    /// Throws for invalid options, and for a frame the system cannot give
    /// unless `fallback` is `"system"`.
    public convenience init(url: String? = nil, windowOptionsJSON: String, context: WebContext? = nil) throws {
        var message: UnsafeMutablePointer<CChar>?
        if let context, context.isClosed { throw ZebkitError("the context is closed") }
        guard let raw = zebkit_view_new_with_options(context?.raw, url, windowOptionsJSON, &message) else {
            throw error(taking: message, otherwise: "the view could not be made")
        }
        zebkit_free(message)
        self.init(wrapping: raw)
    }

    /// The window's state as JSON: `revision`, `owner` (`"engine"`,
    /// `"application"`, `"none"`), `state` (`"normal"`, `"minimized"`,
    /// `"maximized"`, `"fullscreen"`), `pageFullscreen`, `visible`,
    /// `focused`, `bounds`, `content`, `scale`, `frame` (`{requested,
    /// effective}`), `titlebarArea`, `controls`, `capabilities`, `options`.
    /// `nil` for a closed view.
    public var windowStateJSON: String? {
        guard let raw else { return nil }
        return string(taking: zebkit_view_get_window(raw))
    }

    /// Changes the window's options, merged by key, applied whole or not at
    /// all; those fixed once it is made (`width`, `height`, `frame`, `show`,
    /// `fallback`) throw `"requires-recreate"`.
    public func setWindowOptions(json: String) throws {
        guard let raw else { throw ZebkitError("the view is closed") }
        try checked("the window options were refused") { zebkit_view_set_window(raw, json, $0) }
    }

    /// Asks the system to do `action` to the window. What happened comes to
    /// `onWindowState`. Throws where the action is not supported, for a view
    /// in a window that is not the engine's, and for a closed view.
    public func performWindowAction(_ action: WindowAction) throws {
        guard let raw else { throw ZebkitError("the view is closed") }
        try checked("the window action was refused") { zebkit_view_window_action(raw, action.rawValue, $0) }
    }

    /// Told of every change of `windowStateJSON`, in the order of its revision,
    /// whatever caused it; the resizes of a live resize coalesced to one a
    /// frame.
    public var onWindowState: (@ZebkitActor (String) -> Void)? {
        get { handler(.windowState) }
        set { setEvent(.windowState, newValue, zebkit_view_on_window_state) }
    }

    /// Where the window is dragged from, with the option `dragRegions`'s
    /// `source` `"host"`: in content DIPs, later over earlier, at most 1024;
    /// `[]` for none. A drag starts only from the person's own press.
    public func setDragRegions(_ regions: [DragRegion]) throws {
        guard let raw else { throw ZebkitError("the view is closed") }
        let json = try JSON.encode(regions)
        try checked("the drag regions were refused") { zebkit_view_set_drag_regions(raw, json, $0) }
    }

    /// Options for the windows this view's pages open from now on
    /// (`window.open`, `target=_blank`): those of `init(url:windowOptionsJSON:)`
    /// but `dragRegions`. `nil`: the system's frame.
    public func setPopupWindowOptions(json: String?) throws {
        guard let raw else { throw ZebkitError("the view is closed") }
        try checked("the popup window options were refused") { message in
            json.withOptionalCString { zebkit_view_set_popup_window_options(raw, $0, message) }
        }
    }
}

extension Engine {
    /// What this build can do on this system and display, as JSON:
    /// `{"window": {"frames", "position", "actions", "controlsDrawnByEngine",
    /// "controlsHeight"}, "headless", "platform"}`. A window's own state has
    /// capabilities too, which win. `nil` when the engine cannot say.
    @ZebkitActor
    public static var capabilitiesJSON: String? {
        string(taking: zebkit_get_capabilities())
    }
}
