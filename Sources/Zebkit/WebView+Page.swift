import CZebkit
import Foundation

// MARK: - JavaScript dialogs

/// What becomes of a view's dialogs (`WebView.dialogPolicy`). A dialog
/// already open stays as it is when the policy changes.
public enum DialogPolicy: Sendable {
    /// To `WebView.onDialog` when it is set, held until it is answered.
    /// Otherwise held for a CDP client attached to the page
    /// (`Page.javascriptDialogOpening`), as headless Chrome holds them.
    /// Otherwise what the engine does by itself: on macOS a window's dialog
    /// is the system's alert; elsewhere, and without a window, it is
    /// dismissed at once (alert returns, confirm is false, prompt null) and
    /// beforeunload leaves. The default.
    case `default`
    /// Always held, until the application or a CDP client answers it: a page
    /// that alerts waits.
    case hold
    /// Answered at once with OK: confirm is true, prompt its default text,
    /// beforeunload leaves. Still reported, opened and closed.
    case accept
    /// Answered at once with Cancel: confirm is false, prompt null,
    /// beforeunload stays on the page. Still reported, opened and closed.
    case dismiss

    init(_ policy: zebkit_dialog_policy) {
        switch policy {
        case ZEBKIT_DIALOG_POLICY_HOLD: self = .hold
        case ZEBKIT_DIALOG_POLICY_ACCEPT: self = .accept
        case ZEBKIT_DIALOG_POLICY_DISMISS: self = .dismiss
        default: self = .default
        }
    }

    var raw: zebkit_dialog_policy {
        switch self {
        case .default: ZEBKIT_DIALOG_POLICY_DEFAULT
        case .hold: ZEBKIT_DIALOG_POLICY_HOLD
        case .accept: ZEBKIT_DIALOG_POLICY_ACCEPT
        case .dismiss: ZEBKIT_DIALOG_POLICY_DISMISS
        }
    }
}

/// A JavaScript dialog a page opened: `alert()`, `confirm()`, `prompt()`, a
/// beforeunload handler's "leave this page?", or `window.print()`. A held
/// dialog waits until it is answered, by `respond(_:)` (then
/// or later), by a CDP client, or by the page going away; one that is let go
/// of unanswered stays open.
@ZebkitActor
public final class DialogRequest: WebViewRequest {
    /// Which dialog it is. `name` is as CDP and `WebView.openDialogsJSON`
    /// name it.
    public enum Kind: String, Sendable {
        case alert
        case confirm
        case prompt
        /// "Leave this page?": accepting leaves (or reloads, or closes),
        /// dismissing stays. It has no message: browsers show their own text.
        case beforeUnload = "beforeunload"
        /// `window.print()`, which does not wait: the page may be printed by
        /// `WebView.printToPDF(json:)`, and answering only closes it.
        case print
    }

    /// An answer to a dialog.
    public enum Answer: Sendable, Equatable {
        /// OK; for a prompt, with `promptText` (`nil` for its default text).
        case accept(promptText: String? = nil)
        /// Cancel.
        case dismiss
    }

    private weak var view: WebView?

    /// The view's dialogs are numbered 1, 2, 3, ... in the process.
    public let id: UInt64
    public let kind: Kind
    /// The page's text; `""` for beforeunload and print.
    public let message: String
    /// A prompt's default text, else `""`.
    public let defaultPromptText: String
    /// The URL of the frame that opened it.
    public let url: String
    /// A beforeunload of a reload, not of leaving.
    public let isReload: Bool
    /// Whether the dialog is held for an answer: false when the policy
    /// answered it already (`WebView.onDialogClosed` follows).
    public let isHeld: Bool

    init(view: WebView, dialog: zebkit_dialog) {
        self.view = view
        id = dialog.id
        kind =
            switch dialog.type {
            case ZEBKIT_DIALOG_CONFIRM: .confirm
            case ZEBKIT_DIALOG_PROMPT: .prompt
            case ZEBKIT_DIALOG_BEFOREUNLOAD: .beforeUnload
            case ZEBKIT_DIALOG_PRINT: .print
            default: .alert
            }
        message = string(borrowing: dialog.message) ?? ""
        defaultPromptText = string(borrowing: dialog.default_prompt) ?? ""
        url = string(borrowing: dialog.url) ?? ""
        isReload = dialog.is_reload
        isHeld = dialog.held
    }

    /// The dialog as the callback got it, as JSON in the shape of
    /// `WebView.openDialogsJSON`'s entries, with `"held"` added.
    public var metadataJSON: String {
        let object: [String: Any] = [
            "id": id, "type": kind.rawValue, "message": message, "defaultPrompt": defaultPromptText, "url": url,
            "isReload": isReload, "held": isHeld,
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The dialog's entry in `WebView.openDialogsJSON` while it is open;
    /// `nil` once it is closed, or its view is.
    public var infoJSON: String? {
        guard let list = view?.openDialogsJSON,
            let entries = try? JSONSerialization.jsonObject(with: Data(list.utf8)) as? [[String: Any]],
            let entry = entries.first(where: { ($0["id"] as? NSNumber)?.uint64Value == id }),
            let json = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        else { return nil }
        return String(decoding: json, as: UTF8.self)
    }

    /// Answers the dialog: OK, a prompt with its text, or Cancel. Throws
    /// when it is not open any more, or its view is closed.
    public func respond(_ answer: Answer) throws {
        guard let view, !view.isClosed else { throw ZebkitError("the view is closed") }
        let answered =
            switch answer {
            case .accept(let promptText): view.respondToDialog(id: id, accept: true, promptText: promptText)
            case .dismiss: view.respondToDialog(id: id, accept: false)
            }
        guard answered else { throw ZebkitError("the dialog is answered already") }
    }
}

/// A dialog that closed, however it was answered: by the application, by a
/// CDP client, by the policy, or because the page went (`isAccepted` false).
public struct ClosedDialog: Equatable, Sendable {
    /// The `DialogRequest.id` of the dialog.
    public let id: UInt64
    public let isAccepted: Bool
    /// The prompt's text, else `""`.
    public let promptText: String
}

// MARK: - Drag and drop

/// Drag operations: what a drag allows, and what was done with it. `[]` is
/// none: not dropped, or dropped where nothing took it.
public struct DragOperations: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let copy = DragOperations(rawValue: UInt32(ZEBKIT_DRAG_COPY))
    public static let link = DragOperations(rawValue: UInt32(ZEBKIT_DRAG_LINK))
    public static let move = DragOperations(rawValue: UInt32(ZEBKIT_DRAG_MOVE))
    public static let all = DragOperations(rawValue: UInt32(ZEBKIT_DRAG_ALL))
}

/// The picture a page gives a drag it starts.
public struct DragImage: Equatable, Sendable {
    /// BGRA pixels, alpha premultiplied, `stride` bytes a row.
    public let pixels: Data
    public let width: Int
    public let height: Int
    public let stride: Int
    /// Device pixels per CSS pixel.
    public let scale: Double
    /// Where the cursor is in the image, in CSS pixels from its top left.
    public let offsetX: Double
    public let offsetY: Double
}

/// A drag a page started.
public struct PageDrag: Equatable, Sendable {
    /// What the drag carries, as JSON; every member may be missing:
    /// `{"text", "html", "htmlBaseUrl", "urls": [{"url", "title"}],
    /// "files": [paths], "custom": {type: data}, "fileContents": {"name",
    /// "url", "base64"}}`. `"files"` are files the page dragged out of an
    /// `<input type=file>` or a drop before; `"fileContents"` is an image the
    /// page drags (an `<img>`), with its bytes.
    public let dataJSON: String
    /// What the page allows.
    public let operations: DragOperations
    /// Where the drag started in the view, in CSS pixels.
    public let x: Double
    public let y: Double
    /// The picture the page gives the drag; `nil` when there is none.
    public let image: DragImage?

    init(_ drag: zebkit_drag) {
        dataJSON = string(borrowing: drag.data_json) ?? "{}"
        operations = DragOperations(rawValue: UInt32(drag.operations))
        x = Double(drag.x)
        y = Double(drag.y)
        image = drag.image.map { pixels in
            DragImage(
                pixels: Zebkit.data(
                    borrowing: pixels, count: Int(max(drag.image_stride, 0)) * Int(max(drag.image_height, 0))),
                width: Int(drag.image_width), height: Int(drag.image_height), stride: Int(drag.image_stride),
                scale: Double(drag.image_scale), offsetX: Double(drag.image_offset_x),
                offsetY: Double(drag.image_offset_y))
        }
    }
}

// MARK: - The view

/// The page callbacks a view has, kept with the view.
@ZebkitActor
final class PageState: WebViewState {
    var onDialog: (@ZebkitActor (DialogRequest) -> Void)?
    var onDialogClosed: (@ZebkitActor (ClosedDialog) -> Void)?
    var onDragStart: (@ZebkitActor (PageDrag) -> Bool)?
    var onDragEnd: (@ZebkitActor (DragOperations) -> Void)?
    /// What the page chose for the drags into it, still awaited.
    let dragAnswers = Awaited<DragOperations>()

    init() {}

    func viewClosed() {
        // The engine answers nothing for a view that is gone.
        dragAnswers.giveAll([])
    }
}

extension WebView {
    /// The view's page state; `nil` once it is closed.
    private var pageState: PageState? {
        isClosed ? nil : state(PageState.self)
    }

    // MARK: Dialogs

    /// Called with every dialog the view's pages open, held or not; `nil`
    /// stops. While it is set, the `.default` policy holds dialogs for it.
    public var onDialog: (@ZebkitActor (DialogRequest) -> Void)? {
        get { pageState?.onDialog }
        set {
            guard let raw, let state = pageState else { return }
            state.onDialog = newValue
            guard newValue != nil else { return zebkit_view_on_dialog(raw, nil, nil) }
            zebkit_view_on_dialog(raw, { _, dialog, data in
                guard let dialog = dialog?.pointee else { return }
                let view = WebView.from(data)
                // The struct's strings are copied in `DialogRequest.init`, before the callback returns.
                nonisolated(unsafe) let raw = dialog
                onEngineThread {
                    guard let view, let handler = view.pageState?.onDialog else { return }
                    handler(DialogRequest(view: view, dialog: raw))
                }
            }, callbackData)
        }
    }

    /// Called when a dialog closes, however it was answered.
    public var onDialogClosed: (@ZebkitActor (ClosedDialog) -> Void)? {
        get { pageState?.onDialogClosed }
        set {
            guard let raw, let state = pageState else { return }
            state.onDialogClosed = newValue
            guard newValue != nil else { return zebkit_view_on_dialog_closed(raw, nil, nil) }
            zebkit_view_on_dialog_closed(raw, { _, id, accepted, input, data in
                let closed = ClosedDialog(id: id, isAccepted: accepted, promptText: string(borrowing: input) ?? "")
                let view = WebView.from(data)
                onEngineThread { view?.pageState?.onDialogClosed?(closed) }
            }, callbackData)
        }
    }

    /// What becomes of the view's dialogs; `.default` at first. It may be
    /// changed at any time.
    public var dialogPolicy: DialogPolicy {
        get {
            guard let raw else { return .default }
            return DialogPolicy(zebkit_view_get_dialog_policy(raw))
        }
        set {
            guard let raw else { return }
            zebkit_view_set_dialog_policy(raw, newValue.raw)
        }
    }

    /// Answers dialog `id`: OK (`accept`) or Cancel, a prompt with
    /// `promptText` (`nil` for its default text). False when the view has no
    /// such dialog open.
    @discardableResult
    public func respondToDialog(id: UInt64, accept: Bool, promptText: String? = nil) -> Bool {
        guard let raw else { return false }
        return zebkit_view_dialog_respond(raw, id, accept, promptText)
    }

    /// The view's open dialogs as a JSON array, oldest first:
    /// `[{"id": 1, "type": "confirm", "message": "...", "defaultPrompt": "",
    /// "url": "https://...", "isReload": false}]`. `"[]"` for a closed view.
    public var openDialogsJSON: String {
        guard let raw else { return "[]" }
        return string(taking: zebkit_view_dialogs(raw)) ?? "[]"
    }

    /// Closes the view as a browser closes a tab: the page's beforeunload
    /// handlers run first, and a "leave this page?" dialog they ask for comes
    /// as any other; the view closes when the page lets it, and stays
    /// otherwise. `close()` closes without asking.
    public func requestClose() {
        guard let raw else { return }
        zebkit_view_request_close(raw)
    }

    // MARK: Printing

    /// Prints the view's page to PDF, as Chrome prints it, and returns the
    /// document. `json` is an object of CDP's `Page.printToPDF` parameters
    /// (`nil` for the defaults): `landscape`, `displayHeaderFooter`,
    /// `printBackground`, `scale` (0.1 to 2), `paperWidth` and `paperHeight`
    /// (inches; Letter by default), `marginTop`, `marginBottom`,
    /// `marginLeft`, `marginRight` (inches; 0.4 by default), `pageRanges`
    /// (`"1-5, 8"`), `headerTemplate` and `footerTemplate`,
    /// `preferCSSPageSize`, `generateTaggedPDF`, `generateDocumentOutline`.
    /// The page is printed in print mode (`@media print`); frames of other
    /// sites inside it are not printed.
    public func printToPDF(json: String? = nil) async throws -> Data {
        guard let raw else { throw ZebkitError("the view is closed") }
        typealias Continuation = CheckedContinuation<Data, any Error>
        return try await withCheckedThrowingContinuation { (continuation: Continuation) in
            zebkit_view_print_to_pdf(raw, json, { _, pdf, size, error, data in
                let result: Result<Data, any Error> =
                    if let pdf {
                        .success(Zebkit.data(borrowing: pdf, count: size))
                    } else {
                        .failure(ZebkitError(string(borrowing: error) ?? "the page could not be printed"))
                    }
                Box<Continuation>.take(data)?.resume(with: result)
            }, Box<Continuation>.retained(continuation))
        }
    }

    // MARK: Drags the page starts

    /// Called when the page starts a drag. Return false to have the engine
    /// run it inside the page: in an off-screen view, the mouse moves the
    /// application sends from then on are the drag's (dragenter, dragover,
    /// drop) until the button is released, Escape is pressed, or the mouse
    /// leaves and comes back without the button. Return true to run it
    /// yourself (the system's drag and drop): send it back over the page with
    /// `dragEnter(dataJSON:x:y:operations:modifiers:)` and the rest if it comes
    /// back, and end it with `endPageDrag(x:y:operation:)`.
    ///
    /// With `nil` an off-screen view's drags are run by the engine, and a
    /// window's by the system.
    public var onDragStart: (@ZebkitActor (PageDrag) -> Bool)? {
        get { pageState?.onDragStart }
        set {
            guard let raw, let state = pageState else { return }
            state.onDragStart = newValue
            guard newValue != nil else { return zebkit_view_on_drag_start(raw, nil, nil) }
            zebkit_view_on_drag_start(raw, { _, drag, data in
                guard let drag = drag.map({ PageDrag($0.pointee) }) else { return false }
                let view = WebView.from(data)
                return onEngineThread { view?.pageState?.onDragStart?(drag) ?? false }
            }, callbackData)
        }
    }

    /// Called when a drag the page started ends, with what was done: `[]` if
    /// it was not dropped, or dropped where nothing took it.
    public var onDragEnd: (@ZebkitActor (DragOperations) -> Void)? {
        get { pageState?.onDragEnd }
        set {
            guard let raw, let state = pageState else { return }
            state.onDragEnd = newValue
            guard newValue != nil else { return zebkit_view_on_drag_end(raw, nil, nil) }
            zebkit_view_on_drag_end(raw, { _, operation, data in
                let operation = DragOperations(rawValue: UInt32(operation))
                let view = WebView.from(data)
                onEngineThread { view?.pageState?.onDragEnd?(operation) }
            }, callbackData)
        }
    }

    /// Whether a drag the page started is under way.
    public var isDragging: Bool {
        guard let raw else { return false }
        return zebkit_view_is_dragging(raw)
    }

    /// Ends the drag the page started, at (`x`, `y`), with what was done with
    /// it (`[]` for nothing): the page gets its `dragend`.
    public func endPageDrag(x: Double, y: Double, operation: DragOperations) {
        guard let raw else { return }
        zebkit_view_drag_source_end(raw, Float(x), Float(y), operation.rawValue)
    }

    // MARK: Drags into the page

    /// A drag into the page from outside it: `dataJSON` (as `PageDrag.dataJSON`
    /// describes it) enters at (`x`, `y`), CSS pixels in the view, allowing
    /// `operations`. Then it moves (`dragOver`) and leaves (`dragLeave()`)
    /// or is dropped (`drop`). A dropped file is the page's to read, as from
    /// the system's drag and drop, and `zebkit.pathForFile()` knows its path.
    /// Any view, with a window or without.
    public func dragEnter(
        dataJSON: String, x: Double, y: Double, operations: DragOperations = .all, modifiers: Offscreen.Modifiers = []
    ) {
        guard let raw else { return }
        zebkit_view_drag_enter(raw, dataJSON, Float(x), Float(y), operations.rawValue, modifiers.rawValue)
    }

    /// Moves the drag that entered to (`x`, `y`), and returns the operation
    /// the page chose there. `[]` for a closed view, and when the view
    /// closes before the page has chosen.
    @discardableResult
    public func dragOver(
        x: Double, y: Double, operations: DragOperations = .all, modifiers: Offscreen.Modifiers = []
    ) async -> DragOperations {
        guard let raw else { return [] }
        return await state(PageState.self).dragAnswers.value { data in
            zebkit_view_drag_over(raw, Float(x), Float(y), operations.rawValue, modifiers.rawValue, { _, operation, data in
                Awaited<DragOperations>.give(DragOperations(rawValue: UInt32(operation)), to: data)
            }, data)
        }
    }

    /// The drag that entered leaves the page.
    public func dragLeave() {
        guard let raw else { return }
        zebkit_view_drag_leave(raw)
    }

    /// Drops the drag that entered at (`x`, `y`), and returns the operation
    /// done, as the last dragover chose it. `[]` for a closed view, and when
    /// the view closes before the drop is done.
    @discardableResult
    public func drop(x: Double, y: Double, modifiers: Offscreen.Modifiers = []) async -> DragOperations {
        guard let raw else { return [] }
        return await state(PageState.self).dragAnswers.value { data in
            zebkit_view_drop(raw, Float(x), Float(y), modifiers.rawValue, { _, operation, data in
                Awaited<DragOperations>.give(DragOperations(rawValue: UInt32(operation)), to: data)
            }, data)
        }
    }
}
