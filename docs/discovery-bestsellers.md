# Bestseller discovery

Discover keeps its existing Most popular and Recommended catalog feeds and adds Bestsellers. The new section has Indie / New York Times and Fiction / Nonfiction filters. The initial charts are **hardcover** lists, with all 15 ranks from each provider. Source selection and category persist locally. Library has a cover shelf that opens the same section or a book's details.

Indie metadata comes from the public IndieBound national bestseller page. NYT metadata uses the official Books API's current hardcover-fiction and hardcover-nonfiction endpoints. NYT requires the reader's API key with Books API access; Settings → Book discovery → NYT Books stores it in Keychain. Provider HTTP responses use an ephemeral session. Public rankings cache locally for six hours; a failed refresh keeps the dated saved list and shows the error. There is no bundled fallback ranking in release builds.

Artwork uses publisher ISBN cover URLs independently of the list provider. A failed/missing image has a title placeholder. NYT's `book_image` field is not used.

Bestseller lookup shares the existing Z-Library connection and transport. It uses ISBN, then title and author, without replacing the visible catalog search, selected feed, pagination, or account cache. At most two book lookups run concurrently. Account generation changes invalidate the matches. A single supported edition with an exact ISBN or title/author match offers Add. Multiple or uncertain candidates require inspection through the existing edition details. No matches offer an independent editable catalog search. The existing download, quota, cancellation, import, and library metadata flow handles every addition. A work already in the library is recognized across both list sources; no reader/book persistence schema changes are needed.

Ask Leaf reads the selected chart's source, category, date, ranks, and public descriptions, or the open work/edition. Keys and catalog session data never enter that context.

Library refreshes its Z-Library shelf when the account, connection, or website changes. Pull to refresh reloads both the account shelf and the selected bestseller list. Shelf failures keep saved books visible, show a retry action, and allow an immediate manual retry; automatic retries have a short cooldown. A successful matching Discover feed refresh also updates Library, and older in-flight shelf responses cannot replace it.

## Verification scope

`BestsellerFeedTests`, `BestsellerStoreTests`, and `BestsellerMatchingTests` cover parsing, full rankings, provider failures, key privacy, cache retention, source changes, account changes, concurrent lookup limits, cancellation, ambiguity, and work ownership. `BestsellerUITests` covers the Library shelf, all filters, catalog search, matching/import transitions, account setup, retries/quota/cancellation, Ask Leaf, the three appearances, scene geometry, and imported-book Pages/Scroll smoke checks. DEBUG native fixtures use original TXT passages and local publisher cover samples; existing catalog EPUB regressions remain separate.

The live Indie page was parsed into both complete 15-book lists. Authenticated live NYT verification needs a configured Books API key and is not established by fixture tests. Native catalog/download checks use deterministic fixtures, not a live Z-Library account. Scene geometry tests verify layout requests; simulator landscape screenshot artifacts and physical phone rotation require separate review. No phone installation is implied by simulator verification.
