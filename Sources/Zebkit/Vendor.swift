import CZebkit
import Foundation

/// A look at the FFmpeg inside the engine, which is Chromium's: demuxers for
/// MP4, WebM, Ogg, MP3, AAC, FLAC and WAV, and decoders for H.264, AAC, MP3,
/// Vorbis, FLAC, PCM and Opus. It has no encoders. VP8, VP9 and AV1 are
/// decoded by libvpx and dav1d, which are inside the engine too.
///
/// The engine exports FFmpeg's functions as `zebkit_vendor_ffmpeg_<name>`;
/// `Engine.symbol(named:)` reaches the rest of FFmpeg's C API. Needs no
/// running engine; opens it if nothing has, and throws when it cannot.
public enum FFmpeg {
    /// What a codec works on.
    public enum MediaType: Sendable {
        case video
        case audio
        case other
    }

    /// A codec the library was built with.
    public struct Codec: Equatable, Sendable {
        /// The short name, as in `"h264"`.
        public let name: String
        /// The descriptive name, as in `"H.264 / AVC / MPEG-4 AVC"`.
        public let longName: String
        public let mediaType: MediaType
    }

    /// FFmpeg's version, as in `"8.1.3"`.
    public static func version() throws -> String {
        typealias Function = @convention(c) () -> UnsafePointer<CChar>?
        return string(borrowing: try function("av_version_info", as: Function.self)()) ?? ""
    }

    /// libavcodec's version.
    public static func avcodecVersion() throws -> (major: Int, minor: Int, micro: Int) {
        typealias Function = @convention(c) () -> UInt32
        let version = try function("avcodec_version", as: Function.self)()
        return (Int(version >> 16), Int((version >> 8) & 0xff), Int(version & 0xff))
    }

    /// Every decoder the library has.
    public static func decoders() throws -> [Codec] {
        try codecs(where: "av_codec_is_decoder")
    }

    /// Every encoder the library has: none in this engine, so `[]`. Kept as
    /// Rust's `encoders()` is.
    public static func encoders() throws -> [Codec] {
        try codecs(where: "av_codec_is_encoder")
    }

    /// Whether there is a decoder of the short name `name`, as in `"vp9"`.
    public static func hasDecoder(named name: String) throws -> Bool {
        typealias Function = @convention(c) (UnsafePointer<CChar>?) -> UnsafeRawPointer?
        return try function("avcodec_find_decoder_by_name", as: Function.self)(name) != nil
    }

    private static func codecs(where test: String) throws -> [Codec] {
        typealias Iterate = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UnsafeRawPointer?
        typealias Test = @convention(c) (UnsafeRawPointer?) -> Int32
        let iterate = try function("av_codec_iterate", as: Iterate.self)
        let wanted = try function(test, as: Test.self)
        var found: [Codec] = []
        var position: UnsafeMutableRawPointer?
        while let codec = iterate(&position) {
            guard wanted(codec) != 0 else { continue }
            // The start of AVCodec, which is FFmpeg's public ABI:
            // const char *name, *long_name; enum AVMediaType type.
            let pointer = MemoryLayout<UnsafePointer<CChar>?>.stride
            let name = codec.load(as: UnsafePointer<CChar>?.self)
            let longName = codec.load(fromByteOffset: pointer, as: UnsafePointer<CChar>?.self)
            let type = codec.load(fromByteOffset: 2 * pointer, as: Int32.self)
            found.append(
                Codec(
                    name: string(borrowing: name) ?? "", longName: string(borrowing: longName) ?? "",
                    mediaType: type == 0 ? .video : type == 1 ? .audio : .other))
        }
        return found
    }

    /// FFmpeg's function `name`, as the engine exports it.
    private static func function<Function>(_ name: String, as type: Function.Type) throws -> Function {
        guard let symbol = try Engine.symbol(named: "zebkit_vendor_ffmpeg_" + name) else {
            throw ZebkitError("the engine has no FFmpeg function \(name)")
        }
        return unsafeBitCast(symbol, to: type)
    }
}
