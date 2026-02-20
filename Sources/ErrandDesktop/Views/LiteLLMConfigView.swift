import SwiftUI

/// Sub-view for configuring LiteLLM model providers.
/// Shown as a section in SettingsView or presented as a sheet.
struct LiteLLMConfigView: View {
    @EnvironmentObject var appState: AppState
    @State private var providers: [LiteLLMProvider] = []
    @State private var errorMessage: String?

    /// Known provider templates for quick setup.
    private static let providerTemplates: [(name: String, prefix: String)] = [
        ("OpenAI", "openai/"),
        ("Anthropic", "anthropic/"),
        ("Ollama", "ollama/"),
        ("Azure OpenAI", "azure/"),
        ("Google Gemini", "gemini/"),
        ("AWS Bedrock", "bedrock/"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LiteLLM Model Providers")
                .font(.headline)

            if providers.isEmpty {
                Text("No providers configured. Add a provider to route model requests through LiteLLM.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            List {
                ForEach($providers) { $provider in
                    providerRow(provider: $provider)
                }
                .onDelete(perform: deleteProviders)
            }
            .frame(minHeight: 150)

            HStack {
                Menu("Add Provider") {
                    ForEach(Self.providerTemplates, id: \.name) { template in
                        Button(template.name) {
                            addProvider(name: template.name, prefix: template.prefix)
                        }
                    }
                }

                Spacer()

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 500)
        .task {
            await loadProviders()
        }
    }

    @ViewBuilder
    private func providerRow(provider: Binding<LiteLLMProvider>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.wrappedValue.providerName)
                    .font(.subheadline.bold())
                Spacer()
            }

            LabeledContent("Model Name") {
                TextField("e.g. gpt-4", text: provider.modelName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 250)
            }

            LabeledContent("LiteLLM Model") {
                TextField("e.g. openai/gpt-4", text: provider.litellmModel)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 250)
            }

            LabeledContent("API Key") {
                SecureField("sk-...", text: provider.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 250)
            }

            LabeledContent("Base URL") {
                TextField("Optional custom endpoint", text: provider.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 250)
            }
        }
        .padding(.vertical, 4)
    }

    private func addProvider(name: String, prefix: String) {
        providers.append(
            LiteLLMProvider(
                providerName: name,
                modelName: "",
                litellmModel: prefix,
                apiKey: "",
                baseURL: ""
            )
        )
    }

    private func deleteProviders(at offsets: IndexSet) {
        providers.remove(atOffsets: offsets)
    }

    private func loadProviders() async {
        if let manager = await appState.liteLLMManager {
            let loaded = await manager.providers
            providers = loaded
        }
    }

    private func save() {
        Task {
            do {
                errorMessage = nil
                try await appState.liteLLMManager?.saveProviders(providers)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
