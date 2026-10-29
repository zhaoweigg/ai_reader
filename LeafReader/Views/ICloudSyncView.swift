import SwiftUI

/// Settings › iCloud: choose the iCloud Drive folder that carries the library
/// between devices, and manage which book files stay on this one.
struct ICloudSyncView: View {
    @EnvironmentObject private var sync: ICloudSync
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.leafTheme) private var theme
    @State private var choosing = false
    @State private var confirmingStop = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "icloud.fill").font(.title2).foregroundStyle(.white)
                        .frame(width: 46, height: 46).background(Color.blue.gradient, in: .rect(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline).accessibilityIdentifier("syncStatus")
                        Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if sync.status == .syncing { ProgressView() }
                }.padding(.vertical, 4)
            }
            if sync.isConnected {
                Section {
                    LabeledContent("Folder", value: sync.folderName ?? "Leaf")
                    if !sync.isInICloud {
                        Label("This folder is on this device, not in iCloud Drive. Choose a folder under iCloud Drive to reach your other devices.", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Toggle(isOn: $sync.keepBooks) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep books on this device")
                            Text("Off: a book downloads when you open it").font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("syncKeepBooks")
                    Button("Sync Now") { Task { await sync.syncNow() } }.accessibilityIdentifier("syncNow")
                }
                Section("Storage") {
                    LabeledContent("Books on this device", value: bytes(sync.localBookBytes))
                    LabeledContent("Books in iCloud Drive", value: bytes(sync.cloudBytes))
                    Button("Remove Downloaded Books") { sync.removeDownloads() }
                        .disabled(sync.localBookBytes == 0).accessibilityIdentifier("syncRemoveDownloads")
                }
                Section {
                    Button("Stop Syncing", role: .destructive) { confirmingStop = true }.accessibilityIdentifier("syncStop")
                } footer: {
                    Text("Your library stays on this device and in iCloud Drive. Other devices keep syncing.")
                }
            } else {
                Section {
                    Button { choosing = true } label: { Label("Choose iCloud Drive Folder…", systemImage: "folder.badge.plus") }
                        .accessibilityIdentifier("syncChooseFolder")
                } footer: {
                    Text("Create a folder named Leaf in iCloud Drive, then choose it here and on your other iPhone or iPad. Your library, progress, highlights, notes, Ask Leaf conversations and reading settings move through it.")
                }
            }
            Section("What syncs") {
                Label("Books, reading progress and bookmarks", systemImage: "books.vertical")
                Label("Highlights and notes", systemImage: "highlighter")
                Label("Ask Leaf conversations", systemImage: "bubble.left.and.bubble.right")
                Label("Reading, voice and AI settings", systemImage: "slider.horizontal.3")
            }
            Section {
                Label("API keys and sign-ins", systemImage: "key")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Keys stay on this device for now; sign in again on a new one. Voice packs, search caches and the floating button's position also stay on each device.")
            }
        }
        .leafFormStyle().navigationTitle("iCloud").navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { sync.choose(url) }
        }
        .confirmationDialog("Stop syncing this device?", isPresented: $confirmingStop, titleVisibility: .visible) {
            Button("Stop Syncing", role: .destructive) { sync.disconnect() }
        } message: {
            Text("Books that are only in iCloud Drive stay listed and download again if you reconnect.")
        }
    }

    private var title: String {
        switch sync.status {
        case .off: return "Not set up"
        case .syncing: return "Syncing…"
        case .upToDate: return "Up to date"
        case .failed: return "Couldn’t sync"
        }
    }
    private var subtitle: String {
        if case .failed(let message) = sync.status { return message }
        guard sync.isConnected else { return "Keep your library in iCloud Drive to move it to another device." }
        let books = library.books.count, notes = library.books.reduce(0) { $0 + $1.annotations.count }
        let when = sync.lastSynced.map { "Synced " + $0.formatted(.relative(presentation: .named)) } ?? "Not synced yet"
        return "\(when) · \(books) book\(books == 1 ? "" : "s") · \(notes) highlight\(notes == 1 ? "" : "s")"
    }
    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}
