import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SupernoteError: Error, Equatable, CustomStringConvertible {
    case http(Int, String)
    case api(code: String?, message: String?)
    case syncLocked               // E0078: another device is mid-sync
    case notLoggedIn
    case badResponse(String)

    public var description: String {
        switch self {
        case let .http(code, body): "HTTP \(code): \(body.prefix(200))"
        case let .api(code, msg): "API error \(code ?? "?"): \(msg ?? "")"
        case .syncLocked: "Another device is synchronizing (E0078)"
        case .notLoggedIn: "Not logged in"
        case let .badResponse(s): "Malformed response: \(s.prefix(200))"
        }
    }
}

/// Talks to Supernote Cloud / Private Cloud *as a device* (equipment = 3, with an `equipmentNo`).
public actor SupernoteClient {
    public nonisolated let baseURL: URL
    public nonisolated let identity: DeviceIdentity
    public private(set) var token: String?
    private let session: URLSession

    public init(baseURL: URL, identity: DeviceIdentity, token: String? = nil) {
        self.baseURL = baseURL
        self.identity = identity
        self.token = token
        let cfg = URLSessionConfiguration.default
        cfg.httpShouldSetCookies = true
        self.session = URLSession(configuration: cfg)
    }

    // MARK: Auth

    /// Logs in as this device. Binds the equipmentNo to the account on first use.
    @discardableResult
    public func login(account: String, password: String) async throws -> String {
        do {
            return try await equipmentLogin(account: account, password: password)
        } catch SupernoteError.api {
            // Unknown device: plain login, bind this equipmentNo, then retry as the device.
            let t = try await userLogin(account: account, password: password)
            token = t
            try await bindEquipment(account: account)
            return try await equipmentLogin(account: account, password: password)
        }
    }

    public func logout() { token = nil }

    private func challenge(_ account: String) async throws -> RandomCodeResponse {
        let _: Empty = try await post("/api/user/query/token", [String: String](), auth: false)
        return try await post("/api/official/user/query/random/code", ["account": account], auth: false)
    }

    private func loginBody(_ account: String, _ password: String, _ rc: RandomCodeResponse, device: Bool) -> [String: AnyEncodable] {
        var body: [String: AnyEncodable] = [
            "account": .init(account),
            "password": .init(Hashing.password(password, randomCode: rc.randomCode)),
            "timestamp": .init(rc.timestamp),
            "loginMethod": .init(account.allSatisfy(\.isNumber) ? "1" : "2"),
            "language": .init("en"),
        ]
        if device {
            body["equipment"] = .init(3)                      // TERMINAL
            body["equipmentNo"] = .init(identity.equipmentNo)
        } else {
            body["equipment"] = .init(1)
            body["browser"] = .init("Chrome142")
        }
        return body
    }

    private func equipmentLogin(account: String, password: String) async throws -> String {
        let rc = try await challenge(account)
        let res: LoginResponse = try await post("/api/official/user/account/login/equipment",
                                                loginBody(account, password, rc, device: true), auth: false)
        token = res.token
        return res.token
    }

    private func userLogin(account: String, password: String) async throws -> String {
        let rc = try await challenge(account)
        let res: LoginResponse = try await post("/api/official/user/account/login/new",
                                                loginBody(account, password, rc, device: false), auth: false)
        return res.token
    }

    private func bindEquipment(account: String) async throws {
        let _: Empty = try await post("/api/terminal/user/bindEquipment", [
            "account": account,
            "equipmentNo": identity.equipmentNo,
            "name": identity.name,
            "totalCapacity": "32000000",
            "flag": "1",
        ])
    }

    // MARK: Sync session

    /// Takes the per-account sync lock. Throws `.syncLocked` if another device holds it.
    public func syncStart() async throws {
        let _: Empty = try await post("/api/file/2/files/synchronous/start", ["equipmentNo": identity.equipmentNo])
    }

    public func syncEnd() async throws {
        let _: Empty = try await post("/api/file/2/files/synchronous/end",
                                      ["equipmentNo": identity.equipmentNo, "flag": "N"])
    }

    // MARK: Files

    public func list(folderID: String = "0", recursive: Bool = true) async throws -> [RemoteEntry] {
        let res: ListFolderResponse = try await post("/api/file/3/files/list_folder_v3", [
            "id": .init(Int(folderID) ?? 0),
            "equipmentNo": .init(identity.equipmentNo),
            "recursive": .init(recursive),
        ] as [String: AnyEncodable])
        return res.entries
    }

    public func download(id: String) async throws -> Data {
        let res: DownloadResponse = try await post("/api/file/3/files/download_v3", [
            "id": .init(Int(id) ?? 0), "equipmentNo": .init(identity.equipmentNo),
        ] as [String: AnyEncodable])
        let (data, resp) = try await session.data(for: try request(url: resolve(res.url), method: "GET"))
        try check(resp, data)
        return data
    }

    /// Uploads `data` to `path` ("Note/Ideas.note"). Single-part; fine for notes < ~50 MB.
    public func upload(_ data: Data, to path: String) async throws {
        let clean = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileName = (clean as NSString).lastPathComponent
        let parent = (clean as NSString).deletingLastPathComponent
        let md5 = data.supernoteMD5

        let apply: UploadApplyResponse = try await post("/api/file/3/files/upload/apply", [
            "fileName": fileName, "path": "/" + clean, "size": String(data.count),
            "equipmentNo": identity.equipmentNo,
        ])
        guard let urlString = apply.fullUploadUrl else { throw SupernoteError.badResponse("no fullUploadUrl") }

        let boundary = "sn-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = try await request(url: resolve(urlString), method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (respData, resp) = try await session.data(for: req)
        try check(resp, respData)
        if let r = try? JSONDecoder().decode(UploadResult.self, from: respData), let serverMD5 = r.md5, serverMD5 != md5 {
            throw SupernoteError.badResponse("upload MD5 mismatch \(serverMD5) != \(md5)")
        }

        var finish: [String: String] = ["fileName": fileName, "path": parent, "content_hash": md5,
                                        "equipmentNo": identity.equipmentNo, "size": String(data.count)]
        if let inner = apply.innerName { finish["innerName"] = inner }
        let _: UploadFinishResponse = try await post("/api/file/2/files/upload/finish", finish)
    }

    public func createFolder(_ path: String) async throws {
        let _: Empty = try await post("/api/file/2/files/create_folder_v2", [
            "path": .init("/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            "equipmentNo": .init(identity.equipmentNo), "autorename": .init(false),
        ] as [String: AnyEncodable])
    }

    public func delete(id: String) async throws {
        let _: Empty = try await post("/api/file/3/files/delete_folder_v3", [
            "id": .init(Int(id) ?? 0), "equipmentNo": .init(identity.equipmentNo),
        ] as [String: AnyEncodable])
    }

    // MARK: Transport

    private func resolve(_ s: String) -> URL {
        if let u = URL(string: s), u.scheme != nil { return u }
        return baseURL.appendingPathComponent(s)
    }

    private func csrfToken() async throws -> String? {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/csrf"))
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (_, resp) = try await session.data(for: req)
        return (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-XSRF-TOKEN")
    }

    private func request(url: URL, method: String, auth: Bool = true) async throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let xsrf = try? await csrfToken() { req.setValue(xsrf, forHTTPHeaderField: "X-XSRF-TOKEN") }
        if auth {
            guard let token else { throw SupernoteError.notLoggedIn }
            req.setValue(token, forHTTPHeaderField: "x-access-token")
        }
        return req
    }

    private func post<B: Encodable, R: Decodable>(_ path: String, _ body: B, auth: Bool = true) async throws -> R {
        var req = try await request(url: baseURL.appendingPathComponent(path), method: "POST", auth: auth)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await session.data(for: req)

        if let env = try? JSONDecoder().decode(Envelope.self, from: data), env.success == false {
            if env.errorCode == "E0078" { throw SupernoteError.syncLocked }
            throw SupernoteError.api(code: env.errorCode, message: env.errorMsg)
        }
        try check(resp, data)
        if R.self == Empty.self { return Empty() as! R }
        do { return try JSONDecoder().decode(R.self, from: data) }
        catch { throw SupernoteError.badResponse(String(decoding: data, as: UTF8.self)) }
    }

    private func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw SupernoteError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    static let userAgent = "SupernoteIOS/0.1"
}

/// Minimal type-erased Encodable for mixed-type JSON bodies.
struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { encodeFn = value.encode }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}
