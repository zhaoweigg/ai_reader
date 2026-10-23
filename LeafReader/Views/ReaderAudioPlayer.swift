import SwiftUI
import AVFoundation

struct ReaderAudioPlayer: View {
    @Environment(\.leafTheme) private var theme
    @ObservedObject var session: ReadAloudSession
    let onSettings: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onSettings) {
                    HStack(spacing: 8) {
                        Image(systemName: "headphones").foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status).font(.caption.weight(.semibold))
                            Text(session.passage?.label ?? "Read aloud").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Listening settings").accessibilityIdentifier("listeningSettings")
                Menu {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { speed in
                        Button(String(format: "%g×", speed)) { session.speed = speed }
                    }
                } label: { Text(session.speedLabel).font(.caption.weight(.semibold)).frame(minWidth: 38, minHeight: 44) }
                    .accessibilityLabel("Playback speed").accessibilityIdentifier("playbackSpeed")
                Button { session.previous() } label: { Image(systemName: "backward.end.fill").frame(width: 36, height: 44) }
                    .disabled(!session.canGoBack).accessibilityLabel("Previous passage").accessibilityIdentifier("audioPrevious")
                Button { session.togglePlayback() } label: {
                    if session.state == .loading { ProgressView().frame(width: 40, height: 44) }
                    else { Image(systemName: session.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 40, height: 44) }
                }.disabled(session.state == .finished || session.state == .failed)
                    .accessibilityLabel(session.isPlaying ? "Pause listening" : "Resume listening").accessibilityIdentifier("audioPlayPause")
                Button { session.next() } label: { Image(systemName: "forward.end.fill").frame(width: 36, height: 44) }
                    .disabled(session.passage == nil || session.state == .finished || session.state == .loading)
                    .accessibilityLabel("Next passage").accessibilityIdentifier("audioNext")
                Button { session.stop() } label: { Image(systemName: "xmark").frame(width: 32, height: 44) }
                    .accessibilityLabel("Stop listening").accessibilityIdentifier("stopListening")
            }
            if let error = session.error { Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
            else if let passage = session.passage { Text(passage.text).font(.caption).lineLimit(1).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("spokenPassage") }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(theme.foreground.opacity(0.08)))
        .foregroundStyle(theme.foreground).tint(theme.accent)
        .accessibilityElement(children: .contain).accessibilityIdentifier("readerAudioPlayer")
    }
    private var status: String {
        switch session.state {
        case .idle: return "Read aloud"
        case .loading: return "Preparing audio…"
        case .playing: return "Listening"
        case .paused: return "Paused"
        case .finished: return "End of book"
        case .failed: return "Could not start audio"
        }
    }
}

struct ReaderAudioSettings: View {
    @Environment(\.leafTheme) private var theme
    @ObservedObject var session: ReadAloudSession
    let onStart: () -> Void
    let onResume: () -> Void
    @State private var voices: [AVSpeechSynthesisVoice] = []
    var body: some View {
        Form {
            Section {
                Button(action: onStart) { Label("Listen from this page", systemImage: "play.fill") }
                    .accessibilityIdentifier("listenFromPage")
                if session.bookmark != nil {
                    Button(action: onResume) { Label("Resume saved listening position", systemImage: "play.circle") }
                        .accessibilityIdentifier("resumeSavedListening")
                }
                if session.isPresented {
                    Button(session.isPlaying ? "Pause listening" : "Resume listening") { session.togglePlayback() }
                        .disabled(session.state == .finished || session.state == .failed)
                    Button("Stop listening") { session.stop() }
                }
            }.listRowBackground(theme.surface)
            Section {
                Picker("Voice", selection: $session.voice) {
                    Text("Automatic · match the text").tag("")
                    ForEach(voices, id: \.identifier) { voice in
                        Text("\(voice.name) · \(Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language)").tag(voice.identifier)
                    }
                }.accessibilityIdentifier("listeningVoice")
                HStack { Text("Speed"); Spacer(); Text(session.speedLabel).monospacedDigit().foregroundStyle(.secondary) }
                Slider(value: $session.speed, in: 0.5...2, step: 0.25) { Text("Playback speed") }
                    .accessibilityIdentifier("listeningSpeedSlider")
                Toggle("Follow the spoken passage", isOn: $session.followsText)
                    .accessibilityIdentifier("followSpokenText")
            } header: { Text("Voice and speed") } footer: {
                Text("Uses the voices available on your iPhone. Automatic chooses a voice for the text’s language. No AI account is needed. Playback pauses when Leaf goes into the background; your listening position is saved.")
            }.listRowBackground(theme.surface)
            Section {
                Text("Select any text and choose Listen from here to begin at that word and continue through the book. Listening does not change your highlights or conversation history.").font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(theme.surface)
        }.leafFormStyle().navigationTitle("Listen")
            .onAppear { voices = AVSpeechSynthesisVoice.speechVoices().sorted { ($0.language, $0.name) < ($1.language, $1.name) } }
    }
}
