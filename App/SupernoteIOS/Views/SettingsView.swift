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
                    Toggle("Pen (beta)", isOn: $model.penEnabled)
                    Toggle("Apple Pencil only", isOn: $model.pencilOnly)
                } header: { Text("Pen") } footer: {
                    Text("Draw on any note page. Strokes are saved on this device for now — they sync back to your Nomad once .note write-back ships.")
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
