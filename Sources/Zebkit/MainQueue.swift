import CZebkit
import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// Swift's main actor runs its work on the main dispatch queue, which
/// something has to drain. On macOS the engine's loop does, being the
/// system's run loop. On Linux the engine's loop is Chromium's own, which
/// knows nothing of that queue: when the engine has the main thread there,
/// without what is here a `Task` on the main actor, or an `await` there,
/// would never go on while the engine runs. (`ZebkitActor` needs none of
/// this: its work is posted to the engine's loop.)
enum MainQueue {
    /// Has the engine's thread drain the main dispatch queue whenever it has
    /// work, from now on, if that thread is the main thread. Once the engine
    /// runs: what is here posts tasks to it.
    static func drainOnEngineThread() {
        #if os(Linux)
        guard Thread.isMainThread, !started.withLock({ started in
            defer { started = true }
            return started
        }) else { return }
        // What CoreFoundation's run loop is built on: a file descriptor
        // (an eventfd) that is readable when the main queue has work, and
        // the function that does that work. libdispatch exports both for it.
        typealias Handle = @convention(c) () -> Int32
        typealias Drain = @convention(c) (UnsafeMutableRawPointer?) -> Void
        guard let handle = dlsym(nil, "_dispatch_get_main_queue_handle_4CF"),
            let callback = dlsym(nil, "_dispatch_main_queue_callback_4CF")
        else {
            pollWithRunLoop()
            return
        }
        let descriptor = unsafeBitCast(handle, to: Handle.self)()
        // The address of a function: the same for every thread.
        nonisolated(unsafe) let drain = callback
        let thread = Thread {
            var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            while true {
                guard poll(&ready, 1, -1) > 0 else {
                    if errno == EINTR { continue }
                    return
                }
                // The engine does not start again: its loop is over, and
                // the queue is the application's to run from here.
                guard EngineThread.isRunning else { return }
                // Taken, so that the next work makes the descriptor readable again.
                var count: UInt64 = 0
                _ = read(descriptor, &count, MemoryLayout<UInt64>.size)
                zebkit_post_task({ drain in
                    unsafeBitCast(drain, to: Drain.self)(nil)
                }, drain)
            }
        }
        thread.name = "zebkit main queue"
        thread.start()
        #endif
    }

    #if os(Linux)
    private static let started = Locked(false)

    /// Without libdispatch's own notification: looks at the queue every few
    /// milliseconds, through Foundation's run loop.
    private static func pollWithRunLoop() {
        zebkit_post_delayed_task({ _ in
            _ = RunLoop.current.run(mode: .default, before: Date())
            MainQueue.pollWithRunLoop()
        }, nil, 4)
    }
    #endif
}
