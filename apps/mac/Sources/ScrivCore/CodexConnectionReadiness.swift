import Foundation

/// Runtime transport and authentication are separate facts. A stopped Scriv
/// connection says nothing about a CLI/desktop account already signed in.
public enum CodexConnectionReadiness: Equatable, Sendable {
    case disconnected, checkingAccount, signedOut, ready
    public init(isConnected: Bool, accountChecked: Bool, accountLabel: String?) {
        if !isConnected { self = .disconnected }
        else if !accountChecked { self = .checkingAccount }
        else if accountLabel == nil { self = .signedOut }
        else { self = .ready }
    }
    public var requiresSignIn: Bool { self == .signedOut }
    public var generationBlocker: String? {
        switch self {
        case .disconnected: return "Scriv is not connected to the local Codex runtime. Open Codex on this Mac and choose Start, or Connect to an already-running local server. Your existing CLI or desktop sign-in may already be valid; no new sign-in has been requested."
        case .checkingAccount: return "The local runtime is connected, but its account status is still being checked. Wait for that check before generating; no new sign-in is needed unless this runtime reports that it is signed out."
        case .signedOut: return "The connected Codex runtime reports no signed-in account. Choose Sign in under Codex on this Mac, or connect the local runtime that already holds your ChatGPT sign-in."
        case .ready: return nil
        }
    }
}
