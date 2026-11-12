import Foundation

enum NetEaseCookieJar {
    static func update(
        existing: String,
        response: HTTPURLResponse,
        url: URL
    ) -> String? {
        let raw = response.value(forHTTPHeaderField: "Set-Cookie")
        guard let raw, !raw.isEmpty else { return nil }
        // 3.1.12: the QR login now answers from interfacepc.music.163.com. Drop each
        // cookie's Domain attribute (as the reference server does) so a cookie scoped
        // to another music.163.com host is still accepted for this request's host.
        let header = raw.replacingOccurrences(
            of: #";\s*[Dd]omain=[^;,]*"#,
            with: "",
            options: .regularExpression
        )

        let cookies = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": header],
            for: url
        )
        guard !cookies.isEmpty else { return nil }

        var ordered = parse(existing)
        let now = Date()

        for cookie in cookies {
            if let expires = cookie.expiresDate, expires <= now {
                ordered.removeAll { $0.name == cookie.name }
                continue
            }
            if let index = ordered.firstIndex(where: { $0.name == cookie.name }) {
                ordered[index].value = cookie.value
            } else {
                ordered.append((cookie.name, cookie.value))
            }
        }

        guard !ordered.isEmpty else { return "" }
        return ordered.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    static func parse(_ raw: String) -> [(name: String, value: String)] {
        raw.split(separator: ";").compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let separator = trimmed.firstIndex(of: "=")
            else { return nil }
            let name = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return (name, value)
        }
    }
}
