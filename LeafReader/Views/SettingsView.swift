import SwiftUI

struct SettingsView: View {
    @Environment(\.leafTheme) private var theme
    @EnvironmentObject private var sync: ICloudSync
    var body: some View {
        NavigationStack {
            Form {
                ReaderAppearanceControls()
                Group {
                    Section("Sync") {
                        NavigationLink { ICloudSyncView() } label: {
                            LabeledContent { Text(sync.isConnected ? "On" : "Off") } label: { Label("iCloud", systemImage: "icloud") }
                        }.accessibilityIdentifier("openICloudSync")
                    }
                    Section("Reading companion") {
                        NavigationLink("Floating button") { ReaderChatButtonSettings() }.accessibilityIdentifier("openChatButtonSettings")
                        NavigationLink("AI settings") { AISettingsView() }.accessibilityIdentifier("openAISettings")
                    }
                    Section("Bring your library") {
                        formatRow("Books", "EPUB, MOBI, AZW, AZW3, PRC, FB2, FBZ")
                        formatRow("Documents", "PDF, TXT, Markdown, HTML, RTF")
                        formatRow("Comics", "CBZ")
                        Text("Choose DRM-free files up to 100 MB. KFX, ACSM, CBR, and DjVu need conversion before importing.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Made for unhurried reading") {
                        Label(sync.isConnected ? "Books sync through your iCloud Drive" : "Books stay on this device", systemImage: sync.isConnected ? "icloud" : "internaldrive")
                        Label("Offline reading; optional AI chat", systemImage: "wifi.slash")
                        NavigationLink("Open-source acknowledgments") { AcknowledgmentsView() }
                        HStack { Text("Leaf"); Spacer(); Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0").foregroundStyle(.secondary) }
                    }
                }.listRowBackground(theme.surface)
            }.leafFormStyle().navigationTitle("Settings").toolbarBackground(theme.canvas, for: .navigationBar)
        }
    }
    private func formatRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title); Text(detail).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 3)
    }
}

struct AcknowledgmentsView: View {
    @Environment(\.leafTheme) private var theme
    private let licenses = [
        ("foliate-js", "foliate/LICENSE", "https://github.com/johnfactotum/foliate-js"),
        ("zip.js", "foliate/vendor/zip-lib/LICENSE", "https://github.com/gildas-lormeau/zip.js"),
        ("fflate", "foliate/vendor/fflate-lib/LICENSE", "https://github.com/101arrowz/fflate")
    ]
    var body: some View {
        List {
            ForEach(licenses, id: \.0) { name, path, source in
                Section(name) {
                    Link("Project website", destination: URL(string: source)!)
                    if let root = Bundle.main.url(forResource: "Reader", withExtension: nil), let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) {
                        Text(text).font(.caption).textSelection(.enabled)
                    }
                }.listRowBackground(theme.surface)
            }
            Section { Text("The bundled sample books are original short works created for Leaf. They are included for demonstrating the reader.").font(.footnote) }.listRowBackground(theme.surface)
        }.leafFormStyle().navigationTitle("Acknowledgments").navigationBarTitleDisplayMode(.inline)
    }
}
