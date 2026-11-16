import Foundation

/// What the address field turns into a URL: a full URL as typed, `localhost:5173` or an
/// address of this machine over http, a host name over https, anything else a web search.
enum BrowserAddress {
    static func url(from typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about"].contains(scheme), scheme == "about" || url.host != nil || scheme == "file" {
            return url
        }
        if !text.contains(" "), let candidate = URL(string: "http://" + text), let host = candidate.host {
            if isLocal(host) { return candidate }
            if host.contains("."), host.split(separator: ".").last.map({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) == true {
                return URL(string: "https://" + text)
            }
        }
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }

    /// Loopback names, this Mac's `.local` name and private IPv4 ranges: development servers.
    static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host) || host.hasSuffix(".localhost")
            || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, host.split(separator: ".").count == 4 else { return false }
        return parts[0] == 127 || parts[0] == 10 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
    }
}
