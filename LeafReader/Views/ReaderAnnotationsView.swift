import SwiftUI

struct AnnotationEditorView: View {
    @Environment(\.leafTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var library: LibraryStore
    let annotation: BookAnnotation
    let isSaved: Bool
    let voiceFirst: Bool
    let onSave: (BookAnnotation, URL?) async throws -> Void
    var onDelete: (() throws -> Void)?
    let onClose: () -> Void
    @State private var note: String
    @State private var color: BookAnnotationColor
    @State private var error: String?
    @State private var showsFullPassage = false
    @State private var voice: VoiceNote?
    @State private var voiceChanged = false
    @State private var saving = false
    @StateObject private var audio = VoiceNoteSession()

    init(annotation: BookAnnotation, isSaved: Bool, voiceFirst: Bool = false, onSave: @escaping (BookAnnotation, URL?) async throws -> Void,
         onDelete: (() throws -> Void)? = nil, onClose: @escaping () -> Void) {
        self.annotation = annotation; self.isSaved = isSaved
        self.voiceFirst = voiceFirst || annotation.voiceNote != nil
        self.onSave = onSave; self.onDelete = onDelete; self.onClose = onClose
        _note = State(initialValue: annotation.note); _color = State(initialValue: annotation.color)
        _voice = State(initialValue: annotation.voiceNote)
    }
    var body: some View {
        Form {
            Section("Selected passage") {
                Text(annotation.text).font(.body).textSelection(.enabled).lineLimit(showsFullPassage ? nil : 4)
                    .accessibilityIdentifier("annotationQuote")
                if annotation.text.count > 160 {
                    Button(showsFullPassage ? "Show less" : "Show full passage") { showsFullPassage.toggle() }.font(.subheadline)
                }
                if !annotation.chapter.isEmpty { Text(annotation.chapter).font(.caption).foregroundStyle(.secondary) }
            }
            if voiceFirst { voiceSection }
            Section("Highlight color") {
                HStack(spacing: 16) {
                    ForEach(BookAnnotationColor.allCases) { choice in
                        Button { color = choice } label: {
                            Circle().fill(choice.color).frame(width: 40, height: 40)
                                .overlay { if color == choice { Image(systemName: "checkmark").font(.headline).foregroundStyle(.black) } }
                                .frame(minWidth: 44, minHeight: 44)
                        }.buttonStyle(.plain)
                            .accessibilityLabel(choice.title + " highlight")
                            .accessibilityAddTraits(color == choice ? .isSelected : [])
                    }
                }
            }
            Section {
                TextEditor(text: $note).frame(minHeight: 160).scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if note.isEmpty {
                            Text("Add your note…").foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 5)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Note").accessibilityIdentifier("annotationNote")
                if note.count > 20_000 { Text(BookAnnotationError.noteTooLong.localizedDescription).font(.caption).foregroundStyle(.red) }
            } header: { Text(voiceFirst ? "Text note (optional)" : "Note") } footer: { Text("Save keeps the text and audio with this passage. Notes are included when you sync your library with iCloud.") }
            if !voiceFirst { voiceSection }
            if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("annotationSaveError") } }
            if let onDelete {
                Section {
                    Button("Delete highlight and notes", role: .destructive) {
                        do { try onDelete(); onClose() } catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("deleteAnnotation")
                }
            }
        }.disabled(saving).leafFormStyle().accessibilityIdentifier("annotationForm")
            .navigationTitle(isSaved ? "Edit note" : voiceFirst ? "Voice note" : "Add note").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.canvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose).disabled(saving).accessibilityIdentifier("cancelAnnotation") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = annotation; updated.note = note; updated.color = color; updated.updatedAt = Date()
                        updated.contentUpdatedAt = note != annotation.note || color != annotation.color
                            ? updated.updatedAt : annotation.contentUpdatedAt ?? annotation.updatedAt
                        if voiceChanged { updated.voiceNote = voice; updated.voiceNoteUpdatedAt = updated.updatedAt }
                        let draft = voice?.id == audio.recordedNote?.id ? audio.draftURL : nil
                        saving = true
                        Task {
                            do { try await onSave(updated, draft); onClose() }
                            catch { self.error = error.localizedDescription }
                            saving = false
                        }
                    }.disabled(saving || audio.isBusy || note.count > 20_000 || (voiceFirst && !isSaved && voice == nil && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .accessibilityIdentifier("saveAnnotation")
                }
            }
            .interactiveDismissDisabled()
            .onChange(of: audio.recordedNote) { _, clip in if let clip { voice = clip; voiceChanged = true } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { audio.suspend(background: phase == .background) } }
            .onDisappear { audio.close() }
    }
    private var voiceSection: some View {
        Section {
            if audio.state == .authorizing {
                ProgressView("Starting microphone…").accessibilityIdentifier("voiceNoteAuthorizing")
            } else if audio.state == .recording {
                Label("Recording \(VoiceNote.timeLabel(audio.elapsed))", systemImage: "record.circle.fill")
                    .foregroundStyle(.red).monospacedDigit().accessibilityIdentifier("voiceNoteRecording")
                Button("Stop recording", systemImage: "stop.circle.fill") { audio.stopRecording() }
                    .accessibilityIdentifier("stopVoiceNote")
            } else if audio.state == .processing {
                ProgressView("Preparing recording…").accessibilityIdentifier("voiceNoteProcessing")
            } else if let voice {
                VoiceNotePlaybackControls(note: voice, url: voice.id == audio.recordedNote?.id ? audio.draftURL : library.voiceNoteURL(voice), audio: audio)
                Button("Remove voice note", systemImage: "trash", role: .destructive) {
                    audio.discardDraft(); self.voice = nil; voiceChanged = true
                }.disabled(saving).accessibilityIdentifier("removeVoiceNote")
            } else {
                Button("Record voice note", systemImage: "mic.fill") { audio.startRecording() }
                    .accessibilityIdentifier("recordVoiceNote")
            }
            if let error = audio.error {
                Text(error).font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("voiceNoteError")
                if audio.needsSettings {
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                        .accessibilityIdentifier("voiceNoteSettings")
                }
            }
        } header: { Text("Voice note") }
        footer: { Text(audio.state == .recording ? "Stop recording before saving. Recording stops at 10 minutes." : "Record up to 10 minutes. Preview before saving; Cancel keeps your original note.") }
    }
}

private struct VoiceNotePlaybackControls: View {
    let note: VoiceNote
    let url: URL?
    @ObservedObject var audio: VoiceNoteSession
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(audio.isPlaying ? "Pause voice note" : "Play voice note", systemImage: audio.isPlaying ? "pause.circle.fill" : "play.circle.fill") {
                    audio.togglePlayback(url: url)
                }.buttonStyle(.borderless).accessibilityIdentifier("playVoiceNote")
                Spacer()
                Text(audio.isPlaying || audio.playbackTime > 0 ? "\(VoiceNote.timeLabel(audio.playbackTime)) / \(note.durationLabel)" : note.durationLabel)
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).accessibilityIdentifier("voiceNoteDuration")
            }
            if audio.isPlaying || audio.playbackTime > 0 {
                ProgressView(value: audio.playbackTime, total: max(0.1, audio.playbackDuration))
                    .accessibilityLabel("Voice note playback").accessibilityIdentifier("voiceNotePlaybackProgress")
            }
        }.padding(.vertical, 4)
    }
}

struct AnnotationRow: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var audio = VoiceNoteSession()
    let annotation: BookAnnotation
    let onNavigate: () -> Void
    let onEdit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 12) {
            Button(action: onNavigate) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: annotation.voiceNote != nil ? "waveform" : annotation.hasTextNote ? "note.text" : "highlighter")
                        .foregroundStyle(annotation.color.color).frame(width: 24)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(annotation.text).lineLimit(3).foregroundStyle(.primary)
                        if annotation.hasTextNote { Text(annotation.note).lineLimit(2).font(.subheadline).foregroundStyle(.secondary) }
                        if let voice = annotation.voiceNote { Text("Voice note · \(voice.durationLabel)").font(.caption).foregroundStyle(.secondary) }
                        Text(annotation.chapter.isEmpty ? "\(Int(annotation.fraction * 100))% through the book" : annotation.chapter)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }.buttonStyle(.plain).accessibilityIdentifier("savedAnnotation-\(annotation.id)")
            Button(action: onEdit) { Image(systemName: "square.and.pencil").frame(width: 44, height: 44) }
                .buttonStyle(.borderless).accessibilityLabel("Edit highlight and note")
                .accessibilityIdentifier("editAnnotation-\(annotation.id)")
        }
        if let voice = annotation.voiceNote {
            VoiceNotePlaybackControls(note: voice, url: library.voiceNoteURL(voice), audio: audio)
            if let error = audio.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        }.onDisappear { audio.close() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { audio.suspend(background: phase == .background) } }
    }
}

struct ReaderSavedPassagesView: View {
    @Environment(\.leafTheme) private var theme
    let book: Book
    let onNavigate: (String) -> Void
    let onEdit: (BookAnnotation) -> Void
    let onDelete: (UUID) throws -> Void
    let onRemoveBookmark: (UUID) -> Void
    @State private var highlights: Bool
    @State private var error: String?
    init(book: Book, onNavigate: @escaping (String) -> Void, onEdit: @escaping (BookAnnotation) -> Void,
         onDelete: @escaping (UUID) throws -> Void, onRemoveBookmark: @escaping (UUID) -> Void) {
        self.book = book; self.onNavigate = onNavigate; self.onEdit = onEdit
        self.onDelete = onDelete; self.onRemoveBookmark = onRemoveBookmark
        _highlights = State(initialValue: !book.annotations.isEmpty)
    }
    var body: some View {
        List {
            Picker("Saved passages", selection: $highlights) {
                Text("Bookmarks").tag(false)
                Text("Highlights & notes").tag(true)
            }.pickerStyle(.segmented).listRowBackground(theme.surface).accessibilityIdentifier("savedPassageFilter")
            if highlights {
                if book.annotations.isEmpty { Text("Select text in the book, then choose Highlight or Add Note.").foregroundStyle(.secondary) }
                ForEach(book.annotations.sorted { $0.createdAt > $1.createdAt }) { annotation in
                    AnnotationRow(annotation: annotation, onNavigate: { onNavigate(annotation.locator) }, onEdit: { onEdit(annotation) })
                        .swipeActions {
                            Button("Delete", role: .destructive) { do { try onDelete(annotation.id) } catch { self.error = error.localizedDescription } }
                        }.listRowBackground(theme.surface)
                }
            } else {
                if book.bookmarks.isEmpty { Text("Tap the bookmark at the top of the page to save your place.").foregroundStyle(.secondary) }
                ForEach(book.bookmarks) { bookmark in
                    Button { onNavigate(bookmark.locator) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bookmark.label)
                            Text("\(Int(bookmark.fraction * 100))% through the book").font(.caption).foregroundStyle(.secondary)
                        }
                    }.swipeActions { Button("Delete", role: .destructive) { onRemoveBookmark(bookmark.id) } }
                        .listRowBackground(theme.surface)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.leafFormStyle().navigationTitle("Saved places")
    }
}
