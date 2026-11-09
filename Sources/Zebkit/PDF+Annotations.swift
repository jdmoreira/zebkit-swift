import CZebkit
import Foundation

extension PDF.Document {
    // MARK: Reading annotations

    /// The page's annotations, in their order on the page, as JSON:
    /// `[{"index", "object", "type", "rect", "color", "interiorColor",
    /// "opacity", "border", "flags", "contents", "author", "subject",
    /// "name", "modified", "created", "quads", "ink", "vertices", "line",
    /// "url", "page", "popup", "inReplyTo", "field", "appearances",
    /// "entries": {...}}, ...]`, with the keys an annotation has, and the
    /// appearance keys `addAnnotation(page:json:)` sets. `"entries"` is the
    /// annotation's dictionary but /AP and /P, as plain values. Colours are
    /// 0-255, opacity 0-1, flags the PDF's (print 4, hidden 2, readOnly 64,
    /// locked 128), dates PDF dates. `<zebkit/pdf.h>` has the whole schema.
    public func annotationsJSON(page: Int) throws -> String {
        try text("the page's annotations cannot be read") { zebkit_pdf_annotations($0, Int32(clamping: page), $1) }
    }

    /// The top annotation at (`x`, `y`) within `tolerance` points, or `nil`.
    /// Hidden annotations and popups do not count; a line counts within its
    /// width; a kind's hit test decides for it.
    public func annotationIndex(page: Int, x: Double, y: Double, tolerance: Double = 0) throws -> Int? {
        let handle = try open()
        var message: UnsafeMutablePointer<CChar>?
        let index = zebkit_pdf_annotation_at(handle, Int32(clamping: page), x, y, tolerance, &message)
        // -1 is no annotation, unless an error was set.
        if let message { throw error(taking: message, otherwise: "") }
        return index >= 0 ? Int(index) : nil
    }

    /// What activating annotation `index` means, without doing it: JSON
    /// `{"kind": "uri", "url"} | {"kind": "goto", "page"} | {"kind":
    /// "named", "name"} | {"kind": "launch", "file"} | {"kind":
    /// "javascript", "script"} | {"kind": "other", "action"} | {"kind":
    /// "none"}`, with `"handled"`: whether an action hook
    /// (`PDF.addActionHook`) took it.
    public func annotationActionJSON(page: Int, index: Int) throws -> String {
        try text("the annotation's action cannot be read") {
            zebkit_pdf_annotation_action($0, Int32(clamping: page), Int32(clamping: index), $1)
        }
    }

    // MARK: Changing annotations

    /// Adds an annotation to the page from `json`, an object with the keys
    /// `annotationsJSON` reads (`"type"` and `"rect"` at least; not
    /// `"index"` or `"appearances"`), and returns its index. Text markup
    /// takes `"quads"`, ink `"ink"`, polygon and polyline `"vertices"`, line
    /// `"line"`, link `"url"` or `"page"`. The types made this way are text
    /// to ink in the header's list, popup, fileAttachment, redact, and the
    /// kinds registered (`PDF.addAnnotationKind`); their appearance is generated. The
    /// appearance keys (`"borderStyle"`, `"lineEndings"`, `"font"`,
    /// `"stamp"`, `"measure"`, ...) are in `<zebkit/pdf.h>`. Wrong types,
    /// values out of range and unknown keys throw, with nothing added. The
    /// hooks run around it.
    @discardableResult
    public func addAnnotation(page: Int, json: String) throws -> Int {
        try number("the annotation cannot be added") { zebkit_pdf_annotation_add($0, Int32(clamping: page), json, $1) }
    }

    /// Changes annotation `index` of the page: the keys `json` has are set,
    /// `null` removes one. Its appearance is generated again when something
    /// it shows changes; `"regenerate": true` or `false` in `json` says
    /// otherwise, and `true` also replaces an appearance the application
    /// made, which is otherwise kept.
    public func updateAnnotation(page: Int, index: Int, json: String) throws {
        try check("the annotation cannot be changed") {
            zebkit_pdf_annotation_update($0, Int32(clamping: page), Int32(clamping: index), json, $1)
        }
    }

    /// Removes annotation `index`, with its popup, and the replies to it
    /// with theirs.
    public func removeAnnotation(page: Int, index: Int) throws {
        try check("the annotation cannot be removed") {
            zebkit_pdf_annotation_remove($0, Int32(clamping: page), Int32(clamping: index), $1)
        }
    }

    /// Moves annotation `index` to index `to` in the page's order: later is
    /// on top.
    public func moveAnnotation(page: Int, index: Int, to: Int) throws {
        try check("the annotation cannot be moved") {
            zebkit_pdf_annotation_move($0, Int32(clamping: page), Int32(clamping: index), Int32(clamping: to), $1)
        }
    }

    /// Copies annotation `index` to page `targetPage` of `target` (which may
    /// be this document), with its appearance and all its entries, but
    /// without its popup or what it replied to. Returns its index there.
    @discardableResult
    public func copyAnnotation(page: Int, index: Int, to target: PDF.Document, page targetPage: Int) throws -> Int {
        let other = try target.open()
        return try number("the annotation cannot be copied") {
            zebkit_pdf_annotation_copy(
                $0, Int32(clamping: page), Int32(clamping: index), other, Int32(clamping: targetPage), $1)
        }
    }

    /// Makes the page's annotations and form fields part of its content, as
    /// they are shown (or printed, with `forPrinting`): they are no longer
    /// annotations. Links, which draw nothing, go too.
    public func flatten(page: Int, forPrinting: Bool = false) throws {
        try check("the page cannot be flattened") { zebkit_pdf_flatten($0, Int32(clamping: page), forPrinting, $1) }
    }

    /// Makes annotation `index`'s appearance part of the page's content, and
    /// removes the annotation.
    public func flattenAnnotation(page: Int, index: Int) throws {
        try check("the annotation cannot be flattened") {
            zebkit_pdf_annotation_flatten($0, Int32(clamping: page), Int32(clamping: index), $1)
        }
    }

    // MARK: Appearances

    /// Makes `image` the appearance of stamp annotation `index`, drawn over
    /// its rectangle: what an image stamp ("Approved", a signature drawn by
    /// hand) is. `image.rgba` is R, G, B, A in rows top to bottom.
    public func setAnnotationImage(page: Int, index: Int, image: Bitmap) throws {
        guard image.rgba.count >= image.width * image.height * 4 else {
            throw ZebkitError("the image has fewer than width * height * 4 bytes")
        }
        try check("the image cannot be set") { handle, message in
            image.rgba.withUnsafeBytes {
                zebkit_pdf_annotation_set_image(
                    handle, Int32(clamping: page), Int32(clamping: index), $0.bindMemory(to: UInt8.self).baseAddress,
                    Int32(clamping: image.width), Int32(clamping: image.height), message)
            }
        }
    }

    /// Makes page `sourcePage` of `source`, as vectors, the appearance of
    /// stamp annotation `index`.
    public func setAnnotationAppearance(page: Int, index: Int, fromPage sourcePage: Int, of source: PDF.Document) throws {
        let other = try source.open()
        try check("the page cannot be the stamp's appearance") {
            zebkit_pdf_annotation_stamp_page(
                $0, Int32(clamping: page), Int32(clamping: index), other, Int32(clamping: sourcePage), $1)
        }
    }

    /// Draws `json`, a canvas's list of operations as `Drawing.Canvas.run`
    /// takes it (`[["fillColor", rgba], ["rect", x, y, w, h], ["fill",
    /// false], ...]`), as the appearance of annotation `index`: in points,
    /// over its box, the origin its top left. It is kept as
    /// `setAnnotationImage`'s is.
    public func drawAnnotation(page: Int, index: Int, json: String) throws {
        try check("the appearance cannot be drawn") {
            zebkit_pdf_annotation_draw($0, Int32(clamping: page), Int32(clamping: index), json, $1)
        }
    }

    // MARK: Files of annotations

    /// Embeds `data` as the file of file attachment annotation `index`,
    /// named `name`.
    public func setAnnotationFile(page: Int, index: Int, data: Data, name: String) throws {
        try check("the file cannot be attached") { handle, message in
            data.withUnsafeBytes {
                zebkit_pdf_annotation_attach_file(
                    handle, Int32(clamping: page), Int32(clamping: index), name, $0.baseAddress, $0.count, message)
            }
        }
    }

    /// The file of file attachment annotation `index`: its name, when it has
    /// one, and its bytes.
    public func annotationFile(page: Int, index: Int) throws -> (name: String?, data: Data) {
        var name: UnsafeMutablePointer<CChar>?
        let data = try bytes("the annotation has no file") {
            zebkit_pdf_annotation_file($0, Int32(clamping: page), Int32(clamping: index), &name, $1, $2)
        }
        return (string(taking: name), data)
    }

    // MARK: Interchange

    /// The annotations as an XFDF or FDF file: of `page`, or of every page
    /// with `nil`; only annotation `index` of that page, unless `nil`. Links
    /// and widgets are not annotations in these formats, and appearances
    /// are not written. A kind's data travels in elements or entries of
    /// zebkit's own, which other readers skip.
    public func exportAnnotations(as format: PDF.Interchange, page: Int? = nil, index: Int? = nil) throws -> Data {
        try bytes("the annotations cannot be exported") {
            zebkit_pdf_annotations_export(
                $0, format.c, Int32(clamping: page ?? -1), Int32(clamping: index ?? -1), $1, $2)
        }
    }

    /// Adds the annotations of an XFDF or FDF file, of at most 64 MiB and
    /// 100000 annotations, and returns how many. XML is read without the
    /// network, entities or a DTD; actions in FDF are not taken over. All
    /// is checked first, and when a later one fails or a hook refuses,
    /// those added are removed again.
    @discardableResult
    public func importAnnotations(_ file: Data, as format: PDF.Interchange) throws -> Int {
        try number("the annotations cannot be imported") { handle, message in
            file.withUnsafeBytes { zebkit_pdf_annotations_import(handle, format.c, $0.baseAddress, $0.count, message) }
        }
    }
}
