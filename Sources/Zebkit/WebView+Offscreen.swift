import CZebkit
import Foundation

/// The off-screen callbacks a view has, kept with the view.
@ZebkitActor
final class OffscreenState: WebViewState {
    var onFrame: (@ZebkitActor (Offscreen.Frame) -> Void)?
    var onCaret: (@ZebkitActor (Offscreen.Rect?) -> Void)?
    var onCursor: (@ZebkitActor (Offscreen.Cursor) -> Void)?
    var onPopup: (@ZebkitActor (Offscreen.Rect?) -> Void)?

    init() {}
}

extension WebView {
    /// The view's off-screen state; `nil` once it is closed, so that nothing
    /// is kept for a closed view.
    private var offscreen: OffscreenState? {
        isClosed ? nil : state(OffscreenState.self)
    }

    // MARK: Making one

    /// A view without a window, loading `url` (`nil` for `about:blank`),
    /// `width` by `height` CSS pixels at `scale` device pixels per CSS pixel
    /// (0 for 1): its frames are `width * scale` by `height * scale` pixels.
    /// Frames start with `onFrame`. In `context`, or in the engine's own
    /// profile. Otherwise it is a view as any other, closed the same way.
    ///
    /// On Linux and macOS it lives beside views with a window, or in a
    /// process without windows (`--headless`); no window of the system's is
    /// made for it, nor for what its pages open. Throws where the engine
    /// makes none: on Windows without `--headless`, and on a Linux process
    /// whose windows are Wayland's, except under `--headless`; and for a
    /// closed `context`.
    public static func offscreen(
        url: String? = nil, width: Int, height: Int, scale: Double = 1, context: WebContext? = nil
    ) throws -> WebView {
        if let context, context.isClosed { throw ZebkitError("the context is closed") }
        guard let raw = zebkit_view_new_offscreen_in(
            context?.raw, url, Int32(clamping: width), Int32(clamping: height), Float(scale))
        else { throw ZebkitError("no off-screen view here: Windows with windows, or Wayland without --headless") }
        return WebView(wrapping: raw)
    }

    /// Whether the view is off-screen.
    public var isOffscreen: Bool {
        guard let raw else { return false }
        return zebkit_view_is_offscreen(raw)
    }

    /// Sets the view's size in CSS pixels and its scale (`nil` keeps it): the
    /// page is laid out again and the next frame has the new size, all of it
    /// damaged.
    public func setSize(width: Int, height: Int, scale: Double? = nil) {
        guard let raw else { return }
        zebkit_view_set_size(raw, Int32(clamping: width), Int32(clamping: height), Float(scale ?? 0))
    }

    // MARK: Frames

    /// Called with each frame of an off-screen view; setting it starts the
    /// frames, `nil` stops them. The frame is released when the last
    /// reference to it goes, or by `Frame.release()` before: keep it only
    /// while it is drawn, or the engine runs out of buffers and holds back
    /// newer frames. Frames that come with no closure set are released at
    /// once.
    public var onFrame: (@ZebkitActor (Offscreen.Frame) -> Void)? {
        get { offscreen?.onFrame }
        set {
            guard let raw, let state = offscreen else { return }
            state.onFrame = newValue
            guard newValue != nil else { return zebkit_view_on_frame(raw, nil, nil) }
            zebkit_view_on_frame(raw, { _, frame, data in
                guard let raw = frame else { return }
                // Taken first: released when the frame object goes, whatever happens.
                let frame = Offscreen.Frame(taking: raw)
                let view = WebView.from(data)
                onEngineThread { view?.offscreen?.onFrame?(frame) }
            }, callbackData)
        }
    }

    /// At most `fps` frames a second; 0 for no limit but the display's (60).
    public func setFrameRate(_ fps: Double) {
        guard let raw else { return }
        zebkit_view_set_frame_rate(raw, fps)
    }

    /// How many frames the application may hold at once, 1 to 8; 2 by
    /// default.
    public func setMaxFramesInFlight(_ count: Int) {
        guard let raw else { return }
        zebkit_view_set_max_frames_in_flight(raw, Int32(clamping: count))
    }

    /// What frames are made in, from the next frame.
    public func setFrameBuffers(_ buffers: Offscreen.FrameBuffers) {
        guard let raw else { return }
        zebkit_view_set_frame_buffers(raw, buffers.raw)
    }

    /// Asks for a frame now, all of it damaged, even if nothing changed: for
    /// an application that lost what it had drawn.
    public func requestFrame() {
        guard let raw else { return }
        zebkit_view_request_frame(raw)
    }

    // MARK: What the page shows

    /// Called with the caret, or the end of the selection, in the view in
    /// CSS pixels, as it moves, for an input method's window; with `nil`
    /// when there is none.
    public var onCaret: (@ZebkitActor (Offscreen.Rect?) -> Void)? {
        get { offscreen?.onCaret }
        set {
            guard let raw, let state = offscreen else { return }
            state.onCaret = newValue
            guard newValue != nil else { return zebkit_view_on_caret(raw, nil, nil) }
            zebkit_view_on_caret(raw, { _, caret, data in
                let caret = caret.map { Offscreen.Rect($0.pointee) }
                let view = WebView.from(data)
                onEngineThread { view?.offscreen?.onCaret?(caret) }
            }, callbackData)
        }
    }

    /// Called with the cursor the page asks for, whenever it changes.
    public var onCursor: (@ZebkitActor (Offscreen.Cursor) -> Void)? {
        get { offscreen?.onCursor }
        set {
            guard let raw, let state = offscreen else { return }
            state.onCursor = newValue
            guard newValue != nil else { return zebkit_view_on_cursor(raw, nil, nil) }
            zebkit_view_on_cursor(raw, { _, name, image, data in
                let name = string(borrowing: name) ?? "default"
                let image = image.map { image -> Offscreen.CursorImage in
                    let image = image.pointee
                    let count = Int(max(image.width, 0)) * Int(max(image.height, 0)) * 4
                    return Offscreen.CursorImage(
                        pixels: Zebkit.data(borrowing: image.pixels, count: count), width: Int(image.width),
                        height: Int(image.height), hotX: Int(image.hot_x), hotY: Int(image.hot_y),
                        scale: Double(image.scale))
                }
                let cursor = Offscreen.Cursor(name: name, image: image)
                let view = WebView.from(data)
                onEngineThread { view?.offscreen?.onCursor?(cursor) }
            }, callbackData)
        }
    }

    /// Called when a popup widget (a `<select>`'s list, a date picker) is
    /// shown over the view, with its place in the view in CSS pixels, and
    /// with `nil` when it is gone. Its frames come to `onFrame` as
    /// `.popup`; the application draws them there over the view's until it
    /// is gone. The input sent over that place goes to it.
    public var onPopup: (@ZebkitActor (Offscreen.Rect?) -> Void)? {
        get { offscreen?.onPopup }
        set {
            guard let raw, let state = offscreen else { return }
            state.onPopup = newValue
            guard newValue != nil else { return zebkit_view_on_popup(raw, nil, nil) }
            zebkit_view_on_popup(raw, { _, shown, bounds, data in
                let bounds = shown ? bounds.map { Offscreen.Rect($0.pointee) } : nil
                let view = WebView.from(data)
                onEngineThread { view?.offscreen?.onPopup?(bounds) }
            }, callbackData)
        }
    }

    // MARK: Input

    /// Sends a mouse event at (`x`, `y`) in the view, CSS pixels from its top
    /// left. `clickCount` is 1 for a click, 2 for a double click, ... for
    /// `.down` and `.up`, 0 otherwise. Over a popup widget it goes to the
    /// widget. A move with a button held has that button in `modifiers`
    /// (`.leftButton`, ...), or as `button`: it drags (a slider's thumb, a
    /// selection, a drag and drop).
    public func sendMouse(
        _ type: Offscreen.MouseEventType, x: Double, y: Double, button: Offscreen.MouseButton = .none,
        clickCount: Int = 0, modifiers: Offscreen.Modifiers = []
    ) {
        guard let raw else { return }
        zebkit_view_send_mouse(
            raw, type.raw, Float(x), Float(y), button.raw, Int32(clamping: clickCount), modifiers.rawValue)
    }

    /// Sends a scroll at (`x`, `y`) by (`deltaX`, `deltaY`) CSS pixels,
    /// positive to the right and down, as the DOM's `WheelEvent` has it.
    /// `precise` for a trackpad's deltas, scrolled as they come; otherwise a
    /// wheel's notches, scrolled smoothly.
    public func sendWheel(
        x: Double, y: Double, deltaX: Double, deltaY: Double, precise: Bool = false,
        phase: Offscreen.WheelPhase = .none, modifiers: Offscreen.Modifiers = []
    ) {
        guard let raw else { return }
        zebkit_view_send_wheel(
            raw, Float(x), Float(y), Float(deltaX), Float(deltaY), precise, phase.raw, modifiers.rawValue)
    }

    /// Sends a key to the focused element, or to the open popup widget.
    public func sendKey(_ event: Offscreen.KeyEvent) {
        guard let raw else { return }
        event.withRaw { zebkit_view_send_key(raw, $0) }
    }

    /// Sends a `.down` key with the native key-binding commands the system
    /// resolved for it (`MoveWordLeft`, `DeleteBackward`, `SelectAll`), in
    /// place of a second key event. They run with the key, after its DOM
    /// `keydown`, so the page's `preventDefault()` suppresses them too;
    /// unknown commands do nothing. False for a closed view, a key that is
    /// not `.down`, a command without a name, or more than 128 commands.
    @discardableResult
    public func sendKey(_ event: Offscreen.KeyEvent, commands: [Offscreen.EditCommand]) -> Bool {
        guard let raw else { return false }
        // Copies the C strings live in for the call.
        let names = commands.map { strdup($0.name) }
        let values = commands.map { $0.value.map { strdup($0) } ?? nil }
        defer {
            names.forEach { free($0) }
            values.forEach { free($0) }
        }
        let list = zip(names, values).map { zebkit_edit_command(name: $0, value: $1) }
        return event.withRaw { event in
            list.withUnsafeBufferPointer { zebkit_view_send_key_with_commands(raw, event, $0.baseAddress, $0.count) }
        }
    }

    /// Sets an input method's composition: `text` in the focused field,
    /// underlined, not yet typed, with `selection` in it (UTF-16 code units;
    /// an empty range is a caret; `nil` for a caret at its end). Call it again
    /// as the composition changes.
    public func setComposition(_ text: String, selection: Range<Int>? = nil) {
        guard let raw else { return }
        zebkit_view_ime_set_composition(
            raw, text, Int32(clamping: selection?.lowerBound ?? -1), Int32(clamping: selection?.upperBound ?? -1))
    }

    /// Types `text` in place of the composition, or at the caret when there
    /// is none.
    public func commitText(_ text: String) {
        guard let raw else { return }
        zebkit_view_ime_commit(raw, text)
    }

    /// Takes the composition away, typing nothing.
    public func cancelComposition() {
        guard let raw else { return }
        zebkit_view_ime_cancel(raw)
    }

    /// Gives the view the keyboard, or takes it: the focused element, the
    /// blinking caret, `:focus` and focus events, as when its window is
    /// active. An off-screen view starts without it.
    public func setFocus(_ focused: Bool) {
        guard let raw else { return }
        zebkit_view_set_focus(raw, focused)
    }
}
