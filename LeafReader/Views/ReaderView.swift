import SwiftUI

struct ReaderView: View {
    @EnvironmentObject private var library: LibraryStore
    let bookID: UUID
    let initialLocator: String?
    var body: some View {
        if let book = library.book(bookID), let url = library.fileURL(book) {
            ReaderContent(book: book, url: url, library: library, initialLocator: initialLocator)
        } else { ContentUnavailableView("Book unavailable", systemImage: "book.closed", description: Text("Import this book again from Files.")) }
    }
}

private enum ReaderPanel: String, Identifiable { case contents, appearance, search, bookmarks, aiSettings, buttonAppearance, annotation, audio; var id: String { rawValue } }

struct ReaderContent: View {
    let book: Book
    let url: URL
    @StateObject private var model: ReaderModel
    @StateObject private var audio: ReadAloudSession
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("reader.fontSize") private var fontSize = 19.0
    @AppStorage("reader.lineHeight") private var lineHeight = 1.65
    @AppStorage("reader.font") private var font = "Georgia"
    @AppStorage("reader.theme") private var themeName = ReadingTheme.day.rawValue
    @AppStorage("reader.scrolling") private var scrolling = false
    @AppStorage("reader.horizontalMargin") private var horizontalMargin = 20.0
    @AppStorage("reader.verticalMargin") private var verticalMargin = 12.0
    @AppStorage("reader.paragraphSpacing") private var paragraphSpacing = 0.65
    @State private var panel: ReaderPanel?
    @State private var chatIsPresented = false
    @State private var chatButtonIsMoving = false
    @StateObject private var chat: ReaderChatSession
    @EnvironmentObject private var aiSettings: AISettingsStore
    @State private var bookViewportHeight: CGFloat = 0
    @State private var password = ""
    @State private var seek = 0.0
    @State private var seeking = false
    private var showsControls: Bool {
        model.controlsVisible || panel != nil || !model.isReady || model.isLocked || model.error != nil || voiceOverEnabled
    }
    private var theme: ReadingTheme { ReadingTheme(rawValue: themeName) ?? .day }
    private var preferences: ReaderPreferences {
        ReaderPreferences(fontSize: fontSize, lineHeight: lineHeight, font: font, theme: theme, scrolling: scrolling,
                          horizontalMargin: horizontalMargin, verticalMargin: verticalMargin, paragraphSpacing: paragraphSpacing)
    }

    init(book: Book, url: URL, library: LibraryStore, initialLocator: String?) {
        self.book = book; self.url = url
        _model = StateObject(wrappedValue: ReaderModel(bookID: book.id, library: library, initialLocator: initialLocator))
        #if DEBUG
        let defaults = UITesting.defaults
        #else
        let defaults = UserDefaults.standard
        #endif
        _audio = StateObject(wrappedValue: ReadAloudSession(bookmarkURL: library.disk?.root.appendingPathComponent("Audio/\(book.id.uuidString).json"), defaults: defaults))
        _chat = StateObject(wrappedValue: ReaderChatSession(directory: library.disk?.root.appendingPathComponent("ChatHistory", isDirectory: true), conversation: book.fingerprint))
    }
    var body: some View {
        ZStack {
            ZStack {
                if book.format == .pdf { PDFBookSurface(model: model, url: url, theme: theme, onReaderTap: handleBookTap).id(model.reloadID) }
                else { WebBookSurface(model: model, url: url, preferences: preferences, onReaderTap: handleBookTap).id(model.reloadID) }
                if !model.isReady, model.error == nil, !model.isLocked {
                    VStack(spacing: 16) { ProgressView(); Text("Opening your book…").font(.subheadline) }.frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.background)
                }
                if model.isLocked {
                    VStack(spacing: 18) {
                        Image(systemName: "lock.doc").font(.largeTitle)
                        Text("Unlock this PDF").font(.title2)
                        SecureField("PDF password", text: $password).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                        if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
                        Button("Unlock") { model.unlockPDF(password) }.buttonStyle(.borderedProminent).foregroundStyle(theme.onAccent)
                    }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.background)
                } else if let error = model.error {
                    ContentUnavailableView {
                        Label("This book could not be opened", systemImage: "book.closed")
                    } description: { Text(error) } actions: {
                        Button("Reload book") { model.reload() }.buttonStyle(.bordered)
                        Button("Back to library") { dismiss() }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.background).accessibilityIdentifier("readerError")
                }
            }.frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped()
                .overlay {
                    if panel == .appearance {
                        Button {
                            panel = nil
                            model.hideControls()
                        } label: {
                            Color.clear.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss appearance")
                        .accessibilityIdentifier("dismissAppearance")
                    }
                }
            if audio.isPresented, panel == nil {
                VStack {
                    if !chatIsPresented { Spacer(minLength: 0) }
                    ReaderAudioPlayer(session: audio) { panel = .audio }
                        .padding(.horizontal, 12)
                        .padding(.top, chatIsPresented ? (showsControls ? 68 : 8) : 0)
                        .padding(.bottom, chatIsPresented ? 0 : (showsControls ? 112 : 12))
                    if chatIsPresented { Spacer(minLength: 0) }
                }.environment(\.leafTheme, theme)
            }
            if showsControls {
                VStack(spacing: 0) {
                    readerHeader
                    Spacer(minLength: 0)
                    readerFooter
                }.transition(.opacity)
            }
            if model.isReady, !model.isLocked, model.error == nil, panel == nil, !chatIsPresented {
                if chatButtonIsMoving {
                    // Consume the finishing tap, including taps over the reader controls.
                    // It must not also turn a page, open a menu, or change the passage.
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { chatButtonIsMoving = false }
                        .accessibilityLabel("Finish moving Ask Leaf")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("finishMovingChatButton")
                        .accessibilityAction { chatButtonIsMoving = false }
                }
                ReaderChatLauncher(isMoving: $chatButtonIsMoving) {
                    model.hideControls()
                    chatIsPresented = true
                }
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { updateViewport(geometry.size) }
                    .onChange(of: geometry.size) { _, size in updateViewport(size) }
            }
        }
        // Keep only the book full-height; the overlay uses the keyboard safe area.
        .ignoresSafeArea(.keyboard)
        .overlay {
            if chatIsPresented {
                ResizableChatPanel(session: chat, location: .reader, fullHeight: bookViewportHeight, bookTitle: book.title, onClose: {
                    chatIsPresented = false
                    model.clearNativeSelection()
                    model.hideControls()
                }, onSettings: {
                    chat.stop()
                    panel = .aiSettings
                }, onButtonSettings: {
                    panel = .buttonAppearance
                }, onSend: {
                    chat.send(settings: aiSettings) { try await model.readingChatContext() }
                })
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: showsControls)
        .background(theme.background.ignoresSafeArea()).foregroundStyle(theme.foreground).tint(theme.accent)
        .preferredColorScheme(theme.colorScheme)
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(showsControls ? .automatic : .hidden)
        .accessibilityAction(.escape) { library.flush(); dismiss() }
        .task {
            // Configure the retained StateObjects after installation. Creating
            // them eagerly in init would allocate new readers/synthesizers on
            // every parent refresh as reading progress changes.
            audio.source = { [weak model] locator in
                guard let model else { throw ReadAloudError.unavailable }
                return try await model.readAloudPassage(at: locator)
            }
            audio.reveal = { [weak model] locator in await model?.revealReadAloud(at: locator) }
            audio.highlight = { [weak model] passage, range, follow in model?.highlightReadAloud(passage, range: range, follow: follow) }
            audio.clearSource = { [weak model] in model?.webView?.evaluateJavaScript("window.Leaf?.clearReadAloud()", completionHandler: nil) }
            library.open(book.id)
        }
        .onDisappear { audio.stop(); chat.close(); library.flush() }
        .onChange(of: library.book(book.id)?.annotations ?? []) { _, _ in model.synchronizeAnnotations() }
        .onChange(of: model.annotationDraft) { _, draft in if draft != nil { panel = .annotation } }
        .alert("Could not save highlight", isPresented: Binding(get: { model.annotationError != nil }, set: { if !$0 { model.annotationError = nil } })) {
            Button("OK") { model.annotationError = nil }
        } message: { Text(model.annotationError ?? "") }
        .onChange(of: model.liveSelection) { _, selection in
            chat.attachLiveSelection(selection, chatIsPresented: chatIsPresented)
        }
        .onChange(of: model.listeningRequest) { _, request in
            guard let request else { return }
            audio.start(at: request.locator)
            model.clearNativeSelection(); model.hideControls(); panel = nil
        }
        .onChange(of: model.reloadID) { _, _ in audio.stop() }
        .onChange(of: model.selectionRequest) { _, request in
            guard let request else { return }
            chatButtonIsMoving = false
            chat.attachSelection(request.context, prompt: request.intent.prompt(for: request.context.text))
            model.hideControls()
            chatIsPresented = true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { chatButtonIsMoving = false; chat.flush() }
            if phase == .background { audio.pause() }
        }
        .sheet(item: $panel, onDismiss: { model.hideControls() }) { panel in
            NavigationStack {
                Group {
                    switch panel {
                    case .appearance: ReaderAppearancePanel()
                    case .aiSettings: AISettingsView()
                    case .audio:
                        ReaderAudioSettings(session: audio, onStart: {
                            audio.start(at: book.format == .pdf ? model.visiblePDFListeningPosition() : model.locator)
                            self.panel = nil; model.hideControls()
                        }, onResume: {
                            audio.resumeSaved(); self.panel = nil; model.hideControls()
                        })
                    case .buttonAppearance: ReaderChatButtonSettings()
                    case .annotation:
                        if let annotation = model.annotationDraft {
                            let saved = library.book(book.id)?.annotations.contains { $0.id == annotation.id } == true
                            AnnotationEditorView(annotation: annotation, isSaved: saved, onSave: { try model.saveAnnotation($0) },
                                onDelete: saved ? { try model.removeAnnotation(annotation.id) } : nil,
                                onClose: { model.annotationDraft = nil; self.panel = nil })
                                .id(annotation.id)
                        }
                    case .contents:
                        List(model.chapters) { chapter in
                            Button { model.send("navigate", value: chapter.href); self.panel = nil } label: {
                                Text(chapter.label).padding(.leading, CGFloat(chapter.depth) * 16).foregroundStyle(.primary)
                            }.listRowBackground(theme.surface)
                        }.leafFormStyle().overlay { if model.chapters.isEmpty { ContentUnavailableView("No table of contents", systemImage: "list.bullet", description: Text("Use the progress slider to move through this book.")) } }.navigationTitle("Contents")
                    case .bookmarks:
                        if let current = library.book(book.id) {
                            ReaderSavedPassagesView(book: current, onNavigate: { model.send("navigate", value: $0); self.panel = nil },
                                onEdit: { model.annotationDraft = $0 }, onDelete: { try model.removeAnnotation($0) },
                                onRemoveBookmark: { library.removeBookmark(book.id, bookmarkID: $0) })
                        }
                    case .search: ReaderSearchView(model: model) { self.panel = nil; model.hideControls() }
                    }
                }.navigationBarTitleDisplayMode(.inline).toolbar {
                    if panel != .appearance && panel != .annotation {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { self.panel = nil; model.hideControls() }
                        }
                    }
                }
            }
            .environment(\.leafTheme, theme)
            .tint(theme.accent)
            .presentationDetents(panel == .appearance ? [.medium, .large] : [.large])
            .presentationDragIndicator(panel == .appearance ? .visible : .automatic)
            .presentationBackgroundInteraction(panel == .appearance ? .enabled(upThrough: .medium) : .disabled)
        }
    }
    private func updateViewport(_ size: CGSize) {
        bookViewportHeight = size.height
    }
    private func handleBookTap() -> Bool {
        guard chatIsPresented else { return false }
        model.hideControls()
        return true
    }
    private var readerHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button { library.flush(); dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }.accessibilityLabel("Close book").accessibilityIdentifier("closeBook")
                VStack(spacing: 3) {
                    Text(library.book(book.id)?.title ?? book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(model.chapterTitle.isEmpty ? book.author : model.chapterTitle).font(.caption).foregroundStyle(theme.foreground.opacity(0.65)).lineLimit(1).accessibilityIdentifier("readerChapterTitle")
                }.frame(maxWidth: .infinity)
                Button { model.toggleBookmark() } label: { Image(systemName: model.isBookmarked ? "bookmark.fill" : "bookmark").frame(width: 44, height: 44) }
                    .disabled(!model.isReady).accessibilityLabel(model.isBookmarked ? "Remove bookmark" : "Add bookmark").accessibilityIdentifier("toggleBookmark")
            }.padding(.horizontal, 8).padding(.top, 4)
            Rectangle().fill(theme.foreground.opacity(0.08)).frame(height: 1)
        }.background(theme.background)
    }
    private var readerFooter: some View {
        VStack(spacing: 0) {
            Rectangle().fill(theme.foreground.opacity(0.08)).frame(height: 1)
            VStack(spacing: 4) {
                HStack(spacing: 12) {
                    Button { model.send("previous") } label: { Image(systemName: "chevron.left").frame(width: 44, height: 40) }.accessibilityLabel("Previous page")
                    Slider(value: Binding(get: { seeking ? seek : model.fraction }, set: { seek = $0 }), in: 0...1) { Text("Reading progress") } onEditingChanged: { editing in
                        seeking = editing
                        if !editing { model.send("seek", value: seek) }
                    }.accessibilityIdentifier("readingProgress")
                    Text(model.positionLabel).font(.caption.monospacedDigit()).frame(minWidth: 33)
                    Button { model.send("next") } label: { Image(systemName: "chevron.right").frame(width: 44, height: 40) }.accessibilityLabel("Next page").accessibilityIdentifier("nextPage")
                }
                HStack {
                    panelButton("Contents", "list.bullet", .contents)
                    Spacer()
                    panelButton("Search", "magnifyingglass", .search)
                    Spacer()
                    panelButton("Saved", "bookmark", .bookmarks)
                    Spacer()
                    panelButton("Listen", "headphones", .audio)
                    Spacer()
                    panelButton("Appearance", "textformat.size", .appearance)
                }.padding(.horizontal, 16)
            }.padding(.horizontal, 12).padding(.bottom, 8).disabled(!model.isReady)
        }
        .background(theme.background)
    }
    private func panelButton(_ title: String, _ image: String, _ panel: ReaderPanel) -> some View {
        Button { self.panel = panel } label: { VStack(spacing: 4) { Image(systemName: image).font(.system(size: 18)); Text(title).font(.system(size: 10)) }.frame(minWidth: 48, minHeight: 44) }.accessibilityLabel(title)
    }
}

struct ReaderSearchView: View {
    @Environment(\.leafTheme) private var theme
    @ObservedObject var model: ReaderModel
    let onNavigate: () -> Void
    @State private var query = ""
    var body: some View {
        List(model.searchResults) { result in
            Button { model.send("navigate", value: result.locator); onNavigate() } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Text(result.label).font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
                    Text(result.excerpt).font(.subheadline).foregroundStyle(.primary)
                }.padding(.vertical, 4)
            }.listRowBackground(theme.surface)
        }.leafFormStyle()
        .overlay {
            if model.isSearching { ProgressView("Searching…") }
            else if model.searchResults.isEmpty {
                ContentUnavailableView(model.hasSearched ? "No matching passages" : "Find a passage", systemImage: "magnifyingglass", description: Text(model.hasSearched ? "Try a different word or phrase." : "Search the text of this book. Image-only PDFs and comics do not contain searchable text."))
            }
        }
        .searchable(text: $query, prompt: "Search this book")
        .onSubmit(of: .search) { model.search(query) }
        .navigationTitle("Search")
    }
}
