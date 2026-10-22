import SwiftUI

/// One selector is shared by Settings and the reader so there is only one saved theme.
struct ThemePicker: View {
    @AppStorage("reader.theme") private var selection = ReadingTheme.day.rawValue
    @AppStorage("reader.font") private var typeface = "Georgia"
    @Environment(\.leafTheme) private var appTheme
    @Environment(\.dynamicTypeSize) private var dynamicType

    private var selected: ReadingTheme { ReadingTheme(rawValue: selection) ?? .day }
    private var previewFont: Font {
        typeface == "System" ? .system(size: 11) : .custom(typeface, size: 11)
    }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicType.isAccessibilitySize ? 2 : 3)
    }

    var body: some View {
        Section {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(ReadingTheme.allCases) { theme in
                    Button { selection = theme.rawValue } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Aa").font(typeface == "System" ? .system(size: 24) : .custom(typeface, size: 24))
                                Text("A little room\nto read.").font(previewFont).lineSpacing(1).lineLimit(2)
                            }
                            .foregroundStyle(theme.foreground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(theme.background, in: .rect(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(selected == theme ? appTheme.accent : appTheme.foreground.opacity(0.18),
                                        lineWidth: selected == theme ? 2.5 : 1))
                            HStack(spacing: 4) {
                                Text(theme.title).font(.subheadline.weight(selected == theme ? .semibold : .regular))
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                Spacer(minLength: 0)
                                Image(systemName: "checkmark.circle.fill").font(.caption)
                                    .foregroundStyle(appTheme.accent).opacity(selected == theme ? 1 : 0)
                            }
                        }
                        .foregroundStyle(appTheme.foreground)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(theme.title) theme")
                    .accessibilityValue(theme.detail)
                    .accessibilityAddTraits(selected == theme ? .isSelected : [])
                    .accessibilityIdentifier("theme-\(theme.rawValue)")
                }
            }.padding(.vertical, 6)
        } header: {
            Text("App theme")
        } footer: {
            Text("\(selected.detail) Applies to your library, menus, and reading pages. Original PDF and comic pages keep their colors.")
                .accessibilityIdentifier("themeDescription")
        }
        .listRowBackground(appTheme.surface)
    }
}
