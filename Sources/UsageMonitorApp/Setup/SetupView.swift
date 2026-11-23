import SwiftUI
import UsageCore

/// The Settings form. Logic lives in `SetupModel`, `SetupForm` and `SettingsSaver`.
struct SetupView: View {
    @Bindable var model: SetupModel

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
                }
                Section {
                    TextField("Stale after (minutes)", text: $model.form.staleMinutes)
                } header: {
                    Text("Freshness")
                } footer: {
                    Text("Readings older than this are marked stale.").foregroundStyle(.secondary)
                }
                aliasSection
            }
            .formStyle(.grouped)
            .disabled(model.isBusy)
            Divider()
            footer.padding(12)
        }
        .frame(minWidth: 480, minHeight: 560)
    }

    private var cliproxySection: some View {
        Section {
            TextField("URL", text: $model.form.cliproxyURL, prompt: Text(verbatim: "http://cliproxy:8317"))
            SecureField("Management key", text: $model.form.cliproxyKey.value)
            unreadableNote(model.form.cliproxyKey.baseline)
            testRow(.cliproxy)
        } header: {
            Text("cliproxy (Claude and Codex)")
        } footer: {
            Text("The management page URL works too. Five rejected keys ban this Mac's IP for 30 minutes, so Test sends one request and never retries.")
                .foregroundStyle(.secondary)
        }
    }

    private var ocgoSection: some View {
        Section {
            TextField("URL", text: $model.form.ocgoURL, prompt: Text(verbatim: "http://cliproxy:8320"))
            SecureField("Client token", text: $model.form.ocgoToken.value)
            unreadableNote(model.form.ocgoToken.baseline)
            testRow(.ocgo)
        } header: {
            Text("ocgo-proxy (OpenCode Go, optional)")
        } footer: {
            Text("Leave the URL empty to hide the Go row.").foregroundStyle(.secondary)
        }
    }

    private var aliasSection: some View {
        Section {
            ForEach($model.form.aliases) { $row in
                HStack {
                    TextField("Credential file", text: $row.fileKey, prompt: Text(verbatim: "claude-x@example.com.json"))
                        .labelsHidden()
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Identity", text: $row.identity, prompt: Text(verbatim: "1a2b3c4d"))
                        .labelsHidden()
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
        } header: {
            Text("Identity aliases")
        } footer: {
            Text("Maps a credential file to another file for the same login, so the two count once. Give the other file's hash (1a2b3c4d) or its full identity (1a2b3c4d:x@example.com).")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func unreadableNote(_ baseline: SecretBaseline) -> some View {
        if case .unreadable(let reason) = baseline {
            Text("The stored value couldn't be read (\(reason)). Leave the field empty to keep it, or enter a new one.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func testRow(_ kind: SourceKind) -> some View {
        let state = model.testState(kind)
        return HStack(alignment: .firstTextBaseline) {
            Button("Test") { Task { await model.test(kind) } }
                .disabled(state == .running)
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
                Text("Reading the Keychain…").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Save") { Task { await model.save() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)
        }
    }
}
