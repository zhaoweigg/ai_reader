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
                }.buttonStyle(.plain).accessibilityLabel("Listening settings").accessibilityValue(session.spokenText).accessibilityIdentifier("listeningSettings")
                Menu {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { speed in
                        Button(String(format: "%g×", speed)) { session.speed = speed }
                    }
                } label: { Text(session.speedLabel).font(.caption.weight(.semibold)).frame(minWidth: 38, minHeight: 44) }
                    .accessibilityLabel("Playback speed").accessibilityValue(session.speedLabel).accessibilityIdentifier("playbackSpeed")
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
        // The container's value mirrors the visible status ("Generating voice…", "Listening", …)
        // so automation can wait for audible playback without changing the button labels.
        .accessibilityValue(status)
    }
    private var status: String {
        switch session.state {
        case .idle: return "Read aloud"
        case .loading: return "Preparing audio…"
        case .playing: return session.isBuffering ? "Generating voice…" : "Listening"
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
    @State private var voices: [AppleReadingVoice] = []
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
                Picker("Voice engine", selection: $session.engine) {
                    ForEach(ReadAloudEngine.allCases) { engine in
                        Text(engine == .kokoro ? "Natural voice" : "Apple voices").tag(engine)
                    }
                }.pickerStyle(.segmented).accessibilityIdentifier("listeningEngine")
                if session.engine == .kokoro, let model = session.voiceModel {
                    KokoroVoicePackRow(model: model, session: session)
                } else if !voices.isEmpty {
                    Picker("Voice", selection: $session.voice) {
                        Text("Automatic · best quality").tag("")
                        ForEach(voices) { voice in
                            Text("\(voice.name) · \(voice.qualityLabel) · \(Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language)").tag(voice.id)
                        }
                    }.accessibilityIdentifier("listeningVoice")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Download an Enhanced or Premium voice").font(.subheadline.weight(.semibold))
                        Text("Add a voice in iPhone Accessibility settings, then return to Leaf. Basic voices are not used.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.accessibilityIdentifier("appleVoiceDownloadGuidance")
                }
                HStack { Text("Speed"); Spacer(); Text(session.speedLabel).monospacedDigit().foregroundStyle(.secondary).accessibilityIdentifier("listeningSpeedValue") }
                Slider(value: $session.speed, in: 0.5...2, step: 0.25) { Text("Playback speed") }
                    .accessibilityIdentifier("listeningSpeedSlider")
                Toggle("Follow the spoken passage", isOn: $session.followsText)
                    .accessibilityIdentifier("followSpokenText")
            } header: { Text("Voice and speed") } footer: {
                if session.engine == .kokoro {
                    Text("Apple and Natural voices remember separate speeds. Natural voice runs on your iPhone for Chinese and English. No account is needed, and no text leaves the device. If it cannot start, Leaf can use a downloaded Enhanced or Premium Apple voice. Basic voices are not used. Playback pauses in the background; your listening position is saved.")
                } else {
                    Text("Apple and Natural voices remember separate speeds. Only downloaded Enhanced and Premium Apple voices are used. Automatic prefers Premium for the text’s language. Add voices in iPhone Accessibility settings. Playback pauses in the background; your listening position is saved.")
                }
            }.listRowBackground(theme.surface)
            Section {
                Text("Select any text and choose Listen from here to begin at that word and continue through the book. Listening does not change your highlights or conversation history.").font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(theme.surface)
        }.leafFormStyle().navigationTitle("Listen")
            .accessibilityIdentifier("listeningForm")
            .onAppear { voices = AppleVoiceCatalog.installed }
            .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
                voices = AppleVoiceCatalog.installed
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                voices = AppleVoiceCatalog.installed
            }
    }
}

/// Download state and voice choice for the on-device model.
struct KokoroVoicePackRow: View {
    @ObservedObject var model: KokoroModelStore
    @ObservedObject var session: ReadAloudSession
    var body: some View {
        switch model.state {
        case .notInstalled:
            VStack(alignment: .leading, spacing: 6) {
                Text("Voice pack not downloaded").font(.subheadline.weight(.semibold))
                Text("One \(model.manifest.archiveSizeLabel) download (about 420 MB on disk) with 100 Chinese and 3 English voices. Needs Wi‑Fi or a generous data plan.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button { model.install() } label: { Label("Download natural voices", systemImage: "arrow.down.circle") }
                .accessibilityIdentifier("kokoroDownload")
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloading voice pack… \(Int(fraction * 100))%").font(.subheadline)
                ProgressView(value: fraction).accessibilityIdentifier("kokoroDownloadProgress")
            }
            Button("Cancel download", role: .cancel) { model.cancel() }.accessibilityIdentifier("kokoroCancel")
        case .verifying, .unpacking:
            HStack { ProgressView(); Text(model.state == .verifying ? "Checking the download…" : "Unpacking voices…").padding(.leading, 8) }
                .accessibilityIdentifier("kokoroPreparing")
        case .failed(let reason):
            Text(reason).font(.footnote).foregroundStyle(.red)
            Button { model.install() } label: { Label("Try again", systemImage: "arrow.clockwise") }.accessibilityIdentifier("kokoroRetry")
        case .ready:
            Picker("Voice", selection: $session.kokoroVoice) {
                Text("Automatic · match the text").tag("")
                Section("Chinese · female") { ForEach(KokoroVoiceCatalog.chineseFemale) { Text($0.title).tag($0.id) } }
                Section("Chinese · male") { ForEach(KokoroVoiceCatalog.chineseMale) { Text($0.title).tag($0.id) } }
                Section("English") { ForEach(KokoroVoiceCatalog.english) { Text($0.title).tag($0.id) } }
            }.accessibilityIdentifier("kokoroVoice")
            if let reason = session.fallbackReason {
                Text("Last passage used an Enhanced or Premium Apple voice: \(reason)").font(.footnote).foregroundStyle(.secondary)
            }
            Button(role: .destructive) { model.remove() } label: { Label("Remove voice pack", systemImage: "trash") }
                .accessibilityIdentifier("kokoroRemove")
        }
    }
}
