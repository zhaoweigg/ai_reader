# Leaf for iOS

A native ebook reader for iPhone and iPad: offline reading of EPUB, PDF and nine other formats, read-aloud with Apple voices, highlights and voice notes, a book catalog, bestseller charts and Chinese book and web-novel charts, iCloud Drive sync, and an optional AI reading companion ("Ask Leaf") that works with your own API key or ChatGPT subscription. Built with SwiftUI, WebKit and PDFKit. Requires iOS 17 or later and Xcode 16 or later.

```mermaid
mindmap
  root((Leaf))
    Read
      EPUB · PDF · MOBI · FB2 · CBZ · TXT · MD · HTML · RTF
      Pages or Scroll
      7 themes · 7 typefaces · 12–32 pt
      Contents · search · bookmarks · return pill
    Listen
      Apple voices, sentence highlight
      Lock Screen player
      Resume saved position
    Annotate
      Highlights in 4 colors
      Written notes
      Voice notes
    Ask Leaf
      Anthropic · Chat Completions · ChatGPT subscription
      Passage, page or whole-book tools
      Also on Discover, Bookmarks and Library
      Dictation · pictures · Markdown
    Discover
      Z-Library catalog
      Indie and NYT bestsellers
      起点 and 微信读书 charts
    Sync
      iCloud Drive folder
      Library, places, notes, chats, settings
```

## Run

Open `LeafReader.xcodeproj`, select the **LeafReader** scheme and an iPhone or iPad simulator, and press Run. There are no package-manager dependencies. Device signing is set up for the owner's Personal Team and bundle identifier `com.weizhao.leafreader`; with another account, choose your own team and a unique identifier under Signing & Capabilities.

`project.yml` is the source of truth for targets, version and Info.plist keys. After changing it, or after moving source files, regenerate the project with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
```

```bash
xcodebuild -project LeafReader.xcodeproj -scheme LeafReader -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -derivedDataPath build test CODE_SIGNING_ALLOWED=NO
```

## How Leaf is put together

Four tabs sit on a handful of observable stores. Views never talk to the network or the file system directly: a store or session owns each concern, and the reader itself is a WebKit or PDFKit surface driven by a view model.

```mermaid
flowchart TB
    subgraph UI["Views (SwiftUI)"]
        direction LR
        Library["Library"]
        Discover["Discover"]
        Bookmarks["Bookmarks"]
        Settings["Settings"]
        Reader["Reader<br/>Pages · Scroll · PDF"]
        Chat["Ask Leaf panel<br/>+ floating twin button"]
    end
    subgraph Stores["Stores and sessions (@MainActor, ObservableObject)"]
        direction LR
        LibraryStore["LibraryStore<br/>books, places, annotations"]
        ReaderModel["ReaderModel<br/>one open book"]
        ChatSession["ReaderChatSession<br/>one conversation"]
        AISettings["AISettingsStore<br/>provider + credentials"]
        ZLibraryStore["ZLibraryStore"]
        BestsellerStore["BestsellerStore"]
        ReadAloud["ReadAloudSession"]
        Sync["ICloudSync"]
    end
    subgraph Engines["Engines and services"]
        direction LR
        Foliate["foliate-js in WKWebView<br/>leaf-reader:// scheme"]
        PDFKit["PDFKit"]
        Providers["ChatProvider<br/>HTTP · ChatGPT OAuth"]
        Agent["ReadingAgent tools<br/>BookTextIndex"]
        History["ChatHistoryStore<br/>SQLite"]
        Catalog["ZLibraryClient over<br/>ZLibraryBrowserSession (WebKit)"]
        Feeds["BestsellerFeed<br/>IndieBound · NYT public relay or Books API"]
        Speech["AVSpeechSynthesizer<br/>MPNowPlayingInfoCenter"]
        Folder["SyncFolder<br/>coordinated iCloud Drive files"]
        Disk["LibraryDisk<br/>Documents/Leaf"]
    end
    Library & Bookmarks --> LibraryStore
    Reader --> ReaderModel --> Foliate & PDFKit
    Chat --> ChatSession --> Providers & Agent & History
    ChatSession --> AISettings
    Discover --> ZLibraryStore --> Catalog
    Discover --> BestsellerStore --> Feeds
    Reader --> ReadAloud --> Speech
    Settings --> Sync --> Folder
    LibraryStore --> Disk
    Sync -.-> LibraryStore & History
```

### Repository map

```text
LeafReader/
├── LeafReaderApp.swift        app entry, tab bar, store wiring
├── Models/                    Book, annotations, chat records, PDF locators, reading preferences
├── Services/
│   ├── Library/               LibraryStore, LibraryDisk, cover and metadata extraction
│   ├── Reader/                ReaderModel, asset handler for leaf-reader://, scroll diagnostics
│   ├── Chat/                  providers, ReaderChatSession, agent tools, history, retry, dictation
│   ├── Catalog/               Z-Library client and browser session, bestseller and web-novel feeds
│   ├── Speech/                read-aloud session, Apple voice catalog, sentence splitter
│   ├── Sync/                  ICloudSync, SyncFolder, synced record types
│   └── VoiceNotes/            recorder and clip files
├── Views/
│   ├── Library/ Reader/ Chat/ Catalog/ Settings/
├── UITesting/                 DEBUG-only fixtures, probes and the launch-flag registry
└── Resources/
    ├── Reader/                index.html, bridge.js, foliate/, reader.css, bundled CJK fonts
    └── Samples/               five original sample books seeded on first launch
LeafReaderTests/               unit and rendered-WebKit tests (+ Fixtures/)
LeafReaderUITests/             XCUITest flows (+ Fixtures/)
docs/                          design notes; docs/history holds past verification logs
scripts/                       simulator lease, job runner, coordination audit and dashboard
ThirdParty/                    pinned dependency manifest and local foliate-js changes
```

## Reading a book

```mermaid
flowchart LR
    Files["Files app · Share sheet<br/>Discover download · iCloud Drive"] --> Import
    Import["LibraryDisk.prepareImport<br/>copy · SHA-256 fingerprint · ≤100 MB"] --> Manifest["library.json<br/>atomic write"]
    Import --> Meta["BookMetadataLoader<br/>title · author · cover"]
    Manifest --> Shelf["Library grid<br/>search · sort · favorites · formats"]
    Shelf -->|open| Model["ReaderModel<br/>restores saved place"]
    Model -->|EPUB MOBI FB2 CBZ TXT MD HTML RTF| Web["WKWebView + foliate-js<br/>lazy chapters · CFI positions"]
    Model -->|PDF| PDF["PDFView<br/>page locators"]
    Web & PDF --> Surface["Reader surface<br/>tap center for controls"]
    Surface --> Places["Saved place · bookmarks · highlights<br/>written back to library.json"]
```

Books are copied into the app's own folder and never modified. The web engine fetches an archive's directory and only the requested entries, in ranges of at most 256 KB, so EPUB and CBZ files stay on disk. In **Scroll**, the current chapter and its two neighbours share one scrolling surface and distant chapters are released; **Pages** keeps a single-chapter page-turn layout. Saved places, bookmarks and highlights are EPUB CFIs or PDF page-and-character ranges, so they survive font, margin, theme and flow changes.

| Format | Engine | Notes |
| --- | --- | --- |
| EPUB 2/3 | foliate-js | Reflowable and fixed layout; contents, search, CFI restoration |
| PDF | PDFKit | Search, page navigation, pinch zoom, password unlocking |
| MOBI, PRC, AZW, AZW3/KF8 | foliate-js | DRM-free Mobipocket and Kindle Format 8 |
| FB2, FBZ, `.fb2.zip` | foliate-js | FictionBook, compressed or not |
| CBZ | foliate-js | ZIP comic archives in natural page order |
| TXT, Markdown | text adapter | UTF-8; Markdown headings, emphasis, code, quotes, lists |
| HTML, HTM | HTML adapter | Standalone documents; scripts and network loads blocked |
| RTF | Foundation + text adapter | Text extracted, rich formatting simplified |

Not supported: DRM removal, KFX, ACSM, CBR/RAR, DjVu, DOC and DOCX. Image-only PDFs and comics have no OCR, so no search or read-aloud.

### Appearance

Tap the centre of the page, then **Aa**. The panel is a compact sheet so the page stays visible while you adjust it.

```mermaid
flowchart LR
    Aa["Appearance panel"] --> Font["Font<br/>7 typefaces · 12–32 pt · line spacing"]
    Aa --> Layout["Layout<br/>margins · Pages or Scroll"]
    Aa --> Themes["Themes<br/>Day Paper Night Sepia Sage Dusk Black<br/>Compact Standard Large presets"]
    Aa --> Fine["Fine tuning<br/>exact spacing and margin sliders"]
    Font & Layout & Themes & Fine --> Prefs["ReaderPreferences<br/>saved across books and launches"]
    Prefs --> Anchor["Reflow anchored to the current passage"]
```

Typefaces are Georgia, Palatino and the system font plus four bundled CJK faces: LXGW WenKai Lite, Noto Serif CJK SC, LXGW Neo ZhiSong and LXGW Neo XiHei. The theme also colours the library, bookmarks, menus and Ask Leaf; PDF pages and comic artwork keep their own colours. A **Return to reading** pill appears after a seek or a contents jump so you can go back, and **Contents** has a "Reading here" shortcut to the current chapter.

## Listen

```mermaid
flowchart LR
    Start["Listen from this page<br/>or 'Listen from here' on a selection"] --> Passage["Bounded passage + CFI cursor<br/>read-aloud.js or PDFReadAloudSource"]
    Passage --> Split["Sentence splitter<br/>≤48 CJK / ≤160 Latin chars per utterance"]
    Split --> Synth["AVSpeechSynthesizer<br/>downloaded Enhanced/Premium Apple voices<br/>language matched automatically"]
    Synth --> Highlight["Amber highlight follows the spoken line<br/>Follow can be turned off"]
    Synth --> NowPlaying["Lock Screen / Control Center<br/>title · chapter · author · progress"]
    Synth --> Cursor["Saved listening cursor per book<br/>Resume saved position"]
    Passage -->|"end of passage"| Passage
```

Speech is entirely on device; no book text leaves the phone. Playback continues in the background (the `audio` background mode) and pauses on interruptions or when headphones disconnect. Only the current and one prefetched passage are held in memory.

## Highlights, notes and voice notes

Select text and choose **Highlight**, **Note** or **Voice Note** from the compact selection toolbar (Ask Leaf, Listen, Translate, Highlight, Note, Voice, Copy). **Translate** opens Ask Leaf with the passage quoted and asks your AI model to translate it: Chinese text into English, anything else into Simplified Chinese. With text selected, Ask Leaf also shows your **quick prompts** (Explain and Summarize to start with): tapping one sends it with the passage at once, after anything you had already typed. The pencil beside them, or **AI settings › Quick prompts**, lets you rename, rewrite, add, delete and reorder them; with iCloud Drive sync on, your prompts follow you to your other devices.

```mermaid
flowchart LR
    Select["Selection<br/>CFI range or PDF character range"] --> Highlight["Highlight<br/>yellow · green · blue · pink"]
    Select --> Note["Written note"]
    Select --> Voice["Voice note<br/>AAC clip · ≤10 min · mic permission"]
    Highlight & Note & Voice --> Annotation["BookAnnotation in library.json<br/>clip in Documents/Leaf/VoiceNotes"]
    Annotation --> Overlay["Painted as overlays<br/>book text untouched"]
    Annotation --> Lists["Saved → Highlights & notes<br/>Bookmarks tab across books"]
```

Recording stops when Leaf leaves the foreground or another Leaf audio feature starts. Recordings are never transcribed or sent to an AI provider.

## Ask Leaf

Ask Leaf is a resizable, frosted panel launched from a translucent **twin button**: the large leaf opens chat, the small satellite on its upper edge opens a quick theme arc. Long-press to drag the button anywhere; its position, transparency (20–95 %) and panel heights are saved. Text keeps its full width underneath the button. The same panel also answers questions about the **Discover**, **Bookmarks** and **Library** screens.

```mermaid
flowchart TB
    Q["Question + optional quote<br/>typed or dictated"] --> Session["ReaderChatSession"]
    Session --> Ctx{"Include current passage?"}
    Ctx -->|yes| Snap["Snapshot: selection, visible range<br/>or PDF page · ≤12,000 chars"]
    Ctx -->|no| NoCtx["Metadata only"]
    Snap & NoCtx --> Agent["Leaf agent<br/>ReadingAgentRunner"]
    Agent -->|"provider has tools"| Tools["Model calls read-only tools<br/>(table below)"]
    Agent -->|"provider or model has none"| Plain["One request without tools<br/>passage · earlier discussion · screen list as text"]
    Tools & Plain --> Provider["ChatProvider"]
    Provider --> Anthropic["Anthropic Messages<br/>API key"]
    Provider --> OpenAICompat["Chat Completions compatible<br/>any HTTPS endpoint + key"]
    Provider --> ChatGPT["ChatGPT subscription<br/>OAuth · Responses API · can draw pictures"]
    Anthropic & OpenAICompat & ChatGPT --> Stream["SSE stream → ChatEvent"]
    Stream --> Panel["Markdown reply, 80 ms batches<br/>history follows unless you scroll"]
    Stream --> HistoryDB["SQLite history per book<br/>loaded as you scroll back · pictures beside it"]
```

The history is one conversation you scroll through. It opens on the latest 24 messages; scrolling back brings older ones in twelve at a time, a screen ahead of where you are reading, and the text on screen stays where it is while they join above it (`ChatHistoryWindow`). At most 72 messages stay loaded: past that the far end is let go and loads again on the way back. A round **↓** button returns to the latest message from anywhere, and carries a dot while a reply is printing or has finished below.

### What the agent can read

Every Ask Leaf chat, in a book or on a tab, offers the same read-only tools. They read the stores directly when they run, so a question works even if that screen was never opened this launch (a feed or chart is fetched then and kept for the screen).

| Tools | Reads | Where |
| --- | --- | --- |
| `search_book` · `read_passage` · `list_chapters` | the open book, only up to the reading position | reader chat |
| `get_current_view` · `get_item_details` | the screen the chat floats over, as it is now | Discover, Bookmarks, Library |
| `get_catalog_feed` · `search_catalog` · `get_catalog_book` | Z-Library popular / recommended lists, search, one book's details | every chat |
| `get_bestsellers` | Indie or NYT hardcover fiction / nonfiction chart | every chat |
| `get_web_novel_chart` | a 起点 web-novel chart (optionally one category) or a 微信读书 book chart | every chat |
| `list_library` · `search_saved` | your books with progress; bookmarks, highlights and notes | every chat |
| `search_my_books` | other books' text, each only up to where you stopped | every chat, passage sharing on |
| `search_conversation` | older messages in this chat | every chat |

```mermaid
flowchart LR
    Open["Ask Leaf opened<br/>while reading"] --> Warm["warmBookText<br/>sections to the reading position"]
    Warm --> Disk["ChatIndex/‹fingerprint›/v1<br/>section JSON + position.json"]
    Disk --> Other["search_my_books from any chat"]
    Other --> Check{"saved position still behind<br/>the book's current place?"}
    Check -->|yes| Hits["passages up to that position"]
    Check -->|"no (reader went back)"| Skip["listed as not searchable"]
```

Highlight text, notes and book passages follow the **Include current passage** switch; titles, authors, progress and catalog listings do not. The tools never download, add or change anything.

### What happens to one request

```mermaid
sequenceDiagram
    participant U as Reader
    participant S as ReaderChatSession
    participant R as ChatRetryBudget
    participant P as Provider
    U->>S: Send
    S->>S: append question, checkpoint draft
    S->>S: begin background task (survives app switch)
    S->>P: stream(request)
    alt transient failure (connection lost, 408/409/429/5xx, socket dropped)
        P-->>S: error
        S->>R: may retry?
        R-->>S: yes, wait 0.6 s / 1.2 s (+jitter), 2 extra requests max
        S->>P: stream(request) again
    end
    P-->>S: text deltas, tool calls, images, finished
    S->>U: reply grows in 80 ms batches
    S->>S: save every 500 ms and on completion
    Note over S: Backgrounded mid-reply? The task keeps streaming.<br/>If iOS ends it the reply resumes on return with a notice.
```

Recent context is capped at 12 turns and 48,000 characters; opaque locators never leave the device. API-key replies default to 2,048 output tokens (256–8,192); the subscription route follows OpenAI's limits. Authentication, quota and malformed-response errors are shown rather than retried. Details: [docs/automatic-chat-retry.md](docs/automatic-chat-retry.md).

### Providers and credentials

| Provider | Auth | Transport | Notes |
| --- | --- | --- | --- |
| Anthropic | API key in Keychain | `HTTPChatProvider`, Messages API streaming | Default model `claude-haiku-5-5`; any model ID can be typed |
| Chat Completions compatible | API key per endpoint | `HTTPChatProvider` | Full HTTPS endpoint and model ID; legacy `max_tokens` switch |
| ChatGPT subscription | OAuth via `ASWebAuthenticationSession`, loopback callback on 127.0.0.1 | `ChatGPTSubscriptionProvider`, `POST /v1/responses` with `store: false` | Account-specific model list; RS256 ID-token verification; image generation tool |

Keys and tokens are stored `WhenUnlockedThisDeviceOnly` and are not synced. Requests require HTTPS, refuse redirects and disable caching and cookies. Raw provider error bodies are never shown or logged. Each reply's caption says whether the agent used tools; its steps can be inspected in the on-device trace (Settings → Diagnostics).

## Discover

The Discover tab has four sections: Z-Library's most popular books (**Popular**), its recommendations for your account (**For you**), **Bestsellers** with Indie and New York Times hardcover fiction and nonfiction charts, and **中文** with Chinese charts from 起点中文网 and 微信读书. The catalog sections have search with eight sort orders and book details. The Library tab has a cover shelf that opens the catalog and bestseller screens.

中文 shows one chart at a time from the site you pick, and remembers the chart last chosen on each:

| Site | Charts | Each row shows |
| --- | --- | --- |
| 起点 (web novels) | 月票榜, 畅销榜, 阅读指数榜, 推荐票榜 (week, month or all time); whole site or one of fourteen categories; top 20 | author, category, length, the chart's count |
| 微信读书 (published books) | 总榜, 飙升榜, 新书榜, 神作榜; top 20, **Load more** up to 100 | author, category, recommendation rate, readers today |

Every row also has the book's cover and the start of its synopsis. A row offers **Add** when Z-Library has exactly one edition with the same title and author, and **Choose** or **Find** otherwise. Many books on 起点's charts are still being written, so Z-Library may not have them yet or may have only part.

```mermaid
flowchart LR
    subgraph ZLib["Z-Library (unofficial mobile API, your own account)"]
        Store["ZLibraryStore"] --> Client["ZLibraryClient<br/>popular · recommended · search · details · download"]
        Client --> Browser["ZLibraryBrowserSession<br/>hidden WKWebView shares the website's cookie jar"]
        Browser --> Site["z-library domain"]
        Site -->|"307 to same URL<br/>(DiamWall cookie handout)"| Browser
        Browser -->|"repeat once with the cookie"| Site
        Site -->|"517 access-check page"| Browser
        Browser -->|"load the page once,<br/>script sets the cookie"| Site
        Browser -->|"dropped request"| Browser
        Browser -->|"retry after 0.6 s, 1.5 s"| Site
    end
    subgraph Best["Bestsellers (public rankings)"]
        BStore["BestsellerStore<br/>6-hour cache"] --> Indie["IndieBound national list"]
        BStore --> NYT["NYT lists<br/>public relay, no key"]
        NYT -.->|"optional personal key"| NYTAPI["NYT Books API<br/>key in Keychain, sent only to api.nytimes.com"]
        BStore --> Match["BestsellerMatching<br/>finds editions in the catalog"]
    end
    subgraph Novels["中文 (public charts)"]
        NStore["WebNovelStore<br/>6-hour cache, 8 charts"] --> Qidian["起点 mobile chart page<br/>no account"]
        NStore --> WeRead["微信读书 chart data<br/>no account"]
        NStore --> Match
    end
    Client -->|"download ≤100 MB<br/>to a protected temp file"| Import["Library import"]
    Match --> Client
```

Access checks, expired sessions, unavailable domains and download limits are reported as readable errors with a redacted **Request details** diagnostic. Since 2026-11-23 Z-Library refuses app searches without a `source` header (HTTP 400 "Access denied"); Leaf sends `source: ios`, and if search is still refused it reads the website's own search page (`/s/<query>`) in the same hidden browser for 15 minutes, and says "Z-Library is refusing searches" when both fail. Credentials are never sent to a different origin. Cover thumbnails are downsampled into an 8 MB cache. Details: [docs/discovery-bestsellers.md](docs/discovery-bestsellers.md).

### Ratings & reviews

Every Discover book page (catalog, bestseller, 起点 and 微信读书) has one **Ratings & reviews** section. It is filled when the page opens, from the sites that have something for that book, and kept for a week:

| Site | What it gives | How the book is found | Asked for |
| --- | --- | --- | --- |
| Z-Library | its own score, count and file quality | already in the catalog | catalog books |
| 微信读书 | recommendation rate, count, verdict such as 神作 | already in its chart; otherwise its search, by title and author | Chinese books |
| 豆瓣读书 | score, star breakdown, three most useful short reviews | ISBN, or its title suggestions by title and author | books with an ISBN, and Chinese books |
| Open Library | average, star breakdown, want-to-read and read counts | ISBN, or title and author | non-Chinese books |
| The New York Times | links to its critics' reviews | ISBN, with your own NYT Books key | non-Chinese books with an ISBN |

Each site's score is a card. The cards are one height and share the width when they all fit. When three sites answer on an upright phone, two cards show whole with the start of the third at the edge: swipe sideways for it. Each card has its score first and the site's name under it. Readers' scores come first and Z-Library's own score last. 豆瓣's score is marked /10 and Open Library's /5, since 7.4 beside 3.9 compares only when each says what it is out of; Z-Library does not say what its score is out of.

**More reviews** under the 豆瓣 reviews loads the next twenty on the page, most useful first, from the feed 豆瓣's mobile site reads. 豆瓣 shows a visitor who is not signed in the first hundred short reviews of an edition; past that the page says how many more it keeps for signed-in readers, and **All reviews on 豆瓣读书** still opens the site. The extra reviews are not kept after Leaf closes.

**Summarize reviews with Ask Leaf** asks your AI once, with web search as its only tool, for four lines: what reviewers like, what divides them, who the book suits, and the pages it read. Only the title, author, ISBN and the scores on the page are sent. The summary is kept with the book until you ask again. Details: [docs/discovery-bestsellers.md](docs/discovery-bestsellers.md#ratings--reviews).

## iCloud Drive sync

Leaf has no server and no account. Sync works through a folder you pick in iCloud Drive (create one named **Leaf**, choose it on each device).

```mermaid
flowchart LR
    subgraph Device["This device"]
        Lib["library.json<br/>places · bookmarks · annotations"]
        Chats["ChatHistory (SQLite)"]
        Prefs["Reading settings"]
        Books["Book files · covers · voice clips"]
    end
    subgraph Folder["iCloud Drive / Leaf"]
        Records["Per-book and per-conversation JSON records<br/>SyncBaseline tracks what each device last saw"]
        Blobs["Books and covers, uploaded once"]
    end
    Lib & Chats & Prefs -->|"ICloudSync merges three ways<br/>and resolves iCloud conflict versions"| Records
    Books -->|"upload once"| Blobs
    Blobs -->|"download on open, or keep all books"| Books
    Records --> Other["Other iPhone or iPad"]
    Blobs --> Other
```

Every read and write goes through `NSFileCoordinator`, so iCloud never sees a half-written file and cloud-only files are downloaded before use. Concurrent edits on two devices are merged record by record; explicit removals win over stale copies. AI settings and quick prompts changed on another device take effect in the open app as soon as they sync. API keys, sign-ins, voice packs, search caches and the floating button's position stay per device. **Stop Syncing** leaves the library on both the device and in iCloud Drive.

## Storage and privacy

```mermaid
flowchart TB
    Docs["Documents/Leaf"] --> B["Books/<br/>your unmodified copies"]
    Docs --> C["Covers/"]
    Docs --> V["VoiceNotes/<br/>AAC clips"]
    Docs --> M["library.json<br/>metadata · places · bookmarks · highlights · notes"]
    Docs --> H["ChatHistory/<br/>SQLite per library, pictures beside it"]
    Docs --> T["AgentTraces/<br/>opt-in debugging"]
    KC["Keychain (this device only)"] --> K1["AI keys · ChatGPT tokens"]
    KC --> K2["Z-Library session · optional NYT key"]
    UD["UserDefaults"] --> P["Reading preferences · provider choice · theme · button position"]
```

The reader's `leaf-reader://` scheme serves only bundled reader resources and the open book. Its WebView blocks outbound network loads and scripts, website data is non-persistent, and a sanitizer strips active markup from imported HTML. AI requests leave from the native chat service only after you press Send, and only with the passage you chose to include. iOS may include Documents in device backups.

## Tests

```mermaid
flowchart LR
    subgraph Unit["LeafReaderTests · 486 tests"]
        U1["Rendered WebKit and PDFKit<br/>every format, 12–32 pt, both flows, CFI meaning"]
        U2["Chat: providers, SSE, history, retry,<br/>agent tools, Markdown, dictation"]
        U3["Catalog: parsers, cookies, redirects,<br/>loopback WebKit server"]
        U4["Sync, speech, annotations, themes, voice notes"]
    end
    subgraph UI["LeafReaderUITests · 220 tests"]
        X1["Reader flows in Pages, Scroll and PDF"]
        X2["Ask Leaf on every screen"]
        X3["Discover, bestsellers, annotations"]
        X4["Simulator isolation probes"]
    end
    App["App launched with --ui-testing<br/>+ LEAF_UI_TEST_ID + LEAF_UI_* flags"] --> Seams["LeafReader/UITesting<br/>UITestFlag registry · fixtures · probes<br/>DEBUG only, absent from Release"]
    UI --> App
    Seams --> App
```

Every UI launch gets its own temporary library, defaults suite and Keychain service, so tests never touch a real library. `UITestFlag` lists every launch flag the app understands; a fixture is added by adding a case there. Reader changes are verified in both Pages and Scroll, in portrait and landscape, across themes and the full font-size range, with chat closed, open and composing (the checklist is in `AGENTS.md`). Rendered-geometry tests measure actual WebKit layout rather than mocking it.

Three simulators can run jobs at once under exclusive leases; `scripts/simulator_lease.py` fails closed before a launch and `scripts/simulator_job.py` runs one job and restores only that device's keyboard preference. See [docs/simulator-ui-isolation.md](docs/simulator-ui-isolation.md). Past per-version verification and iPhone installation logs are archived in [docs/history](docs/history/).

## Dependencies

[foliate-js](https://github.com/johnfactotum/foliate-js) (MIT), [zip.js](https://github.com/gildas-lormeau/zip.js) (BSD-3-Clause) and [fflate](https://github.com/101arrowz/fflate) (MIT) are vendored for offline use; the pinned commit, versions and checksums are in `ThirdParty/dependencies.json`, and Leaf's local changes to the paginator are listed in `ThirdParty/LOCAL_CHANGES.md`. The four bundled CJK typefaces ship under the SIL Open Font License with their license files next to them. Licenses are shown in Settings → Open-source acknowledgments.

This is a personal, development-signed build, not an App Store submission.
