import Foundation

/// No bearer-authenticated API call may resolve a caller-supplied URL off origin.
public enum CloudEndpoint {
    public static func isValid(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", let host = url.host, !host.isEmpty else { return false }
        return url.scheme == "https" || url.scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }
    public static func apiURL(path: String, base: URL) throws -> URL {
        guard isValid(base), path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let relative = URLComponents(string: path), relative.scheme == nil, relative.host == nil,
              relative.user == nil, relative.password == nil, relative.fragment == nil,
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host, url.port == base.port else { throw ScrivError.invalid("Cloud API paths must stay on the configured Scriv server.") }
        // Dot segments can turn a harmless identifier into another API endpoint.
        let decoded = relative.percentEncodedPath.removingPercentEncoding ?? relative.path
        guard !decoded.contains("\\"), !decoded.hasPrefix("//"), !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else { throw ScrivError.invalid("Cloud API paths cannot contain traversal components.") }
        return url
    }
    public static func queryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
    }
}
