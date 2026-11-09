import CZebkit
import Foundation

/// An error the engine reported.
///
/// It is the one error this module throws: every throwing function throws
/// `ZebkitError`, and nothing else, except the decoders. `evaluate(_:as:)`
/// of `WebView` and `Script`, `Call.arguments(as:)` and
/// `WebViewRequest.metadata(as:)` also throw Swift's `DecodingError` when
/// the JSON does not fit the type asked for.
///
///     do {
///         try await view.loadFinished()
///     } catch let error as ZebkitError {
///         print(error.message)
///     }
public struct ZebkitError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// What the engine said.
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

// MARK: - What the engine hands over

/// A copy of a C string the engine still owns. `nil` for a null pointer.
func string(borrowing text: UnsafePointer<CChar>?) -> String? {
    text.map { String(cString: $0) }
}

/// A copy of a C string the engine gave away, which is then freed.
func string(taking text: UnsafeMutablePointer<CChar>?) -> String? {
    guard let text else { return nil }
    defer { zebkit_free(text) }
    return String(cString: text)
}

/// A copy of a buffer the engine gave away, which is then freed. Empty for a
/// null pointer.
func data(taking bytes: UnsafeMutablePointer<UInt8>?, count: Int) -> Data {
    guard let bytes else { return Data() }
    defer { zebkit_free(bytes) }
    return Data(bytes: bytes, count: count)
}

/// A copy of a buffer the engine still owns. Empty for a null pointer.
func data(borrowing bytes: UnsafePointer<UInt8>?, count: Int) -> Data {
    guard let bytes, count > 0 else { return Data() }
    return Data(bytes: bytes, count: count)
}

/// The error a failed call set, which is then freed, or `fallback` when it
/// set none.
func error(taking message: UnsafeMutablePointer<CChar>?, otherwise fallback: String) -> ZebkitError {
    ZebkitError(string(taking: message) ?? fallback)
}

/// Calls `body` with a place for the engine's error message, and throws that
/// message when `body` returns false.
func checked(_ fallback: String, _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Bool) throws {
    var message: UnsafeMutablePointer<CChar>?
    guard body(&message) else { throw error(taking: message, otherwise: fallback) }
    zebkit_free(message)
}

/// The value of a script or of a call from the engine: JSON, or what was
/// thrown. A value with no JSON (`undefined`) is `"null"`.
func scriptResult(json: UnsafePointer<CChar>?, error: UnsafePointer<CChar>?) -> Result<String, ZebkitError> {
    if let message = string(borrowing: error) { return .failure(ZebkitError(message)) }
    return .success(string(borrowing: json) ?? "null")
}

extension Optional where Wrapped == String {
    /// Calls `body` with the string as C sees it, or with NULL for `nil`.
    func withOptionalCString<Result>(_ body: (UnsafePointer<CChar>?) throws -> Result) rethrows -> Result {
        switch self {
        case .some(let text): try text.withCString(body)
        case .none: try body(nil)
        }
    }
}

// MARK: - What the engine is handed

/// Holds a value of any kind as an object, so that its address can be the
/// `void *data` of a C callback.
final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// A pointer that owns one reference to a new box, for a callback the
    /// engine calls exactly once: `Box.take(_:)` there gets the value back.
    static func retained(_ value: Value) -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(Box(value)).toOpaque()
    }

    /// The value of a box made by `retained(_:)`, whose reference is given up.
    static func take(_ pointer: UnsafeMutableRawPointer?) -> Value? {
        guard let pointer else { return nil }
        return Unmanaged<Box<Value>>.fromOpaque(pointer).takeRetainedValue().value
    }

    /// A pointer to the box that owns nothing: the box has to be kept alive
    /// for as long as the engine has the pointer.
    var unretained: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    /// The value of the box an unowned pointer is of.
    static func borrow(_ pointer: UnsafeMutableRawPointer?) -> Value? {
        guard let pointer else { return nil }
        return Unmanaged<Box<Value>>.fromOpaque(pointer).takeUnretainedValue().value
    }
}

/// Runs `body` as `ZebkitActor`'s, from a callback of the engine's, which is
/// on the engine's thread.
///
/// What `body` captures has to be `Sendable`, although nothing changes
/// thread: turn the callback's pointers into Swift values before it
/// (`WebView.from(data)`, `string(borrowing:)`, `Box.take(data)`), and mark
/// a handle of the engine's that has to go in as it is
/// `nonisolated(unsafe) let handle = handle`.
func onEngineThread<Result: Sendable>(_ body: @ZebkitActor () -> Result) -> Result {
    ZebkitActor.assumeIsolated(body)
}

/// Runs `body` on the engine's thread: now when this is that thread, and
/// otherwise once the engine's loop gets to it. For a `deinit`, which runs on
/// whatever thread lets go of the object last, and has a handle of the
/// engine's to give back that only the engine's thread may.
///
/// `body` has to keep alive whatever the engine may still call with until
/// then (the `data` of the handle's callbacks).
func onEngineThreadEventually(_ body: @escaping @ZebkitActor @Sendable () -> Void) {
    if EngineThread.isCurrent {
        onEngineThread(body)
    } else {
        EngineThread.post { onEngineThread(body) }
    }
}

/// Results awaited from the engine that it may never give: each is given
/// once, by the engine's callback or, when that will not come (the view
/// closed, the script was destroyed), by `giveAll(_:)`.
@ZebkitActor
final class Awaited<Value: Sendable> {
    /// One result awaited: what the engine's callback has as its `data`.
    @ZebkitActor
    final class Waiter {
        private var continuation: CheckedContinuation<Value, Never>?
        private weak var owner: Awaited?

        init(_ continuation: CheckedContinuation<Value, Never>, owner: Awaited) {
            self.continuation = continuation
            self.owner = owner
        }

        func give(_ value: Value) {
            owner?.waiters[ObjectIdentifier(self)] = nil
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    private var waiters: [ObjectIdentifier: Waiter] = [:]

    /// Calls `start` with the `data` for a callback of the engine's, and
    /// returns what that callback then gives with `give(_:to:)`, or what
    /// `giveAll(_:)` gives first.
    func value(_ start: (UnsafeMutableRawPointer) -> Void) async -> Value {
        await withCheckedContinuation { continuation in
            let waiter = Waiter(continuation, owner: self)
            waiters[ObjectIdentifier(waiter)] = waiter
            // The callback's reference: its to give up, if it is ever called.
            start(Unmanaged.passRetained(waiter).toOpaque())
        }
    }

    /// From the engine's callback, on its thread: gives `value` to the
    /// result `data` is of. Once for each `data`.
    nonisolated static func give(_ value: Value, to data: UnsafeMutableRawPointer?) {
        guard let data else { return }
        let waiter = Unmanaged<Waiter>.fromOpaque(data).takeRetainedValue()
        onEngineThread { waiter.give(value) }
    }

    /// Gives `value` to every result still awaited.
    func giveAll(_ value: Value) {
        for waiter in Array(waiters.values) { waiter.give(value) }
    }
}

// MARK: - JSON

enum JSON {
    /// `value` as JSON text.
    static func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// The value JSON text is of.
    static func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}
