import CZebkit

/// The Chrome DevTools Protocol, served by the engine as Chrome serves it
/// with `--remote-debugging-port`. On the engine's thread, while it runs.
@ZebkitActor
public enum CDP {
    /// Serves CDP on `address` (a numeric IP address; `nil` for 127.0.0.1)
    /// and `port` (0 for one the system chooses), and returns the port.
    /// When it is served already, returns that port. Throws when it cannot
    /// be served there.
    @discardableResult
    public static func listen(address: String? = nil, port: Int = 0) throws -> Int {
        guard (0...Int(UInt16.max)).contains(port) else { throw ZebkitError("\(port) is not a port") }
        var message: UnsafeMutablePointer<CChar>?
        let served = zebkit_cdp_listen(address, UInt32(port), &message)
        guard served != 0 else { throw error(taking: message, otherwise: "CDP could not be served") }
        zebkit_free(message)
        return Int(served)
    }

    /// The port CDP is served on; `nil` when it is not.
    public static var port: Int? {
        let port = zebkit_cdp_get_port()
        return port == 0 ? nil : Int(port)
    }

    /// The browser target's WebSocket address, what Puppeteer calls
    /// `browserWSEndpoint`; `nil` when CDP is not served.
    public static var url: String? {
        string(taking: zebkit_cdp_get_url())
    }

    /// Disconnects every client and stops serving CDP.
    public static func stop() {
        zebkit_cdp_stop()
    }
}
