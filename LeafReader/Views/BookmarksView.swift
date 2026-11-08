import SwiftUI

struct BookmarksView: View {
    @Environment(\.leafTheme) private var theme
    @EnvironmentObject private var library: LibraryStore
    let onOpen: (UUID, String) -> Void
    @State private var highlights = false
    @State private var editing: SavedAnnotationReference?
    @State private var error: String?
    @StateObject private var chat = TabChat()
    private struct SavedAnnotationReference: Identifiable {
        let bookID: UUID
        let annotation: BookAnnotation
        var id: UUID { annotation.id }
    }
    private var books: [Book] { library.books.filter { highlights ? !$0.annotations.isEmpty : !$0.bookmarks.isEmpty } }
    var body: some View {
        NavigationStack {
            VStack {
                Picker("Saved passages", selection: $highlights) {
                    Text("Bookmarks").tag(false)
                    Text("Highlights & notes").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal).accessibilityIdentifier("librarySavedPassageFilter")
                if books.isEmpty {
                    ContentUnavailableView(highlights ? "Highlights and notes" : "Keep a place worth returning to", systemImage: highlights ? "highlighter" : "bookmark", description: Text(highlights ? "Select a passage while reading, then choose Highlight or Add Note." : "Tap the bookmark while reading. Your saved places will appear here."))
                } else {
                    List {
                        ForEach(books) { book in
                            Section(book.title) {
                                if highlights {
                                    ForEach(book.annotations.sorted { $0.createdAt > $1.createdAt }) { annotation in
                                        AnnotationRow(annotation: annotation, onNavigate: { open(book.id, annotation.locator) },
                                            onEdit: { editing = SavedAnnotationReference(bookID: book.id, annotation: annotation) })
                                            .swipeActions {
                                                Button("Delete", role: .destructive) {
                                                    do { try library.removeAnnotation(annotation.id, bookID: book.id) } catch { self.error = error.localizedDescription }
                                                }
                                            }
                                    }
                                } else {
                                ForEach(book.bookmarks.sorted { $0.createdAt > $1.createdAt }) { bookmark in
                                    Button { open(book.id, bookmark.locator) } label: {
                                        HStack(spacing: 14) {
                                            Image(systemName: "bookmark.fill").foregroundStyle(theme.accent)
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(bookmark.label).foregroundStyle(.primary)
                                                Text("\(Int(bookmark.fraction * 100))% through the book").font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                        }.padding(.vertical, 5)
                                    }.swipeActions { Button("Delete", role: .destructive) { library.removeBookmark(book.id, bookmarkID: bookmark.id) } }
                                }
                                }
                            }.listRowBackground(theme.surface)
                        }
                    }.leafFormStyle()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.canvas)
                .toolbarBackground(theme.canvas, for: .navigationBar).navigationTitle("Bookmarks")
                .sheet(item: $editing) { reference in
                    NavigationStack {
                        AnnotationEditorView(annotation: reference.annotation, isSaved: true, voiceFirst: reference.annotation.voiceNote != nil,
                            onSave: { try await library.saveAnnotation($0, bookID: reference.bookID, voiceDraft: $1) },
                            onDelete: { try library.removeAnnotation(reference.id, bookID: reference.bookID) },
                            onClose: { editing = nil })
                    }.environment(\.leafTheme, theme).tint(theme.accent)
                }
                .alert("Could not update saved passage", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK") { error = nil }
                } message: { Text(error ?? "") }
        }
        .modifier(TabChatHost(chat: chat, finishMovingIdentifier: "finishMovingBookmarksChatButton",
                              screen: { ChatScreen.bookmarks(library, highlights: { highlights }) }))
    }
    /// A book's chat opens in the reader, so this tab's session closes first.
    private func open(_ id: UUID, _ locator: String) { chat.close(); onOpen(id, locator) }
}
