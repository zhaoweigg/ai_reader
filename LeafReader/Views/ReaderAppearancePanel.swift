import SwiftUI

enum ReaderAppearanceTab: String, CaseIterable, Identifiable {
    case font = "Font", layout = "Layout", themes = "Themes"
    var id: String { rawValue }
}

struct ReaderAppearancePanel: View {
    @State private var tab: ReaderAppearanceTab = .font
    var body: some View {
        VStack(spacing: 0) {
            Picker("Reading options", selection: $tab) {
                ForEach(ReaderAppearanceTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("appearanceTabs")
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 4)
            Form { ReaderAppearanceControls(tab: tab) }
                .contentMargins(.top, 8, for: .scrollContent)
        }
        .background(LeafStyle.canvas).navigationTitle("Appearance")
    }
}

private enum ReadingPreset: String, CaseIterable, Identifiable {
    case compact = "Compact", standard = "Standard", large = "Large"
    var id: String { rawValue }
    // Font size, line height, paragraph spacing, side margin, vertical margin.
    var values: [Double] {
        switch self {
        case .compact: return [17, 1.35, 0.35, 12, 8]
        case .standard: return [19, 1.65, 0.65, 20, 12]
        case .large: return [24, 1.8, 0.8, 20, 16]
        }
    }
}

struct ReaderAppearanceControls: View {
    var tab: ReaderAppearanceTab? = nil
    @AppStorage("reader.fontSize") private var fontSize = 19.0
    @AppStorage("reader.lineHeight") private var lineHeight = 1.65
    @AppStorage("reader.font") private var font = "Georgia"
    @AppStorage("reader.theme") private var theme = ReadingTheme.day.rawValue
    @AppStorage("reader.scrolling") private var scrolling = false
    @AppStorage("reader.horizontalMargin") private var horizontalMargin = 20.0
    @AppStorage("reader.verticalMargin") private var verticalMargin = 12.0
    @AppStorage("reader.paragraphSpacing") private var paragraphSpacing = 0.65
    @State private var fineTuning = false

    private var density: [Double] { [fontSize, lineHeight, paragraphSpacing, horizontalMargin, verticalMargin] }
    private func matches(_ values: [Double]) -> Bool {
        zip(density, values).allSatisfy { abs($0 - $1) < 0.01 }
    }
    private func apply(_ preset: ReadingPreset) {
        let values = preset.values
        fontSize = values[0]; lineHeight = values[1]; paragraphSpacing = values[2]
        horizontalMargin = values[3]; verticalMargin = values[4]
    }

    var body: some View {
        if tab == nil || tab == .themes { themeControls }
        if tab == nil || tab == .font { fontControls }
        if tab == nil || tab == .layout { layoutControls }
    }

    @ViewBuilder private var themeControls: some View {
        Section("Page color") {
            HStack(spacing: 12) {
                ForEach(ReadingTheme.allCases) { item in
                    Button { theme = item.rawValue } label: {
                        VStack(spacing: 7) {
                            Text("Aa").font(.system(size: 23, design: .serif)).foregroundStyle(item.foreground)
                                .frame(maxWidth: .infinity).frame(height: 48).background(item.background, in: .rect(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme == item.rawValue ? LeafStyle.accent : Color.secondary.opacity(0.25), lineWidth: theme == item.rawValue ? 2 : 1))
                            Text(item.title).font(.caption).foregroundStyle(.primary)
                        }
                    }.buttonStyle(.plain).accessibilityLabel("\(item.title) theme").accessibilityAddTraits(theme == item.rawValue ? .isSelected : [])
                }
            }.padding(.vertical, 4)
        }
        Section {
            HStack(spacing: 8) {
                ForEach(ReadingPreset.allCases) { preset in
                    AppearanceChoice(title: preset.rawValue, selected: matches(preset.values), action: { apply(preset) }) {
                        Text("Aa").font(.system(size: preset.values[0], design: .serif))
                    }
                    .accessibilityLabel("\(preset.rawValue) reading preset")
                    .accessibilityIdentifier(preset == .compact ? "compactLayout" : "preset-\(preset.id)")
                }
            }
        } header: { Text("Reading presets") } footer: { Text("Compact fits more text on each page. Your page color and typeface stay the same.") }
    }

    @ViewBuilder private var fontControls: some View {
        Section {
            Picker("Typeface", selection: $font) {
                Text("Georgia").tag("Georgia"); Text("Palatino").tag("Palatino"); Text("System").tag("System")
            }
            VStack(spacing: 4) {
                HStack { Text("Text size"); Spacer(); Text("\(Int(fontSize)) pt").foregroundStyle(.secondary) }
                HStack(spacing: 8) {
                    Button { fontSize = max(12, fontSize - 1) } label: { Text("A").font(.system(size: 16)).frame(width: 44, height: 44) }
                        .disabled(fontSize <= 12).accessibilityLabel("Smaller text").accessibilityIdentifier("decreaseTextSize")
                    Slider(value: $fontSize, in: 12...32, step: 1) { Text("Text size") }
                        .accessibilityIdentifier("fontSize").accessibilityValue("\(Int(fontSize)) points")
                    Button { fontSize = min(32, fontSize + 1) } label: { Text("A").font(.system(size: 25)).frame(width: 44, height: 44) }
                        .disabled(fontSize >= 32).accessibilityLabel("Larger text").accessibilityIdentifier("increaseTextSize")
                }.buttonStyle(.borderless)
            }
        }
        Section("Line spacing") {
            HStack(spacing: 8) {
                spacingChoice("Tight", value: 1.35, gap: 3)
                spacingChoice("Standard", value: 1.65, gap: 5)
                spacingChoice("Loose", value: 1.95, gap: 7)
            }
            if tab == nil { textFineTuning }
            else { DisclosureGroup("Fine tuning", isExpanded: $fineTuning) { textFineTuning } }
        }
    }

    private func spacingChoice(_ title: String, value: Double, gap: CGFloat) -> some View {
        AppearanceChoice(title: title, selected: abs(lineHeight - value) < 0.01, action: { lineHeight = value }) {
            PageLines(inset: 6, spacing: gap)
        }.accessibilityLabel("\(title) line spacing").accessibilityIdentifier("spacing-\(title)")
    }

    @ViewBuilder private var textFineTuning: some View {
        VStack(alignment: .leading) {
            HStack { Text("Line spacing"); Spacer(); Text(lineHeight, format: .number.precision(.fractionLength(2))).foregroundStyle(.secondary) }
            Slider(value: $lineHeight, in: 1.1...2.2, step: 0.05) { Text("Line spacing") }.accessibilityIdentifier("lineSpacing")
        }
        VStack(alignment: .leading) {
            HStack { Text("Paragraph spacing"); Spacer(); Text(paragraphSpacing, format: .number.precision(.fractionLength(2))).foregroundStyle(.secondary) }
            Slider(value: $paragraphSpacing, in: 0...1.5, step: 0.05) { Text("Paragraph spacing") }.accessibilityIdentifier("paragraphSpacing")
        }
    }

    @ViewBuilder private var layoutControls: some View {
        Section("Margins") {
            HStack(spacing: 8) {
                marginChoice("Narrow", horizontal: 12, vertical: 8, inset: 3)
                marginChoice("Standard", horizontal: 20, vertical: 12, inset: 9)
                marginChoice("Wide", horizontal: 36, vertical: 24, inset: 15)
            }
            if tab == nil { marginFineTuning }
            else { DisclosureGroup("Fine tuning", isExpanded: $fineTuning) { marginFineTuning } }
        }
        Section {
            Picker("Reading flow", selection: $scrolling) {
                Text("Pages").tag(false); Text("Scroll").tag(true)
            }.pickerStyle(.segmented).accessibilityIdentifier("readingFlow")
        } header: { Text("Reading flow") } footer: {
            Text("Changes apply as you read and are saved for all books. PDFs and comics keep their original layout.")
        }
    }

    private func marginChoice(_ title: String, horizontal: Double, vertical: Double, inset: CGFloat) -> some View {
        AppearanceChoice(title: title, selected: abs(horizontalMargin - horizontal) < 0.01 && abs(verticalMargin - vertical) < 0.01,
                         action: { horizontalMargin = horizontal; verticalMargin = vertical }) {
            PageLines(inset: inset, spacing: 4)
        }.accessibilityLabel("\(title) margins").accessibilityIdentifier("margins-\(title)")
    }

    @ViewBuilder private var marginFineTuning: some View {
        VStack(alignment: .leading) {
            HStack { Text("Side margins"); Spacer(); Text("\(Int(horizontalMargin)) pt").foregroundStyle(.secondary) }
            Slider(value: $horizontalMargin, in: 8...48, step: 2) { Text("Side margins") }.accessibilityIdentifier("horizontalMargin")
        }
        VStack(alignment: .leading) {
            HStack { Text("Top and bottom margins"); Spacer(); Text("\(Int(verticalMargin)) pt").foregroundStyle(.secondary) }
            Slider(value: $verticalMargin, in: 0...48, step: 2) { Text("Top and bottom margins") }.accessibilityIdentifier("verticalMargin")
        }
    }
}

private struct AppearanceChoice<Illustration: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let illustration: () -> Illustration
    private var accent: Color { colorScheme == .dark ? Color(hex: "#93CABB") : LeafStyle.accent }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                illustration().frame(width: 54, height: 30).accessibilityHidden(true)
                Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .foregroundStyle(selected ? accent : Color.primary)
            .background(selected ? accent.opacity(0.08) : .clear, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? accent : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PageLines: View {
    let inset: CGFloat
    let spacing: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(0..<4) { index in
                Capsule().frame(height: 2).padding(.trailing, index == 3 ? 8 : 0)
            }
        }.padding(.horizontal, inset).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
