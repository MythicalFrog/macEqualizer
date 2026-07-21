import SwiftUI

let accent = Color(red: 0.35, green: 0.65, blue: 0.72)
let surface1 = Color.white.opacity(0.05)
let surface2 = Color.white.opacity(0.03)
let glassBorder = Color.white.opacity(0.06)

struct PillToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? accent : Color.white.opacity(0.12))
                .frame(width: 36, height: 20)
                .overlay(
                    Circle()
                        .fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.25), radius: 2)
                        .offset(x: isOn ? 8 : -8)
                        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
                )
        }
        .buttonStyle(.plain)
    }
}

struct EQAssistantPanel: View {
    @EnvironmentObject private var model: EqualizerModel
    @EnvironmentObject private var assistant: EQAssistantService
    @Binding var csvText: String
    @State private var inputText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PanelTitle("EQ Assistant", systemImage: "waveform.badge.mic")
                Spacer()
                if assistant.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                }

            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if assistant.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Describe the sound you want")
                                    .font(.subheadline.weight(.medium))
                                Text("e.g. \"bass boost for EDM\", \"bright vocal clarity\", \"warm vintage radio\", or even a song name")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(10)
                            .background(surface2, in: RoundedRectangle(cornerRadius: 8))
                        }

                        ForEach(assistant.messages) { message in
                            MessageBubble(message: message, csvText: $csvText)
                        }

                        if assistant.isLoading {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Analyzing...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            HStack(spacing: 8) {
                TextField("Describe your sound...", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onSubmit(send)
                    .disabled(assistant.isLoading)

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(accent)
                .padding(7)
                .background(accent.opacity(0.12), in: Capsule())
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || assistant.isLoading)
            }
        }
        .panelStyle()
        .blur(radius: model.isAutoEQEnabled ? 4 : 0)
        .overlay {
            if model.isAutoEQEnabled {
                ZStack {
                    Color.black.opacity(0.35)
                    Text("Turn off Auto-EQ to use this feature")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        }
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !assistant.isLoading else { return }
        inputText = ""
        Task {
            await assistant.sendMessage(text, model: model)
            if !assistant.lastGeneratedCSV.isEmpty {
                csvText = assistant.lastGeneratedCSV
            }
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @Binding var csvText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: message.role == .user ? "person.fill" : "sparkle")
                    .font(.caption2)
                    .foregroundStyle(message.role == .user ? accent : accent)
                Text(message.role == .user ? "You" : "AI")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if message.role == .assistant && message.content.contains(",") {
                Text(message.content)
                    .font(.caption2.monospaced())
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(surface2, in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(accent)

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(accent)
                    Text("Applied to EQ")
                        .font(.caption2)
                        .foregroundStyle(accent)
                }
            } else if message.role == .assistant && message.content.hasPrefix("Error:") {
                Text(message.content)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(message.content)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
        .padding(10)
        .background(
            message.role == .user
                ? surface1
                : surface2,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}
