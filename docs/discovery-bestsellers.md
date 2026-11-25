# Bestseller discovery

Discover keeps its existing Most popular and Recommended catalog feeds and adds Bestsellers. The new section has Indie / New York Times and Fiction / Nonfiction filters. The initial charts are **hardcover** lists, with all 15 ranks from each provider. Source selection and category persist locally. Library has a cover shelf that opens the same section or a book's details.

Indie metadata comes from the public IndieBound national bestseller page. NYT metadata defaults to Team Book Club’s public hardcover-fiction and hardcover-nonfiction pages, reading their schema.org Book lists without an account or API key. The UI names and links this relay separately from NYT attribution. Both charts must contain all 15 unique contiguous ranks, valid ISBNs, the expected category/page identity and a publication date no more than 28 days old or 14 days ahead (NYT dates its lists ahead). An unfamiliar, incomplete or stale page fails without replacing the saved list. Settings → Book discovery → NYT Books optionally stores a personal Books API key in Keychain to use the official NYT endpoints instead. The key goes only to api.nytimes.com, never to the public relay. A locked optional Keychain falls back to the public feed; removing a saved key returns to the public feed. Provider HTTP responses use an ephemeral session. Public rankings cache locally for six hours; a failed refresh keeps the dated saved list and shows the error. There is no bundled fallback ranking in release builds.

Artwork uses publisher ISBN cover URLs independently of the list provider. A failed/missing image has a title placeholder. NYT's `book_image` field is not used.

Bestseller lookup shares the existing Z-Library connection and transport. It uses ISBN, then title and author, without replacing the visible catalog search, selected feed, pagination, or account cache. At most two book lookups run concurrently. Account generation changes invalidate the matches. A single supported edition with an exact ISBN or title/author match offers Add. Multiple or uncertain candidates require inspection through the existing edition details. No matches offer an independent editable catalog search. The existing download, quota, cancellation, import, and library metadata flow handles every addition. A work already in the library is recognized across both list sources; no reader/book persistence schema changes are needed.

Ask Leaf reads the selected chart's source, category, date, ranks, and public descriptions, or the open work/edition. Keys and catalog session data never enter that context.

Library refreshes its Z-Library shelf when the account, connection, or website changes. Pull to refresh reloads both the account shelf and the selected bestseller list. Shelf failures keep saved books visible, show a retry action, and allow an immediate manual retry; automatic retries have a short cooldown. A successful matching Discover feed refresh also updates Library, and older in-flight shelf responses cannot replace it.

## 中文 (Chinese charts)

Since 1.47 起点 and 微信读书 are separate Discover chips (see Discover lists). Each shows one chart at a time; the catalog headings keep the feeds' full names. The chosen site, the chart last chosen on each site, and 起点's category and period persist on the device; they are not synced. The type names (`WebNovel…`) date from 1.41, when the section held only 起点's web novels.

### 起点中文网

月票榜, 畅销榜, 阅读指数榜 and 推荐票榜 (周榜 / 月榜 / 总榜), for 全站 or one of the site's fourteen categories; the top 20 of each.

Each chart is one request to the public chart page of 起点's mobile site (`m.qidian.com/rank/<chart>/catid<id>/[<period>/]`), with no account and an ephemeral session. The desktop site answers with a browser check and is not used. The page carries its data as JSON for its own scripts (`vite-plugin-ssr_pageContext`); `QidianChart.parse` reads that and nothing executable. A page is accepted only when it names the chart, category and period that were asked for, is the first page, and has a gapless ranking of a full page (20) or, for a small category, of everything the site says the chart has. Book identifiers must be numeric because they form the cover and book addresses. 月票榜 carries the month it counts; the other charts show the day they were retrieved. The chart does not say whether a book is finished, so rows cannot be marked 连载 or 完结. 起点's 女生 charts did not load at the addresses tried and are not offered.

### 微信读书

总榜 (TOP 200), 飙升榜, 新书榜 and 神作榜, for the whole site. The first 20 books load with the chart; **Load more** adds 20 at a time up to 100.

The data is what the site's own web pages load: `weread.qq.com/web/bookListInCategory/<chart>?maxIndex=<offset>&rank=1`, JSON, no account, an ephemeral session. This is not a published API and can change. `WeReadChart.parse` accepts a response only as the next page of the ranking: every book's place must continue from the offset asked for, a response that says there is more must be a full 20, and identifiers must be plain. Each book carries its recommendation rate (shown as a percentage), the number reading it today, a category, a synopsis, a cover and a page on the site; cover and page addresses are used only when they are https on the site's own hosts. A book that reappears on a later page because the chart moved is not listed twice. Only the first page of a chart is kept between launches.

### Shared behaviour

Any response that fails those checks leaves the saved chart in place and shows a readable error. The last eight charts are cached for six hours each. There is no bundled fallback chart and no Library shelf for this section.

Neither site gives an ISBN, so catalog lookup is by title and author only (`WebNovelText`). Uploads are usually titled like `《书名》（精校版）作者：某某`, and the charts add notes of their own such as `（全三册）`, `全集` or `[英]` before a translated author; the comparison takes those off first. The same title with the same author is a sure match. An upload with no author or only the author's surname, a longer title that begins the same way (a sequel or a collection), or one that differs only in its subtitle is offered for the reader to check.

Ask Leaf reads the chart on screen or the open book's page, and `get_web_novel_chart` reads any chart of either site from any chat without changing the screen.

Not verified: whether Z-Library carries the charted titles (fixtures stand in for the catalog), and the live sites from inside the app, from a phone, or from mainland China. Outside the app, the parser's rules were checked against every live 起点 chart page and the first pages of the four 微信读书 charts.

## Discover lists (1.47)

The four-segment picker became a row of chips, one per list, so lists can be added without crowding it. `DiscoverList` names every list; `DiscoverListsStore` keeps their order and which are shown in one synced setting, `discover.lists`: shown lists by name, then hidden ones prefixed with `-`, so a list added in a later version can be told apart from one the reader hid (a new list starts hidden unless it is one of the initial eight). Unknown names are dropped and at least one list always stays on. Another device's arrangement applies as soon as it is written to the defaults. The last chip (`discover.list`) stays on the device. Hiding the list on screen while the sheet is open moves Discover to the first list still shown. A list opened from elsewhere while hidden (Library's bestseller shelf) shows its chip at the end until another is chosen.

Each existing list keeps its own controls inside its chip: NYT and Indie each have Fiction / Nonfiction, 起点 has its charts, category and period, and 微信读书 its four charts. The site and source switches that used to sit inside those sections are gone.

The new lists share `BookListStore` (6-hour cache of the first 50 books of the last ten lists, Load more for long lists) and one row and book-page design. Every request is public, with an ephemeral session and no account:

| List | Read from | Notes |
| --- | --- | --- |
| 豆瓣读书 Top 250 | `book.douban.com/top250?start=N`, 25 a page to 250 | title, author, publisher and date, score and number of ratings, the list's one-line description; translator and price stay on 豆瓣 |
| 新书速递 | `book.douban.com/latest?subcat=全部&p=N`, about 20 a page to 100 | follows the page's own paginator |
| Project Gutenberg | Gutendex `gutendex.com/books/?sort=popular&page=N`, 32 a page to 160 | only books with an EPUB; "Austen, Jane" read as Jane Austen; Add downloads `gutenberg.org`'s EPUB (accepted only if it is a zip file) and records `gutenberg:<id>` as its catalog source |
| Apple Books | `rss.marketingtools.apple.com/api/v2/<store>/books/top-paid\|top-free/50/books.json` | the response must name the store asked for; Taiwan and Hong Kong publish an empty Top paid chart, which Leaf says |
| Prize winners | `PrizeWinners.swift` in the app | the year each prize was given; checked against the prizes' own lists on 2026-11-24. Wikidata's query service was rate limited and its winners data had gaps and wrong years, so it is used only to cross-check (`scripts/fetch_prize_winners.py`) |
| Open Library | `openlibrary.org/trending/<daily\|weekly\|monthly>.json?limit=50` | covers by cover ID, one ISBN when the work lists one |

Rows match Z-Library editions like the other lists: 豆瓣 books, 茅盾文学奖 winners and any Chinese title by `WebNovelText`, the rest by `BestsellerMatching` (ISBN first when Open Library gives one). Gutenberg rows skip Z-Library and offer **Add** for the free EPUB. Ask Leaf reads the list on screen (`ChatScreen.bookList`) and the open book; the app-wide chart tools do not cover these lists yet.

Not verified: the lists from inside the app or on a phone, and a real Gutenberg download (gutenberg.org answered 503 "down for maintenance" on 2026-11-24). Outside the app on 2026-11-24 the parsers read the live 豆瓣 Top 250 (first and last pages), 新书速递 (pages 1–2), Gutendex (pages 1–2), Apple Books (US, Japan; Taiwan's empty Top paid) and Open Library (today, this month). UI tests use `UITestBookListClient`.

## Ratings & reviews

`BookReviewsSection` sits on `ZLibraryBookView`, `BestsellerBookView` and `WebNovelBookView`. `BookReviewStore` keys each book by its first ISBN (ISBN-10 and ISBN-13 are the same key) or, without one, by title and author as `WebNovelText` compares them, so a book opened from two lists shares one entry. A lookup runs when a page opens and is kept for seven days; if a site did not answer, the page says so with **Try again**, the site is asked again after an hour, and what it said last time is kept meanwhile. The catalog page waits for the edition's details so the lookup has its ISBNs. The last 60 books and their summaries are kept in UserDefaults.

`BookRatingCards` lays the scores out: `ViewThatFits` takes one row in which the cards share the width (128 pt each at least, so three fit across a phone held sideways) and, when that does not fit, a sideways scroll whose cards are sized from the scroll's width so that two show whole and the third starts 14 pt inside the section's padding. In both, every card is as tall as the tallest. Z-Library's own score is moved to the end, and `BookReviewSite.scoreScale` supplies the "/10" and "/5" beside 豆瓣's and Open Library's scores.

`BookReviewClient` asks the sites at once with an honest User-Agent and an ephemeral session, and each site's failure stays its own:

- **Open Library**: `openlibrary.org/search.json` by `isbn`, or `title` + `author`, with the rating fields; a title search must match the title and an author. Official, no key.
- **豆瓣读书**: no API. `book.douban.com/isbn/<isbn>/` redirects to the book's page; for a Chinese book without an ISBN, `book.douban.com/j/subject_suggest` lists candidates and one with the same title (or a numbered volume of it) and author is chosen. One page fetch then gives the score, the star shares and the page's short reviews, of which the three most useful are shown without readers' names. A redirect to its `sec.` check host, or a 403/418, is reported as not answering; Leaf does not retry inside the same lookup. 豆瓣 discourages automated reading, so it is asked only for a book page the reader opened.
- **豆瓣 more reviews**: **More reviews** (`BookReviewStore.loadMoreReaderReviews`) reads `m.douban.com/rexxar/api/v2/book/<id>/interests?count=20&start=N&order_by=hot`, the feed 豆瓣's mobile site uses, with that page as `Referer` (without it the feed answers 400). Reviews already on the page are skipped, a page with nothing new asks for the next one once, and readers' names are not kept. A visitor gets the first 100 short reviews of the edition; later pages come back empty, and "newest first" answers 403 `need_permission`, so only the most useful order is offered. The book page's "全部 N 条" gives the count shown beside the button. The extra reviews live in memory only. 豆瓣 splits reviews by edition: an English edition may have a few while its Chinese translation has thousands; only the edition found by ISBN or title is read.
- **微信读书**: chart rows keep `newRating`, `newRatingCount` and `newRatingDetail.title`; other Chinese books use `weread.qq.com/web/search/global` and need the same title and author. Its written reviews need a 微信读书 login and are not read.
- **NYT**: `api.nytimes.com/svc/books/v3/reviews.json?isbn=` with the key saved for the NYT lists; only `nytimes.com` links are kept.
- **起点** pages carry no score or reviews, only a few 书友圈 posts, so 起点 books rely on 豆瓣 and 微信读书.
- Goodreads (no API) and Google Books (keyless requests are rate limited) are not used.

**Summarize reviews with Ask Leaf** (`BookReviewSummarizer`) sends one request through the reader's AI settings with web search as the only tool (`search_conversation` is turned off), in Chinese for a Chinese book. The request carries the title, author, ISBN and the scores on the page as untrusted data. The answer is four lines with its sources; a model that could not search says so, and the page labels the summary "from general knowledge". Providers without the agent interface answer without searching.

Not verified: the live sites from inside the app or from a phone. UI tests use `UITestBookReviewClient` and the mock AI. Outside the app on 2026-11-23, Open Library, 豆瓣 (by ISBN, by title, the book page and its short reviews) and 微信读书 search answered without an account; the NYT reviews endpoint needs a key and was not called. On 2026-11-24 the 豆瓣 feed answered pages 1–5 for 三体 (125,237 short reviews) without an account, returned nothing from `start=100`, and refused requests without the mobile `Referer`.

## Verification scope

`BestsellerFeedTests`, `BestsellerStoreTests`, and `BestsellerMatchingTests` cover parsing, full rankings, provider failures, key privacy, cache retention, source changes, account changes, concurrent lookup limits, cancellation, ambiguity, and work ownership. `BestsellerUITests` covers the Library shelf, all filters, catalog search, matching/import transitions, account setup, retries/quota/cancellation, Ask Leaf, the three appearances, scene geometry, and imported-book Pages/Scroll smoke checks. DEBUG native fixtures use original TXT passages and local publisher cover samples; existing catalog EPUB regressions remain separate.

The live Indie page was parsed into both complete 15-book lists. The public NYT relay can be verified without a key; authenticated live official NYT verification still needs a configured Books API key and is not established by fixture tests. Native catalog/download checks use deterministic fixtures, not a live Z-Library account. Scene geometry tests verify layout requests; simulator landscape screenshot artifacts and physical phone rotation require separate review. No phone installation is implied by simulator verification.
