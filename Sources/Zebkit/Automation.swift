import CZebkit
import Foundation

/// Playwright's API, run inside the engine (zebkit's `docs/AUTOMATION.md`):
/// a view's page driven as Playwright drives one, with selectors and
/// locators (CSS, `text=`, `role=`, `internal:role=button[name="Go"i]`),
/// actions that wait until the element is visible, enabled, stable and the
/// one under the point, keyboard and mouse, and navigation that waits for
/// the page to load. No CDP, no driver process. On the engine's thread.
///
/// Each command is one of Playwright's protocol (the `.yml` files of
/// `packages/protocol/spec` in Playwright's source), with its name, its
/// parameters as a JSON object and its result as one:
///
///     _ = try await Automation.call("Frame.goto", on: view, json: #"{"url": "https://example.com/"}"#)
///     _ = try await Automation.call("Frame.click", on: view, json: #"{"selector": "#go", "strict": true}"#)
///     let text = try await Automation.call("Frame.textContent", on: view, json: #"{"selector": "#out"}"#)
///
/// Where zebkit differs from the protocol: an evaluation's `"arg"` and
/// `"value"` are plain JSON, not Playwright's serialized values; binary
/// results (`"binary"` of `Page.screenshot`) are base64; `Page.screenshot`
/// also takes `"path"`, a file to write instead.
@ZebkitActor
public enum Automation {
    /// The commands this engine has, by name.
    public static var commands: [String] {
        string(taking: zebkit_automation_commands()).flatMap { try? JSON.decode([String].self, from: $0) } ?? []
    }

    /// Runs Playwright's command `method` with `json`, its parameters as a
    /// JSON object (`nil` for `{}`), and returns its result as a JSON
    /// object; throws Playwright's message (`"Timeout 30000ms
    /// exceeded.\nCall log: ..."`, `"strict mode violation: ..."`).
    ///
    /// With `view`, on that view's page: a command acts on the main frame
    /// unless `json` has `"frame"`. Without, a command that names no view:
    /// `Browser.newContext` (answering `{"context": "x1"}`) and a context's
    /// (`BrowserContext.newPage`, `.pages`, `.close`, with its
    /// `"context"`). Commands that wait take `"timeout"` in milliseconds
    /// (30000 by default, 0 for none). Several may run at once.
    @discardableResult
    public static func call(_ method: String, on view: WebView? = nil, json: String? = nil) async throws -> String {
        var raw: OpaquePointer?
        if let view {
            guard let viewRaw = view.raw else { throw ZebkitError("the view is closed") }
            raw = viewRaw
        }
        return try await withResult { zebkit_automation_call(raw, method, json, $0, $1) }
    }

    /// The picture `Page.screenshot` (or `ElementHandle.screenshot` with
    /// the element's `"handle"` in `json`) takes of `view`'s page, as its
    /// pixels, not a PNG: zebkit's own, beyond Playwright's API. `json` is
    /// the command's parameters (`clip`, `fullPage`, `scale`, `animations`,
    /// `caret`, `mask`, `maskColor`, `style`, `omitBackground`, `timeout`),
    /// but not `type`, `quality` or `path`.
    public static func screenshot(
        of view: WebView, method: String = "Page.screenshot", json: String? = nil
    ) async throws -> Bitmap {
        guard let raw = view.raw else { throw ZebkitError("the view is closed") }
        typealias Continuation = CheckedContinuation<Bitmap, any Error>
        return try await withCheckedThrowingContinuation { (continuation: Continuation) in
            zebkit_automation_screenshot_pixels(raw, method, json, { _, pixels, width, height, stride, error, data in
                let result: Result<Bitmap, any Error>
                if let message = string(borrowing: error) {
                    result = .failure(ZebkitError(message))
                } else if let pixels, width > 0, height > 0, stride >= width * 4 {
                    let (width, height, stride) = (Int(width), Int(height), Int(stride))
                    var rgba = Data(capacity: width * height * 4)
                    for row in 0..<height { rgba.append(pixels + row * stride, count: width * 4) }
                    result = .success(Bitmap(width: width, height: height, rgba: rgba))
                } else {
                    result = .failure(ZebkitError("the screenshot has no pixels"))
                }
                Box<Continuation>.take(data)?.resume(with: result)
            }, Box<Continuation>.retained(continuation))
        }
    }

    /// Serves Playwright's own protocol on a WebSocket on 127.0.0.1:`port`
    /// (0 picks one), what `chromium.connect(url)` of each of Playwright's
    /// languages connects to, and returns its URL,
    /// `ws://127.0.0.1:<port>/<random token>`.
    ///
    /// The URL is the credential: anything with it drives the engine and
    /// writes files, so give it only to what should. Only that path
    /// connects, and no request with an `Origin` header (a web page's
    /// WebSocket has one). A client's contexts close when it disconnects.
    public static func listen(port: Int = 0) async throws -> String {
        typealias Continuation = CheckedContinuation<String, any Error>
        return try await withCheckedThrowingContinuation { (continuation: Continuation) in
            zebkit_automation_listen(Int32(clamping: port), { url, error, data in
                let result: Result<String, any Error> =
                    if let url = string(borrowing: url), !url.hasPrefix("ws://127.0.0.1:0/") {
                        // (The engine answers a second call with port 0
                        // while the first still waits, and after it failed.)
                        .success(url)
                    } else {
                        .failure(ZebkitError(string(borrowing: error) ?? "Playwright's protocol could not be served"))
                    }
                Box<Continuation>.take(data)?.resume(with: result)
            }, Box<Continuation>.retained(continuation))
        }
    }

    /// The view of page `id` (`BrowserContext.newPage` answers `{"page":
    /// "p2"}`): off-screen under `--headless`. `nil` for an unknown or closed
    /// page. A page has one `WebView`: the same each time, and for a view the
    /// application made itself, that one.
    public static func view(forPage id: String) -> WebView? {
        zebkit_automation_page(id).map(WebView.of)
    }
}

/// The closure of `WebView.onAutomationEvent`.
@ZebkitActor
final class AutomationEventState: WebViewState {
    var handler: (@ZebkitActor (String, String) -> Void)?
    init() {}
}

extension WebView {
    /// The page's id in Playwright's protocol, as in `"p2"`; `nil` for a
    /// closed view.
    public var automationPageID: String? {
        guard let raw else { return nil }
        return string(taking: zebkit_automation_page_id(raw))
    }

    /// Called with the events of the view's page, as Playwright's protocol
    /// has them: the event's name (`"Frame.navigated"`, `"Frame.loadstate"`,
    /// `"Page.frameAttached"`, `"Page.frameDetached"`,
    /// `"BrowserContext.console"`, `"BrowserContext.dialog"`,
    /// `"BrowserContext.dialogClosed"`, `"Page.fileChooser"`, `"Page.crash"`,
    /// `"Page.close"`) and its parameters as JSON.
    ///
    /// Dialogs are held for `Dialog.accept` or `Dialog.dismiss`, and file
    /// choosers for `FileChooser.setFiles`, once `Page.updateSubscription`
    /// has asked for them (`{"event": "dialog" or "fileChooser", "enabled":
    /// true}`).
    public var onAutomationEvent: (@ZebkitActor (_ event: String, _ json: String) -> Void)? {
        get { raw == nil ? nil : state(AutomationEventState.self).handler }
        set {
            guard let raw else { return }
            state(AutomationEventState.self).handler = newValue
            guard newValue != nil else { return zebkit_automation_on_event(raw, nil, nil) }
            zebkit_automation_on_event(raw, { _, event, json, data in
                let event = string(borrowing: event) ?? ""
                let json = string(borrowing: json) ?? "{}"
                let view = WebView.from(data)
                onEngineThread { view?.state(AutomationEventState.self).handler?(event, json) }
            }, callbackData)
        }
    }
}
