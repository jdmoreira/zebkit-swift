import CZebkit
import Foundation

// The library is the application's to extend: hooks before and after what
// changes a document, and for appearances, kinds of annotation, layers, OCR,
// fonts, trust, actions and drawing tools (`zebkit_pdf_hook_*`).
//
// Each takes the document it is for, or `nil` for all documents. A hook goes
// when `Hook.remove()` is called or its document closes; dropping the `Hook`
// value leaves it in place. Its closure is released once the hook is gone and
// no call of it runs.
//
// Callbacks run on the thread that made the call that needs them, outside the
// engine's lock around PDFium: for hooks of all documents, or of a document
// that moves between threads, that is any thread, so the closures are
// `@Sendable`. They may call this API, which runs its hooks in turn, to a
// depth of 16.
extension PDF {
    /// A hook: `remove()` takes it away.
    public struct Hook: Sendable, Hashable {
        /// The engine's id of the hook, above 0.
        let id: Int

        /// Removes the hook. A hook may remove itself or others from its
        /// callback: one removed during a round is not called again. False
        /// when it is gone already.
        @discardableResult
        public func remove() -> Bool {
            zebkit_pdf_hook_remove(Int32(clamping: id))
        }
    }

    /// What a "before" hook says of an operation.
    public enum Decision: Sendable, Equatable {
        /// It goes on as it is.
        case `continue`
        /// It goes on as `json`, another operation of the same form, which
        /// the next hooks see and which is checked as a caller's arguments
        /// are.
        case change(json: String)
        /// Nothing changes, and the call fails with `reason`, or with the
        /// engine's own message for `nil`.
        case refuse(reason: String?)
    }

    /// What a trust hook says of a signer.
    public enum Trust: Sendable {
        /// `"trusted": true` in `signaturesJSON()`.
        case trusted
        /// `"trusted": false`.
        case untrusted
        /// Nothing is said.
        case unknown
    }

    /// Where a layer hook draws: below or above the page's content.
    public enum LayerPosition: Sendable {
        case below
        case above
    }

    /// The annotation an appearance hook or a kind draws.
    public struct AnnotationAppearance: Sendable {
        public let page: Int
        /// Its index on the page.
        public let index: Int
        /// The annotation as `annotationsJSON(page:)` has it.
        public let annotationJSON: String
        /// The size of its box, in points.
        public let width: Double
        public let height: Double
    }

    /// The point a kind's hit test is asked about.
    public struct AnnotationPoint: Sendable {
        public let page: Int
        public let index: Int
        /// The annotation as `annotationsJSON(page:)` has it.
        public let annotationJSON: String
        /// In page space.
        public let x: Double
        public let y: Double
    }

    /// The page a layer hook draws on, and how its canvas maps to the
    /// bitmap being rendered.
    public struct LayerInfo: Sendable, Equatable {
        public let page: Int
        /// The bitmap's size in pixels, a tile's when a tile is rendered.
        public let width: Int
        public let height: Int
        /// Pixels per point.
        public let scale: Double
        /// The render options' rotation.
        public let rotation: Int
        /// `[a, b, c, d, e, f]`: page space to the bitmap's pixels, for what
        /// is drawn in pixels with `Drawing.Canvas.setMatrix`.
        public let matrix: [Double]
    }

    /// A page an OCR hook is asked to read.
    public struct OCRPage: Sendable {
        public let page: Int
        /// The page rendered.
        public let image: Bitmap
        /// Pixels per point of `image`.
        public let scale: Double
    }

    /// A kind of annotation of the application's own (`PDF.addAnnotationKind`).
    public struct AnnotationKind: Sendable {
        /// `"type"` in JSON, as in `"MyApp_Sticker"`: letters, digits, `_`,
        /// `.` and `-`, starting with `prefix` unless `subtype` is given.
        public var name: String
        /// As in `"MyApp_"`: its data is kept as the annotation's entry
        /// /MyApp_Data, and every entry of the prefix is carried through
        /// save, copy, XFDF and FDF, and through flatten into the page's
        /// /PieceInfo (`pageDataJSON(page:prefix:)`).
        public var prefix: String
        /// `nil`: /Subtype is `name`, which other readers draw by its
        /// appearance. Or a standard one (`"Stamp"`), and /<prefix>Kind says
        /// which kind it is.
        public var subtype: String?
        /// What `"data"` may hold, as JSON: `{"mood": {"type": "string",
        /// "enum": ["a", "b"], "required": true}, "size": {"type": "number",
        /// "min": 1, "max": 9}}`. Types: string (also `"maxLength"`),
        /// number, integer, boolean, array, object. Keys it does not name
        /// fail.
        public var schemaJSON: String?
        /// Given `"data"` as JSON: what is wrong with it, or `nil`.
        public var check: (@Sendable (String) -> String?)?
        /// Its appearance, drawn for every change: as an appearance hook's.
        /// `nil` for none.
        public var draw: (@Sendable (Drawing.Canvas, AnnotationAppearance) -> Bool)?
        /// Whether a point is on it; `nil` for its rectangle.
        public var hitTest: (@Sendable (AnnotationPoint) -> Bool)?

        public init(
            name: String, prefix: String, subtype: String? = nil, schemaJSON: String? = nil,
            check: (@Sendable (String) -> String?)? = nil,
            draw: (@Sendable (Drawing.Canvas, AnnotationAppearance) -> Bool)? = nil,
            hitTest: (@Sendable (AnnotationPoint) -> Bool)? = nil
        ) {
            self.name = name
            self.prefix = prefix
            self.subtype = subtype
            self.schemaJSON = schemaJSON
            self.check = check
            self.draw = draw
            self.hitTest = hitTest
        }
    }

    // MARK: Registering

    /// Runs `body` before `event` ("annotation.add", "page.delete", ...,
    /// or `"*"`; `<zebkit/pdf.h>` lists them), on `document` or on all with
    /// `nil`. `body` is given the document (`nil` for "open", which only
    /// hooks for all documents see) and the operation as JSON with
    /// `"event"` in it, and decides. Nothing has changed yet.
    ///
    /// The document given is lent for the call: it may be used there, and
    /// throws after. Closing it there does not close the document.
    @discardableResult
    public static func addBeforeHook(
        event: String, for document: Document? = nil, _ body: @escaping @Sendable (Document?, String) -> Decision
    ) throws -> Hook {
        try register(body, document) { pdf, data in
            zebkit_pdf_hook_before(pdf, event, beforeCall, data, releaseHook)
        }
    }

    /// Runs `body` after `event` (or `"*"`), on `document` or on all with
    /// `nil`, given the document and what happened, as an operation in JSON:
    /// the arguments as they were used and, when it can be undone,
    /// `"inverse"`, which `Document.apply(operationJSON:)` runs.
    ///
    /// The document given is lent for the call, as for `addBeforeHook`.
    @discardableResult
    public static func addAfterHook(
        event: String, for document: Document? = nil, _ body: @escaping @Sendable (Document, String) -> Void
    ) throws -> Hook {
        try register(body, document) { pdf, data in
            zebkit_pdf_hook_after(pdf, event, afterCall, data, releaseHook)
        }
    }

    /// Draws annotations of `type` (as `"type"` names it, `"stamp"`, or
    /// `"*"`) in place of the generator: `body` draws on the canvas and
    /// returns true, or returns false to leave it to the generator. The last
    /// registered goes first.
    @discardableResult
    public static func addAppearanceHook(
        type: String, for document: Document? = nil,
        _ body: @escaping @Sendable (Drawing.Canvas, AnnotationAppearance) -> Bool
    ) throws -> Hook {
        try register(body, document) { pdf, data in
            zebkit_pdf_hook_appearance(pdf, type, appearanceCall, data, releaseHook)
        }
    }

    /// Registers a kind of annotation of the application's own, for
    /// `document` or for all with `nil`. `addAnnotation` then takes its
    /// name as `"type"`, with `"data"` checked against it.
    @discardableResult
    public static func addAnnotationKind(_ kind: AnnotationKind, for document: Document? = nil) throws -> Hook {
        let pdf = try document?.open()
        let data = Box<Any>.retained(KindCalls(check: kind.check, draw: kind.draw, hitTest: kind.hitTest))
        var message: UnsafeMutablePointer<CChar>?
        let id = kind.name.withCString { name in
            kind.prefix.withCString { prefix in
                kind.subtype.withOptionalCString { subtype in
                    kind.schemaJSON.withOptionalCString { schema in
                        var c = zebkit_pdf_kind(
                            name: name, prefix: prefix, subtype: subtype, schema: schema,
                            check: kind.check == nil ? nil : kindCheckCall,
                            draw: kind.draw == nil ? nil : kindDrawCall,
                            hit_test: kind.hitTest == nil ? nil : kindHitCall,
                            data: data, destroy: releaseHook)
                        return zebkit_pdf_hook_kind(pdf, &c, &message)
                    }
                }
            }
        }
        guard id > 0 else {
            // A kind refused is not the engine's: its data is still ours.
            _ = Box<Any>.take(data)
            throw error(taking: message, otherwise: "the kind cannot be registered")
        }
        zebkit_free(message)
        return Hook(id: Int(id))
    }

    /// Draws below or above a page's content when it is rendered, on the
    /// page's bitmap: selections, search results, a cursor, a watermark.
    /// `body` is given the canvas, with page space as its first space
    /// (points, y up), and the page with how that maps to pixels. The
    /// canvas is lent for the length of the call: kept beyond it, it does
    /// nothing and `run(json:)` throws.
    @discardableResult
    public static func addLayerHook(
        _ position: LayerPosition, for document: Document? = nil,
        _ body: @escaping @Sendable (Drawing.Canvas, LayerInfo) -> Void
    ) throws -> Hook {
        let layer = position == .above ? ZEBKIT_PDF_LAYER_ABOVE : ZEBKIT_PDF_LAYER_BELOW
        return try register(body, document) { pdf, data in
            zebkit_pdf_hook_layer(pdf, layer, layerCall, data, releaseHook)
        }
    }

    /// Text for scanned pages: asked when a page has no text of its own,
    /// once per page and document, for `text(page:)`, `textLinesJSON` and
    /// `search`. `body` is given the page rendered, and returns JSON
    /// `[{"text", "box": [l, b, r, t]}, ...]` in page space, or `nil` for
    /// none.
    @discardableResult
    public static func addOCRHook(
        for document: Document? = nil, _ body: @escaping @Sendable (OCRPage) -> String?
    ) throws -> Hook {
        try register(body, document) { pdf, data in
            zebkit_pdf_hook_ocr(pdf, ocrCall, data, releaseHook)
        }
    }

    /// Fonts for free text: asked for a family that is not a standard font,
    /// or for `""` when text has what the standard fonts lack. `body`
    /// returns a TrueType or OpenType file, or `nil`.
    @discardableResult
    public static func addFontHook(
        for document: Document? = nil, _ body: @escaping @Sendable (String) -> Data?
    ) throws -> Hook {
        try register(body, document) { pdf, data in
            zebkit_pdf_hook_font(pdf, fontCall, data, releaseHook)
        }
    }

    /// Trust in a signer: asked for each signature of `signaturesJSON()`,
    /// given its entry as JSON and its PKCS#7.
    @discardableResult
    public static func addTrustHook(
        for document: Document? = nil, _ body: @escaping @Sendable (String, Data) -> Trust
    ) throws -> Hook {
        try register(body, document) { pdf, data in
            zebkit_pdf_hook_trust(pdf, trustCall, data, releaseHook)
        }
    }

    /// Actions, as `annotationActionJSON` describes them: `body` returns
    /// true when the application has done it, which that says as
    /// `"handled"`.
    @discardableResult
    public static func addActionHook(
        for document: Document? = nil, _ body: @escaping @Sendable (String) -> Bool
    ) throws -> Hook {
        try register(body, document) { pdf, data in
            zebkit_pdf_hook_action(pdf, actionCall, data, releaseHook)
        }
    }

    /// A filter of drawing tool `tool`'s points, after the built-in ones of
    /// `filterInput`: given the tool and the points as JSON `[[x, y], ...]`,
    /// `body` returns new points, or `nil` for no change.
    @discardableResult
    public static func addInputHook(
        tool: String, for document: Document? = nil, _ body: @escaping @Sendable (String, String) -> String?
    ) throws -> Hook {
        try register(body, document) { pdf, data in
            zebkit_pdf_hook_input(pdf, tool, inputCall, data, releaseHook)
        }
    }

    // MARK: Inside

    /// Registers `body` as a hook's data. The engine releases it with
    /// `releaseHook`; when it refuses the hook it has not taken it, and it
    /// is released here.
    private static func register(
        _ body: Any, _ document: Document?, _ call: (OpaquePointer?, UnsafeMutableRawPointer) -> Int32
    ) throws -> Hook {
        // A closed document is not `nil`, which would be every document.
        let pdf = try document?.open()
        let data = Box<Any>.retained(body)
        let id = call(pdf, data)
        guard id > 0 else {
            _ = Box<Any>.take(data)
            throw ZebkitError("the hook cannot be registered")
        }
        return Hook(id: Int(id))
    }

    private struct KindCalls {
        let check: (@Sendable (String) -> String?)?
        let draw: (@Sendable (Drawing.Canvas, AnnotationAppearance) -> Bool)?
        let hitTest: (@Sendable (AnnotationPoint) -> Bool)?
    }

    private static func body<Body>(_ data: UnsafeMutableRawPointer?, as _: Body.Type) -> Body? {
        Box<Any>.borrow(data) as? Body
    }

    /// What a callback gives the engine as a string: `zebkit_pdf_string`'s,
    /// which the engine frees.
    private static func give(_ text: String) -> UnsafeMutablePointer<CChar>? {
        zebkit_pdf_string(text)
    }

    private static let releaseHook: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
        _ = Box<Any>.take(data)
    }

    private static let beforeCall: zebkit_pdf_before_func = { pdf, operation, change, reason, data in
        typealias Body = @Sendable (Document?, String) -> Decision
        guard let body = PDF.body(data, as: Body.self) else { return ZEBKIT_PDF_CONTINUE }
        let text = string(borrowing: operation) ?? "{}"
        switch Document.lend(pdf, { body($0, text) }) {
        case .continue:
            return ZEBKIT_PDF_CONTINUE
        case .change(let json):
            change?.pointee = PDF.give(json)
            return ZEBKIT_PDF_CONTINUE
        case .refuse(let why):
            if let why { reason?.pointee = PDF.give(why) }
            return ZEBKIT_PDF_REFUSE
        }
    }

    private static let afterCall: zebkit_pdf_after_func = { pdf, operation, data in
        typealias Body = @Sendable (Document, String) -> Void
        guard let body = PDF.body(data, as: Body.self) else { return }
        let text = string(borrowing: operation) ?? "{}"
        Document.lend(pdf) { document in
            if let document { body(document, text) }
        }
    }

    private static let appearanceCall: zebkit_pdf_appearance_func = {
        canvas, _, page, index, annotation, width, height, data in
        typealias Body = @Sendable (Drawing.Canvas, AnnotationAppearance) -> Bool
        guard let body = PDF.body(data, as: Body.self) else { return false }
        let what = AnnotationAppearance(
            page: Int(page), index: Int(index), annotationJSON: string(borrowing: annotation) ?? "{}",
            width: width, height: height)
        return Drawing.Canvas.lend(canvas) { body($0, what) }
    }

    private static let kindCheckCall: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) ->
        UnsafeMutablePointer<CChar>? = { json, data in
            guard let check = PDF.body(data, as: KindCalls.self)?.check else { return nil }
            return check(string(borrowing: json) ?? "null").flatMap(PDF.give)
        }

    private static let kindDrawCall: zebkit_pdf_appearance_func = {
        canvas, _, page, index, annotation, width, height, data in
        guard let draw = PDF.body(data, as: KindCalls.self)?.draw else { return false }
        let what = AnnotationAppearance(
            page: Int(page), index: Int(index), annotationJSON: string(borrowing: annotation) ?? "{}",
            width: width, height: height)
        return Drawing.Canvas.lend(canvas) { draw($0, what) }
    }

    private static let kindHitCall:
        @convention(c) (OpaquePointer?, Int32, Int32, UnsafePointer<CChar>?, Double, Double, UnsafeMutableRawPointer?)
        -> Bool = { _, page, index, annotation, x, y, data in
            guard let hitTest = PDF.body(data, as: KindCalls.self)?.hitTest else { return false }
            return hitTest(
                AnnotationPoint(
                    page: Int(page), index: Int(index), annotationJSON: string(borrowing: annotation) ?? "{}", x: x,
                    y: y))
        }

    private static let layerCall: zebkit_pdf_layer_func = { canvas, _, page, info, data in
        typealias Body = @Sendable (Drawing.Canvas, LayerInfo) -> Void
        guard let body = PDF.body(data, as: Body.self), let info = info?.pointee else { return }
        let m = info.matrix
        let layer = LayerInfo(
            page: Int(page), width: Int(info.width), height: Int(info.height), scale: info.scale,
            rotation: Int(info.rotation), matrix: [m.0, m.1, m.2, m.3, m.4, m.5])
        Drawing.Canvas.lend(canvas) { body($0, layer) }
    }

    private static let ocrCall: zebkit_pdf_ocr_func = { _, page, rgba, width, height, scale, data in
        typealias Body = @Sendable (OCRPage) -> String?
        guard let body = PDF.body(data, as: Body.self) else { return nil }
        let (w, h) = (Int(max(width, 0)), Int(max(height, 0)))
        let image = Bitmap(width: w, height: h, rgba: Zebkit.data(borrowing: rgba, count: w * h * 4))
        return body(OCRPage(page: Int(page), image: image, scale: scale)).flatMap(PDF.give)
    }

    private static let fontCall: zebkit_pdf_font_func = { _, family, size, data in
        typealias Body = @Sendable (String) -> Data?
        guard let body = PDF.body(data, as: Body.self), let size,
            let font = body(string(borrowing: family) ?? ""), !font.isEmpty
        else { return nil }
        let bytes = font.withUnsafeBytes { zebkit_pdf_bytes($0.baseAddress, $0.count) }
        if bytes != nil { size.pointee = font.count }
        return bytes
    }

    private static let trustCall: zebkit_pdf_trust_func = { _, signature, contents, size, data in
        typealias Body = @Sendable (String, Data) -> Trust
        guard let body = PDF.body(data, as: Body.self) else { return ZEBKIT_PDF_TRUST_UNKNOWN }
        switch body(string(borrowing: signature) ?? "{}", Zebkit.data(borrowing: contents, count: size)) {
        case .trusted: return ZEBKIT_PDF_TRUSTED
        case .untrusted: return ZEBKIT_PDF_UNTRUSTED
        case .unknown: return ZEBKIT_PDF_TRUST_UNKNOWN
        }
    }

    private static let actionCall: zebkit_pdf_action_func = { _, action, data in
        typealias Body = @Sendable (String) -> Bool
        guard let body = PDF.body(data, as: Body.self) else { return false }
        return body(string(borrowing: action) ?? "{}")
    }

    private static let inputCall: zebkit_pdf_input_func = { _, tool, points, data in
        typealias Body = @Sendable (String, String) -> String?
        guard let body = PDF.body(data, as: Body.self) else { return nil }
        return body(string(borrowing: tool) ?? "", string(borrowing: points) ?? "[]").flatMap(PDF.give)
    }
}

extension PDF.Document {
    /// Lends the engine's document `pdf` to `body` as a document that does
    /// not own it, and ends that object's use of it after.
    static func lend<Result>(_ pdf: OpaquePointer?, _ body: (PDF.Document?) -> Result) -> Result {
        guard let pdf else { return body(nil) }
        let lent = PDF.Document(handle: pdf, owned: false)
        defer { lent.close() }
        return body(lent)
    }
}
