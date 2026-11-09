import CZebkit
import Foundation

/// A JavaScript context of the application's own, in this process, on the
/// engine's thread: V8 with the whole of `zebkit.*`, with no grants (it is
/// the application's code, as an Electron application's main process is),
/// and `zebkit.View` to make views, load pages in them and answer their
/// calls. zebkit's `docs/API.md` is the script's reference.
///
/// It runs until `close()`: its timers stop then, its views stay. One
/// that is let go of unclosed is closed then, on the engine's thread.
/// An `evaluate` or `runModule` still waiting when the script is closed
/// throws: the script will not give its result.
@ZebkitActor
public final class Script {
    // Read by `deinit`, which is the last to have the object.
    private nonisolated(unsafe) var raw: OpaquePointer?

    /// `onIdle`, where the engine calls it from: kept for as long as the
    /// engine may.
    private nonisolated(unsafe) let idle = Box<(@ZebkitActor () -> Void)?>(nil)

    /// A script that sees `arguments` as `zebkit.args`.
    public init(arguments: [String] = []) {
        var argv: [UnsafePointer<CChar>?] = arguments.map { UnsafePointer(strdup($0)) }
        defer { argv.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        let count = Int32(argv.count)
        argv.append(nil)
        raw = argv.withUnsafeBufferPointer { zebkit_script_new(count, $0.baseAddress) }
    }

    deinit {
        guard let raw else { return }
        // `idle` goes after the script that calls it.
        nonisolated(unsafe) let handle = raw
        nonisolated(unsafe) let idle = idle
        Engine.post {
            zebkit_script_destroy(handle)
            _ = idle
        }
    }

    /// Whether the script is closed.
    public var isClosed: Bool { raw == nil }

    /// Ends the script: its timers stop, its views stay.
    public func close() {
        guard let raw else { return }
        self.raw = nil
        zebkit_script_destroy(raw)
        // The engine calls nothing of a closed script.
        results.giveAll(.failure(ZebkitError("the script is closed")))
    }

    /// The results awaited of the script.
    private let results = Awaited<Result<String, ZebkitError>>()

    /// Calls `start` with a callback for a result of the script's and its
    /// data, and returns that result, or throws when the script is closed
    /// before it gives one.
    private func result(_ start: (zebkit_result_func, UnsafeMutableRawPointer) -> Void) async throws -> String {
        try await results.value { data in
            start({ _, json, error, data in
                Awaited<Result<String, ZebkitError>>.give(scriptResult(json: json, error: error), to: data)
            }, data)
        }.get()
    }

    /// Runs the ES module in `file`, with the modules it imports relative to
    /// it, and returns when its evaluation ends (for a top-level await, when
    /// the promise settles). Throws the message and stack of what it threw.
    public func runModule(at file: URL) async throws {
        guard let raw else { throw ZebkitError("the script is closed") }
        _ = try await result { zebkit_script_run_module(raw, file.path, $0, $1) }
    }

    /// Evaluates `source` as a classic script and returns its value as JSON;
    /// throws what it threw. A value JSON has nothing for (`undefined`) is
    /// `"null"`.
    @discardableResult
    public func evaluate(_ source: String) async throws -> String {
        guard let raw else { throw ZebkitError("the script is closed") }
        return try await result { zebkit_script_evaluate(raw, source, $0, $1) }
    }

    /// Evaluates `source` and decodes its value.
    public func evaluate<Value: Decodable>(_ source: String, as type: Value.Type = Value.self) async throws -> Value {
        try JSON.decode(type, from: try await evaluate(source))
    }

    /// Called once nothing of the script is pending: no timer, no call in
    /// progress, no view open, and its module evaluated. zebkit-js quits
    /// then, as Node exits.
    public var onIdle: (@ZebkitActor () -> Void)? {
        get { idle.value }
        set {
            idle.value = newValue
            guard let raw else { return }
            guard newValue != nil else { return zebkit_script_on_idle(raw, nil, nil) }
            zebkit_script_on_idle(raw, { data in
                let idle = Box<(@ZebkitActor () -> Void)?>.borrow(data)
                onEngineThread { idle??() }
            }, idle.unretained)
        }
    }
}
