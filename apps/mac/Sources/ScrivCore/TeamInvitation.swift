import Foundation

/// Invitation links identify this Scriv server, not arbitrary web destinations.
public enum TeamInvitation {
    public static func token(from input: String, serverURL: URL? = nil) throws -> String {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isToken(raw) { return raw }
        guard let parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw ScrivError.invalid("Paste a valid Scriv team invitation link or token.")
        }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        let candidate: String
        if scheme == "scriv" {
            guard parts.host == "join", parts.port == nil, path.count == 2, path[0].isEmpty else {
                throw ScrivError.invalid("This is not a Scriv team invitation.")
            }
            candidate = String(path[1])
        } else {
            guard scheme == "https" || scheme == "http", path.count == 3, path[0].isEmpty, path[1] == "join", parts.host != nil else {
                throw ScrivError.invalid("This is not a Scriv team invitation.")
            }
            if let serverURL, let server = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) {
                guard scheme == server.scheme?.lowercased(), parts.host?.lowercased() == server.host?.lowercased(), effectivePort(parts) == effectivePort(server) else {
                    throw ScrivError.invalid("This invitation belongs to a different Scriv server. Check the server in Settings.")
                }
            }
            guard scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(parts.host?.lowercased() ?? "") else {
                throw ScrivError.invalid("Scriv invitation links require HTTPS.")
            }
            candidate = String(path[2])
        }
        guard isToken(candidate) else { throw ScrivError.invalid("This invitation token is incomplete or invalid.") }
        return candidate
    }

    private static func isToken(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{32,128}$", options: .regularExpression) != nil
    }
    private static func effectivePort(_ components: URLComponents) -> Int? {
        components.port ?? (components.scheme?.lowercased() == "https" ? 443 : components.scheme?.lowercased() == "http" ? 80 : nil)
    }
}
