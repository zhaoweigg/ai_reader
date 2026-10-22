import SwiftUI

struct BookmarksView: View {
    @Environment(\.leafTheme) private var theme
    @EnvironmentObject private var library: LibraryStore
    let onOpen: (UUID, String) -> Void
    private var books: [Book] { library.books.filter { !$0.bookmarks.isEmpty } }
    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    ContentUnavailableView("Keep a place worth returning to", systemImage: "bookmark", description: Text("Tap the bookmark while reading. Your saved places will appear here."))
                } else {
                    List {
                        ForEach(books) { book in
                            Section(book.title) {
                                ForEach(book.bookmarks.sorted { $0.createdAt > $1.createdAt }) { bookmark in
                                    Button { onOpen(book.id, bookmark.locator) } label: {
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
                            }.listRowBackground(theme.surface)
                        }
                    }.leafFormStyle()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.canvas)
                .toolbarBackground(theme.canvas, for: .navigationBar).navigationTitle("Bookmarks")
        }
    }
}
