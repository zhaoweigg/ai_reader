# Bestseller discovery

Discover keeps its existing Most popular and Recommended catalog feeds and adds Bestsellers. The new section has Indie / New York Times and Fiction / Nonfiction filters. The initial charts are **hardcover** lists, with all 15 ranks from each provider. Source selection and category persist locally. Library has a cover shelf that opens the same section or a book's details.

Indie metadata comes from the public IndieBound national bestseller page. NYT metadata defaults to Team Book Club’s public hardcover-fiction and hardcover-nonfiction pages, reading their schema.org Book lists without an account or API key. The UI names and links this relay separately from NYT attribution. Both charts must contain all 15 unique contiguous ranks, valid ISBNs, the expected category/page identity and a publication date no more than 28 days old or 14 days ahead (NYT dates its lists ahead). An unfamiliar, incomplete or stale page fails without replacing the saved list. Settings → Book discovery → NYT Books optionally stores a personal Books API key in Keychain to use the official NYT endpoints instead. The key goes only to api.nytimes.com, never to the public relay. A locked optional Keychain falls back to the public feed; removing a saved key returns to the public feed. Provider HTTP responses use an ephemeral session. Public rankings cache locally for six hours; a failed refresh keeps the dated saved list and shows the error. There is no bundled fallback ranking in release builds.

Artwork uses publisher ISBN cover URLs independently of the list provider. A failed/missing image has a title placeholder. NYT's `book_image` field is not used.

Bestseller lookup shares the existing Z-Library connection and transport. It uses ISBN, then title and author, without replacing the visible catalog search, selected feed, pagination, or account cache. At most two book lookups run concurrently. Account generation changes invalidate the matches. A single supported edition with an exact ISBN or title/author match offers Add. Multiple or uncertain candidates require inspection through the existing edition details. No matches offer an independent editable catalog search. The existing download, quota, cancellation, import, and library metadata flow handles every addition. A work already in the library is recognized across both list sources; no reader/book persistence schema changes are needed.

Ask Leaf reads the selected chart's source, category, date, ranks, and public descriptions, or the open work/edition. Keys and catalog session data never enter that context.

Library refreshes its Z-Library shelf when the account, connection, or website changes. Pull to refresh reloads both the account shelf and the selected bestseller list. Shelf failures keep saved books visible, show a retry action, and allow an immediate manual retry; automatic retries have a short cooldown. A successful matching Discover feed refresh also updates Library, and older in-flight shelf responses cannot replace it.

## 网文 (Chinese web novels)

Discover's fourth section shows 起点中文网 charts: 月票榜, 畅销榜, 阅读指数榜 and 推荐票榜 (周榜 / 月榜 / 总榜), for 全站 or one of the site's fourteen categories. The segment labels were shortened to Popular / For you / Bestsellers / 网文 so four fit on a narrow phone; the catalog headings keep the feeds' full names.

Each chart is one request to the public chart page of 起点's mobile site (`m.qidian.com/rank/<chart>/catid<id>/[<period>/]`), with no account and an ephemeral session. The desktop site answers with a browser check and is not used. The page carries its data as JSON for its own scripts (`vite-plugin-ssr_pageContext`); `QidianChartClient.parse` reads that and nothing executable. A page is accepted only when it names the chart, category and period that were asked for, is the first page, and has a gapless ranking of a full page (20) or, for a small category, of everything the site says the chart has. Book identifiers must be numeric because they form the cover and book addresses. Anything else fails without replacing the saved chart. 月票榜 carries the month it counts; the other charts show the day they were retrieved.

The last eight charts are cached for six hours each. The chosen chart, category and period persist on the device; they are not synced. Covers come from 起点's cover host by book identifier. There is no bundled fallback chart and no Library shelf for 网文.

Web novels have no ISBN, so catalog lookup is by title and author only (`WebNovelText`). Uploads are usually titled like `《书名》（精校版）作者：某某`; the comparison takes off 《》, bracketed notes, the author credit and edition words first. The same title with the same author is a sure match; an upload with no author, or a longer title that begins the same way (a sequel or a collection), is offered only for the reader to check. The chart does not say whether a book is finished, so rows cannot be marked 连载 or 完结.

Ask Leaf reads the chart on screen or the open book's page, and `get_web_novel_chart` reads any chart from any chat without changing the screen.

Not verified: whether Z-Library carries the charted titles (fixtures stand in for the catalog), the live page from a phone or from mainland China, and 起点's 女生 charts, which did not load at the addresses tried and are not offered.

## Verification scope

`BestsellerFeedTests`, `BestsellerStoreTests`, and `BestsellerMatchingTests` cover parsing, full rankings, provider failures, key privacy, cache retention, source changes, account changes, concurrent lookup limits, cancellation, ambiguity, and work ownership. `BestsellerUITests` covers the Library shelf, all filters, catalog search, matching/import transitions, account setup, retries/quota/cancellation, Ask Leaf, the three appearances, scene geometry, and imported-book Pages/Scroll smoke checks. DEBUG native fixtures use original TXT passages and local publisher cover samples; existing catalog EPUB regressions remain separate.

The live Indie page was parsed into both complete 15-book lists. The public NYT relay can be verified without a key; authenticated live official NYT verification still needs a configured Books API key and is not established by fixture tests. Native catalog/download checks use deterministic fixtures, not a live Z-Library account. Scene geometry tests verify layout requests; simulator landscape screenshot artifacts and physical phone rotation require separate review. No phone installation is implied by simulator verification.
