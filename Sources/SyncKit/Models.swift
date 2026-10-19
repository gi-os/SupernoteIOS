import Foundation

// Wire models for the Supernote (Private) Cloud device API.
// Field names follow allenporter/supernote's reverse-engineered models.

struct Envelope: Decodable {
    var success: Bool?
    var errorCode: String?
    var errorMsg: String?
}

struct RandomCodeResponse: Decodable {
    var randomCode: String
    var timestamp: String
}

struct LoginResponse: Decodable {
    var token: String
    var userName: String?
}

public struct RemoteEntry: Decodable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var tag: String
    public var pathDisplay: String
    public var contentHash: String?
    public var isDownloadable: Bool?
    public var size: Int?
    public var lastUpdateTime: Int?
    public var parentPath: String?

    public var isFolder: Bool { tag == "folder" }
    /// Path relative to the cloud root, without a leading slash ("Note/Ideas.note").
    public var relativePath: String { pathDisplay.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    enum CodingKeys: String, CodingKey {
        case id, name, tag, size, lastUpdateTime
        case pathDisplay = "path_display"
        case contentHash = "content_hash"
        case isDownloadable = "is_downloadable"
        case parentPath = "parent_path"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Some servers send numeric ids, others strings.
        if let s = try? c.decode(String.self, forKey: .id) { id = s } else { id = String(try c.decode(Int.self, forKey: .id)) }
        name = try c.decode(String.self, forKey: .name)
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? "file"
        pathDisplay = try c.decodeIfPresent(String.self, forKey: .pathDisplay) ?? name
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
        isDownloadable = try c.decodeIfPresent(Bool.self, forKey: .isDownloadable)
        size = try c.decodeIfPresent(Int.self, forKey: .size)
        lastUpdateTime = try c.decodeIfPresent(Int.self, forKey: .lastUpdateTime)
        parentPath = try c.decodeIfPresent(String.self, forKey: .parentPath)
    }
}

struct ListFolderResponse: Decodable {
    var entries: [RemoteEntry]
}

struct DownloadResponse: Decodable {
    var url: String
}

struct UploadApplyResponse: Decodable {
    var fullUploadUrl: String?
    var partUploadUrl: String?
    var innerName: String?
}

struct UploadResult: Decodable {
    var md5: String?
}

struct UploadFinishResponse: Decodable {
    var contentHash: String?
    enum CodingKeys: String, CodingKey { case contentHash = "content_hash" }
}

struct Empty: Decodable {}
