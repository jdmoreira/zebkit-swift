import CZebkit

/// The closure of `WebView.onAuthentication`.
@ZebkitActor
final class AuthenticationState: WebViewState {
    var handler: (@ZebkitActor (String) -> Void)?
    init() {}
}

extension WebView {
    /// Shows WebAuthn's requests (passkeys, security keys, a phone) in the
    /// application's own interface, in place of the engine's: it gets each
    /// step of a request as JSON, version 1 of zebkit's `docs/PASSKEYS.md`
    /// (`version`, `request`, `revision`, `state`, and for a request still
    /// open `origin`, `rp_id`, `title`, `actions`), and the application
    /// answers with `sendAuthenticationAction(json:)`.
    ///
    /// Set it before a request: one already shown in the engine's interface
    /// stays there. `nil`, or another handler, cancels the requests in
    /// progress and stops their events at once; `nil` gives future requests
    /// the engine's interface again. Closing the view ends the events.
    ///
    /// The events hold secrets (a phone's pairing QR code, accounts): never
    /// log or keep them.
    public var onAuthentication: (@ZebkitActor (String) -> Void)? {
        get { state(AuthenticationState.self).handler }
        set {
            guard let raw else { return }
            let state = state(AuthenticationState.self)
            guard newValue != nil else {
                zebkit_view_on_authentication(raw, nil, nil)
                state.handler = nil
                return
            }
            state.handler = newValue
            zebkit_view_on_authentication(raw, { _, json, data in
                let json = string(borrowing: json) ?? "{}"
                let view = WebView.from(data)
                onEngineThread { view?.state(AuthenticationState.self).handler?(json) }
            }, callbackData)
        }
    }

    /// Answers the current step of a WebAuthn request, as JSON with the
    /// `request` and `revision` of its latest event:
    /// `{"request": "42", "revision": 3, "action": "cancel"}`. The actions
    /// are `cancel`, `system`, `external`, `bluetooth`, `pin` (with `pin`,
    /// and `confirmation` when setting one) and `account` (with `account`,
    /// an id of the latest list); only those the event lists are taken.
    ///
    /// True means the action was queued, not that the person was
    /// authenticated. False for a stale, malformed, unsupported or
    /// unavailable action, and for a closed view. Safe from inside the
    /// handler.
    @discardableResult
    public func sendAuthenticationAction(json: String) -> Bool {
        guard let raw else { return false }
        return zebkit_view_authentication_action(raw, json)
    }

    /// Enables or disables the passkey authentication UI. Views with a window
    /// have it by default; off-screen views do not. An off-screen view that
    /// has it may show a temporary authentication window only while it is
    /// focused (`setFocus(_:)`, kept in step with the application's active
    /// tab or window) and its page has a recent user activation; the window
    /// closes with the request. No credentials are made up. False for a
    /// closed view.
    @discardableResult
    public func setAuthenticationUIEnabled(_ enabled: Bool) -> Bool {
        guard let raw else { return false }
        return zebkit_view_set_authentication_ui(raw, enabled)
    }
}
