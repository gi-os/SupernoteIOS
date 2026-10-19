import Foundation

/// What to do for one path. Pure data so the planner is unit-testable.
public enum SyncAction: Equatable, Sendable {
    case download(path: String, id: String)
    case upload(path: String)
    case deleteLocal(path: String)
    case deleteRemote(path: String, id: String)
    /// Both sides changed: remote wins at `path`, local copy is re-uploaded as `conflictPath`.
    case conflict(path: String, id: String, conflictPath: String)
}

public enum SyncPlanner {
    public struct Remote: Equatable, Sendable { public var id: String; public var md5: String
        public init(id: String, md5: String) { self.id = id; self.md5 = md5 } }

    /// Three-way plan: remote listing vs local disk vs the hashes recorded at the last sync.
    public static func plan(remote: [String: Remote], local: [String: String], base: [String: String],
                            deviceName: String) -> [SyncAction] {
        var actions: [SyncAction] = []
        for path in Set(remote.keys).union(local.keys).sorted() {
            let r = remote[path], l = local[path], s = base[path]
            switch (r, l) {
            case let (r?, l?):
                if r.md5 == l { continue }
                if l == s { actions.append(.download(path: path, id: r.id)) }
                else if r.md5 == s { actions.append(.upload(path: path)) }
                else { actions.append(.conflict(path: path, id: r.id, conflictPath: conflictName(path, deviceName))) }
            case let (r?, nil):
                if s != nil && r.md5 == s { actions.append(.deleteRemote(path: path, id: r.id)) }
                else { actions.append(.download(path: path, id: r.id)) }
            case let (nil, l?):
                if s != nil && l == s { actions.append(.deleteLocal(path: path)) }
                else { actions.append(.upload(path: path)) }
            case (nil, nil):
                continue
            }
        }
        return actions
    }

    static func conflictName(_ path: String, _ device: String) -> String {
        let ns = path as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        return ext.isEmpty ? "\(base) (conflict \(device))" : "\(base) (conflict \(device)).\(ext)"
    }
}

public struct SyncReport: Sendable, CustomStringConvertible {
    public var downloaded: [String] = []
    public var uploaded: [String] = []
    public var deletedLocal: [String] = []
    public var deletedRemote: [String] = []
    public var conflicts: [String] = []
    public var description: String {
        "↓\(downloaded.count) ↑\(uploaded.count) ✕local \(deletedLocal.count) ✕remote \(deletedRemote.count) ⚠︎\(conflicts.count)"
    }
}

/// Mirrors the cloud into a local folder, behaving like a Supernote's sync button.
public actor SyncEngine {
    public static let stateFileName = ".snsync-state.json"

    let client: SupernoteClient
    public nonisolated let root: URL
    let fm = FileManager.default

    public init(client: SupernoteClient, root: URL) {
        self.client = client
        self.root = root
    }

    public func sync(lockRetries: Int = 5) async throws -> SyncReport {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try await acquireLock(retries: lockRetries)
        do {
            let report = try await runSync()
            try await client.syncEnd()
            return report
        } catch {
            try? await client.syncEnd()
            throw error
        }
    }

    private func acquireLock(retries: Int) async throws {
        var delay: UInt64 = 2
        for attempt in 0 ... retries {
            do { return try await client.syncStart() }
            catch SupernoteError.syncLocked where attempt < retries {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 30)
            }
        }
    }

    private func runSync() async throws -> SyncReport {
        let entries = try await client.list()
        let remoteFolders = Set(entries.filter(\.isFolder).map(\.relativePath))
        var remote: [String: SyncPlanner.Remote] = [:]
        for e in entries where !e.isFolder {
            remote[e.relativePath] = .init(id: e.id, md5: e.contentHash ?? "")
        }
        let local = try scanLocal()
        let base = loadState()
        let actions = SyncPlanner.plan(remote: remote, local: local, base: base, deviceName: client.identity.name)

        var report = SyncReport()
        var newState = base
        for (path, r) in remote where local[path] == r.md5 { newState[path] = r.md5 }
        var createdFolders = remoteFolders

        func ensureRemoteParents(_ path: String) async throws {
            var parts = path.split(separator: "/").dropLast().map(String.init)
            var acc: [String] = []
            while !parts.isEmpty {
                acc.append(parts.removeFirst())
                let p = acc.joined(separator: "/")
                if !createdFolders.contains(p) {
                    try? await client.createFolder(p)
                    createdFolders.insert(p)
                }
            }
        }

        for action in actions {
            switch action {
            case let .download(path, id):
                let data = try await client.download(id: id)
                try write(data, to: path)
                newState[path] = data.supernoteMD5
                report.downloaded.append(path)
            case let .upload(path):
                let data = try Data(contentsOf: url(path))
                try await ensureRemoteParents(path)
                try await client.upload(data, to: path)
                newState[path] = data.supernoteMD5
                report.uploaded.append(path)
            case let .deleteLocal(path):
                try? fm.removeItem(at: url(path))
                newState[path] = nil
                report.deletedLocal.append(path)
            case let .deleteRemote(path, id):
                try await client.delete(id: id)
                newState[path] = nil
                report.deletedRemote.append(path)
            case let .conflict(path, id, conflictPath):
                try fm.moveItem(at: url(path), to: url(conflictPath))
                let localCopy = try Data(contentsOf: url(conflictPath))
                try await client.upload(localCopy, to: conflictPath)
                newState[conflictPath] = localCopy.supernoteMD5
                let data = try await client.download(id: id)
                try write(data, to: path)
                newState[path] = data.supernoteMD5
                report.conflicts.append(path)
            }
            try saveState(newState) // checkpoint after every action so a crash never re-plays deletes
        }
        try saveState(newState)
        return report
    }

    // MARK: Local disk

    nonisolated func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }

    func write(_ data: Data, to path: String) throws {
        let u = url(path)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u, options: .atomic)
    }

    func scanLocal() throws -> [String: String] {
        var out: [String: String] = [:]
        let rootPath = root.standardizedFileURL.path
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                    options: [.skipsHiddenFiles]) else { return out }
        for case let file as URL in e {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            var rel = String(file.standardizedFileURL.path.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            out[rel] = try Data(contentsOf: file, options: .mappedIfSafe).supernoteMD5
        }
        return out
    }

    func loadState() -> [String: String] {
        guard let d = try? Data(contentsOf: url(Self.stateFileName)) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }

    func saveState(_ s: [String: String]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(s).write(to: url(Self.stateFileName), options: .atomic)
    }
}
