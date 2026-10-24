import SwiftUI

/// Opens history without opening a renderer or loading a book's chapters.
struct LibraryChatOverlay: View {
    @ObservedObject var session: ReaderChatSession
    let book: Book?
    let fullHeight: CGFloat
    let onClose: () -> Void
    let onChoose: () -> Void
    @Environment(\.leafTheme) private var theme
    @EnvironmentObject private var settings: AISettingsStore
    @State private var panel: Panel?
    private enum Panel: String, Identifiable { case settings, button; var id: String { rawValue } }

    var body: some View {
        ResizableChatPanel(session: session, location: .library, fullHeight: fullHeight, bookTitle: book?.title ?? "",
            context: book == nil ? .general : .libraryBook, onChooseConversation: onChoose,
            onClose: onClose, onSettings: { session.stop(); panel = .settings }, onButtonSettings: { panel = .button },
            onSend: {
                session.send(settings: settings, missingContextNotice: nil) {
                    // A quoted draft already has its own snapshot. Otherwise only
                    // the selected book's metadata is sent, never an unseen passage.
                    book.map { ReadingChatContext(title: $0.title, author: $0.author, chapter: "", text: "", source: "library_metadata", locator: "") }
                }
            })
        .sheet(item: $panel) { value in
            NavigationStack {
                Group {
                    switch value {
                    case .settings: AISettingsView()
                    case .button: ReaderChatButtonSettings()
                    }
                }.toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Close") { panel = nil } }
                }
            }.environment(\.leafTheme, theme).tint(theme.accent)
        }
    }
}

struct LibraryChatConversationPicker: View {
    let books: [Book]
    let selected: String
    let onChoose: (Book?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.leafTheme) private var theme
    @State private var query = ""
    var body: some View {
        NavigationStack {
            List {
                Section {
                    choice("General chat", author: "Separate from your book conversations", book: nil)
                }.listRowBackground(theme.surface)
                Section("Book conversations") {
                    ForEach(books.filter { query.isEmpty || "\($0.title) \($0.author)".localizedCaseInsensitiveContains(query) }) { book in
                        choice(book.title, author: book.author, book: book)
                    }
                }.listRowBackground(theme.surface)
            }.leafFormStyle().searchable(text: $query, prompt: "Find a book")
                .navigationTitle("Conversation").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .toolbarBackground(theme.canvas, for: .navigationBar)
        }.environment(\.leafTheme, theme).tint(theme.accent)
    }
    private func choice(_ title: String, author: String, book: Book?) -> some View {
        Button { onChoose(book); dismiss() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(theme.foreground)
                    Text(author).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selected == (book?.fingerprint ?? "general") { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
            }.frame(minHeight: 44)
        }.accessibilityIdentifier(book.map { "chatBook-\($0.title)" } ?? "chatGeneral")
    }
}
