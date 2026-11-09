import CZebkit
import Foundation

/// The engine: finding it, starting it, its loop, and running code on its
/// thread.
///
/// The engine has one thread, the one that starts it, and everything that
/// needs it is `ZebkitActor`'s: views, their callbacks, `quit()`. From other
/// threads, `post(_:)` runs a closure there, and a `Task { @ZebkitActor in }`
/// or an `await` gets there as to any actor. The engine's services
/// (compression, digests, PDF and the rest) need no running engine.
///
///     import Zebkit
///
///     exit(Engine.run {
///         let view = try WebView(url: "https://example.com/", width: 1024, height: 768)
///         view.onClose = { Engine.quit() }
///     })
public enum Engine {
    // MARK: Finding the engine

    /// Opens the engine in `directory`, a package directory: the one that
    /// holds `Zebkit.framework` on macOS, `libzebkit.so.1` on Linux. With
    /// `nil` it is looked for in `$ZEBKIT_DIR`, beside the executable (in a
    /// directory `zebkit`, or `../Frameworks` of an application bundle), and
    /// in the cache `zebkit-engine install` downloads to.
    ///
    /// Calling this is optional: the first use of the engine opens it from
    /// those same places, and ends the program with the reason if it is not
    /// there. Call it to open an engine from elsewhere, or to handle its
    /// absence. Once the engine is open this does nothing.
    public static func load(from directory: URL? = nil) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard zk_engine_load(directory?.path, &message) else {
            // The loader's own message: malloc()'s, as there may be no engine to free it.
            defer { free(message) }
            throw ZebkitError(message.map { String(cString: $0) } ?? "the engine could not be opened")
        }
    }

    /// Whether the engine has been opened.
    public static var isLoaded: Bool { zk_engine_is_loaded() }

    /// The package directory the engine was opened from; `nil` before that.
    public static var directory: URL? {
        zk_engine_directory().map { URL(fileURLWithPath: String(cString: $0), isDirectory: true) }
    }

    /// The version of zebkit this package was written for, as in `"0.4.0"`:
    /// the one `zebkit-engine install` downloads. Needs no engine.
    public static var releaseVersion: String { String(cString: zk_release_version()) }

    /// The address of a function of the engine's that this package does not
    /// declare, such as the `zebkit_vendor_*` of the libraries inside it
    /// (SQLite, zlib, FFmpeg and the rest); `nil` when the engine has none of
    /// that name. Opens the engine if nothing has.
    public static func symbol(named name: String) throws -> UnsafeMutableRawPointer? {
        try load()
        return zk_engine_symbol(name)
    }

    /// zebkit's version, as in `"0.4.0"`.
    public static var version: String { string(borrowing: zebkit_version()) ?? "" }

    /// The engine's, as in `"Chromium 157.0.8103.38"`.
    public static var engineVersion: String { string(borrowing: zebkit_engine_version()) ?? "" }

    // MARK: Before the engine starts

    /// Where the key that encrypts cookies is kept.
    public enum CookieStorage: Sendable {
        /// The system's key store: the Keychain, the desktop's keyring. The default.
        case system
        /// A private key file zebkit makes and uses again, in `directory`
        /// (an absolute path) or, with `nil`, in the profile's `Secrets`.
        /// Nothing is asked of the system's key store.
        case file(directory: URL? = nil)
    }

    /// Selects where the cookies' key is kept. Before the engine starts, on
    /// the thread that starts it; false after, and for a directory that is
    /// not absolute.
    @discardableResult
    public static func setCookieStorage(_ storage: CookieStorage) -> Bool {
        switch storage {
        case .system: zebkit_set_cookie_storage(ZEBKIT_COOKIE_STORAGE_OS, nil)
        case .file(let directory): zebkit_set_cookie_storage(ZEBKIT_COOKIE_STORAGE_FILE, directory?.path)
        }
    }

    /// Encrypts cookies with a key of the application's own, 32 random bytes
    /// (AES-256-GCM) it keeps and gives again at each start: no key store of
    /// the system's is used. `nil` goes back to the system's. Before the
    /// engine starts, on the thread that starts it; false after, and for a
    /// key of another size.
    @discardableResult
    public static func setCookieEncryptionKey(_ key: Data?) -> Bool {
        guard let key else { return zebkit_set_cookie_encryption_key(nil, 0) }
        return key.withUnsafeBytes { zebkit_set_cookie_encryption_key($0.bindMemory(to: UInt8.self).baseAddress, key.count) }
    }

    // MARK: The engine's own loop

    /// Starts the engine, calls `ready` once views can be made, and runs
    /// until `quit()`. Returns the exit code for the process: 1 when `ready`
    /// threw, after writing what it threw to standard error. Call it once,
    /// from `main`, on the main thread, which is the engine's from then on.
    ///
    /// Chromium's switches among `arguments` are honoured, as Chrome honours
    /// them: `--remote-debugging-port=9222`, `--user-data-dir`, `--headless`,
    /// `--no-sandbox`, `--enable-logging=stderr`. The first argument is the
    /// program's name.
    ///
    /// The loop does not end when the last view closes: that is the
    /// application's to act on (`WebView.onClose`).
    public static func run(
        arguments: [String] = CommandLine.arguments, ready: @escaping @ZebkitActor () throws -> Void
    ) -> Int32 {
        noteSandboxReach(arguments: arguments, settings: nil)
        EngineThread.claim()
        let failed = Locked(false)
        let data = Box<@ZebkitActor () -> Void>.retained {
            do {
                try ready()
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                failed.set(true)
                quit()
            }
        }
        let code = withArguments(arguments) { argc, argv in
            zebkit_main(argc, argv, { box in
                let whenReady = Box<@ZebkitActor () -> Void>.take(box)
                EngineThread.started()
                onEngineThread { whenReady?() }
            }, data)
        }
        if !EngineThread.stopped() {
            // A start that failed never called `ready`: its box is still ours.
            _ = Box<@ZebkitActor () -> Void>.take(data)
        }
        return code != 0 ? code : (failed.get() ? 1 : 0)
    }

    /// Starts the engine, runs `body`, and quits when it returns or throws:
    /// a program that is one asynchronous function. Returns the exit code
    /// for the process, 1 when `body` threw, after writing what it threw to
    /// standard error.
    ///
    ///     exit(Engine.run(until: {
    ///         let view = try WebView(url: "https://example.com/")
    ///         try await view.loadFinished()
    ///         print(try await view.evaluate("document.title", as: String.self))
    ///     }))
    public static func run(
        arguments: [String] = CommandLine.arguments, until body: @escaping @ZebkitActor () async throws -> Void
    ) -> Int32 {
        let failed = Locked(false)
        let code = run(arguments: arguments) {
            Task { @ZebkitActor in
                do {
                    try await body()
                } catch {
                    FileHandle.standardError.write(Data("\(error)\n".utf8))
                    failed.set(true)
                }
                quit()
            }
        }
        return code != 0 ? code : (failed.get() ? 1 : 0)
    }

    /// Closes every view and ends `run`'s loop, once the current callback
    /// has returned. With a loop of the application's own (`start`) it
    /// closes the views, and the application calls `shutdown()`.
    @ZebkitActor
    public static func quit() {
        zebkit_quit()
    }

    /// Whether the engine is running: `run` has called `ready`, or `start`
    /// has returned, and it has not stopped since. From any thread.
    public static var isRunning: Bool { EngineThread.isRunning }

    // MARK: A loop of the application's own

    /// Starts the engine without giving it the loop: for an application
    /// with a loop of its own (AppKit, GTK, Qt), which then calls `pump()`
    /// from it. Once per process, also after `shutdown()`; not with `run`.
    ///
    /// The thread that calls this is the engine's from then on. On macOS it
    /// has to be the main thread; on Linux any thread will do. That loop is
    /// not a task of `ZebkitActor`'s, so what it does with the engine goes
    /// in `ZebkitActor.assumeIsolated { }`.
    ///
    /// `settingsJSON` is the startup settings, applied over the matching
    /// switches of `arguments`: `profileDirectory`, `proxy`, `userAgent`,
    /// `headless`, `sandbox`, `gpu`, `logging`, `cookies`,
    /// `applicationIntegration`, `appearance` (`<zebkit/zebkit.h>`). Unknown
    /// keys and malformed values are refused before anything starts.
    public static func start(arguments: [String] = CommandLine.arguments, settingsJSON: String? = nil) throws {
        noteSandboxReach(arguments: arguments, settings: settingsJSON)
        EngineThread.claim()
        var message: UnsafeMutablePointer<CChar>?
        let code = withArguments(arguments) { argc, argv in
            zebkit_init_with_settings(argc, argv, settingsJSON, &message)
        }
        guard code == 0 else { throw error(taking: message, otherwise: "the engine did not start: \(code)") }
        zebkit_free(message)
        EngineThread.started()
    }

    /// Does what the engine and the system have ready, without waiting.
    /// From the application's loop, on the engine's thread, outside the
    /// engine's callbacks. False before `start`, after `shutdown`, and
    /// inside a callback.
    @discardableResult
    public static func pump() -> Bool {
        precondition(EngineThread.isCurrent, "zebkit: not on the engine's thread")
        return zebkit_pump()
    }

    /// Closes the views and stops the engine's threads and processes; the
    /// application's loop goes on. On the engine's thread, outside the
    /// engine's callbacks. False in the states `pump()` is false in. The
    /// engine cannot be started again in this process.
    @discardableResult
    public static func shutdown() -> Bool {
        precondition(EngineThread.isCurrent, "zebkit: not on the engine's thread")
        guard zebkit_shutdown() else { return false }
        EngineThread.stopped()
        wakeup.set(nil)
        return true
    }

    /// Tells the application's loop when to call `pump()`: no later than
    /// the given time from now (zero: promptly). For event-driven pumping
    /// in place of a timer. `nil` removes it. Before `start`; false after.
    ///
    /// `handler` may be called on any thread, also during `start`. It must
    /// only queue an event or a timer for the application's loop: never
    /// call zebkit, never block. Keep the earliest deadline asked for: a
    /// later call must not postpone earlier work.
    @discardableResult
    public static func setWakeup(_ handler: (@Sendable (Duration) -> Void)?) -> Bool {
        guard let handler else {
            guard zebkit_set_wakeup(nil, nil) else { return false }
            wakeup.set(nil)
            return true
        }
        // Stored first: the engine may call it from another thread at once.
        let previous = wakeup.get()
        wakeup.set(handler)
        let installed = zebkit_set_wakeup({ delay, _ in
            Engine.wakeup.get()?(.milliseconds(max(delay, 0)))
        }, nil)
        if !installed { wakeup.set(previous) }
        return installed
    }

    private static let wakeup = Locked<(@Sendable (Duration) -> Void)?>(nil)

    // MARK: The engine's thread

    /// Runs `work` on the engine's thread. Any thread may call it, at any
    /// time: while the engine is not running, the work waits for it (on
    /// macOS on the main dispatch queue, which is that thread's too).
    public static func post(_ work: @escaping @ZebkitActor @Sendable () -> Void) {
        EngineThread.post { onEngineThread(work) }
    }

    /// Runs `work` on the engine's thread, `delay` from now. Any thread may
    /// call it, as `post(_:)`.
    public static func post(after delay: Duration, _ work: @escaping @ZebkitActor @Sendable () -> Void) {
        EngineThread.post(after: delay) { onEngineThread(work) }
    }

    /// Whether views are without windows: there is no display, or the
    /// arguments said `--headless`.
    @ZebkitActor public static var isHeadless: Bool { zebkit_is_headless() }

    // MARK: Arguments

    /// Says on standard error, before a start on macOS that is going to fail,
    /// why it will: Chromium's sandbox lets the engine's helper processes
    /// read the program's bundle, which for a plain executable is the
    /// directory it is in, and they stop at their start when the engine is
    /// anywhere else, as in the download cache. The engine's own words for
    /// that are "GPU process isn't usable. Goodbye."
    private static func noteSandboxReach(arguments: [String], settings: String?) {
        #if os(macOS)
        if arguments.contains("--no-sandbox") { return }
        if let settings, let values = try? JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [String: Any],
            values["sandbox"] as? Bool == false
        {
            return
        }
        guard (try? load()) != nil, let engine = directory?.resolvingSymlinksInPath().path else { return }
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if engine == bundle || engine.hasPrefix(bundle + "/") { return }
        FileHandle.standardError.write(Data("""
            zebkit: the engine is at \(engine), outside this program's bundle (\(bundle)). \
            Chromium's sandbox on macOS stops the engine's helper processes there, and the engine with them. \
            Put the engine in the bundle (`swift run zebkit-engine bundle '\(bundle)'`), or pass --no-sandbox.

            """.utf8))
        #endif
    }

    /// Calls `body` with `arguments` as C's `main` has them. A zero byte
    /// ends a C string, so an argument is cut at one.
    private static func withArguments<Result>(
        _ arguments: [String], _ body: (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        defer { argv.forEach { free($0) } }
        let argc = Int32(argv.count)
        argv.append(nil)
        return argv.withUnsafeMutableBufferPointer { body(argc, $0.baseAddress!) }
    }
}

/// A duration as the engine's whole milliseconds, at most what 32 bits hold.
func milliseconds(_ duration: Duration) -> UInt32 {
    let (seconds, attoseconds) = duration.components
    let total = seconds.multipliedReportingOverflow(by: 1000)
    guard !total.overflow, total.partialValue >= 0 else { return seconds < 0 ? 0 : .max }
    let whole = total.partialValue + attoseconds / 1_000_000_000_000_000
    return UInt32(clamping: max(whole, 0))
}

/// A value several threads read and write, one at a time.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ new: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = new
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
