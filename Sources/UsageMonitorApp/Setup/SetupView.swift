import SwiftUI
import UsageCore

/// The Settings form. Logic lives in `SetupModel`, `SetupForm` and `SettingsSaver`.
struct SetupView: View {
    @Bindable var model: SetupModel
    /// Set while the retry confirmation for this source is showing.
    @State private var confirmingTest: SourceKind?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                cliproxySection
                ocgoSection
                Section("Menubar") {
                    Picker("Style", selection: $model.form.menubarStyle) {
                        Text("Normal").tag(MenubarStyle.normal)
                        Text("Compact").tag(MenubarStyle.compact)
                    }
                    .pickerStyle(.segmented)
                    .help("Normal shows each provider's logo and %. Compact shows one icon that expands on click.")
                }
                Section("Freshness") {
                    TextField("Stale after (minutes)", text: $model.form.staleMinutes)
                        .help("Readings older than this are marked stale in the dropdown.")
                }
                aliasSection
            }
            .formStyle(.grouped)
            .disabled(model.isBusy)
            Divider()
            footer.padding(12)
        }
        .frame(minWidth: 480, minHeight: 560)
        .alert("Test the key again?", isPresented: Binding(
            get: { confirmingTest != nil },
            set: { if !$0 { confirmingTest = nil } }
        ), presenting: confirmingTest) { kind in
            Button("Test") { Task { await model.test(kind) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(Self.retryWarning(model.cliproxyRejections))
        }
    }

    private var cliproxySection: some View {
        Section {
            TextField("URL", text: $model.form.cliproxyURL, prompt: Text(verbatim: "http://cliproxy:8317"))
                .help("Base URL or /management.html URL.")
            SecureField("Management key", text: $model.form.cliproxyKey.value)
            unreadableNote(model.form.cliproxyKey.baseline)
            testRow(.cliproxy)
        } header: {
            Text("cliproxy (Claude and Codex)")
        }
    }

    private var ocgoSection: some View {
        Section {
            TextField("URL", text: $model.form.ocgoURL, prompt: Text(verbatim: "http://cliproxy:8320"))
                .help("Leave blank to hide OpenCode Go.")
            SecureField("Client token", text: $model.form.ocgoToken.value)
            unreadableNote(model.form.ocgoToken.baseline)
            testRow(.ocgo)
        } header: {
            Text("ocgo-proxy (OpenCode Go, optional)")
        }
    }

    private var aliasSection: some View {
        Section {
            ForEach($model.form.aliases) { $row in
                HStack {
                    TextField("Credential file", text: $row.fileKey, prompt: Text(verbatim: "claude-x@example.com.json"))
                        .labelsHidden()
                        .help("Duplicate credential filename from cliproxy, e.g. claude-you@example.com.json.")
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Target account", text: $row.identity, prompt: Text(verbatim: "1a2b3c4d or id:email"))
                        .labelsHidden()
                        .help("Target account's 8-char filename hash (e.g. 1a2b3c4d) or Codex workspace ID. Append :email if the two files have different emails.")
                    Button {
                        model.form.aliases.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this alias")
                }
            }
            Button("Add alias") { model.form.aliases.append(AliasRow()) }
                .help(Self.aliasHelp)
        } header: {
            Text("Account aliases (optional)").help(Self.aliasHelp)
        }
    }

    static func retryWarning(_ rejections: Int) -> String {
        let times = rejections == 1 ? "once" : "\(rejections) times"
        return "cliproxy has rejected a key \(times) since the last successful test. 5 wrong keys ban this Mac's IP for 30 minutes."
    }

    private static let aliasHelp = "Rarely needed. Merge two credential files for the same login so they count as one account."

    @ViewBuilder
    private func unreadableNote(_ baseline: SecretBaseline) -> some View {
        if case .unreadable(let reason) = baseline {
            Text("Couldn't read from Keychain (\(reason)). Leave blank to keep the saved value, or enter a new one.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func testRow(_ kind: SourceKind) -> some View {
        let state = model.testState(kind)
        return HStack(alignment: .firstTextBaseline) {
            Button("Test") {
                if model.confirmsTest(kind) {
                    confirmingTest = kind
                } else {
                    Task { await model.test(kind) }
                }
            }
            .disabled(state == .running)
            .help(kind == .cliproxy ? "Sends one request. 5 wrong keys ban this Mac's IP for 30 minutes." : "Sends one request.")
            switch state {
            case .idle:
                EmptyView()
            case .running:
                ProgressView().controlSize(.small)
            case .succeeded(let text):
                Label(text, systemImage: "checkmark.circle").foregroundStyle(.green)
            case .failed(let text):
                Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
        .textSelection(.enabled)
    }

    private var footer: some View {
        HStack {
            switch model.saveState {
            case .idle: EmptyView()
            case .saving: ProgressView().controlSize(.small)
            case .saved: Text("Saved.").foregroundStyle(.secondary)
            case .failed(let text): Text(text).foregroundStyle(.red)
            }
            if model.phase == .loading {
                Text("Reading Keychain…").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Save") { Task { await model.save() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)
        }
    }
}
