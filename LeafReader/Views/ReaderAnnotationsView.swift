import SwiftUI

struct AnnotationEditorView: View {
    @Environment(\.leafTheme) private var theme
    let annotation: BookAnnotation
    let isSaved: Bool
    let onSave: (BookAnnotation) throws -> Void
    var onDelete: (() throws -> Void)?
    let onClose: () -> Void
    @State private var note: String
    @State private var color: BookAnnotationColor
    @State private var error: String?

    init(annotation: BookAnnotation, isSaved: Bool, onSave: @escaping (BookAnnotation) throws -> Void,
         onDelete: (() throws -> Void)? = nil, onClose: @escaping () -> Void) {
        self.annotation = annotation; self.isSaved = isSaved
        self.onSave = onSave; self.onDelete = onDelete; self.onClose = onClose
        _note = State(initialValue: annotation.note); _color = State(initialValue: annotation.color)
    }
    var body: some View {
        Form {
            Section("Selected passage") {
                Text(annotation.text).font(.body).textSelection(.enabled)
                    .accessibilityIdentifier("annotationQuote")
                if !annotation.chapter.isEmpty { Text(annotation.chapter).font(.caption).foregroundStyle(.secondary) }
            }
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
                    .accessibilityLabel("Note").accessibilityIdentifier("annotationNote")
                if note.count > 20_000 { Text(BookAnnotationError.noteTooLong.localizedDescription).font(.caption).foregroundStyle(.red) }
            } header: { Text("Note") } footer: { Text("Your highlights and notes are saved on this device with the book.") }
            if let error { Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("annotationSaveError") } }
            if let onDelete {
                Section {
                    Button("Delete highlight and note", role: .destructive) {
                        do { try onDelete(); onClose() } catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("deleteAnnotation")
                }
            }
        }.leafFormStyle()
            .navigationTitle(isSaved ? "Edit highlight" : "Add note").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(theme.canvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose).accessibilityIdentifier("cancelAnnotation") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = annotation; updated.note = note; updated.color = color; updated.updatedAt = Date()
                        do { try onSave(updated); onClose() } catch { self.error = error.localizedDescription }
                    }.disabled(note.count > 20_000).accessibilityIdentifier("saveAnnotation")
                }
            }
            .interactiveDismissDisabled()
    }
}

struct AnnotationRow: View {
    let annotation: BookAnnotation
    let onNavigate: () -> Void
    let onEdit: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: onNavigate) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: annotation.hasNote ? "note.text" : "highlighter")
                        .foregroundStyle(annotation.color.color).frame(width: 24)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(annotation.text).lineLimit(3).foregroundStyle(.primary)
                        if annotation.hasNote { Text(annotation.note).lineLimit(2).font(.subheadline).foregroundStyle(.secondary) }
                        Text(annotation.chapter.isEmpty ? "\(Int(annotation.fraction * 100))% through the book" : annotation.chapter)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }.buttonStyle(.plain).accessibilityIdentifier("savedAnnotation-\(annotation.id)")
            Button(action: onEdit) { Image(systemName: "square.and.pencil").frame(width: 44, height: 44) }
                .buttonStyle(.borderless).accessibilityLabel("Edit highlight and note")
                .accessibilityIdentifier("editAnnotation-\(annotation.id)")
        }
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
