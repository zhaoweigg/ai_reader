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

    private var entry: BookReviews? { reviews.reviews(for: query) }
    private var ratings: [BookRating] { entry?.ratings ?? [query.listed].compactMap { $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ratings & reviews").font(.headline).accessibilityAddTraits(.isHeader)
            if !ratings.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(ratings, id: \.site) { BookRatingTile(rating: $0) }
                }
            }
            status
            if let entry, !entry.readerReviews.isEmpty { readerReviews(entry) }
            if let entry, !entry.critics.isEmpty { critics(entry.critics) }
            summary
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(theme.surface, in: .rect(cornerRadius: 18))
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Reader reviews" + (entry.readerReviewsSite.map { " · \($0.title)" } ?? "")).font(.subheadline.weight(.semibold))
            ForEach(Array(entry.readerReviews.enumerated()), id: \.offset) { index, review in
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
                if index < entry.readerReviews.count - 1 { Divider() }
            }
            if let url = entry.readerReviewsURL, let site = entry.readerReviewsSite {
                Link("All reviews on \(site.title)", destination: url).font(.caption.weight(.semibold)).accessibilityIdentifier("allReaderReviews")
            }
        }
    }

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
                .accessibilityElement(children: .contain).accessibilityIdentifier("bookCriticReview-\(index)")
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

private struct BookRatingTile: View {
    let rating: BookRating
    @Environment(\.leafTheme) private var theme

    var body: some View {
        Group {
            if let url = rating.url { Link(destination: url) { tile }.buttonStyle(.plain) } else { tile }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([rating.site.title, rating.score, rating.count] + [rating.verdict].compactMap { $0 } + rating.notes).joined(separator: ", "))
        .accessibilityHint(Text(rating.url == nil ? "" : "Opens the book on \(rating.site.title)"))
        .accessibilityAddTraits(rating.url == nil ? [] : .isLink)
        .accessibilityIdentifier("bookRating-\(rating.site.rawValue)")
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(rating.score).font(.title2.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rating.site.title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(rating.count).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
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
        .padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
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
