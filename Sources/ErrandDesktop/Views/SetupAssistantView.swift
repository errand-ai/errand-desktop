import SwiftUI

/// First-run setup assistant for API keys and image pulling.
struct SetupAssistantView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var isPulling = false

    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            // Step indicators
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Circle()
                        .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 16)

            // Step content
            Group {
                switch step {
                case 0: welcomeStep
                case 1: llmStep
                case 2: litellmStep
                case 3: imagePullStep
                case 4: doneStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)

            Divider()

            // Navigation
            HStack {
                if step > 0 && step < totalSteps - 1 {
                    Button("Back") { step -= 1 }
                        .disabled(isPulling)
                }

                Spacer()

                if step < totalSteps - 1 {
                    Button("Continue") { step += 1 }
                        .keyboardShortcut(.defaultAction)
                        .disabled(step == 3 && isPulling)
                } else {
                    Button("Finish") {
                        appState.completeFirstRun()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 500, height: 420)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 48))
                .foregroundStyle(.accent)

            Text("Welcome to Errand Desktop")
                .font(.title2.weight(.semibold))

            Text("This app runs the Content Manager stack locally using lightweight Linux containers on your Mac.\n\nLet's configure a few things to get started.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var llmStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LLM Configuration")
                .font(.title2.weight(.semibold))

            Text("Enter your OpenAI-compatible API credentials.")
                .foregroundStyle(.secondary)

            Form {
                LabeledContent("Base URL") {
                    TextField("https://api.openai.com/v1", text: $appState.config.openaiBaseURL)
                        .frame(width: 250)
                }

                LabeledContent("API Key") {
                    SecureField("sk-...", text: $appState.config.openaiAPIKey)
                        .frame(width: 250)
                }
            }
        }
    }

    private var litellmStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LiteLLM Proxy")
                .font(.title2.weight(.semibold))

            Text("LiteLLM provides a unified API proxy for multiple LLM providers. Enable it if you want to use models from different providers.")
                .foregroundStyle(.secondary)

            Toggle("Enable LiteLLM", isOn: $appState.config.litellmEnabled)
                .padding(.top, 8)
        }
    }

    private var imagePullStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pulling Container Images")
                .font(.title2.weight(.semibold))

            Text("Downloading the required container images. This may take a few minutes.")
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(appState.services) { service in
                    let progress = appState.imagePullProgress[service.id] ?? 0

                    HStack {
                        Text(service.displayName)
                            .frame(width: 90, alignment: .leading)

                        ProgressView(value: progress)

                        if progress >= 1.0 {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .task {
            let allPulled = !appState.imagePullProgress.isEmpty
                && appState.imagePullProgress.values.allSatisfy { $0 >= 1.0 }
            guard !allPulled else { return }
            isPulling = true
            await appState.pullRequiredImages()
            isPulling = false
        }
    }

    private var doneStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.title2.weight(.semibold))

            Text("Click the menu bar icon to start your services.")
                .foregroundStyle(.secondary)
        }
    }
}
