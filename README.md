# Leaf for iOS

A native ebook reader for iPhone and iPad with offline reading and optional AI chat, built with SwiftUI, WebKit, and PDFKit. Requires iOS 17+ and Xcode 16+.

## Run

Open `LeafReader.xcodeproj`, select the **LeafReader** scheme and an iPhone/iPad simulator, and press Run. The project is checked in and has no Swift Package Manager or CocoaPods dependencies. Physical-device signing is configured for the owner's Personal Team and the registered bundle identifier `com.weizhao.leafreader`. If building with another account, select your own development team in Signing & Capabilities and a unique bundle identifier.

`project.yml` is the project source. If you change targets or resources, regenerate with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
xcodebuild -project LeafReader.xcodeproj -scheme LeafReader -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -derivedDataPath build test CODE_SIGNING_ALLOWED=NO
```

## Supported files

| Format | Reader | Notes |
| --- | --- | --- |
| EPUB 2/3 | foliate-js in WKWebView | Reflowable and fixed-layout; table of contents, text search, CFI position restoration |
| PDF | Apple PDFKit | Text search, page navigation, pinch to zoom; password unlocking |
| MOBI, PRC, AZW | foliate-js | DRM-free Mobipocket, including PalmDOC and HUFF/CDIC compression |
| AZW3 / KF8 | foliate-js | DRM-free Kindle Format 8, including combo MOBI/KF8 books |
| FB2, FBZ, `.fb2.zip` | foliate-js | FictionBook, including compressed books |
| CBZ | foliate-js | ZIP comic archives with supported images; natural page order |
| TXT | Local text adapter | UTF-8; paragraphs and line breaks preserved |
| Markdown | Local text adapter | Headings, bold, inline/fenced code, quotes, and simple lists; no raw HTML |
| HTML, HTM | Local HTML adapter | Standalone documents; inline/data assets; scripts and network resources blocked |
| RTF | Foundation + text adapter | Text extracted; rich formatting simplified |

DRM removal, KFX, ACSM, CBR/RAR, DjVu, legacy DOC, and DOCX are not implemented. Convert those to EPUB or PDF before importing. Image-only PDFs and comics have no OCR or text search. Imports are capped at 100 MB because the web reader holds a book Blob in memory. Typography controls affect reflowable books; fixed-layout books preserve their layout. PDF page color changes the surrounding canvas, not the printed page.

## Features

- Multi-file import from Files and iCloud Drive, plus Open in Leaf from another app.
- App-owned file copies, SHA-256 duplicate detection, atomic library manifests, and visible import errors.
- Search and filter the library, sort books, favorites, recent reading, and finished books.
- Table of contents, page turning/swiping, progress seeking, and full-book text search (up to 200 results).
- Fullscreen reading with a center tap to reveal controls; page-edge taps and swipes return to uninterrupted reading.
- Translucent floating Ask Leaf chat with streaming AI replies, page/selection context, Stop, and Retry.
- Swappable Anthropic and Chat Completions providers, editable model IDs/endpoints, and device-only Keychain credentials.
- Persistent reading positions and per-book bookmarks, including a library-wide bookmarks tab.
- Day, paper, and night themes; three typefaces; adjustable font size, line and paragraph spacing, and page margins; paginated or vertical flow.
- Original short sample books in EPUB, PDF, FB2, and TXT.
- Cover thumbnails and embedded title/author metadata load during import; existing books with missing covers are checked automatically on launch.
- Native accessibility labels, Dynamic Type in app controls, iPad layouts, and landscape support.

Books open with the title bar, bottom controls, and system status indicators hidden. Tap the center of the page to show or hide controls. In paginated mode, tap the left/right edges or swipe to turn pages; controls hide when reading resumes. Menus overlay the page without resizing it, preserving the current passage and bookmarks. Loading, error, password, and VoiceOver states keep controls available.

Reflowable books follow your finger during a swipe and settle with a brief 0.36-second slide. Short swipes visibly return to the current page; page turns settle before accepting another turn. Holding still before lifting does not count as a flick, and interrupted drags return to the current passage. Reduce Motion disables settling animation; continuous scrolling keeps its normal behavior.

Tap the center, then open **Appearance (Aa)** while reading. **Font** contains the typeface, text size (12–32 pt), A−/A+ buttons, and visual line-spacing choices. **Layout** contains visual margin choices and paginated/scrolling flow. **Themes** contains page colors and Compact, Standard, and Large reading presets. **Fine tuning** exposes precise sliders for line/paragraph spacing and side/top/bottom margins. The panel opens as a compact sheet so the page stays visible while adjusting it; drag upward for more room. Tap the visible book page or swipe down from the title bar to dismiss and resume reading. The dismissal tap keeps your place, including when tapping a page edge.

**Themes → Compact** fits more text in one tap: 17 pt text, 1.35 line spacing, 0.35 em paragraph spacing, 12 pt side margins, and 8 pt top/bottom margins. Changes apply immediately and are saved across books and app restarts. The same controls are available in Settings.

Text size uses the selected 12–32 pt value in both Pages and Scroll, with browser text autosizing disabled. Changing size or flow anchors reflow to the current passage rather than a percentage through the chapter.

**Ask Leaf** opens a frosted chat panel at about one third of the screen height. While typing, it becomes a compact composer above the keyboard, leaving the book visible without resizing its viewport. Swipe the exposed book to browse while keeping the keyboard and draft, or use Hide keyboard to see more of the page. Tap the book, close the panel, or swipe down on its header to return to reading without an accidental page turn. The launcher uses a translucent teal fill with solid fallbacks for increased contrast and Reduce Transparency.

Unsent drafts and conversations stay in memory while the reader is open, including when chat is closed and reopened. They reset when leaving the reader. Sending dismisses the keyboard to show the streamed reply. Stop cancels an in-flight request; Retry replaces a failed or stopped answer while keeping the original question and passage snapshot. Clearing the conversation cancels an active response. There are no sample answers in normal use.

## AI chat setup and provider architecture

Open **Settings → AI settings** (also available in the chat’s options menu). Anthropic is initially selected with `claude-haiku-5-5`; a menu also offers `claude-haiku-4-5`, and any model ID can be entered directly. Add your own Anthropic API key, then tap **Save AI settings**. No credentials are bundled or read from developer environment files. API billing and model access belong to the selected provider account.

To change models on the same provider, edit only the model ID. To use another service with Chat Completions streaming, select **Chat Completions compatible**, enter its full HTTPS endpoint (including the completion path), its model ID, and its key. This adapter sends `max_completion_tokens` by default; enable the legacy `max_tokens` option if required by that service. The app remembers a separate profile for each API format. Keys are scoped to the exact endpoint and API format, so changing destinations requires an appropriate saved or newly entered key. Use **Remove saved key** to delete a credential.

**Include current passage** controls whether Leaf shares book details and text. On Send, the reader snapshots selected text, or the visible EPUB/text range/current PDF page if nothing is selected. Context is capped at 12,000 characters, and unusually escape-heavy text is further reduced. It never uses the diagnostic `visibleText()` method, which exposes a whole loaded chapter. Images, scans, and comics have no text analysis; Leaf explains when no readable passage is available. There is no OCR, whole-book retrieval, web browsing, or external tool execution. The system prompt asks for grounded explanations in the reader’s language and avoids spoilers beyond supplied text.

Recent conversation input is capped at 12 turns and 48,000 characters, with each question tied to its own bounded passage snapshot. Opaque reading locators stay on device. Disabling passage sharing also removes attached passages and metadata from prior turns in subsequent requests; previously typed questions and replies remain conversational input. Provider retention policies apply to data already sent. Replies are limited to 2,048 output tokens by default, adjustable from 256–8,192. Interrupted or truncated replies are visibly marked and can be retried. Requests have no automatic retries, avoiding duplicate billable requests.

Implementation boundaries:

- `ChatProvider` streams provider-neutral `ChatEvent` values. The reader UI and `ReaderChatSession` do not depend on a vendor SDK or API response shape. Inject another implementation through `AISettingsStore.provider()` to add local inference, a backend proxy, or another API.
- `HTTPChatProvider` translates Anthropic Messages and Chat Completions requests/events. `ChatTransport` separates networking from parsing and supports deterministic tests. SSE framing preserves blank lines, CRLF, multiline events, and UTF-8 across network chunks; thinking/usage metadata are not rendered as answer text.
- `AISettingsStore` persists nonsecret configuration in UserDefaults. `KeychainChatCredentials` stores keys with `WhenUnlockedThisDeviceOnly`. HTTPS is required, redirects are refused, caching/cookies are disabled, and raw provider error bodies are never shown or logged by Leaf.
- UI tests explicitly inject a debug-only fake streaming provider using both `--ui-testing` and `LEAF_UI_CHAT_MOCK=1`. Normal launches and Release builds never substitute a fake reply.

The request formats were checked against [Anthropic streaming documentation](https://platform.claude.com/docs/en/build-with-claude/streaming), [Haiku model documentation](https://platform.claude.com/docs/en/models/haiku-5-5/overview), and the [official OpenAI Chat Completions reference](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create). Actual provider calls require a user-supplied API key; automated verification uses intercepted HTTP streams and injected providers without transmitting book text or incurring API charges.

## Storage and privacy

Library files live in `Documents/Leaf/Books`, cover images in `Documents/Leaf/Covers`, and the atomic JSON manifest in `Documents/Leaf/library.json`. The manifest holds metadata, favorites, reading positions, and bookmarks. Imported originals are never modified. Removing a book removes only Leaf's copy and saved places. Files can be shared through the book's context menu or copied using Finder file sharing. iOS may include Documents in device/iCloud backups; Leaf implements no cross-device sync, account, analytics, or server.

The local `leaf-reader://` scheme exposes only bundled reader resources and the currently opened book. Reader website data is nonpersistent. The reader WebView’s CSP blocks outbound network loads and embedded scripts; an additional sanitizer removes active markup. External book links are not opened automatically. A damaged manifest is preserved and reported rather than replaced. Optional AI requests originate from the native chat service after the reader sends a question; they do not relax the book WebView’s network restrictions.

## Tests

`LeafReaderTests` covers format aliases, duplicate imports, source preservation, invalid files, manifest corruption, bookmark persistence, and actual WebKit rendering of EPUB, FB2, TXT, MOBI, HTML, CBZ, plus PDFKit rendering/navigation/search. EPUB tests also search rendered content, navigate, bookmark, and reopen at the saved location. UI tests exercise the library, appearance controls, bookmarks, and library search.

The initial version was verified on October 20, 2026: **16 tests passed, zero failures or skips**, on iPhone 17 Pro Simulator running iOS 26.5 (13 unit/integration tests and 3 UI tests). The PDF UI test turns a page, closes the reader, and verifies that reopening restores that page. EPUB restoration checks that the start of the saved passage is visible; progress estimates can change with pagination. Debug UI tests use a separate temporary library and preferences suite for each test instead of changing the normal library or reading settings.

Version **1.0.1 build 2** passed **25 tests with zero failures or skips** on the same Simulator. Nine new metadata tests verify covers and authors before the first read, EPUB 2/3 declarations, SVG rasterization, XHTML cover pages with relative image paths, PDF thumbnails, persistence, existing-library updates, retry after failure, and deletion during extraction. Results: `build/CoverFixFinal-20261020.xcresult` and `build/cover-fix-test-summary-20261020.json`.

Version **1.0.2 build 3** balances the Leaf toolbar logo's horizontal padding and centers its icon and title within a 44-point row. The existing library/reader/bookmarks/appearance UI test passed, and screenshots confirmed the logo spacing at the top of the library and after scrolling. Results: `build/LeafTitleAlignmentFinal-20261020.xcresult` and `build/title-alignment-final-attachments/`.

Version **1.0.3 build 4** passed **27 tests with zero failures or skips**. Page layout now supplies valid CSS lengths to the paginator, preventing excessive blank space. New controls adjust page margins and paragraph spacing, with a compact preset and smaller minimum text size. A Chinese HTML regression fixture verifies actual page dimensions, increased visible text, and preservation of the saved passage when changing density or switching to scrolling. The UI test verifies that layout settings survive a restart. Results: `build/LeafDensityFinal-20261020.xcresult`; screenshots and density measurements are exported to `build/density-final-attachments/`.

Version **1.0.4 build 5** reorganizes Appearance into a compact Font/Layout/Themes panel with a visible reading page, visual margin and spacing choices, and reading presets. The full **27-test suite passed** (`build/LeafAaControls-20261020.xcresult`). Subsequent targeted checks verify night controls, text-size buttons, preset selection and persistence, page bounds, density, scrolling, PDF navigation, and EPUB search/position restoration after the final preview refinements. The web surface prevents outer scrolling during focus restoration after dismissing the sheet. Visual artifacts are in `build/aa-controls-attachments/`, `build/aa-visual-final-attachments/`, and `build/aa-focus-final-attachments/`.

Version **1.0.5 build 6** passed **28 tests with zero failures or skips** (`build/LeafImmersiveFinal-20261020.xcresult`). Reading controls now overlay a stable, larger page viewport and hide automatically. A new UI test checks hidden controls on opening, a center tap to reveal/hide them, unchanged page height and bookmarked passage during toggling, edge-tap navigation, and hiding on swipes. Updated EPUB/PDF and appearance tests exercise the same tap-to-reveal interaction. Screenshots are exported to `build/immersive-final-attachments/`; the summary is `build/immersive-final-test-summary-20261020.json`.

Version **1.0.6 build 7** removes Done from Appearance. Both existing appearance UI tests passed, verifying swipe-down dismissal, hidden reading controls after dismissal, and saved preferences after relaunch (`build/LeafRemoveDone-20261020.xcresult`). Screenshots are in `build/remove-done-attachments/`.

Version **1.0.7 build 8** passed **29 tests with zero failures or skips** (`build/LeafPageMotionFull-20261020.xcresult`). Page-turn animation is now enabled for paginated reflowable books, with a 360 ms settle (375 ms measured in the full run). WebKit tests sample intermediate movement and verify snap-back, paused releases, interrupted drags, overlapping input, and forward/backward position restoration. The immersive UI test verifies short-drag cancellation and real forward/backward swipes using saved bookmarks. Timing measurements and screenshots are in `build/page-motion-full-attachments/`; upstream engine modifications are described in `ThirdParty/LOCAL_CHANGES.md`.

Version **1.0.8 build 9** passed **31 tests with zero failures or skips** (`build/LeafFontFinal-20261020.xcresult`, completed October 21). WebKit text autosizing previously changed a requested 12 pt to 20 pt and could retain distorted sizing after returning to Pages. A new regression sweeps every integer size from 12–32 pt through Scroll → Pages → Scroll → Pages, checking actual font and glyph sizes, line height, text width, visible content, and passage preservation in all 84 cases. Reflow now pins to text, with an inset to avoid losing the anchored line at an exact pixel boundary. The UI test checks 12/32 pt scrolling previews, vertical swipes, and returning to Pages at 22 pt. Measurements and screenshots are in `build/font-final-attachments/`.

Version **1.0.9 build 10** dismisses Appearance when the exposed book page is tapped. A temporary tap target consumes the dismissal tap, preserving the current page even at its edges. Both targeted UI tests passed (`build/LeafTapDismiss-20261021.xcresult`): the immersive test checks dismissal and the unchanged bookmarked passage, and the appearance test checks controls, swipe dismissal, and preference persistence.

Version **1.1.0 build 11** passed **32 tests with zero failures or skips** (`build/LeafChatFinal2-20261021.xcresult`). The new chat UI test verifies the compact panel height, unchanged book viewport with the keyboard, sample message submission, the latest reply visible after reopening, page-tap dismissal without navigation, and bookmark preservation. Reading, appearance, font-size sweeps, imports, and PDF checks also passed. Screenshots are in `build/chat-final2-attachments/`; the summary is `build/chat-final2-test-summary-20261021.json`.

Version **1.1.1 build 12** passed **six targeted checks with zero failures or skips** (`build/LeafComposeFinal-20261021.xcresult`). Day and night chat checks verify a compact composer above the keyboard, visible book content, a stable book viewport, forward/backward swipes while retaining the keyboard and draft, draft restoration after closing chat, and keyboard dismissal when sending or choosing Hide keyboard. The text-size sweep, page-turn animation, immersive controls, and PDF navigation checks also passed. Screenshots are in `build/compose-final-attachments/`; the summary is `build/compose-final-test-summary-20261021.json`.

Version **1.2.0 build 13** passed **24 final targeted tests with zero failures or skips** (`build/LeafAIChatVerified-20261021.xcresult`): 18 provider, transport, Keychain, and conversation lifecycle tests; two actual WebKit/PDF context tests; and four UI checks for settings persistence, missing-key draft preservation, Stop/Retry, and reading while typing in day/night themes. Tests include byte-fragmented Unicode SSE, cancellation of the underlying HTTP request, malformed/interrupted responses, HTTP errors, endpoint credential isolation, bounded history, disabled passage sharing, and retrying the original passage. Results and screenshots are `build/ai-chat-verified-test-summary-20261021.json` and `build/ai-chat-verified-attachments/`.

The broader 53-test regression run (`build/LeafAIChatFinal-20261021.xcresult`) passed 52 tests, including all reading, import, metadata, font-size sweep, animation, and PDF checks. Its sole failure was a simulated tap missing the passage-sharing switch; the final targeted run uses a precise switch tap and verifies the changed value both immediately and after relaunch. UI tests isolate their Keychain service as well as their library and preferences. No test uses a live provider credential or incurs API charges.

Cover extraction runs separately from the reader, so it does not mark books as opened or change reading positions, bookmarks, or favorites. Images are converted to PNG thumbnails with a maximum dimension of 600 pixels, including SVG covers. Books without embedded artwork retain their generated covers, and successful coverless checks are remembered across launches. Existing books with missing artwork are updated automatically without reimporting.

The verified build bundles the reader engine, sample books, and test fixtures with their directory structure intact. WebKit's deferred ResizeObserver layout notification is no longer treated as a failed book import. The library toolbar and cover bounds were also checked in captured screenshots.

Local verification artifacts (ignored by source control):

- `build/LeafVerified-20261020.xcresult` — full Xcode test result.
- `build/LeafCoverLayout-20261020.xcresult` — targeted UI recheck after final cover spacing adjustments.
- `build/leaf-test-summary-20261020.json` — machine-readable test summary.
- `build/previews/` — library, book grid, EPUB day/night, and PDF screenshots.

The fixtures establish rendering for the formats named above; they do not test every publisher's EPUB layout, every Kindle encoding, or every supported adapter. iCloud Drive picking has not been verified in this run.

## Physical iPhone installation

On October 20, 2026, version **1.0.0 build 1** was built and signed for the owner's iPhone 17 Pro running iOS 27.0, installed successfully, and launched. A subsequent device process query confirmed the app remained running. The signed bundle includes the reader engine and all four sample books; its signature and device provisioning were validated. This establishes installation and launch, rather than a complete on-device reading or iCloud import test.

Version **1.0.2 build 3** was also signed, verified, and installed successfully. The phone was locked when launch was attempted, so this update's on-device appearance remains to be checked after unlocking and opening Leaf. Installation and launch diagnostics are recorded in `build/title-alignment-iphone-install-20261020.json` and `build/title-alignment-iphone-launch-20261020.json`.

Version **1.0.3 build 4** was signed, verified, installed, and launched successfully on the same iPhone. Installation and launch diagnostics are saved in `build/density-iphone-install-20261020.json` and `build/density-iphone-launch-20261020.json`.

Version **1.0.4 build 5** was also signed, verified, installed, and launched successfully. A before/after comparison confirmed that the five-book library manifest was unchanged by the update. Diagnostics are `build/aa-controls-iphone-install-20261020.json`, `build/aa-controls-iphone-launch-20261020.json`, and `build/aa-final-phone-library-preservation.json`.

Version **1.0.5 build 6** was signed, verified, installed, and launched successfully, with the five-book library manifest preserved. Diagnostics are `build/immersive-iphone-install-20261020.json`, `build/immersive-iphone-launch-20261020.json`, and `build/immersive-phone-library-preservation.json`.

Version **1.0.7 build 8** was signed, verified, installed, and launched successfully. Diagnostics are `build/page-motion-iphone-install-20261020.json` and `build/page-motion-iphone-launch-20261020.json`.

Version **1.1.0 build 11** was signed, verified, installed, and launched successfully on October 21, 2026. Diagnostics are `build/chat-iphone-install-20261021.json` and `build/chat-iphone-launch-20261021.json`.

Version **1.1.1 build 12** was signed, verified, and installed successfully on October 21, 2026. The launch request was blocked because the iPhone was locked; opening Leaf manually completes launch. Diagnostics are `build/compose-iphone-install-20261021.json` and `build/compose-iphone-launch-20261021.json`.

Version **1.2.0 build 13** was built in Release configuration, signed, verified, and installed successfully on October 21, 2026. Diagnostics are `build/ai-chat-iphone-verified-build-20261021.log` and `build/ai-chat-iphone-install-20261021.json`. Launch and live-provider verification are deferred; the owner can open Leaf and add an API key in AI settings.

The unique app identifier and development team are saved in `project.yml` and the generated Xcode project. Installation artifacts are `build/iphone-signing-validation-20261020.json`, `build/iphone-install-20261020.json`, and `build/iphone-launch-20261020.json`; the signed build log is `build/leaf-iphone-signed-build-20261020.log`. This is a development-signed installation; its profile expiration is recorded in the signing-validation artifact.

## Dependencies

[foliate-js](https://github.com/johnfactotum/foliate-js) (MIT), [zip.js](https://github.com/gildas-lormeau/zip.js) (BSD-3-Clause), and [fflate](https://github.com/101arrowz/fflate) (MIT) are vendored for offline use. Versions, the pinned foliate-js commit, download provenance, and archive checksums are recorded in `ThirdParty/dependencies.json`; upstream licenses are preserved in the resource tree and available in Settings.

This is an implemented first version, not an App Store submission. Signing, App Store metadata, distribution, cloud sync, OCR, and DRM services require separate setup or development.
