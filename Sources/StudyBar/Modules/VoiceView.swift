import SwiftUI

/// Voice Note: record a memo, transcribe it on-device, save it as a note.
struct VoiceView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var voice = VoiceService()
    @State private var courseID: UUID?

    var body: some View {
        NavigationStack {
            ModulePane(title: "Voice Note") {
                if !voice.transcript.isEmpty && !voice.isRecording {
                    CoursePicker(courseID: $courseID)
                }
            } content: {
                VStack(spacing: 16) {
                    switch voice.status {
                    case .denied:
                        deniedState
                    case .unavailable(let msg):
                        EmptyState(symbol: "mic.slash", title: "Can't record", subtitle: msg)
                    default:
                        recorder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            }
        }
    }

    private var recorder: some View {
        VStack(spacing: 16) {
            Button { voice.toggle() } label: {
                ZStack {
                    Circle().fill(voice.isRecording ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                        .frame(width: 78, height: 78)
                    Image(systemName: voice.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30)).foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottom) {
                Text(voice.isRecording ? "Recording — tap to stop" : "Tap to record")
                    .font(.caption).foregroundStyle(.secondary).offset(y: 22)
            }

            if !voice.transcript.isEmpty {
                ScrollView {
                    Text(voice.transcript)
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.sbSurface, in: RoundedRectangle(cornerRadius: 10))
                }
                .frame(maxHeight: 220)

                if !voice.isRecording {
                    HStack {
                        Button("Save as note") { saveNote() }.buttonStyle(.borderedProminent)
                        Button("Discard") { voice.transcript = "" }.buttonStyle(.bordered)
                    }
                }
            } else if !voice.isRecording {
                Text("Speak a quick memo — a reminder, an idea, a to-do — and StudyBar transcribes it into a note, all on your Mac.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.top, 24)
            }
            Spacer()
        }
    }

    private var deniedState: some View {
        VStack(spacing: 12) {
            EmptyState(symbol: "mic.slash", title: "Microphone or speech access off",
                       subtitle: "Allow StudyBar under System Settings ▸ Privacy & Security ▸ Microphone and Speech Recognition.")
            Button("Open Privacy Settings") {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(u)
                }
            }.buttonStyle(.borderedProminent)
        }
    }

    private func saveNote() {
        let text = voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let title = "Voice note \(Date().dayMonth)"
        state.data.notes.append(Note(title: title, body: text, courseID: courseID))
        voice.transcript = ""
        state.selectedModuleID = "notes"
    }
}
