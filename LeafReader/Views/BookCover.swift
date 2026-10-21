import SwiftUI

struct BookCover: View {
    let book: Book
    var coverURL: URL?
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let colors = LeafStyle.palettes[book.paletteIndex]
            ZStack(alignment: .topLeading) {
                if let url = coverURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: width, height: geometry.size.height).clipped()
                } else {
                    colors.0
                    Circle().fill(colors.1.opacity(0.8)).frame(width: width * 0.96, height: width * 0.96)
                        .offset(x: width * 0.28, y: geometry.size.height * 0.48)
                    Circle().stroke(colors.1.opacity(0.35), lineWidth: 1).frame(width: width * 1.22, height: width * 1.22)
                        .offset(x: -width * 0.35, y: geometry.size.height * 0.53)
                    VStack(alignment: .leading, spacing: width * 0.08) {
                        Image(systemName: "leaf").font(.system(size: max(12, width * 0.12))).foregroundStyle(colors.1)
                        Text(book.title).font(.system(size: max(14, width * 0.155), weight: .medium, design: .serif))
                            .foregroundStyle(.white).lineLimit(4).minimumScaleFactor(0.65)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 4)
                        Text(book.author).font(.system(size: max(9, width * 0.065), weight: .medium))
                            .foregroundStyle(.white.opacity(0.9)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: max(0, width * 0.74), height: max(0, geometry.size.height - width * 0.26), alignment: .topLeading)
                    .padding(width * 0.13)
                    Rectangle().fill(.black.opacity(0.13)).frame(width: width * 0.045)
                    Rectangle().fill(.white.opacity(0.13)).frame(width: 1).offset(x: width * 0.06)
                }
            }
            .frame(width: width, height: geometry.size.height, alignment: .topLeading)
            .clipShape(.rect(cornerRadius: 4))
            .shadow(color: .black.opacity(0.13), radius: 6, x: 2, y: 5)
        }
        .aspectRatio(0.68, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
