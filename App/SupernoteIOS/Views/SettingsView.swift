import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Sync") {
                    LabeledContent("Server", value: model.serverURL)
                    LabeledContent("Account", value: model.account)
                    switch model.status {
                    case .idle: LabeledContent("Status", value: "Idle")
                    case .syncing: LabeledContent("Status", value: "Syncing…")
                    case let .done(s): LabeledContent("Last sync", value: s)
                    case let .failed(e): Text(e).foregroundStyle(.red).font(.footnote)
                    }
                    if let r = model.lastReport, !r.conflicts.isEmpty {
                        ForEach(r.conflicts, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") }
                    }
                }
                Section {
                    Toggle("Apple Pencil only", isOn: $model.pencilOnly)
                    Toggle("Left-handed mode", isOn: $model.leftHanded)
                } header: { Text("Writing") } footer: {
                    Text("Edits are written into the .note file and sync to your Nomad. The previous five versions of each note are kept in Backups.")
                }
                Section {
                    LabeledContent("Device ID", value: model.identity.equipmentNo)
                    LabeledContent("Name", value: model.identity.name)
                    Button("Regenerate device ID", role: .destructive) { model.resetIdentity(); dismiss() }
                } header: { Text("This device") }
                Section {
                    Button("Sign out", role: .destructive) { model.logout(); dismiss() }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
