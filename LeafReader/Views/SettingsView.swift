import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                ReaderAppearanceControls()
                Section("Bring your library") {
                    formatRow("Books", "EPUB, MOBI, AZW, AZW3, PRC, FB2, FBZ")
                    formatRow("Documents", "PDF, TXT, Markdown, HTML, RTF")
                    formatRow("Comics", "CBZ")
                    Text("Choose DRM-free files up to 100 MB. KFX, ACSM, CBR, and DjVu need conversion before importing.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Made for unhurried reading") {
                    Label("Books stay on this device", systemImage: "internaldrive")
                    Label("No account or connection needed", systemImage: "wifi.slash")
                    NavigationLink("Open-source acknowledgments") { AcknowledgmentsView() }
                    HStack { Text("Leaf"); Spacer(); Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0").foregroundStyle(.secondary) }
                }
            }.navigationTitle("Settings")
        }
    }
    private func formatRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title); Text(detail).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 3)
    }
}

struct ReaderAppearanceControls: View {
    @AppStorage("reader.fontSize") private var fontSize = 19.0
    @AppStorage("reader.lineHeight") private var lineHeight = 1.65
    @AppStorage("reader.font") private var font = "Georgia"
    @AppStorage("reader.theme") private var theme = ReadingTheme.day.rawValue
    @AppStorage("reader.scrolling") private var scrolling = false
    @AppStorage("reader.horizontalMargin") private var horizontalMargin = 20.0
    @AppStorage("reader.verticalMargin") private var verticalMargin = 12.0
    @AppStorage("reader.paragraphSpacing") private var paragraphSpacing = 0.65
    var body: some View {
        Section("Page color") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ForEach(ReadingTheme.allCases) { item in
                        Button { theme = item.rawValue } label: {
                            VStack(spacing: 7) {
                                Text("Aa").font(.system(size: 23, design: .serif)).foregroundStyle(item.foreground)
                                    .frame(maxWidth: .infinity).frame(height: 55).background(item.background, in: .rect(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme == item.rawValue ? LeafStyle.accent : Color.secondary.opacity(0.25), lineWidth: theme == item.rawValue ? 2 : 1))
                                Text(item.title).font(.caption).foregroundStyle(.primary)
                            }
                        }.buttonStyle(.plain).accessibilityLabel("\(item.title) theme").accessibilityAddTraits(theme == item.rawValue ? .isSelected : [])
                    }
                }
            }.padding(.vertical, 7)
        }
        Section("Text") {
            Picker("Typeface", selection: $font) { Text("Georgia").tag("Georgia"); Text("Palatino").tag("Palatino"); Text("System").tag("System") }
            VStack(alignment: .leading) {
                HStack { Text("Text size"); Spacer(); Text("\(Int(fontSize)) pt").foregroundStyle(.secondary) }
                Slider(value: $fontSize, in: 12...32, step: 1) { Text("Text size") }.accessibilityIdentifier("fontSize")
            }
            VStack(alignment: .leading) {
                HStack { Text("Line spacing"); Spacer(); Text(lineHeight, format: .number.precision(.fractionLength(2))).foregroundStyle(.secondary) }
                Slider(value: $lineHeight, in: 1.1...2.2, step: 0.05) { Text("Line spacing") }.accessibilityIdentifier("lineSpacing")
            }
            VStack(alignment: .leading) {
                HStack { Text("Paragraph spacing"); Spacer(); Text(paragraphSpacing, format: .number.precision(.fractionLength(2))).foregroundStyle(.secondary) }
                Slider(value: $paragraphSpacing, in: 0...1.5, step: 0.05) { Text("Paragraph spacing") }.accessibilityIdentifier("paragraphSpacing")
            }
        }
        Section {
            Button("Fit more text") {
                fontSize = 17; lineHeight = 1.35; paragraphSpacing = 0.35
                horizontalMargin = 12; verticalMargin = 8
            }.accessibilityIdentifier("compactLayout")
            VStack(alignment: .leading) {
                HStack { Text("Side margins"); Spacer(); Text("\(Int(horizontalMargin)) pt").foregroundStyle(.secondary) }
                Slider(value: $horizontalMargin, in: 8...48, step: 2) { Text("Side margins") }.accessibilityIdentifier("horizontalMargin")
            }
            VStack(alignment: .leading) {
                HStack { Text("Top and bottom margins"); Spacer(); Text("\(Int(verticalMargin)) pt").foregroundStyle(.secondary) }
                Slider(value: $verticalMargin, in: 0...48, step: 2) { Text("Top and bottom margins") }.accessibilityIdentifier("verticalMargin")
            }
            Toggle("Scroll pages vertically", isOn: $scrolling)
        } header: { Text("Page layout") } footer: {
            Text("Changes are saved for all books. Text and margin settings apply to reflowable books; PDFs and comics keep their original layout.")
        }
    }
}

struct AcknowledgmentsView: View {
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
                }
            }
            Section { Text("The bundled sample books are original short works created for Leaf. They are included for demonstrating the reader.").font(.footnote) }
        }.navigationTitle("Acknowledgments").navigationBarTitleDisplayMode(.inline)
    }
}
