import SwiftUI
import AppKit

/// Preferences window (⌘,). Edits AI provider / key, optional Temporal Cloud,
/// capture tuning, and the summary output directory — then writes `.env` and
/// restarts the worker.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var isApplying = false
    @State private var statusMessage: String?

    var body: some View {
        @Bindable var settings = app.settings

        Form {
            // Role ------------------------------------------------------------
            Section("Your Role") {
                Picker("Role", selection: $settings.role) {
                    Text("Select a role…").tag(Settings.Role?.none)
                    ForEach(Settings.Role.allCases) { r in
                        Text(r.label).tag(Settings.Role?.some(r))
                    }
                }
                Text("Tailors live guidance and the summary to how you sell.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            // AI provider -----------------------------------------------------
            Section("AI Provider") {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(Settings.Provider.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.segmented)

                if settings.provider == .openai {
                    SecureField("OpenAI API key (required)", text: $settings.openAIKey)
                } else {
                    SecureField("Anthropic API key (required)", text: $settings.anthropicKey)
                }

                TextField("Model (optional, blank = provider default)", text: $settings.llmModel)
            }

            // AI assistance ---------------------------------------------------
            Section("AI Assistance") {
                Toggle("Live guidance during calls", isOn: $settings.aiAssistance)
                Text(settings.aiAssistance
                     ? "Surfaces real-time active-listening suggestions while you record."
                     : "Off: the call is only transcribed and summarized — no live suggestions.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            // Temporal --------------------------------------------------------
            Section("Temporal") {
                Toggle("Use Temporal Cloud", isOn: $settings.useTemporalCloud)
                if settings.useTemporalCloud {
                    TextField("Address (e.g. ns.acct.tmprl.cloud:7233)", text: $settings.temporalAddress)
                    TextField("Namespace (e.g. your-ns.acct)", text: $settings.temporalNamespace)
                    SecureField("Cloud API key (required)", text: $settings.temporalApiKey)
                } else {
                    Label("Local dev server · localhost:7233", systemImage: "desktopcomputer")
                        .foregroundStyle(Theme.textSecondary)
                }
                LabeledContent("Task queue") {
                    Text(TemporalConfig.deviceTaskQueue)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }

            // Capture tuning --------------------------------------------------
            Section("App Configuration") {
                HStack {
                    Text("Chunk length")
                    Spacer()
                    TextField("", value: $settings.chunkSeconds, format: .number)
                        .frame(width: 70).multilineTextAlignment(.trailing)
                    Text("seconds").foregroundStyle(Theme.textSecondary)
                }
                Stepper(value: $settings.analyzeEveryNChunks, in: 1...20) {
                    HStack {
                        Text("Analyze every")
                        Spacer()
                        Text("\(settings.analyzeEveryNChunks) chunk\(settings.analyzeEveryNChunks == 1 ? "" : "s")")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                HStack {
                    Text("Guidance warmup")
                    Spacer()
                    TextField("", value: $settings.warmupMinutes, format: .number)
                        .frame(width: 70).multilineTextAlignment(.trailing)
                    Text("minutes").foregroundStyle(Theme.textSecondary)
                }
                Stepper(value: $settings.maxActiveSuggestions, in: 1...20) {
                    HStack {
                        Text("Max live suggestions")
                        Spacer()
                        Text("\(settings.maxActiveSuggestions)")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }

            // Output ----------------------------------------------------------
            Section("Summary Output Folder") {
                HStack {
                    Text(settings.outputDir.isEmpty ? "Default (<project>/out)" : settings.outputDir)
                        .foregroundStyle(settings.outputDir.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseOutputFolder() }
                    if !settings.outputDir.isEmpty {
                        Button("Reset") { settings.outputDir = "" }
                    }
                }
            }

            // Apply -----------------------------------------------------------
            Section {
                HStack {
                    if let statusMessage {
                        Text(statusMessage).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button {
                        apply()
                    } label: {
                        if isApplying {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save & Restart Worker").fontWeight(.semibold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.purple)
                    .disabled(!settings.isValid || isApplying)
                }
                if !settings.isValid {
                    Text("Select your role and an API key for the selected provider" +
                         (settings.useTemporalCloud ? ", and Temporal Cloud needs an address, namespace, and API key." : "."))
                        .font(.caption)
                        .foregroundStyle(Theme.mediumPriority)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }

    private func apply() {
        app.settings.save()
        isApplying = true
        statusMessage = "Writing .env and restarting worker…"
        Task {
            await app.reload()
            isApplying = false
            statusMessage = app.isReady ? "Applied. Worker restarted." : "Worker restart reported an issue — see the main window."
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose or create a folder for meeting summaries"
        if panel.runModal() == .OK, let url = panel.url {
            app.settings.outputDir = url.path
        }
    }
}
