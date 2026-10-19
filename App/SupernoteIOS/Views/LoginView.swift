import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    TextField("Server", text: $model.serverURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } header: { Text("Server") } footer: {
                    Text("Supernote Cloud, or your Private Cloud, e.g. http://basilnet.local:19072")
                }
                Section("Account") {
                    TextField("Email", text: $model.account)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                    SecureField("Password", text: $password)
                }
                Section {
                    LabeledContent("Device ID", value: model.identity.equipmentNo)
                    LabeledContent("Device name", value: model.identity.name)
                } footer: {
                    Text("This device registers as its own Supernote on your account.")
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                Button {
                    Task {
                        busy = true; defer { busy = false }
                        do { try await model.login(password: password); error = nil }
                        catch { self.error = "\(error)" }
                    }
                } label: {
                    HStack { Text("Sign in"); if busy { Spacer(); ProgressView() } }
                }
                .disabled(busy || model.account.isEmpty || password.isEmpty)
            }
            .navigationTitle("Supernote")
        }
    }
}
