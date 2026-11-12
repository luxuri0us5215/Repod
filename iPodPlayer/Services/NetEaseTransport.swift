import Foundation

enum NetEaseConnectionMode: String, CaseIterable, Sendable {
    case direct
    case gateway

    static func resolved(storedRaw: String?, address: String?) -> NetEaseConnectionMode {
        if let storedRaw, let mode = NetEaseConnectionMode(rawValue: storedRaw) {
            return mode
        }
        let trimmed = (address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .direct : .gateway
    }

    var displayName: String {
        switch self {
        case .direct: return L10n.text("直连官方接口")
        case .gateway: return L10n.text("自建网关")
        }
    }

    var detail: String {
        switch self {
        case .direct: return L10n.text("无需服务器，直接连接网易云")
        case .gateway: return L10n.text("使用你填写的自建服务地址")
        }
    }
}

enum NetEaseTransportError: LocalizedError {
    case missingBaseURL
    case invalidBaseURL
    case invalidResponse
    case loginRequired
    case unsupportedRoute(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL:
            return "请先到“设置 → 网易云设置”填写自己的服务地址。"
        case .invalidBaseURL:
            return "服务地址无效，请填写完整的网页服务地址，不要包含账号、密码或查询参数。"
        case .invalidResponse:
            return "网易云服务请求失败，请检查服务运行状态和网络连接。"
        case .loginRequired:
            return "网易云登录已失效，请在设置中重新扫码登录。"
        case .unsupportedRoute(let path):
            return "直连模式暂不支持该接口（\(path)）。"
        case .message(let text):
            return text
        }
    }
}

struct NetEaseTransportResponse {
    let statusCode: Int
    let body: [String: Any]?
    let updatedCookie: String?
    let byteCount: Int
}

@MainActor
protocol NetEaseTransport: AnyObject {
    var mode: NetEaseConnectionMode { get }
    func send(
        path: String,
        parameters: [String: String],
        cookie: String,
        timeout: TimeInterval?
    ) async throws -> NetEaseTransportResponse
    func configure(baseURL: String)
}

enum NetEaseHTTP {
    static func isRetryable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    static func sendWithRetry(
        session: URLSession,
        request: URLRequest,
        attempts: Int = 2
    ) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<max(1, attempts) {
            do {
                return try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
                if attempt + 1 < attempts, isRetryable(error) {
                    continue
                }
                throw error
            }
        }
        throw lastError ?? NetEaseTransportError.invalidResponse
    }
}

private struct ParsedJSON: @unchecked Sendable {
    let value: [String: Any]?
}

enum NetEaseJSON {
    static func parse(_ data: Data) async -> [String: Any]? {
        await Task.detached(priority: .utility) {
            let object = try? JSONSerialization.jsonObject(with: data)
            return ParsedJSON(value: object as? [String: Any])
        }.value.value
    }
}

@MainActor
final class NetEaseGatewayTransport: NetEaseTransport {
    let mode: NetEaseConnectionMode = .gateway

    private let session: URLSession
    private var baseURL: String

    init(baseURL: String, session: URLSession) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func configure(baseURL: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func send(
        path: String,
        parameters: [String: String],
        cookie: String,
        timeout: TimeInterval?
    ) async throws -> NetEaseTransportResponse {
        guard !baseURL.isEmpty else {
            throw NetEaseTransportError.missingBaseURL
        }
        guard var components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw NetEaseTransportError.invalidBaseURL
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let joinedPath = [basePath, requestPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        components.path = "/" + joinedPath

        var items = parameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "timestamp", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        components.queryItems = items

        guard let url = components.url else {
            throw NetEaseTransportError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout ?? 25

        if !cookie.isEmpty {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "+")
            let encoded = cookie.addingPercentEncoding(withAllowedCharacters: allowed) ?? cookie
            request.httpBody = Data("cookie=\(encoded)".utf8)
        }

        let (data, response) = try await NetEaseHTTP.sendWithRetry(session: session, request: request)
        let http = response as? HTTPURLResponse
        let body = await NetEaseJSON.parse(data)

        return NetEaseTransportResponse(
            statusCode: http?.statusCode ?? 0,
            body: body,
            updatedCookie: nil,
            byteCount: data.count
        )
    }
}
