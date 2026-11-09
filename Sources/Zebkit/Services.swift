import CZebkit
import Foundation

// The engine's services (`<zebkit/services.h>`): what Chromium has inside it
// besides the web page. Compression, cryptography and images need no running
// engine and any thread may use them; `Engine.fetch` needs the engine.

// MARK: - Compression

/// Compression with the zlib, Brotli and Zstandard inside the engine. Needs
/// no running engine; any thread may call it.
public enum DataCompression {
    /// A compressed format.
    public enum Format: Sendable, CaseIterable {
        /// RFC 1952, as `Content-Encoding: gzip`.
        case gzip
        /// RFC 1950, as `Content-Encoding: deflate`.
        case zlib
        /// RFC 1951, with no header.
        case deflateRaw
        /// RFC 7932.
        case brotli
        /// RFC 8878.
        case zstd

        var raw: zebkit_compression {
            switch self {
            case .gzip: ZEBKIT_COMPRESS_GZIP
            case .zlib: ZEBKIT_COMPRESS_ZLIB
            case .deflateRaw: ZEBKIT_COMPRESS_DEFLATE_RAW
            case .brotli: ZEBKIT_COMPRESS_BROTLI
            case .zstd: ZEBKIT_COMPRESS_ZSTD
            }
        }
    }

    /// `data` compressed in `format`. `level` `nil` is the format's default;
    /// otherwise 0-9 for zlib's formats, 0-11 for Brotli, 1-22 for Zstandard.
    public static func compress(_ data: Data, format: Format, level: Int? = nil) throws -> Data {
        var size = 0
        var message: UnsafeMutablePointer<CChar>?
        let bytes = data.withUnsafeBytes {
            zebkit_compress(format.raw, $0.baseAddress, $0.count, Int32(clamping: level ?? -1), &size, &message)
        }
        guard let bytes else { throw error(taking: message, otherwise: "the data cannot be compressed") }
        zebkit_free(message)
        return Zebkit.data(taking: bytes, count: size)
    }

    /// `data`, compressed in `format`, decompressed. Fails rather than
    /// produce more than `maxSize` bytes (`nil`: 256 MiB), against data that
    /// expands without end. Throws for a `maxSize` that is not positive.
    public static func decompress(_ data: Data, format: Format, maxSize: Int? = nil) throws -> Data {
        // 0 is the engine's word for its own limit, the largest there is.
        if let maxSize, maxSize <= 0 { throw ZebkitError("the size limit is not positive") }
        var size = 0
        var message: UnsafeMutablePointer<CChar>?
        let bytes = data.withUnsafeBytes {
            zebkit_decompress(format.raw, $0.baseAddress, $0.count, maxSize ?? 0, &size, &message)
        }
        guard let bytes else { throw error(taking: message, otherwise: "the data cannot be decompressed") }
        zebkit_free(message)
        return Zebkit.data(taking: bytes, count: size)
    }
}

// MARK: - Cryptography

/// Digests, HMAC, random bytes and AES-GCM with the BoringSSL inside the
/// engine. Needs no running engine; any thread may call it.
public enum Cryptography {
    /// A digest.
    public enum Digest: Sendable, CaseIterable {
        case sha1
        case sha256
        case sha384
        case sha512

        var raw: zebkit_digest {
            switch self {
            case .sha1: ZEBKIT_DIGEST_SHA1
            case .sha256: ZEBKIT_DIGEST_SHA256
            case .sha384: ZEBKIT_DIGEST_SHA384
            case .sha512: ZEBKIT_DIGEST_SHA512
            }
        }

        /// The size of the digest in bytes: 20, 32, 48 or 64.
        public var size: Int { zebkit_digest_size(raw) }
    }

    /// The `digest` of `data`.
    public static func digest(_ digest: Digest, of data: Data) -> Data {
        var out = Data(count: digest.size)
        let done = out.withUnsafeMutableBytes { out in
            data.withUnsafeBytes {
                zebkit_digest_compute(digest.raw, $0.baseAddress, $0.count, out.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        precondition(done, "zebkit_digest_compute failed for a known digest")
        return out
    }

    /// The HMAC of `data` with `key` and `digest`.
    public static func hmac(_ digest: Digest, key: Data, data: Data) -> Data {
        var out = Data(count: digest.size)
        let done = out.withUnsafeMutableBytes { out in
            key.withUnsafeBytes { key in
                data.withUnsafeBytes {
                    zebkit_hmac(
                        digest.raw, key.baseAddress, key.count, $0.baseAddress, $0.count,
                        out.bindMemory(to: UInt8.self).baseAddress)
                }
            }
        }
        precondition(done, "zebkit_hmac failed for a known digest")
        return out
    }

    /// `count` bytes from the system's secure random source.
    public static func randomBytes(count: Int) -> Data {
        var out = Data(count: max(count, 0))
        let done = out.withUnsafeMutableBytes { zebkit_random_bytes($0.baseAddress, $0.count) }
        precondition(done, "the system's secure random source failed")
        return out
    }

    /// `plaintext` sealed with AES-GCM and a 16-byte tag: the ciphertext
    /// followed by the tag. `key` is 16 or 32 bytes (AES-128 or AES-256),
    /// `nonce` 12 bytes and never used twice with the same key.
    /// `authenticating` is authenticated, not encrypted.
    public static func sealAESGCM(_ plaintext: Data, key: Data, nonce: Data, authenticating: Data = Data()) throws -> Data {
        try aesGCM(zebkit_aes_gcm_seal, plaintext, key: key, nonce: nonce, ad: authenticating, failure: "the data cannot be sealed")
    }

    /// The plaintext of what `sealAESGCM` sealed with the same `key`, `nonce`
    /// and `authenticating`. Fails when anything was changed.
    public static func openAESGCM(_ sealed: Data, key: Data, nonce: Data, authenticating: Data = Data()) throws -> Data {
        try aesGCM(zebkit_aes_gcm_open, sealed, key: key, nonce: nonce, ad: authenticating, failure: "the data cannot be opened")
    }

    private typealias AESGCM = (
        UnsafeRawPointer?, Int, UnsafeRawPointer?, Int, UnsafeRawPointer?, Int, UnsafeRawPointer?, Int,
        UnsafeMutablePointer<Int>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> UnsafeMutablePointer<UInt8>?

    private static func aesGCM(_ function: AESGCM, _ input: Data, key: Data, nonce: Data, ad: Data, failure: String) throws -> Data {
        var size = 0
        var message: UnsafeMutablePointer<CChar>?
        let bytes = key.withUnsafeBytes { key in
            nonce.withUnsafeBytes { nonce in
                ad.withUnsafeBytes { ad in
                    input.withUnsafeBytes { input in
                        function(
                            key.baseAddress, key.count, nonce.baseAddress, nonce.count, ad.baseAddress, ad.count,
                            input.baseAddress, input.count, &size, &message)
                    }
                }
            }
        }
        guard let bytes else { throw error(taking: message, otherwise: failure) }
        zebkit_free(message)
        return Zebkit.data(taking: bytes, count: size)
    }
}

// MARK: - URLs

/// URLs as Chromium's parser parses and canonicalizes them. Needs no running
/// engine; any thread may call it. In a process that also starts the
/// engine, use it once the engine is ready (`Engine.run`'s `ready`):
/// Chromium registers and locks URL schemes during startup, before any URLs
/// are parsed. Without the engine, `Engine.loadICUData()` first.
public enum URLParsing {
    /// A part of a URL.
    public enum Part: Sendable, CaseIterable {
        /// The whole URL, canonical.
        case spec
        /// As in `"https"`.
        case scheme
        case username
        case password
        /// As in `"example.com"` or `"[::1]"`; punycode for IDN.
        case host
        /// `""` when it is the scheme's default.
        case port
        /// As in `"/a/b"`.
        case path
        /// Without the `?`.
        case query
        /// Without the `#`.
        case fragment
        /// As in `"https://example.com"`, or `"null"`.
        case origin

        var raw: zebkit_url_part {
            switch self {
            case .spec: ZEBKIT_URL_SPEC
            case .scheme: ZEBKIT_URL_SCHEME
            case .username: ZEBKIT_URL_USERNAME
            case .password: ZEBKIT_URL_PASSWORD
            case .host: ZEBKIT_URL_HOST
            case .port: ZEBKIT_URL_PORT
            case .path: ZEBKIT_URL_PATH
            case .query: ZEBKIT_URL_QUERY
            case .fragment: ZEBKIT_URL_FRAGMENT
            case .origin: ZEBKIT_URL_ORIGIN
            }
        }
    }

    /// `part` of `url`, resolved against `base` when there is one, as a
    /// browser parses and canonicalizes it. `nil` when it is not a valid URL.
    public static func part(_ part: Part, of url: String, relativeTo base: String? = nil) -> String? {
        base.withOptionalCString { string(taking: zebkit_url_get(url, $0, part.raw)) }
    }

    /// The registrable domain of a host or URL, by the public suffix list:
    /// `"example.co.uk"` for `"a.b.example.co.uk"`. `""` for a host that has
    /// none (an IP address, `"localhost"`, a public suffix itself); `nil`
    /// when it is not valid.
    public static func registrableDomain(of hostOrURL: String) -> String? {
        string(taking: zebkit_url_registrable_domain(hostOrURL))
    }
}

// MARK: - Images

/// Pixels as 8-bit R, G, B, A, not premultiplied, rows top to bottom: what
/// `ImageCodec` decodes and encodes, `PDF` renders, `Drawing.Canvas` draws
/// and gives, and `Automation.screenshot(of:)` takes.
public struct Bitmap: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// R, G, B, A for each pixel, not premultiplied, in rows top to
    /// bottom: `width * height * 4` bytes.
    public var rgba: Data

    public init(width: Int, height: Int, rgba: Data) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

/// Image files with Chromium's codecs. Needs no running engine; any thread
/// may call it.
public enum ImageCodec {

    /// A format to encode an image in.
    public enum Format: Sendable, Equatable {
        case png
        /// `quality` 0-100; what is outside is taken as the nearer end.
        case jpeg(quality: Int)
        /// Lossy WebP, `quality` 0-100; what is outside is taken as the
        /// nearer end.
        case webp(quality: Int)
        case webpLossless

        var raw: (format: zebkit_image_format, quality: Int32) {
            // Outside 0-100 the engine means something else: its default
            // quality below, lossless WebP above.
            switch self {
            case .png: (ZEBKIT_IMAGE_PNG, 0)
            case .jpeg(let quality): (ZEBKIT_IMAGE_JPEG, Int32(min(max(quality, 0), 100)))
            case .webp(let quality): (ZEBKIT_IMAGE_WEBP, Int32(min(max(quality, 0), 100)))
            case .webpLossless: (ZEBKIT_IMAGE_WEBP, 101)
            }
        }
    }

    /// Decodes an image file: PNG, JPEG, WebP, and what else the engine's
    /// Skia reads.
    public static func decode(_ file: Data) throws -> Bitmap {
        var width: Int32 = 0
        var height: Int32 = 0
        var message: UnsafeMutablePointer<CChar>?
        let bytes = file.withUnsafeBytes { zebkit_image_decode($0.baseAddress, $0.count, &width, &height, &message) }
        guard let bytes else { throw error(taking: message, otherwise: "the image cannot be decoded") }
        zebkit_free(message)
        let rgba = data(taking: bytes, count: Int(width) * Int(height) * 4)
        return Bitmap(width: Int(width), height: Int(height), rgba: rgba)
    }

    /// `bitmap` as a file in `format`. Fails for pixels that are not
    /// `width * height * 4` bytes.
    public static func encode(_ bitmap: Bitmap, as format: Format) throws -> Data {
        guard bitmap.width > 0, bitmap.height > 0, bitmap.rgba.count == bitmap.width * bitmap.height * 4 else {
            throw ZebkitError("the pixels are not width by height RGBA")
        }
        var size = 0
        var message: UnsafeMutablePointer<CChar>?
        let (raw, quality) = format.raw
        let bytes = bitmap.rgba.withUnsafeBytes {
            zebkit_image_encode(
                raw, $0.bindMemory(to: UInt8.self).baseAddress, Int32(clamping: bitmap.width),
                Int32(clamping: bitmap.height), quality, &size, &message)
        }
        guard let bytes else { throw error(taking: message, otherwise: "the image cannot be encoded") }
        zebkit_free(message)
        return data(taking: bytes, count: size)
    }
}

// MARK: - ICU and fetch

extension Engine {
    /// Loads ICU's data (`icudtl.dat`, beside the engine), so that the ICU
    /// inside the engine, and `URLParsing`, can be used without the engine
    /// running. Calling it again, or with the engine running, does no harm.
    /// In a process that also starts the engine, use ICU's services once it
    /// is ready instead. Any thread may call it. Fails when the data is not
    /// found or not loaded.
    public static func loadICUData() throws {
        guard zebkit_icu_init() else { throw ZebkitError("ICU's data could not be loaded") }
    }

    /// Sends a request through the engine's network stack: HTTP/1.1, HTTP/2
    /// and HTTP/3, its cache, its cookies and its proxy settings, as the
    /// browser makes a request of its own (no CORS, no page). `method` `nil`
    /// is GET. Redirects are followed; a body over 256 MiB fails. Needs the
    /// engine running.
    ///
    /// Throws when there was no response. A response whose body then failed
    /// is returned, with the failure in its `error`.
    @ZebkitActor
    public static func fetch(
        _ url: String, method: String? = nil, headers: [HTTPHeader] = [], body: Data? = nil
    ) async throws -> FetchResponse {
        typealias Continuation = CheckedContinuation<FetchResponse, Never>
        guard isRunning else { throw ZebkitError("the engine is not running") }
        // A line break in a header would be the start of another header.
        guard !headers.contains(where: { ($0.name + $0.value).contains(where: \.isNewline) }) else {
            throw ZebkitError("a header has a line break in it")
        }
        let headerLines = headers.lines
        let response = await withCheckedContinuation { (continuation: Continuation) in
            let data = Box<Continuation>.retained(continuation)
            method.withOptionalCString { method in
                headerLines.withOptionalCString { headerLines in
                    (body ?? Data()).withUnsafeBytes { body in
                        zebkit_fetch(method, url, headerLines, body.baseAddress, body.count, { response, data in
                            let answer = response.map { FetchResponse($0.pointee) }
                                ?? FetchResponse(status: 0, url: "", headers: [], body: Data(), error: "no response")
                            Box<Continuation>.take(data)?.resume(returning: answer)
                        }, data)
                    }
                }
            }
        }
        if response.status == 0 { throw ZebkitError(response.error ?? "no response") }
        return response
    }
}

/// The answer to `Engine.fetch`.
public struct FetchResponse: Equatable, Sendable {
    /// The HTTP status.
    public let status: Int
    /// The URL after redirects.
    public let url: String
    /// Each header as it came.
    public let headers: [HTTPHeader]
    public let body: Data
    /// Why the body failed to arrive whole; `nil` when it came.
    public let error: String?

    init(status: Int, url: String, headers: [HTTPHeader], body: Data, error: String?) {
        self.status = status
        self.url = url
        self.headers = headers
        self.body = body
        self.error = error
    }

    /// A copy of what the engine lends for the length of its callback.
    init(_ response: zebkit_response) {
        let lines = string(borrowing: response.headers) ?? ""
        self.init(
            status: Int(response.status),
            url: string(borrowing: response.url) ?? "",
            headers: HTTPHeader.parse(lines),
            body: data(borrowing: response.body, count: response.body_size),
            error: string(borrowing: response.error))
    }

    /// The value of the first header named `name`, in any case.
    public func header(_ name: String) -> String? {
        headers.value(named: name)
    }
}
