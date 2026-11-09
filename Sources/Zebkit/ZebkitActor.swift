import CZebkit
import Foundation

/// The actor of the engine's thread: everything that needs the running
/// engine is isolated to it (views, their callbacks, `Engine.quit()`).
///
/// The engine has one thread, the one that started it. On macOS that is
/// always the main thread, and this actor runs on the main actor's executor:
/// an `await` between the two never changes thread. On Linux it is the
/// main thread with `Engine.run`, and with `Engine.start` any thread that
/// calls it; the actor's work is posted to the engine's loop.
///
///     Task { @ZebkitActor in
///         view.load("https://example.com/")
///     }
@globalActor
public actor ZebkitActor {
    public static let shared = ZebkitActor()

    private init() {}

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        #if canImport(Darwin)
        MainActor.sharedUnownedExecutor
        #else
        EngineExecutor.shared.asUnownedSerialExecutor()
        #endif
    }

    /// Whether this thread is the engine's.
    public static var isCurrent: Bool { EngineThread.isCurrent }

    /// Runs `operation` as this actor's, from synchronous code that is on
    /// the engine's thread and that the compiler cannot tell is: a loop of
    /// the application's own, a callback of another library's. Stops the
    /// program on any other thread.
    public static func assumeIsolated<Result: Sendable>(
        _ operation: @ZebkitActor () throws -> Result, file: StaticString = #fileID, line: UInt = #line
    ) rethrows -> Result {
        typealias Isolated = @ZebkitActor () throws -> Result
        typealias Plain = () throws -> Result
        precondition(isCurrent, "zebkit: not on the engine's thread", file: file, line: line)
        // What `MainActor.assumeIsolated` does: the same function, called
        // without the hop that the check above shows is not needed.
        return try withoutActuallyEscaping(operation) { (operation: @escaping Isolated) throws -> Result in
            try unsafeBitCast(operation, to: Plain.self)()
        }
    }
}

#if !canImport(Darwin)
/// Runs the actor's jobs on the engine's thread, as tasks of its loop.
final class EngineExecutor: SerialExecutor {
    static let shared = EngineExecutor()

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        EngineThread.post { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// For code that is on the engine's thread without being in a task: a
    /// callback of the engine's.
    func checkIsolated() {
        precondition(EngineThread.isCurrent, "zebkit: not on the engine's thread")
    }
}
#endif

/// The engine's thread: which one it is, and work for it from any thread.
enum EngineThread {
    private struct State {
        var isRunning = false
        #if !canImport(Darwin)
        var thread: pthread_t?
        /// Posted while the engine was not running: it stops the process
        /// for a task posted before it has started.
        var waiting: [@Sendable () -> Void] = []
        #endif
    }

    private static let state = Locked(State())

    /// Whether the engine is running, and so takes tasks.
    static var isRunning: Bool { state.withLock { $0.isRunning } }

    static var isCurrent: Bool {
        #if canImport(Darwin)
        Thread.isMainThread
        #else
        state.withLock { state in state.thread.map { pthread_equal($0, pthread_self()) != 0 } ?? false }
        #endif
    }

    /// Makes the calling thread the engine's, before it starts the engine.
    static func claim() {
        #if canImport(Darwin)
        precondition(Thread.isMainThread, "zebkit: on macOS the engine starts on the main thread")
        #else
        state.withLock { $0.thread = pthread_self() }
        #endif
    }

    /// The engine runs: on its thread, once it takes tasks.
    static func started() {
        #if canImport(Darwin)
        state.withLock { $0.isRunning = true }
        #else
        let waiting = state.withLock { state in
            state.isRunning = true
            defer { state.waiting = [] }
            return state.waiting
        }
        waiting.forEach(post)
        MainQueue.drainOnEngineThread()
        #endif
    }

    /// The engine has stopped. False when it was not running.
    @discardableResult
    static func stopped() -> Bool {
        state.withLock { state in
            defer { state.isRunning = false }
            return state.isRunning
        }
    }

    /// Runs `work` on the engine's thread, from any thread. While the engine
    /// is not running the work waits: on macOS on the main queue, elsewhere
    /// until the engine starts.
    static func post(_ work: @escaping @Sendable () -> Void) {
        #if canImport(Darwin)
        guard isRunning else { return DispatchQueue.main.async(execute: work) }
        #else
        let waits = state.withLock { state in
            if !state.isRunning { state.waiting.append(work) }
            return !state.isRunning
        }
        if waits { return }
        #endif
        zebkit_post_task(runPosted, Box<@Sendable () -> Void>.retained(work))
    }

    /// As `post(_:)`, `delay` from now, or from the engine's start when that
    /// is later.
    static func post(after delay: Duration, _ work: @escaping @Sendable () -> Void) {
        guard isRunning else {
            #if canImport(Darwin)
            return DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(milliseconds(delay))), execute: work)
            #else
            return post { post(after: delay, work) }
            #endif
        }
        zebkit_post_delayed_task(runPosted, Box<@Sendable () -> Void>.retained(work), milliseconds(delay))
    }

    private static let runPosted: zebkit_task_func = { data in
        Box<@Sendable () -> Void>.take(data)?()
    }
}
