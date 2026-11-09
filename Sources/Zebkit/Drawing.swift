import CZebkit
import Foundation

/// 2D drawing on the engine's Skia (`<zebkit/canvas.h>`): a canvas over a
/// bitmap of its own or over the caller's pixels, with a matrix, paths, fill
/// and stroke, colours, gradients, images, text in a font given as bytes,
/// and PNG out. None of it needs the engine running.
///
/// It works as the web's canvas does: a current path whose points are put
/// through the matrix as they are added, and a stack of state (matrix,
/// colours, line style, clip, font) kept by `save()` and `restore()`. The
/// origin is the top left, y down, units are pixels. Colours are
/// `0xRRGGBBAA`.
public enum Drawing {
    /// How a stroke's open ends are drawn.
    public enum LineCap: Sendable {
        case butt
        case round
        case square

        var raw: zebkit_canvas_cap {
            switch self {
            case .butt: ZEBKIT_CANVAS_CAP_BUTT
            case .round: ZEBKIT_CANVAS_CAP_ROUND
            case .square: ZEBKIT_CANVAS_CAP_SQUARE
            }
        }
    }

    /// How a stroke's corners are drawn.
    public enum LineJoin: Sendable {
        case miter
        case round
        case bevel

        var raw: zebkit_canvas_join {
            switch self {
            case .miter: ZEBKIT_CANVAS_JOIN_MITER
            case .round: ZEBKIT_CANVAS_JOIN_ROUND
            case .bevel: ZEBKIT_CANVAS_JOIN_BEVEL
            }
        }
    }

    /// How what is drawn mixes with what is there, by PDF's names.
    public enum BlendMode: String, Sendable, CaseIterable {
        case normal = "Normal"
        case multiply = "Multiply"
        case screen = "Screen"
        case overlay = "Overlay"
        case darken = "Darken"
        case lighten = "Lighten"
        case colorDodge = "ColorDodge"
        case colorBurn = "ColorBurn"
        case hardLight = "HardLight"
        case softLight = "SoftLight"
        case difference = "Difference"
        case exclusion = "Exclusion"
        case hue = "Hue"
        case saturation = "Saturation"
        case color = "Color"
        case luminosity = "Luminosity"
    }

    /// A stop of a gradient: where, from 0 to 1, and its colour, `0xRRGGBBAA`.
    public struct GradientStop: Equatable, Hashable, Sendable {
        public var offset: Double
        public var rgba: UInt32

        public init(offset: Double, rgba: UInt32) {
            self.offset = offset
            self.rgba = rgba
        }
    }

    /// A font from its bytes, which are copied: TrueType or OpenType
    /// outlines. A canvas keeps what it uses, so a font may go once no
    /// canvas will be set to it again. Used by one thread at a time.
    public final class Font {
        let raw: OpaquePointer

        /// The font in `data`. Fails on what is not such a font.
        public init(data: Data) throws {
            var message: UnsafeMutablePointer<CChar>?
            let raw = data.withUnsafeBytes { zebkit_canvas_font_new($0.baseAddress, $0.count, &message) }
            guard let raw else { throw error(taking: message, otherwise: "the font cannot be read") }
            zebkit_free(message)
            self.raw = raw
        }

        deinit {
            zebkit_canvas_font_close(raw)
        }
    }

    /// A canvas. A canvas is used by one thread at a time.
    ///
    /// A canvas that a PDF hook hands out to draw an appearance writes PDF
    /// operators rather than pixels: its units are points, and `bitmap()`
    /// and `png()` fail on it.
    public final class Canvas {
        /// The engine's canvas; `nil` once a canvas over the caller's pixels
        /// is closed. What a closed canvas is asked to do is not done.
        private(set) var raw: OpaquePointer?
        private let owned: Bool

        /// A transparent canvas of `width` by `height` pixels, at most 32768
        /// on a side and 1 << 28 pixels.
        public init(width: Int, height: Int) throws {
            var message: UnsafeMutablePointer<CChar>?
            guard let raw = zebkit_canvas_new(Int32(clamping: width), Int32(clamping: height), &message) else {
                throw error(taking: message, otherwise: "the canvas cannot be made")
            }
            zebkit_free(message)
            self.raw = raw
            owned = true
        }

        /// A canvas of the engine's that this one only uses.
        private init(borrowing raw: OpaquePointer?) {
            self.raw = raw
            owned = false
        }

        /// Calls `body` with the canvas a hook of the engine's lends for the
        /// length of its call, `raw`, which is the engine's to close: the
        /// canvas `body` got is closed to Swift when it returns.
        static func lend<Result>(_ raw: OpaquePointer?, _ body: (Canvas) -> Result) -> Result {
            let canvas = Canvas(borrowing: raw)
            defer { canvas.raw = nil }
            return body(canvas)
        }

        private init(owning raw: OpaquePointer) {
            self.raw = raw
            owned = true
        }

        deinit {
            if owned, let raw { zebkit_canvas_close(raw) }
        }

        /// Calls `body` with a canvas over `pixels`, R, G, B, A, `width` by
        /// `height`, `stride` bytes from row to row (`nil` for `width * 4`),
        /// and then gives them back drawn on. With `premultiplied` false the
        /// pixels are premultiplied in place for the drawing and put back
        /// after; opaque pixels are premultiplied already. The canvas is
        /// closed when `body` returns: kept beyond it, it does nothing.
        public static func drawing<Result>(
            on pixels: inout Data, width: Int, height: Int, stride: Int? = nil, premultiplied: Bool = false,
            _ body: (Canvas) throws -> Result
        ) throws -> Result {
            let rowBytes = stride ?? width * 4
            guard width > 0, height > 0, rowBytes >= width * 4, pixels.count >= rowBytes * (height - 1) + width * 4 else {
                throw ZebkitError("the pixels are not width by height RGBA")
            }
            let flags = premultiplied ? 0 : ZEBKIT_CANVAS_UNPREMULTIPLIED.rawValue
            return try pixels.withUnsafeMutableBytes { buffer in
                var message: UnsafeMutablePointer<CChar>?
                guard
                    let raw = zebkit_canvas_wrap(
                        buffer.bindMemory(to: UInt8.self).baseAddress, Int32(clamping: width), Int32(clamping: height),
                        stride ?? 0, UInt32(flags), &message)
                else { throw error(taking: message, otherwise: "the canvas cannot be made") }
                zebkit_free(message)
                let canvas = Canvas(owning: raw)
                defer {
                    canvas.raw = nil
                    zebkit_canvas_close(raw)
                }
                return try body(canvas)
            }
        }

        private func with(_ body: (OpaquePointer) -> Void) {
            if let raw { body(raw) }
        }

        // MARK: The bitmap

        /// The width in pixels; 0 once closed.
        public var width: Int { raw.map { Int(zebkit_canvas_width($0)) } ?? 0 }

        /// The height in pixels; 0 once closed.
        public var height: Int { raw.map { Int(zebkit_canvas_height($0)) } ?? 0 }

        /// A copy of the pixels, as a bitmap.
        public func bitmap() throws -> Bitmap {
            guard let raw else { throw ZebkitError("the canvas is closed") }
            let (width, height) = (Int(zebkit_canvas_width(raw)), Int(zebkit_canvas_height(raw)))
            var message: UnsafeMutablePointer<CChar>?
            guard let bytes = zebkit_canvas_pixels(raw, &message) else {
                throw error(taking: message, otherwise: "the pixels cannot be read")
            }
            zebkit_free(message)
            return Bitmap(width: width, height: height, rgba: data(taking: bytes, count: width * height * 4))
        }

        /// The pixels as a PNG file.
        public func png() throws -> Data {
            guard let raw else { throw ZebkitError("the canvas is closed") }
            var size = 0
            var message: UnsafeMutablePointer<CChar>?
            guard let bytes = zebkit_canvas_png(raw, &size, &message) else {
                throw error(taking: message, otherwise: "the PNG cannot be made")
            }
            zebkit_free(message)
            return data(taking: bytes, count: size)
        }

        // MARK: State

        /// Saves the state: matrix, colours, line style, clip, font.
        public func save() { with { zebkit_canvas_save($0) } }

        /// Restores the state last saved; does nothing when nothing is saved.
        public func restore() { with { zebkit_canvas_restore($0) } }

        public func translate(x: Double, y: Double) { with { zebkit_canvas_translate($0, x, y) } }

        public func scale(x: Double, y: Double) { with { zebkit_canvas_scale($0, x, y) } }

        public func rotate(degrees: Double) { with { zebkit_canvas_rotate($0, degrees) } }

        /// Multiplies the matrix by [a c e; b d f; 0 0 1], as the web's
        /// `transform()` and PDF's `cm`.
        public func transform(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
            with { zebkit_canvas_transform($0, a, b, c, d, e, f) }
        }

        /// Replaces the matrix, [a c e; b d f; 0 0 1]: what it maps from, to
        /// the canvas's first space.
        public func setMatrix(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
            with { zebkit_canvas_set_matrix($0, a, b, c, d, e, f) }
        }

        /// Fills with `rgba`, `0xRRGGBBAA`, from now on; ends a gradient.
        public func setFillColor(_ rgba: UInt32) { with { zebkit_canvas_set_fill_color($0, rgba) } }

        /// Strokes with `rgba`, `0xRRGGBBAA`, from now on.
        public func setStrokeColor(_ rgba: UInt32) { with { zebkit_canvas_set_stroke_color($0, rgba) } }

        /// 0 to 1, multiplied into everything drawn.
        public func setAlpha(_ alpha: Double) { with { zebkit_canvas_set_alpha($0, alpha) } }

        /// Mixes what is drawn from now on with what is there by `mode`.
        public func setBlendMode(_ mode: BlendMode) {
            with { _ = zebkit_canvas_set_blend($0, mode.rawValue) }
        }

        public func setLineWidth(_ width: Double) { with { zebkit_canvas_set_line_width($0, width) } }

        public func setLineCap(_ cap: LineCap) { with { zebkit_canvas_set_line_cap($0, cap.raw) } }

        public func setLineJoin(_ join: LineJoin) { with { zebkit_canvas_set_line_join($0, join.raw) } }

        public func setMiterLimit(_ limit: Double) { with { zebkit_canvas_set_miter_limit($0, limit) } }

        /// Dashes strokes: `lengths` on and off in turn, starting `phase`
        /// into them; empty for a solid line.
        public func setDash(_ lengths: [Double], phase: Double = 0) {
            with { raw in lengths.withUnsafeBufferPointer { zebkit_canvas_set_dash(raw, $0.baseAddress, Int32(clamping: $0.count), phase) } }
        }

        /// Fills from now on with a linear gradient from (`x0`, `y0`) to
        /// (`x1`, `y1`), in the space of the matrix now, clamped beyond its
        /// ends. `stops`: 2 to 256, offsets from 0 to 1 going up; false for
        /// others. A fill colour set later ends it.
        @discardableResult
        public func setLinearGradient(x0: Double, y0: Double, x1: Double, y1: Double, stops: [GradientStop]) -> Bool {
            guard let raw else { return false }
            return withStops(stops) { zebkit_canvas_set_linear_gradient(raw, x0, y0, x1, y1, $0, $1, $2) }
        }

        /// Fills from now on with a radial gradient around (`x`, `y`) out to
        /// `radius`, as `setLinearGradient` does.
        @discardableResult
        public func setRadialGradient(x: Double, y: Double, radius: Double, stops: [GradientStop]) -> Bool {
            guard let raw else { return false }
            return withStops(stops) { zebkit_canvas_set_radial_gradient(raw, x, y, radius, $0, $1, $2) }
        }

        private func withStops(
            _ stops: [GradientStop], _ body: (UnsafePointer<Double>?, UnsafePointer<UInt32>?, Int32) -> Bool
        ) -> Bool {
            let offsets = stops.map(\.offset)
            let colors = stops.map(\.rgba)
            return offsets.withUnsafeBufferPointer { offsets in
                colors.withUnsafeBufferPointer { body(offsets.baseAddress, $0.baseAddress, Int32(clamping: stops.count)) }
            }
        }

        // MARK: Paths

        /// Empties the current path.
        public func beginPath() { with { zebkit_canvas_begin_path($0) } }

        public func move(toX x: Double, y: Double) { with { zebkit_canvas_move_to($0, x, y) } }

        public func line(toX x: Double, y: Double) { with { zebkit_canvas_line_to($0, x, y) } }

        /// A quadratic curve to (`x`, `y`) with the control point (`cx`, `cy`).
        public func quad(toX x: Double, y: Double, cx: Double, cy: Double) {
            with { zebkit_canvas_quad_to($0, cx, cy, x, y) }
        }

        /// A cubic curve to (`x`, `y`) with the control points (`c1x`, `c1y`)
        /// and (`c2x`, `c2y`).
        public func curve(toX x: Double, y: Double, c1x: Double, c1y: Double, c2x: Double, c2y: Double) {
            with { zebkit_canvas_curve_to($0, c1x, c1y, c2x, c2y, x, y) }
        }

        /// An arc around (`x`, `y`) from `startDegrees` to `endDegrees`,
        /// clockwise on the screen, or the other way. Degrees, where the
        /// web's canvas has radians.
        public func arc(
            x: Double, y: Double, radius: Double, startDegrees: Double, endDegrees: Double, counterclockwise: Bool = false
        ) {
            with { zebkit_canvas_arc($0, x, y, radius, startDegrees, endDegrees, counterclockwise) }
        }

        public func rect(x: Double, y: Double, width: Double, height: Double) {
            with { zebkit_canvas_rect($0, x, y, width, height) }
        }

        public func closePath() { with { zebkit_canvas_close_path($0) } }

        /// Fills the current path, by the even-odd rule or by non-zero winding.
        public func fill(evenOdd: Bool = false) { with { zebkit_canvas_fill($0, evenOdd) } }

        /// Strokes the current path.
        public func stroke() { with { zebkit_canvas_stroke($0) } }

        /// Keeps what is drawn from now on inside the current path too, until
        /// `restore()`.
        public func clip(evenOdd: Bool = false) { with { zebkit_canvas_clip($0, evenOdd) } }

        /// Paints every pixel inside the clip with `rgba`, replacing what is
        /// there. On a canvas that writes PDF, what is there stays beneath.
        public func clear(_ rgba: UInt32) { with { zebkit_canvas_clear($0, rgba) } }

        // MARK: Images

        /// Draws `bitmap` over the rectangle (`x`, `y`) `width` by `height`,
        /// or at its own size when they are `nil`. False for a bitmap whose
        /// size is not positive or is over 1 << 14, or that has too few
        /// bytes.
        @discardableResult
        public func draw(_ bitmap: Bitmap, x: Double, y: Double, width: Double? = nil, height: Double? = nil) -> Bool {
            guard let raw, bitmap.width > 0, bitmap.height > 0, bitmap.rgba.count >= bitmap.width * bitmap.height * 4 else {
                return false
            }
            return bitmap.rgba.withUnsafeBytes {
                zebkit_canvas_draw_image(
                    raw, $0.bindMemory(to: UInt8.self).baseAddress, Int32(clamping: bitmap.width),
                    Int32(clamping: bitmap.height), x, y, width ?? Double(bitmap.width), height ?? Double(bitmap.height))
            }
        }

        // MARK: Text

        /// Draws text in `font` at `size` from now on.
        public func setFont(_ font: Font, size: Double) {
            with { zebkit_canvas_set_font($0, font.raw, size) }
        }

        /// Shapes `text` (as `TextShaping` does) and fills its outlines with
        /// the baseline's left end at (`x`, `y`). Fails without a font.
        /// Glyphs without outlines (colour bitmaps) draw nothing.
        public func fillText(_ text: String, x: Double, y: Double) throws {
            guard let raw else { throw ZebkitError("the canvas is closed") }
            try checked("the text cannot be drawn") { zebkit_canvas_fill_text(raw, text, x, y, $0) }
        }

        /// Adds the outlines of `text` to the current path, as `fillText`
        /// places them, to stroke or clip.
        public func addTextPath(_ text: String, x: Double, y: Double) throws {
            guard let raw else { throw ZebkitError("the canvas is closed") }
            try checked("the text cannot be drawn") { zebkit_canvas_text_path(raw, text, x, y, $0) }
        }

        /// The advance of `text` in the canvas's font; `nil` without one.
        public func measureText(_ text: String) -> Double? {
            guard let raw else { return nil }
            let advance = zebkit_canvas_measure_text(raw, text)
            return advance < 0 ? nil : advance
        }

        // MARK: A list of operations

        /// Runs `json`, a JSON array of operations, each an array with its
        /// name first, as `<zebkit/canvas.h>` lists them (`["fillColor",
        /// rgba]`, `["rect", x, y, w, h]`, `["fill", evenOdd]`, ...). At most
        /// 1000000 operations and 256 MiB. Stops at the first that is wrong,
        /// with its index in the error; those before it stay drawn.
        public func run(json: String) throws {
            guard let raw else { throw ZebkitError("the canvas is closed") }
            try checked("the operations failed") { zebkit_canvas_run(raw, json, $0) }
        }
    }
}

/// Shaping a line of text with the engine's HarfBuzz (`<zebkit/text.h>`):
/// from a font's bytes, a size and text to the glyphs to draw and where.
/// Breaking lines, choosing fonts and bidirectional reordering are the
/// application's. Needs no running engine; any thread may call it.
public enum TextShaping {
    /// The direction of a line of text.
    public enum Direction: String, Decodable, Sendable, CaseIterable {
        case leftToRight = "ltr"
        case rightToLeft = "rtl"
        case topToBottom = "ttb"
        case bottomToTop = "btt"
    }

    /// A shaped line. y is up; units are the size's.
    public struct Line: Decodable, Equatable, Sendable {
        public let direction: Direction
        /// An ISO 15924 script code, as in `"Latn"`.
        public let script: String
        public let unitsPerEm: Int
        /// The whole line's advance.
        public let advance: Vector
        /// In visual order: in right-to-left text clusters go down.
        public let glyphs: [Glyph]
    }

    /// A glyph of a shaped line.
    public struct Glyph: Decodable, Equatable, Sendable {
        /// The glyph's index in the font.
        public let index: Int
        /// The byte of the text's UTF-8 the glyph came from.
        public let cluster: Int
        /// How far the pen moves after it.
        public let advance: Vector
        /// Where it is drawn, from the pen.
        public let offset: Vector

        enum CodingKeys: String, CodingKey {
            case index = "glyph", cluster, advance, offset
        }
    }

    /// x and y, in the size's units.
    public struct Vector: Decodable, Equatable, Hashable, Sendable {
        public let x: Double
        public let y: Double

        public init(from decoder: Decoder) throws {
            var pair = try decoder.unkeyedContainer()
            x = try pair.decode(Double.self)
            y = try pair.decode(Double.self)
        }
    }

    /// `text` shaped as `shape` does, as the engine's JSON.
    static func shapeJSON(
        _ text: String, font: Data, size: Double, language: String? = nil, direction: Direction? = nil
    ) throws -> String {
        var message: UnsafeMutablePointer<CChar>?
        let answer = font.withUnsafeBytes { font in
            language.withOptionalCString { language in
                (direction?.rawValue).withOptionalCString { direction in
                    zebkit_text_shape(font.baseAddress, font.count, size, text, language, direction, &message)
                }
            }
        }
        guard let answer else { throw error(taking: message, otherwise: "the text cannot be shaped") }
        zebkit_free(message)
        return string(taking: answer) ?? ""
    }

    /// `text` shaped in the font in `font` (TrueType or OpenType; the first
    /// face of a collection) at `size` units per em. `language` is a BCP 47
    /// tag (`"ar"`, `"zh-Hans"`); `direction` `nil` tells from the text.
    /// Fails on what is not a font, a size not above 0 or above 100000, a
    /// font over 256 MiB, a text over 16 MiB.
    public static func shape(
        _ text: String, font: Data, size: Double, language: String? = nil, direction: Direction? = nil
    ) throws -> Line {
        try JSON.decode(Line.self, from: try shapeJSON(text, font: font, size: size, language: language, direction: direction))
    }
}
