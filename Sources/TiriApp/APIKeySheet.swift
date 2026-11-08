import SwiftUI
import TiriCore

/// What's being typed in the API key sheet, kept with Settings so a test copy can fill it in.
@Observable final class APIKeyDraft {
    var provider = KeyedModel.Provider.anthropic
    var model = KeyedModel.suggestedModel(.anthropic)
    var baseURL = ""
    var key = ""
    var problem: String?
    var isChecking = false
    /// There's one in the keychain: an empty key field keeps it.
    var hasSaved = false

    var keyed: KeyedModel { KeyedModel(provider: provider, model: model, baseURL: baseURL, key: key) }

    /// The suggested model follows the provider, unless someone typed their own.
    func choose(_ provider: KeyedModel.Provider) {
        if model.isEmpty || KeyedModel.Provider.allCases.contains(where: { KeyedModel.suggestedModel($0) == model }) {
            model = KeyedModel.suggestedModel(provider)
        }
        self.provider = provider
        problem = nil
    }
}

extension AppModel {
    func openAPIKeySheet() {
        let draft = settingsUI.apiKey
        if let saved = ModelKeyStore.current {
            draft.provider = saved.provider
            draft.model = saved.model
            draft.baseURL = saved.baseURL
            draft.hasSaved = true
        } else {
            draft.hasSaved = false
        }
        draft.key = ""
        draft.problem = nil
        draft.isChecking = false
        settingsUI.showsAPIKeySheet = true
    }

    /// Tried once before it's kept, so a wrong key is found here and not in a list of titles that never come.
    func saveAPIKey() {
        let draft = settingsUI.apiKey
        var keyed = draft.keyed
        if keyed.key.trimmingCharacters(in: .whitespaces).isEmpty, draft.hasSaved, let saved = ModelKeyStore.current { keyed.key = saved.key }
        guard keyed.isComplete, !draft.isChecking else { return }
        draft.isChecking = true
        draft.problem = nil
        Task {
            let problem = await ConversationAssistant.check(keyed)
            draft.isChecking = false
            if let problem {
                draft.problem = problem
                return
            }
            do {
                try ModelKeyStore.save(keyed)
            } catch {
                draft.problem = error.localizedDescription
                return
            }
            settingsUI.showsAPIKeySheet = false
            settingsUI.macModelChanges += 1
            if !settings.conversationsUseMacModel { _ = setSetting("conversations.useMacModel", to: .bool(true)) }
            updateSummarizingAll()
        }
    }

    func removeAPIKey() {
        ModelKeyStore.remove()
        settingsUI.showsAPIKeySheet = false
        settingsUI.macModelChanges += 1
        updateSummarizingAll()
    }
}

struct APIKeySheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var draft = model.settingsUI.apiKey
        VStack(alignment: .leading, spacing: 0) {
            Text("Use an API Key")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)
            Form {
                Section {
                    Picker("Provider", selection: Binding(get: { draft.provider }, set: { draft.choose($0) })) {
                        Text(verbatim: "Anthropic").tag(KeyedModel.Provider.anthropic)
                        Text(verbatim: "OpenAI").tag(KeyedModel.Provider.openai)
                        Text("Other").tag(KeyedModel.Provider.other)
                    }
                    .pickerStyle(.segmented)
                    if draft.provider == .other {
                        TextField("Address", text: $draft.baseURL, prompt: Text(verbatim: "https://api.deepseek.com/v1"))
                    }
                    TextField("Model", text: $draft.model, prompt: Text(verbatim: draft.provider == .other ? "deepseek-chat" : KeyedModel.suggestedModel(draft.provider)))
                    SecureField("Key", text: $draft.key, prompt: Text(draft.hasSaved ? "Saved in your keychain" : "Paste your key"))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(footnote(draft))
                            .foregroundStyle(.secondary)
                        if let problem = draft.problem {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .disabled(draft.isChecking)

            HStack(spacing: 8) {
                if draft.hasSaved {
                    Button("Remove Key", role: .destructive) { model.removeAPIKey() }
                }
                Spacer()
                if draft.isChecking { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { model.settingsUI.showsAPIKeySheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.saveAPIKey() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave(draft) || draft.isChecking)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func canSave(_ draft: APIKeyDraft) -> Bool {
        var keyed = draft.keyed
        if draft.hasSaved, keyed.key.isEmpty { keyed.key = "saved" }
        return keyed.isComplete
    }

    /// Where the words go, said plainly: this is the one thing that's different from Apple Intelligence.
    private func footnote(_ draft: APIKeyDraft) -> String {
        let name = draft.keyed.providerName
        return name.isEmpty
            ? String(localized: "Titles and search send excerpts of your conversations to this address. The key stays in your Mac's keychain.")
            : String(localized: "Titles and search send excerpts of your conversations to \(name). The key stays in your Mac's keychain.")
    }
}
