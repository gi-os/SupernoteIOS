import Foundation
import Observation
import SyncKit
import UIKit

@MainActor @Observable
final class AppModel {
    enum SyncStatus: Equatable { case idle, syncing, done(String), failed(String) }

    // Settings (UserDefaults) — server defaults to Ratta's cloud; point it at your Private Cloud.
    var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? "https://cloud.supernote.com" {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }
    var account: String = UserDefaults.standard.string(forKey: "account") ?? "" {
        didSet { UserDefaults.standard.set(account, forKey: "account") }
    }
    /// Mirrors the Nomad's handedness setting: moves toolbar + undo sidebar to the right.
    var leftHanded: Bool = UserDefaults.standard.bool(forKey: "leftHanded") {
        didSet { UserDefaults.standard.set(leftHanded, forKey: "leftHanded") }
    }
    /// iPad: Apple Pencil only (fingers scroll). iPhone: fingers draw.
    var pencilOnly: Bool = UserDefaults.standard.object(forKey: "pencilOnly") as? Bool
        ?? (UIDevice.current.userInterfaceIdiom == .pad) {
        didSet { UserDefaults.standard.set(pencilOnly, forKey: "pencilOnly") }
    }

    private(set) var identity: DeviceIdentity
    private(set) var isLoggedIn = false
    private(set) var status: SyncStatus = .idle
    private(set) var lastReport: SyncReport?
    /// Bumped after each sync so file lists reload.
    private(set) var revision = 0

    private var client: SupernoteClient?

    let mirrorRoot: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Supernote", isDirectory: true)

    init() {
        // One stable fake serial per physical device — the cloud sees iPhone and iPad mini as two Supernotes.
        if let data = UserDefaults.standard.data(forKey: "identity"),
           let saved = try? JSONDecoder().decode(DeviceIdentity.self, from: data) {
            identity = saved
        } else {
            let fresh = DeviceIdentity.generate(name: UIDevice.current.name)
            UserDefaults.standard.set(try? JSONEncoder().encode(fresh), forKey: "identity")
            identity = fresh
        }
        try? FileManager.default.createDirectory(at: mirrorRoot, withIntermediateDirectories: true)
    }

    func bootstrap() async {
        guard !account.isEmpty, let password = Keychain.get("password") else { return }
        try? await login(password: password)
    }

    func login(password: String) async throws {
        guard let url = URL(string: serverURL) else { throw URLError(.badURL) }
        let c = SupernoteClient(baseURL: url, identity: identity)
        try await c.login(account: account, password: password)
        Keychain.set(password, for: "password")
        client = c
        isLoggedIn = true
        await sync()
    }

    func logout() {
        Keychain.set(nil, for: "password")
        client = nil
        isLoggedIn = false
        status = .idle
    }

    func syncIfLoggedIn() async {
        if isLoggedIn { await sync() }
    }

    func sync() async {
        guard let client, status != .syncing else { return }
        status = .syncing
        do {
            let report = try await runSync(client)
            lastReport = report
            status = .done(report.description)
        } catch SupernoteError.http(401, _) {
            // Token expired: re-login once with the stored password, then retry.
            if let pw = Keychain.get("password"), (try? await client.login(account: account, password: pw)) != nil,
               let report = try? await runSync(client) {
                lastReport = report
                status = .done(report.description)
            } else {
                status = .failed("Session expired — log in again")
            }
        } catch {
            status = .failed("\(error)")
        }
        revision += 1
    }

    private func runSync(_ client: SupernoteClient) async throws -> SyncReport {
        try await SyncEngine(client: client, root: mirrorRoot).sync()
    }

    /// Lets users regenerate the device serial (e.g. if the server rejects the binding).
    func resetIdentity() {
        identity = DeviceIdentity.generate(name: UIDevice.current.name)
        UserDefaults.standard.set(try? JSONEncoder().encode(identity), forKey: "identity")
        logout()
    }
}
