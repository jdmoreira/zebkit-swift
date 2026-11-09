import CZebkit
import Foundation

/// zebkit's PDF API: Chromium's PDFium inside the engine, as documents an
/// application opens, reads, renders, searches, changes and saves
/// (`<zebkit/pdf.h>`).
///
/// None of it needs a running engine, and none of it is `ZebkitActor`'s:
/// any thread may call it. PDFium is not thread-safe, so the engine makes
/// the calls one at a time inside; a document is used by one thread at a
/// time.
///
/// Coordinates are PDF page space: points (1/72 inch), the origin at the
/// bottom left of the page's media box, y up, before the page's rotation. A
/// rectangle is `[left, bottom, right, top]`. Pages are counted from 0.
/// Structured answers are JSON, passed through as `String`, as in the
/// header; the small, stable ones are typed as well.
///
///     let document = try PDF.Document(url: fileURL)
///     let page = try document.render(page: 0, options: .init(scale: 2))
///     print(page.width, page.height, try document.text(page: 0))
public enum PDF {
    /// How `Document.save(_:)` writes the file.
    public struct SaveOptions: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        /// Appends the changes to the file as it was: keeps signatures valid.
        public static let incremental = SaveOptions(rawValue: ZEBKIT_PDF_SAVE_INCREMENTAL.rawValue)
        /// Writes the document without its encryption.
        public static let withoutSecurity = SaveOptions(rawValue: ZEBKIT_PDF_SAVE_NO_SECURITY.rawValue)
    }

    /// What a page is rendered with.
    public struct RenderFlags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        /// Annotations' appearances.
        public static let annotations = RenderFlags(rawValue: ZEBKIT_PDF_RENDER_ANNOTATIONS.rawValue)
        /// Form fields, as filled in.
        public static let forms = RenderFlags(rawValue: ZEBKIT_PDF_RENDER_FORMS.rawValue)
        /// Subpixel text, for an opaque background.
        public static let lcdText = RenderFlags(rawValue: ZEBKIT_PDF_RENDER_LCD_TEXT.rawValue)
        public static let grayscale = RenderFlags(rawValue: ZEBKIT_PDF_RENDER_GRAYSCALE.rawValue)
        /// As for printing: print-only annotations are drawn.
        public static let printing = RenderFlags(rawValue: ZEBKIT_PDF_RENDER_PRINTING.rawValue)
        public static let noSmoothing = RenderFlags(rawValue: ZEBKIT_PDF_RENDER_NO_SMOOTHING.rawValue)
    }

    /// How a page is rendered: `zebkit_pdf_render_options`, field for field.
    /// The defaults are what the engine uses without options: the whole page
    /// at scale 1, with annotations, on white.
    public struct RenderOptions: Sendable, Equatable {
        /// A part of the rendered page, in its pixels.
        public struct Tile: Sendable, Equatable, Hashable {
            public var x: Int
            public var y: Int
            public var width: Int
            public var height: Int

            public init(x: Int, y: Int, width: Int, height: Int) {
                self.x = x
                self.y = y
                self.width = width
                self.height = height
            }
        }

        /// Pixels per point.
        public var scale: Double
        /// 0, 90, 180 or 270, added to the page's own rotation.
        public var rotation: Int
        public var flags: RenderFlags
        /// The background, 0xRRGGBBAA; 0 is transparent.
        public var background: UInt32
        /// The part of the page to render; `nil` for the whole page.
        public var tile: Tile?

        public init(
            scale: Double = 1, rotation: Int = 0, flags: RenderFlags = .annotations, background: UInt32 = 0xFFFF_FFFF,
            tile: Tile? = nil
        ) {
            self.scale = scale
            self.rotation = rotation
            self.flags = flags
            self.background = background
            self.tile = tile
        }

        var c: zebkit_pdf_render_options {
            zebkit_pdf_render_options(
                scale: Float(scale), rotation: Int32(clamping: rotation), flags: flags.rawValue, background: background,
                x: Int32(clamping: tile?.x ?? 0), y: Int32(clamping: tile?.y ?? 0),
                width: Int32(clamping: tile?.width ?? 0), height: Int32(clamping: tile?.height ?? 0))
        }
    }

    /// Which appearance of an annotation `Document.renderAnnotation` draws:
    /// those `annotationsJSON(page:)` lists under `"appearances"`.
    public enum AppearanceMode: Sendable {
        case normal, rollover, down

        var raw: Int32 {
            switch self {
            case .normal: 0
            case .rollover: 1
            case .down: 2
            }
        }
    }

    /// How `Document.search` matches.
    public struct SearchOptions: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        /// Matches case.
        public static let matchCase = SearchOptions(rawValue: ZEBKIT_PDF_SEARCH_CASE.rawValue)
        public static let wholeWord = SearchOptions(rawValue: ZEBKIT_PDF_SEARCH_WHOLE_WORD.rawValue)
    }

    /// A match of `Document.search`.
    public struct Match: Sendable, Equatable, Decodable {
        public let page: Int
        /// The index of its first character, as the text functions count them.
        public let start: Int
        /// How many characters it has.
        public let count: Int
        /// The rectangles that cover it, `[left, bottom, right, top]` each.
        public let rects: [[Double]]
        /// The text around it.
        public let context: String
    }

    /// The document information, as `Document.infoJSON()` has it under
    /// `"metadata"`: `nil` for an entry the document does not have. Dates
    /// are PDF dates, as in `"D:20261020120000Z"`.
    public struct Metadata: Sendable, Equatable, Decodable {
        public let title: String?
        public let author: String?
        public let subject: String?
        public let keywords: String?
        public let creator: String?
        public let producer: String?
        public let creationDate: String?
        public let modificationDate: String?

        enum CodingKeys: String, CodingKey {
            case title, author, subject, keywords, creator, producer, creationDate
            case modificationDate = "modDate"
        }
    }

    /// The file formats annotations are exchanged in.
    public enum Interchange: Sendable {
        case xfdf
        case fdf

        var c: zebkit_pdf_interchange {
            switch self {
            case .xfdf: ZEBKIT_PDF_XFDF
            case .fdf: ZEBKIT_PDF_FDF
            }
        }
    }

    /// Runs the built-in filters `optionsJSON` names over a drawing tool's
    /// points, without a document, then the input hooks for all documents
    /// of `tool` (none with `nil`): `pointsJSON` is `[[x, y], ...]`, and so
    /// is what is returned. Options, a JSON object, at most 1000000 points:
    /// `"smooth": n` (1-8, Chaikin's passes, for ink), `"simplify":
    /// tolerance` in points, `"snapGrid": spacing`, `"snapAngle": degrees`,
    /// `"constrain": "square" | "circle"`.
    public static func filterInput(tool: String? = nil, pointsJSON: String, optionsJSON: String? = nil) throws -> String {
        var message: UnsafeMutablePointer<CChar>?
        let result = tool.withOptionalCString { tool in
            optionsJSON.withOptionalCString { options in
                zebkit_pdf_filter_input(nil, tool, pointsJSON, options, &message)
            }
        }
        guard let result else { throw error(taking: message, otherwise: "the points cannot be filtered") }
        zebkit_free(message)
        return string(taking: result) ?? "[]"
    }
}

extension PDF {
    /// A PDF document. It owns its engine document, which `close()` or the
    /// end of the object closes; after `close()` every call throws (or, for
    /// `pageCount`, gives 0), and none crashes.
    ///
    /// Not `Sendable`: the header lets any thread use a document, but only
    /// one at a time, so one is not shared between threads. It may be
    /// handed from one thread to another.
    ///
    /// A document's hooks go with it. A hook's closure that holds the
    /// document keeps it open: hooks are given the document as an argument.
    public final class Document {
        private(set) var handle: OpaquePointer?
        /// False for a document a hook is lent, which its owner closes.
        private let owned: Bool

        init(handle: OpaquePointer, owned: Bool = true) {
            self.handle = handle
            self.owned = owned
        }

        /// Opens the PDF file at `url`, a file URL, with `password` (`nil`
        /// for none). The file is read as it is needed, and must stay where
        /// it is while the document is open. Throws `"password"` when one is
        /// needed or is wrong.
        public convenience init(url: URL, password: String? = nil) throws {
            var message: UnsafeMutablePointer<CChar>?
            let handle = password.withOptionalCString { zebkit_pdf_open_file(url.path, $0, &message) }
            guard let handle else { throw error(taking: message, otherwise: "the document cannot be opened") }
            zebkit_free(message)
            self.init(handle: handle)
        }

        /// Opens a PDF from `data`, which is copied, with `password` (`nil`
        /// for none). Throws `"password"` when one is needed or is wrong.
        public convenience init(data: Data, password: String? = nil) throws {
            var message: UnsafeMutablePointer<CChar>?
            let handle = password.withOptionalCString { password in
                data.withUnsafeBytes { zebkit_pdf_open($0.baseAddress, $0.count, password, &message) }
            }
            guard let handle else { throw error(taking: message, otherwise: "the document cannot be opened") }
            zebkit_free(message)
            self.init(handle: handle)
        }

        /// A new, empty document, for building one from others' pages.
        public convenience init() throws {
            var message: UnsafeMutablePointer<CChar>?
            guard let handle = zebkit_pdf_new(&message) else {
                throw error(taking: message, otherwise: "the document cannot be made")
            }
            zebkit_free(message)
            self.init(handle: handle)
        }

        deinit {
            close()
        }

        /// Closes the document, with its hooks; later calls throw. Closing
        /// again does nothing. The document a hook is given is not its to
        /// close: there this only ends that object's use of it.
        public func close() {
            guard let handle else { return }
            self.handle = nil
            if owned { zebkit_pdf_close(handle) }
        }

        /// Whether `close()` has been called.
        public var isClosed: Bool { handle == nil }

        /// The engine's document, or an error once it is closed.
        func open() throws -> OpaquePointer {
            guard let handle else { throw ZebkitError("the document is closed") }
            return handle
        }

        // MARK: Calls

        typealias ErrorPlace = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>

        /// A string the engine gives away, or the error it set.
        func text(_ fallback: String, _ body: (OpaquePointer, ErrorPlace) -> UnsafeMutablePointer<CChar>?) throws
            -> String
        {
            let handle = try open()
            var message: UnsafeMutablePointer<CChar>?
            guard let result = body(handle, &message) else { throw error(taking: message, otherwise: fallback) }
            zebkit_free(message)
            return string(taking: result) ?? ""
        }

        /// Bytes the engine gives away, or the error it set.
        func bytes(
            _ fallback: String, _ body: (OpaquePointer, UnsafeMutablePointer<Int>, ErrorPlace) -> UnsafeMutablePointer<UInt8>?
        ) throws -> Data {
            let handle = try open()
            var message: UnsafeMutablePointer<CChar>?
            var size = 0
            guard let result = body(handle, &size, &message) else { throw error(taking: message, otherwise: fallback) }
            zebkit_free(message)
            return data(taking: result, count: size)
        }

        /// A call that returns false on failure.
        func check(_ fallback: String, _ body: (OpaquePointer, ErrorPlace) -> Bool) throws {
            let handle = try open()
            try checked(fallback) { body(handle, $0) }
        }

        /// A call that returns -1 on failure.
        func number(_ fallback: String, _ body: (OpaquePointer, ErrorPlace) -> Int32) throws -> Int {
            let handle = try open()
            var message: UnsafeMutablePointer<CChar>?
            let result = body(handle, &message)
            guard result >= 0 else { throw error(taking: message, otherwise: fallback) }
            zebkit_free(message)
            return Int(result)
        }

        // MARK: The document

        /// The document as a file, with the changes made to it.
        public func save(_ options: SaveOptions = []) throws -> Data {
            try bytes("the document cannot be saved") { zebkit_pdf_save($0, options.rawValue, $1, $2) }
        }

        /// What the document is, as JSON: `{"pages", "version", "encrypted",
        /// "securityRevision", "permissions": {"print", "modify", "copy",
        /// "annotate", "fillForms", "extract", "assemble",
        /// "printHighQuality"}, "permissionBits", "userPermissionBits",
        /// "form": "none" | "acro" | "xfa", "formDefaultAppearance",
        /// "tagged", "language", "metadata": {...}}`.
        public func infoJSON() throws -> String {
            let handle = try open()
            guard let result = zebkit_pdf_info(handle) else { throw ZebkitError("the document's information cannot be read") }
            return string(taking: result) ?? "{}"
        }

        /// The document information: `"metadata"` of `infoJSON()`.
        public func metadata() throws -> Metadata {
            struct Info: Decodable { let metadata: Metadata? }
            return try JSON.decode(Info.self, from: infoJSON()).metadata ?? JSON.decode(Metadata.self, from: "{}")
        }

        /// Sets the document information: `json` is an object with the keys
        /// of `Metadata`; a string sets the entry, `null` removes it, a key
        /// left out stays as it is.
        public func setMetadata(json: String) throws {
            try check("the metadata cannot be set") { zebkit_pdf_set_metadata($0, json, $1) }
        }

        // MARK: Pages

        /// How many pages the document has; 0 once it is closed.
        public var pageCount: Int {
            guard let handle else { return 0 }
            return max(Int(zebkit_pdf_page_count(handle)), 0)
        }

        /// A page, as JSON: `{"width", "height", "rotation": 0 | 90 | 180 |
        /// 270, "objectNumber", "label", "mediaBox": [l, b, r, t],
        /// "cropBox", "bleedBox", "trimBox", "artBox"}` (the boxes it has).
        /// Width and height are the page as it is shown: its crop box, turned
        /// by its rotation, as `render` draws it at scale 1.
        public func pageJSON(_ page: Int) throws -> String {
            try text("no such page") { zebkit_pdf_page($0, Int32(clamping: page), $1) }
        }

        /// The size of the page as it is shown, in points: `"width"` and
        /// `"height"` of `pageJSON(_:)`.
        public func pageSize(_ page: Int) throws -> (width: Double, height: Double) {
            struct Size: Decodable { let width: Double, height: Double }
            let size = try JSON.decode(Size.self, from: pageJSON(page))
            return (size.width, size.height)
        }

        /// Renders a page. Without options: the whole page at scale 1, with
        /// annotations, on white.
        public func render(page: Int, options: RenderOptions = RenderOptions()) throws -> Bitmap {
            let handle = try open()
            var width: Int32 = 0
            var height: Int32 = 0
            var message: UnsafeMutablePointer<CChar>?
            var c = options.c
            let pixels = zebkit_pdf_render(handle, Int32(clamping: page), &c, &width, &height, &message)
            return try bitmap(pixels, width, height, message, "the page cannot be rendered")
        }

        /// Renders appearance `mode` of annotation `index` of the page, alone:
        /// an image of its rectangle at the options' scale, turned clockwise by
        /// their rotation (not by the page's), on their background. With
        /// `nil` options the scale is 1 and the background transparent. The
        /// tile and the flags are not used. Throws `"no appearance"` when
        /// there is none to draw, as for a hidden annotation.
        public func renderAnnotation(
            page: Int, index: Int, mode: AppearanceMode = .normal, options: RenderOptions? = nil
        ) throws -> Bitmap {
            let handle = try open()
            var width: Int32 = 0
            var height: Int32 = 0
            var message: UnsafeMutablePointer<CChar>?
            let pixels: UnsafeMutablePointer<UInt8>?
            if var c = options?.c {
                pixels = zebkit_pdf_render_annotation(
                    handle, Int32(clamping: page), Int32(clamping: index), mode.raw, &c, &width, &height, &message)
            } else {
                pixels = zebkit_pdf_render_annotation(
                    handle, Int32(clamping: page), Int32(clamping: index), mode.raw, nil, &width, &height, &message)
            }
            return try bitmap(pixels, width, height, message, "the annotation cannot be rendered")
        }

        private func bitmap(
            _ pixels: UnsafeMutablePointer<UInt8>?, _ width: Int32, _ height: Int32,
            _ message: UnsafeMutablePointer<CChar>?, _ fallback: String
        ) throws -> Bitmap {
            guard let pixels else { throw error(taking: message, otherwise: fallback) }
            zebkit_free(message)
            let (w, h) = (Int(max(width, 0)), Int(max(height, 0)))
            return Bitmap(width: w, height: h, rgba: data(taking: pixels, count: w * h * 4))
        }

        // MARK: Text

        /// The page's text, in reading order as PDFium extracts it.
        public func text(page: Int) throws -> String {
            try text("the page's text cannot be read") { zebkit_pdf_text($0, Int32(clamping: page), $1) }
        }

        /// The page's characters, as JSON: `{"text", "chars": [{"c", "box",
        /// "loose", "size", "font", "angle", "object"}, ...], "objects":
        /// [{"font", "family", "weight", "italic", "monospaced", "embedded",
        /// "size", "color"}, ...]}`. Character i of `"chars"` is UTF-16 unit
        /// i of the page's text as PDFium counts it, which the other text
        /// functions take as indexes; characters PDFium makes up (spaces,
        /// line ends) have no box.
        public func textLayoutJSON(page: Int) throws -> String {
            try text("the page's text cannot be read") { zebkit_pdf_text_layout($0, Int32(clamping: page), $1) }
        }

        /// The rectangles that cover `count` characters from `start`, a
        /// line's run each, as a selection draws them: JSON `[[l, b, r, t], ...]`.
        public func textRectsJSON(page: Int, start: Int, count: Int) throws -> String {
            try text("the text's rectangles cannot be read") {
                zebkit_pdf_text_rects($0, Int32(clamping: page), Int32(clamping: start), Int32(clamping: count), $1)
            }
        }

        /// The page's text as lines, as PDFium breaks it: JSON `[{"text",
        /// "box": [l, b, r, t], "unmapped"}, ...]`, `"unmapped"` how many of
        /// its characters have no Unicode of their font's own (text to OCR
        /// instead).
        public func textLinesJSON(page: Int) throws -> String {
            try text("the page's text cannot be read") { zebkit_pdf_text_lines($0, Int32(clamping: page), $1) }
        }

        /// The index of the character at (`x`, `y`), within `tolerance`
        /// points; `nil` for none, and once the document is closed.
        public func characterIndex(page: Int, x: Double, y: Double, tolerance: Double = 0) -> Int? {
            guard let handle else { return nil }
            let index = zebkit_pdf_char_at(handle, Int32(clamping: page), x, y, tolerance)
            return index >= 0 ? Int(index) : nil
        }

        /// `search`'s matches as the engine's JSON.
        func searchJSON(_ query: String, options: SearchOptions = [], from first: Int = 0, limit: Int = 0)
            throws -> String
        {
            try text("the document cannot be searched") {
                zebkit_pdf_search($0, query, options.rawValue, Int32(clamping: first), Int32(clamping: limit), $1)
            }
        }

        /// Every match of `query` in the document, from page `first` on, at
        /// most `limit` (0 for all).
        public func search(_ query: String, options: SearchOptions = [], from first: Int = 0, limit: Int = 0)
            throws -> [Match]
        {
            try JSON.decode([Match].self, from: searchJSON(query, options: options, from: first, limit: limit))
        }

        // MARK: Images

        /// The images the page draws, inside forms too: JSON `[{"width",
        /// "height", "rect": [l, b, r, t], "jpeg"}, ...]`, the size in
        /// pixels, `"rect"` where it is drawn, `"jpeg"` whether it is stored
        /// as a JPEG file. A page that is one large image is a scan.
        public func imagesJSON(page: Int) throws -> String {
            try text("the page's images cannot be read") { zebkit_pdf_images($0, Int32(clamping: page), $1) }
        }

        /// Image `image` of the page, numbered as `imagesJSON` lists them: a
        /// JPEG file as the document stores it (`isJPEG`), otherwise its
        /// pixels decoded, as PNG. Throws when there is no such image or it
        /// cannot be decoded.
        public func imageData(page: Int, image: Int) throws -> (data: Data, isJPEG: Bool) {
            var jpeg = false
            let data = try bytes("the image cannot be read") {
                zebkit_pdf_image_data($0, Int32(clamping: page), Int32(clamping: image), $1, &jpeg, $2)
            }
            return (data, jpeg)
        }

        // MARK: Signatures

        /// The document's digital signatures, in its form's order, as JSON:
        /// `[{"field", "subFilter", "reason", "time", "byteRange", "docMDP",
        /// "size", "signer": {"name", "issuer", "serial", "notBefore",
        /// "notAfter"}, "intact", "digest", "problem", "coversDocument",
        /// "trusted"}, ...]`. Each is checked against the document as it was
        /// opened: `"intact"` when the bytes it covers are those it signed
        /// and it is by the key of the signer's certificate. Whether the
        /// certificate is one to trust is not checked; a trust hook
        /// (`PDF.addTrustHook`) says it as `"trusted"`.
        public func signaturesJSON() throws -> String {
            try text("the signatures cannot be read") { zebkit_pdf_signatures($0, $1) }
        }

        /// Signature `index`'s contents: the DER-encoded PKCS#7 or time
        /// stamp it holds.
        public func signatureContents(_ index: Int) throws -> Data {
            try bytes("no such signature") { zebkit_pdf_signature_contents($0, Int32(clamping: index), $1, $2) }
        }

        // MARK: Navigation

        /// The outline (bookmarks), as JSON: `[{"title", "page", "x", "y",
        /// "zoom", "url", "open", "children": [...]}, ...]`; `"page"` for a
        /// place in the document, `"url"` for a link out, either or neither.
        public func outlineJSON() throws -> String {
            try text("the outline cannot be read") { zebkit_pdf_outline($0, $1) }
        }

        /// Replaces the outline with an array in `outlineJSON()`'s format;
        /// `[]` removes it. Titles are required; page and URL exclude each
        /// other; x, y and zoom need a page, zoom >= 0. Unknown keys and
        /// wrong values refuse the whole tree before anything changes. At
        /// most 64 levels, 100000 entries and 16 MiB. `save` keeps it.
        public func setOutline(json: String) throws {
            try check("the outline cannot be set") { zebkit_pdf_set_outline($0, json, $1) }
        }

        /// The page's links: its link annotations, and addresses written in
        /// its text (`"detected": true`): JSON `[{"rect": [l, b, r, t],
        /// "page": 2 | "url": "...", ...}, ...]`.
        public func linksJSON(page: Int) throws -> String {
            try text("the page's links cannot be read") { zebkit_pdf_links($0, Int32(clamping: page), $1) }
        }

        // MARK: Forms

        /// The document's form fields, as JSON: `[{"name", "type": "text" |
        /// "checkbox" | "radio" | "combobox" | "listbox" | "pushbutton" |
        /// "signature", "value", "readOnly", "required", "flags", "options":
        /// [{"label", "selected"}], "widgets": [{"page", "annotation",
        /// "rect", "checked", "exportValue"}]}, ...]`, with the keys a field
        /// has; one entry per field, however many widgets it has.
        public func formFieldsJSON() throws -> String {
            try text("the form cannot be read") { zebkit_pdf_form_fields($0, $1) }
        }

        /// Sets field `name` (its full name) to `value`: the text of a text
        /// field or combo box, an option's value of a list box, the export
        /// value of the check box or radio button to check (`"Off"` for
        /// none). The fields' appearances follow.
        public func setFormField(_ name: String, to value: String) throws {
            try check("the field cannot be set") { zebkit_pdf_form_set($0, name, value, $1) }
        }

        /// Sets every field back to its default value.
        public func resetForm() throws {
            try check("the form cannot be reset") { zebkit_pdf_form_reset($0, $1) }
        }

        // MARK: Changing pages

        /// Sets the page's rotation: 0, 90, 180 or 270.
        public func rotatePage(_ page: Int, to rotation: Int) throws {
            try check("the page cannot be turned") {
                zebkit_pdf_page_rotate($0, Int32(clamping: page), Int32(clamping: rotation), $1)
            }
        }

        /// Deletes the pages at `pages`.
        public func deletePages(_ pages: [Int]) throws {
            let indexes = pages.map { Int32(clamping: $0) }
            try check("the pages cannot be deleted") { handle, message in
                indexes.withUnsafeBufferPointer { zebkit_pdf_pages_delete(handle, $0.baseAddress, Int32($0.count), message) }
            }
        }

        /// Moves `pages`, in the order given, to start at index `to` of the
        /// document they leave.
        public func movePages(_ pages: [Int], to: Int) throws {
            let indexes = pages.map { Int32(clamping: $0) }
            try check("the pages cannot be moved") { handle, message in
                indexes.withUnsafeBufferPointer {
                    zebkit_pdf_pages_move(handle, $0.baseAddress, Int32($0.count), Int32(clamping: to), message)
                }
            }
        }

        /// Inserts a blank page `width` by `height` points at index `at`.
        public func insertPage(at index: Int, width: Double, height: Double) throws {
            try check("the page cannot be inserted") {
                zebkit_pdf_page_insert($0, Int32(clamping: index), width, height, $1)
            }
        }

        /// Copies `pages` of `source` (all with `nil`) into this document at
        /// index `at`: merging documents, and taking pages from another.
        public func importPages(from source: Document, pages: [Int]? = nil, at index: Int) throws {
            let from = try source.open()
            let indexes = pages?.map { Int32(clamping: $0) }
            try check("the pages cannot be imported") { handle, message in
                guard let indexes else { return zebkit_pdf_pages_import(handle, from, nil, 0, Int32(clamping: index), message) }
                return indexes.withUnsafeBufferPointer {
                    zebkit_pdf_pages_import(handle, from, $0.baseAddress, Int32($0.count), Int32(clamping: index), message)
                }
            }
        }

        // MARK: Attachments

        /// The files attached to the document: JSON `[{"name", "size"}, ...]`.
        public func attachmentsJSON() throws -> String {
            try text("the attachments cannot be read") { zebkit_pdf_attachments($0, $1) }
        }

        /// Attachment `index`'s bytes.
        public func attachment(_ index: Int) throws -> Data {
            try bytes("no such attachment") { zebkit_pdf_attachment($0, Int32(clamping: index), $1, $2) }
        }

        /// Attaches `data` to the document as `name`.
        public func attach(_ data: Data, name: String) throws {
            try check("the file cannot be attached") { handle, message in
                data.withUnsafeBytes { zebkit_pdf_attach(handle, name, $0.baseAddress, $0.count, message) }
            }
        }

        /// Removes attachment `index`.
        public func detach(_ index: Int) throws {
            try check("no such attachment") { zebkit_pdf_detach($0, Int32(clamping: index), $1) }
        }

        // MARK: Redaction

        /// Takes what is under `areasJSON`, a JSON array of `[l, b, r, t]`
        /// (`nil` for the page's redaction marks), out of the page for good:
        /// characters of text one by one, the pixels of images (blacked
        /// out), paths, shadings and forms that reach into an area whole,
        /// annotations that reach into one. Draws a box of `fill`
        /// (0xRRGGBBAA; 0 for none) over each area, and removes the marks.
        /// Returns the number of areas.
        @discardableResult
        public func redact(page: Int, areasJSON: String? = nil, fill: UInt32 = 0) throws -> Int {
            try number("the page cannot be redacted") { handle, message in
                areasJSON.withOptionalCString { zebkit_pdf_redact(handle, Int32(clamping: page), $0, fill, message) }
            }
        }

        // MARK: Fonts, operations, tools

        /// Gives free text family `family` (`""` for what the standard fonts
        /// and the rest lack) as `font`, a TrueType or OpenType file.
        public func addFont(_ font: Data, family: String) throws {
            try check("the font cannot be added") { handle, message in
                font.withUnsafeBytes { zebkit_pdf_font_add(handle, family, $0.baseAddress, $0.count, message) }
            }
        }

        /// Runs `operationJSON`: one an "after" hook saw, or its `"inverse"`,
        /// for undo and redo, or sent by a collaborator. Events:
        /// annotation.add, annotation.update, annotation.remove,
        /// annotation.restore, annotation.move, form.set, page.insert,
        /// page.delete, page.move, page.rotate. Its own hooks run.
        public func apply(operationJSON: String) throws {
            try check("the operation cannot be applied") { zebkit_pdf_apply($0, operationJSON, $1) }
        }

        /// What flatten kept of annotations with entries of `prefix` (a
        /// kind's, `PDF.AnnotationKind`), as JSON `[{"Subtype", "Rect", "<prefix>Data"},
        /// ...]`, from the page's /PieceInfo.
        public func pageDataJSON(page: Int, prefix: String) throws -> String {
            try text("the page's data cannot be read") { zebkit_pdf_page_data($0, Int32(clamping: page), prefix, $1) }
        }

        /// Runs the built-in filters `optionsJSON` names over drawing tool
        /// `tool`'s points, then the input hooks for `tool`: as
        /// `PDF.filterInput`, with this document's hooks and those for all.
        public func filterInput(tool: String? = nil, pointsJSON: String, optionsJSON: String? = nil) throws -> String {
            try text("the points cannot be filtered") { handle, message in
                tool.withOptionalCString { tool in
                    optionsJSON.withOptionalCString { zebkit_pdf_filter_input(handle, tool, pointsJSON, $0, message) }
                }
            }
        }
    }
}
