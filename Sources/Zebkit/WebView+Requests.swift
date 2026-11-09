import CZebkit
import Foundation

// The requests of <zebkit/hooks.h> that a view's pages make, each answered
// once with `respond(_:)`. `NetworkRequest` is in WebView+Network.swift.

/// What a permission is, for a page of an origin: the view's rule, and the
/// answer to a request.
public enum PermissionState: Sendable {
    /// The page is asked (as an answer: the request is dismissed).
    case prompt
    case granted
    case denied

    init?(_ state: zebkit_permission_state) {
        switch state {
        case ZEBKIT_PERMISSION_PROMPT: self = .prompt
        case ZEBKIT_PERMISSION_GRANTED: self = .granted
        case ZEBKIT_PERMISSION_DENIED: self = .denied
        default: return nil
        }
    }

    var raw: zebkit_permission_state {
        switch self {
        case .prompt: ZEBKIT_PERMISSION_PROMPT
        case .granted: ZEBKIT_PERMISSION_GRANTED
        case .denied: ZEBKIT_PERMISSION_DENIED
        }
    }
}

/// A permission a page asked for (`onPermission`). The metadata has `id`,
/// `permission`, `requestingOrigin`, `topOrigin`, `userGesture`,
/// `timeoutMs`, `deadlineUnixMs` and `state`. Navigation, the view closing,
/// a replaced handler and the deadline settle it.
@ZebkitActor
public final class PermissionRequest: RequestToken {
    let raw: OpaquePointer
    public let metadataJSON: String

    init(raw: OpaquePointer, metadataJSON: String) {
        self.raw = raw
        self.metadataJSON = metadataJSON
    }

    public var infoJSON: String? { string(taking: zebkit_permission_request_info(raw)) }

    public enum Answer: Sendable, Equatable {
        /// Grants it; with `remember`, for the origin from now on.
        case grant(remember: Bool = false)
        /// Denies it; with `remember`, for the origin from now on.
        case deny(remember: Bool = false)
        /// Dismisses it, as a person closing the prompt would.
        case dismiss
    }

    /// Answers the request. An opaque origin's decision cannot be
    /// remembered; nor can approximate-only geolocation's apart from
    /// geolocation's. Throws when the answer is not taken.
    public func respond(_ answer: Answer) throws {
        switch answer {
        case .grant(let remember): try taken(zebkit_permission_respond(raw, ZEBKIT_PERMISSION_GRANTED, remember))
        case .deny(let remember): try taken(zebkit_permission_respond(raw, ZEBKIT_PERMISSION_DENIED, remember))
        case .dismiss: try taken(zebkit_permission_respond(raw, ZEBKIT_PERMISSION_PROMPT, false))
        }
    }
}

/// A document navigation at one of its stages (`onNavigation`). The
/// metadata has `id`, `navigationId`, `frameId`, `phase`, `url` (a
/// redirect's destination), `method`, `mainFrame`, `userGesture`,
/// `rendererInitiated`, `sameDocument`, `referrer`, `redirectChain`,
/// `responseStatus`, `responseHeaders`, `netError`, `timeoutMs` and
/// `deadlineUnixMs`. Closing, superseding or cancelling the navigation
/// settles it.
@ZebkitActor
public final class NavigationRequest: RequestToken {
    let raw: OpaquePointer
    public let metadataJSON: String

    init(raw: OpaquePointer, metadataJSON: String) {
        self.raw = raw
        self.metadataJSON = metadataJSON
    }

    public var infoJSON: String? { string(taking: zebkit_navigation_request_info(raw)) }

    public enum Answer: Sendable, Equatable {
        /// Lets the navigation go on.
        case proceed
        /// Stops it.
        case cancel
        /// Cancels it and starts a GET of `url` in the same frame.
        case redirect(to: String)
    }

    /// Answers the request. Throws when the answer is not taken: an
    /// invalid one leaves the request pending.
    public func respond(_ answer: Answer) throws {
        try checked("the answer was not taken: the request is settled, or the answer is invalid") { message in
            switch answer {
            case .proceed: zebkit_navigation_respond(raw, ZEBKIT_NAVIGATION_CONTINUE, nil, message)
            case .cancel: zebkit_navigation_respond(raw, ZEBKIT_NAVIGATION_CANCEL, nil, message)
            case .redirect(let url): zebkit_navigation_respond(raw, ZEBKIT_NAVIGATION_REDIRECT, url, message)
            }
        }
    }
}

/// A document's certificate error (`onCertificate`). The metadata has the
/// URL, `error`, `mainFrame`, `strictEnforcement`, `canIgnore`, the
/// certificate's subject, issuer and validity, `certStatus`, `knownRoot`, a
/// bounded PEM `certificateChain` and `chainTruncated`: not a verdict on
/// trust. Unanswered, it is denied.
@ZebkitActor
public final class CertificateRequest: RequestToken {
    let raw: OpaquePointer
    public let metadataJSON: String

    init(raw: OpaquePointer, metadataJSON: String) {
        self.raw = raw
        self.metadataJSON = metadataJSON
    }

    public var infoJSON: String? { string(taking: zebkit_certificate_request_info(raw)) }

    public enum Answer: Sendable, Equatable {
        /// Goes on despite the error, for this request only. Refused for a
        /// `strictEnforcement` error.
        case proceed
        /// Fails the load.
        case deny
    }

    /// Answers the request. Throws when the answer is not taken.
    public func respond(_ answer: Answer) throws {
        try taken(zebkit_certificate_respond(raw, answer == .proceed))
    }
}

/// An HTTP authentication challenge (`onHTTPAuth`), a proxy's too. URL
/// userinfo in the metadata is redacted.
@ZebkitActor
public final class HTTPAuthRequest: RequestToken {
    let raw: OpaquePointer
    public let metadataJSON: String

    init(raw: OpaquePointer, metadataJSON: String) {
        self.raw = raw
        self.metadataJSON = metadataJSON
    }

    public var infoJSON: String? { string(taking: zebkit_http_auth_request_info(raw)) }

    public enum Answer: Sendable, Equatable {
        /// Sends these credentials (empty strings are allowed), each at most
        /// 65536 bytes of UTF-8. They are not put in any JSON.
        case credentials(user: String, password: String)
        /// Cancels the challenge.
        case cancel
    }

    /// Answers the request. Throws when the answer is not taken: an
    /// invalid one leaves the challenge pending.
    public func respond(_ answer: Answer) throws {
        switch answer {
        case .credentials(let user, let password): try taken(zebkit_http_auth_respond(raw, user, password))
        case .cancel: try taken(zebkit_http_auth_respond(raw, nil, nil))
        }
    }
}

/// A download (`onDownload`). The metadata has `downloadId`, `url`,
/// `suggestedName`, `mimeType`, `totalBytes` (null when unknown),
/// `userGesture`, `origin`, `timeoutMs`, `deadlineUnixMs`. Unanswered, it
/// is cancelled.
@ZebkitActor
public final class DownloadRequest: RequestToken {
    let raw: OpaquePointer
    public let metadataJSON: String

    init(raw: OpaquePointer, metadataJSON: String) {
        self.raw = raw
        self.metadataJSON = metadataJSON
    }

    public var infoJSON: String? { string(taking: zebkit_download_request_info(raw)) }

    public enum Answer: Sendable, Equatable {
        /// Saves it at `file`, an absolute file URL in a directory that
        /// exists; a file there is replaced.
        case save(to: URL)
        /// Cancels it.
        case cancel
    }

    /// Answers the request. Throws when the answer is not taken: an
    /// invalid one leaves the request pending.
    public func respond(_ answer: Answer) throws {
        try checked("the answer was not taken: the request is settled, or the answer is invalid") { message in
            switch answer {
            case .save(let file): zebkit_download_respond(raw, ZEBKIT_DOWNLOAD_SAVE, file.path, message)
            case .cancel: zebkit_download_respond(raw, ZEBKIT_DOWNLOAD_CANCEL, nil, message)
            }
        }
    }
}

/// A TLS server's request for a client certificate (`onClientCertificate`).
/// The metadata has `host`, `port`, `proxy`, `certificateAuthorities`
/// (base64 DER names), `timeoutMs`, `deadlineUnixMs`, and, with the engine
/// setting `clientCertificateStores` true, `identities`: the system store's
/// that match. Unanswered, it is cancelled.
@ZebkitActor
public final class ClientCertificateRequest: RequestToken {
    let raw: OpaquePointer
    public let metadataJSON: String

    init(raw: OpaquePointer, metadataJSON: String) {
        self.raw = raw
        self.metadataJSON = metadataJSON
    }

    public var infoJSON: String? { string(taking: zebkit_client_certificate_request_info(raw)) }

    public enum Answer: Sendable, Equatable {
        /// Goes on without a certificate. Remembered for the host and port
        /// in the whole context.
        case withoutCertificate
        /// Sends a PEM chain, leaf first, with its PEM private key (RSA or
        /// EC). Remembered for the host and port in the whole context.
        case provide(certificatePEM: String, keyPEM: String)
        /// Sends `metadata.identities[index]`, the system store's, whose key
        /// stays in the store. The request ends once the store has given
        /// its key, or as `cancel` when it gives none.
        case identity(index: Int)
        /// Fails the request. Not remembered.
        case cancel
    }

    /// Answers the request. Throws when the answer is not taken (a key that
    /// does not match the leaf, anything invalid): the request stays pending.
    public func respond(_ answer: Answer) throws {
        try checked("the answer was not taken: the request is settled, or the answer is invalid") { message in
            switch answer {
            case .withoutCertificate:
                zebkit_client_certificate_respond(raw, ZEBKIT_CLIENT_CERTIFICATE_NONE, nil, nil, message)
            case .provide(let certificate, let key):
                zebkit_client_certificate_respond(raw, ZEBKIT_CLIENT_CERTIFICATE_PROVIDE, certificate, key, message)
            case .identity(let index):
                index >= 0 && zebkit_client_certificate_choose(raw, index, message)
            case .cancel:
                zebkit_client_certificate_respond(raw, ZEBKIT_CLIENT_CERTIFICATE_CANCEL, nil, nil, message)
            }
        }
    }
}

/// A page's file chooser (`onFileChooser`). The metadata has `mode`
/// (`open`, `open-multiple`, `upload-folder`, `directory`, `save`), `api`
/// (`input`, `file-system-access`), `title`, `defaultFileName`,
/// `acceptTypes`, `capture`, `frameId`, `mainFrame`, `origin`. Unanswered,
/// it is cancelled.
@ZebkitActor
public final class FileChooserRequest: RequestToken {
    let raw: OpaquePointer
    public let metadataJSON: String

    init(raw: OpaquePointer, metadataJSON: String) {
        self.raw = raw
        self.metadataJSON = metadataJSON
    }

    public var infoJSON: String? { string(taking: zebkit_file_chooser_request_info(raw)) }

    public enum Answer: Sendable, Equatable {
        /// Absolute file URLs: one for `open`, `save`, `directory` and
        /// `upload-folder` (a directory, whose files the page gets). What a
        /// File System Access page may do with them beyond reading what was
        /// picked and writing where it saves is the `file-system-read` and
        /// `file-system-write` permissions'.
        case select([URL])
        /// Cancels the chooser.
        case cancel
    }

    /// Answers the request. Throws when the answer is not taken.
    public func respond(_ answer: Answer) throws {
        let files: [URL]
        switch answer {
        case .select(let selected): files = selected
        case .cancel: files = []
        }
        let paths: [UnsafeMutablePointer<CChar>?] = files.map { strdup($0.path) }
        defer { paths.forEach { free($0) } }
        try checked("the answer was not taken: the request is settled, or the answer is invalid") { message in
            paths.withUnsafeBufferPointer { buffer in
                buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) {
                    zebkit_file_chooser_respond(raw, $0.baseAddress, $0.count, message)
                }
            }
        }
    }
}

/// A page's `EyeDropper.open()` (`onEyeDropper`). The metadata has
/// `origin`, `frameId`, `mainFrame`. Unanswered, it is cancelled.
@ZebkitActor
public final class EyeDropperRequest: RequestToken {
    let raw: OpaquePointer
    public let metadataJSON: String

    init(raw: OpaquePointer, metadataJSON: String) {
        self.raw = raw
        self.metadataJSON = metadataJSON
    }

    public var infoJSON: String? { string(taking: zebkit_eye_dropper_request_info(raw)) }

    public enum Answer: Sendable, Equatable {
        /// The colour picked, `"#rrggbb"`.
        case color(String)
        case cancel
    }

    /// Answers the request. Throws when the answer is not taken.
    public func respond(_ answer: Answer) throws {
        switch answer {
        case .color(let color): try taken(zebkit_eye_dropper_respond(raw, color))
        case .cancel: try taken(zebkit_eye_dropper_respond(raw, nil))
        }
    }
}

/// A page's USB, HID or serial chooser (`onDeviceChooser`). The metadata has
/// `kind` (`usb`, `hid`, `serial`), `origin`, `frameId`, the page's
/// `filters`, and `devices`, the system's that match, each with an `id`, a
/// `name` and what its kind has. `infoJSON` has the devices as they are now.
@ZebkitActor
public final class DeviceChooserRequest: RequestToken {
    let raw: OpaquePointer
    public let metadataJSON: String

    init(raw: OpaquePointer, metadataJSON: String) {
        self.raw = raw
        self.metadataJSON = metadataJSON
    }

    public var infoJSON: String? { string(taking: zebkit_device_chooser_request_info(raw)) }

    public enum Answer: Sendable, Equatable {
        /// The device of this `id`, which the origin may then use while the
        /// engine runs.
        case device(id: String)
        /// No device.
        case cancel
    }

    /// Answers the request. Throws when the answer is not taken.
    public func respond(_ answer: Answer) throws {
        switch answer {
        case .device(let id): try taken(zebkit_device_chooser_respond(raw, id))
        case .cancel: try taken(zebkit_device_chooser_respond(raw, nil))
        }
    }
}

/// A page's `navigator.share()` (`onShare`). The metadata has `title`,
/// `text`, `url`, `files` (their names), `origin`. Unanswered, it is
/// cancelled.
@ZebkitActor
public final class ShareRequest: RequestToken {
    let raw: OpaquePointer
    public let metadataJSON: String

    init(raw: OpaquePointer, metadataJSON: String) {
        self.raw = raw
        self.metadataJSON = metadataJSON
    }

    public var infoJSON: String? { string(taking: zebkit_share_request_info(raw)) }

    public enum Answer: Sendable, Equatable {
        /// The application shared it.
        case shared
        /// It was not shared: the page's promise rejects.
        case cancel
    }

    /// Answers the request. Throws when the answer is not taken.
    public func respond(_ answer: Answer) throws {
        try taken(zebkit_share_respond(raw, answer == .shared))
    }
}

/// A page's request for the camera or the microphone (`onMediaAccess`). The
/// metadata has `audio`, `video`, `origin`, `frameId`, `mainFrame`,
/// `userGesture`, `requestedAudioDevices`, `requestedVideoDevices`, and
/// `audioDevices` and `videoDevices` (`{id, name}`). Screen and tab capture
/// stay refused. Unanswered, it is refused.
@ZebkitActor
public final class MediaAccessRequest: RequestToken {
    let raw: OpaquePointer
    public let metadataJSON: String

    init(raw: OpaquePointer, metadataJSON: String) {
        self.raw = raw
        self.metadataJSON = metadataJSON
    }

    public var infoJSON: String? { string(taking: zebkit_media_access_request_info(raw)) }

    public enum Answer: Sendable, Equatable {
        /// Allows it, with these devices' ids; `nil` takes what the page
        /// asked for, else the first. A device that does not exist fails as
        /// without hardware.
        case allow(audioDevice: String? = nil, videoDevice: String? = nil)
        /// Refuses it.
        case deny
    }

    /// Answers the request. Throws when the answer is not taken.
    public func respond(_ answer: Answer) throws {
        switch answer {
        case .allow(let audio, let video):
            let accepted = audio.withOptionalCString { audio in
                video.withOptionalCString { video in zebkit_media_access_respond(raw, true, audio, video) }
            }
            try taken(accepted)
        case .deny:
            try taken(zebkit_media_access_respond(raw, false, nil, nil))
        }
    }
}
