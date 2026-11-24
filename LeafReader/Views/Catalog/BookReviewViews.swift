import SwiftUI

/// Ratings & reviews on every Discover book page: each site's score, a few short reader
/// reviews, critics' reviews, and an Ask Leaf summary on request.
struct BookReviewsSection: View {
    let query: BookReviewQuery
    /// False while the page is still learning the book's ISBN, so the lookup is made once.
    var ready = true
    @EnvironmentObject private var reviews: BookReviewStore
    @EnvironmentObject private var settings: AISettingsStore
    @Environment(\.leafTheme) private var theme

    private static let padding: CGFloat = 18
    private var entry: BookReviews? { reviews.reviews(for: query) }
    private var ratings: [BookRating] { entry?.ratings ?? [query.listed].compactMap { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ratings & reviews").font(.headline).accessibilityAddTraits(.isHeader)
            if !ratings.isEmpty {
                BookRatingCards(ratings: ratings, edge: Self.padding)
            }
            status
            if let entry, !entry.readerReviews.isEmpty { readerReviews(entry) }
            if let entry, !entry.critics.isEmpty { critics(entry.critics) }
            summary
        }
        .padding(Self.padding).frame(maxWidth: .infinity, alignment: .leading).background(theme.surface, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .contain).accessibilityIdentifier("bookReviewsSection")
        .task(id: ready ? query.key : "") { if ready { await reviews.load(query) } }
    }

    @ViewBuilder private var status: some View {
        if reviews.isLoading(query) && (entry == nil || entry?.unavailable.isEmpty == false) {
            ProgressView("Looking for ratings and reviews…").font(.subheadline).accessibilityIdentifier("bookReviewsLoading")
        } else if let entry, !entry.unavailable.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(ListFormatter.localizedString(byJoining: entry.unavailable.map(\.title))) didn’t answer this time.")
                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("bookReviewsUnavailable")
                Button("Try again") { Task { await reviews.load(query, force: true) } }
                    .font(.footnote.weight(.semibold)).accessibilityIdentifier("retryBookReviews")
            }
        } else if let entry, onlyListed(entry) {
            Text(entry.isEmpty ? "No ratings or reviews were found for this book." : "No other site rates this book yet.")
                .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("bookReviewsEmpty")
        }
    }

    /// Nothing beyond the score the list or catalog already showed.
    private func onlyListed(_ entry: BookReviews) -> Bool {
        entry.readerReviews.isEmpty && entry.critics.isEmpty && entry.ratings.allSatisfy { $0.site == query.listed?.site }
    }

    private func readerReviews(_ entry: BookReviews) -> some View {
        let more = reviews.more[query.key]
        let all = entry.readerReviews + (more?.reviews ?? [])
        return VStack(alignment: .leading, spacing: 10) {
            Text("Reader reviews" + (entry.readerReviewsSite.map { " · \($0.title)" } ?? "")).font(.subheadline.weight(.semibold))
            ForEach(Array(all.enumerated()), id: \.offset) { index, review in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let stars = review.stars { BookStars(value: Double(stars)).font(.caption2) }
                        if let helpful = review.helpful, helpful > 0 {
                            Text("\(helpful.formatted()) found this useful").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text(review.text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel([review.stars.map { "\($0) of 5 stars" }, review.helpful.map { "\($0) found this useful" }, review.text].compactMap { $0 }.joined(separator: ", "))
                .accessibilityIdentifier("bookReaderReview-\(index)")
                if index < all.count - 1 { Divider() }
            }
            moreReaderReviews(entry, shown: all.count, more: more)
            if let url = entry.readerReviewsURL, let site = entry.readerReviewsSite {
                Link("All reviews on \(site.title)", destination: url).font(.caption.weight(.semibold)).accessibilityIdentifier("allReaderReviews")
            }
        }
    }

    /// Loads the next reviews here, or says why there are no more to load.
    @ViewBuilder private func moreReaderReviews(_ entry: BookReviews, shown: Int, more: MoreReaderReviews?) -> some View {
        let total = more?.total ?? entry.readerReviewsTotal
        if more?.loading == true {
            HStack(spacing: 8) { ProgressView(); Text("Loading more reviews…").font(.footnote).foregroundStyle(.secondary) }
                .accessibilityElement(children: .combine).accessibilityIdentifier("moreReaderReviewsLoading")
        } else if let error = more?.error {
            VStack(alignment: .leading, spacing: 4) {
                Text(error).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("moreReaderReviewsError")
                Button("Try again", action: loadMore).font(.footnote.weight(.semibold)).accessibilityIdentifier("retryMoreReaderReviews")
            }
        } else if reviews.hasMoreReaderReviews(query) {
            HStack(spacing: 10) {
                Button(action: loadMore) { Label("More reviews", systemImage: "text.bubble") }
                    .buttonStyle(.bordered).controlSize(.small).tint(theme.accent).accessibilityIdentifier("moreReaderReviews")
                if let total, total > shown {
                    Text("\(shown.formatted()) of \(total.formatted())").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityIdentifier("readerReviewsShown")
                }
            }
        } else if more != nil, let total, total > shown, let site = entry.readerReviewsSite {
            // 豆瓣 shows a visitor its first hundred.
            Text("\(site.title) shows its other \((total - shown).formatted()) reviews only to signed-in readers.")
                .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("readerReviewsLimit")
        }
    }
    private func loadMore() { Task { await reviews.loadMoreReaderReviews(query) } }

    private func critics(_ reviews: [CriticReview]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Critics").font(.subheadline.weight(.semibold))
            ForEach(Array(reviews.enumerated()), id: \.offset) { index, review in
                VStack(alignment: .leading, spacing: 3) {
                    Text([review.outlet, review.published].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption.weight(.semibold))
                    if !review.byline.isEmpty { Text(review.byline).font(.caption).foregroundStyle(.secondary) }
                    if !review.summary.isEmpty { Text(review.summary).font(.subheadline).lineLimit(3) }
                    Link("Read the review", destination: review.url).font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // One element that reads the outlet, date and summary, and opens the review.
                .accessibilityElement(children: .combine).accessibilityIdentifier("bookCriticReview-\(index)")
            }
        }
    }

    @ViewBuilder private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What readers say").font(.subheadline.weight(.semibold))
            if let activity = reviews.summarizing[query.key] {
                HStack(spacing: 8) { ProgressView(); Text(activity).font(.footnote).foregroundStyle(.secondary) }
                    .accessibilityElement(children: .combine).accessibilityIdentifier("bookReviewSummaryProgress")
            } else if let summary = reviews.summary(for: query) {
                Text(Self.markdown(summary.text)).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.accent.opacity(0.08), in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier("bookReviewSummary")
                HStack {
                    Text((summary.searchedWeb ? "Ask Leaf, from a web search · " : "Ask Leaf, from general knowledge · ")
                         + summary.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("bookReviewSummarySource")
                    Spacer()
                    Button("Summarize again") { summarize() }.font(.caption.weight(.semibold)).accessibilityIdentifier("refreshBookReviewSummary")
                }
            } else {
                Button(action: summarize) {
                    Label("Summarize reviews with Ask Leaf", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(theme.accent).accessibilityIdentifier("summarizeBookReviews")
                Text("Your AI searches the web for reviews of this book. Its title and author are sent; nothing from your library is.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = reviews.summaryErrors[query.key], reviews.summarizing[query.key] == nil {
                Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("bookReviewSummaryError")
            }
        }
    }
    private func summarize() { Task { await reviews.summarize(query, settings: settings) } }

    /// Bold labels and links from the model; its line breaks are kept.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Each site's score on a card. The cards are one height. They share the width while they
/// all fit; when they do not, they are swiped sideways and the next one shows at the edge.
private struct BookRatingCards: View {
    let ratings: [BookRating]
    /// The section's padding: the swiped row runs through it to the section's edge.
    let edge: CGFloat

    private static let spacing: CGFloat = 10
    private static let narrowest: CGFloat = 128
    /// How much of the next card shows inside the section's padding.
    private static let peek: CGFloat = 14

    /// Readers' scores first; the catalog's own score says the least about the book.
    private var ordered: [BookRating] { ratings.filter { $0.site != .zlibrary } + ratings.filter { $0.site == .zlibrary } }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Three fit across a phone held sideways.
            row { $0.frame(minWidth: Self.narrowest, idealWidth: Self.narrowest, maxWidth: .infinity) }
            ScrollView(.horizontal) {
                // Two whole cards and the start of the third, whatever the phone's width.
                row { $0.containerRelativeFrame(.horizontal) { width, _ in max(Self.narrowest, (width - 2 * edge - 2 * Self.spacing - Self.peek) / 2) } }
                    .padding(.horizontal, edge)
            }
            .scrollIndicators(.hidden)
            // A card at either edge fades out, so it reads as more to swipe to.
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.1), .black], startPoint: .leading, endPoint: .trailing).frame(width: edge)
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0.1)], startPoint: .leading, endPoint: .trailing).frame(width: edge)
                }
            }
            .padding(.horizontal, -edge)
            .accessibilityIdentifier("bookRatingsScroll")
        }
    }

    /// The cards side by side, each as tall as the tallest.
    private func row<Card: View>(@ViewBuilder _ sized: @escaping (BookRatingTile) -> Card) -> some View {
        HStack(alignment: .top, spacing: Self.spacing) { ForEach(ordered, id: \.site) { sized(BookRatingTile(rating: $0)) } }
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct BookRatingTile: View {
    let rating: BookRating
    @Environment(\.leafTheme) private var theme

    var body: some View {
        Group {
            if let url = rating.url { Link(destination: url) { tile }.buttonStyle(.plain) } else { tile }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([rating.site.title, rating.score + (rating.site.scoreScale.map { " out of \($0)" } ?? ""), rating.count]
                             + [rating.verdict].compactMap { $0 } + rating.notes).joined(separator: ", "))
        .accessibilityHint(Text(rating.url == nil ? "" : "Opens the book on \(rating.site.title)"))
        .accessibilityAddTraits(rating.url == nil ? [] : .isLink)
        .accessibilityIdentifier("bookRating-\(rating.site.rawValue)")
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The site's name sits under its score: beside it, 微信读书 broke in two next to 91.2%.
            VStack(alignment: .leading, spacing: 2) {
                // 7.4 beside 3.9 compares only when each says what it is out of.
                (Text(rating.score).font(.title2.weight(.bold)).monospacedDigit()
                 + Text(rating.site.scoreScale.map { "/\($0)" } ?? "").font(.caption.weight(.semibold)).foregroundColor(.secondary))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(rating.site.title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(rating.count).font(.caption2).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let stars = rating.stars { BookStars(value: stars).font(.caption) }
            if let verdict = rating.verdict {
                Text(verdict).font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(theme.accent.opacity(0.12), in: Capsule()).foregroundStyle(theme.accent)
            }
            if let shares = rating.distribution, shares.count == 5 {
                VStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { index in
                        HStack(spacing: 5) {
                            Text("\(5 - index)").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary).frame(width: 8)
                            GeometryReader { proxy in
                                Capsule().fill(Color.secondary.opacity(0.15))
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(theme.accent).frame(width: max(2, proxy.size.width * CGFloat(min(1, max(0, shares[index])))))
                                    }
                            }.frame(height: 5)
                        }
                    }
                }
            }
            ForEach(rating.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.canvas.opacity(0.6), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.2), lineWidth: 0.75))
    }
}

/// Five stars filled to a score out of five, in halves.
private struct BookStars: View {
    let value: Double
    var body: some View {
        let halves = Int((min(5, max(0, value)) * 2).rounded())
        HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: halves >= (index + 1) * 2 ? "star.fill" : halves == index * 2 + 1 ? "star.leadinghalf.filled" : "star")
            }
        }
        .foregroundStyle(Color(red: 0.85, green: 0.6, blue: 0.15)).accessibilityHidden(true)
    }
}
