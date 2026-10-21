# Leaf for iOS

A native, offline ebook reader for iPhone and iPad, built with SwiftUI, WebKit, and PDFKit. Requires iOS 17+ and Xcode 16+.

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
- Persistent reading positions and per-book bookmarks, including a library-wide bookmarks tab.
- Day, paper, and night themes; three typefaces; adjustable font size and line spacing; paginated or vertical flow.
- Original short sample books in EPUB, PDF, FB2, and TXT.
- Cover thumbnails and embedded title/author metadata load during import; existing books with missing covers are checked automatically on launch.
- Native accessibility labels, Dynamic Type in app controls, iPad layouts, and landscape support.

## Storage and privacy

Library files live in `Documents/Leaf/Books`, cover images in `Documents/Leaf/Covers`, and the atomic JSON manifest in `Documents/Leaf/library.json`. The manifest holds metadata, favorites, reading positions, and bookmarks. Imported originals are never modified. Removing a book removes only Leaf's copy and saved places. Files can be shared through the book's context menu or copied using Finder file sharing. iOS may include Documents in device/iCloud backups; Leaf implements no cross-device sync, account, analytics, or server.

The local `leaf-reader://` scheme exposes only bundled reader resources and the currently opened book. Reader website data is nonpersistent. CSP blocks outbound network loads and embedded scripts; an additional sanitizer removes active markup. External book links are not opened automatically. A damaged manifest is preserved and reported rather than replaced.

## Tests

`LeafReaderTests` covers format aliases, duplicate imports, source preservation, invalid files, manifest corruption, bookmark persistence, and actual WebKit rendering of EPUB, FB2, TXT, MOBI, HTML, CBZ, plus PDFKit rendering/navigation/search. EPUB tests also search rendered content, navigate, bookmark, and reopen at the saved location. UI tests exercise the library, appearance controls, bookmarks, and library search.

The initial version was verified on October 20, 2026: **16 tests passed, zero failures or skips**, on iPhone 17 Pro Simulator running iOS 26.5 (13 unit/integration tests and 3 UI tests). The PDF UI test turns a page, closes the reader, and verifies that reopening restores that page. EPUB restoration checks that the start of the saved passage is visible; progress estimates can change with pagination. Debug UI tests use a separate temporary library and preferences suite for each test instead of changing the normal library or reading settings.

Version **1.0.1 build 2** passed **25 tests with zero failures or skips** on the same Simulator. Nine new metadata tests verify covers and authors before the first read, EPUB 2/3 declarations, SVG rasterization, XHTML cover pages with relative image paths, PDF thumbnails, persistence, existing-library updates, retry after failure, and deletion during extraction. Results: `build/CoverFixFinal-20261020.xcresult` and `build/cover-fix-test-summary-20261020.json`.

Version **1.0.2 build 3** balances the Leaf toolbar logo's horizontal padding and centers its icon and title within a 44-point row. The existing library/reader/bookmarks/appearance UI test passed, and screenshots confirmed the logo spacing at the top of the library and after scrolling. Results: `build/LeafTitleAlignmentFinal-20261020.xcresult` and `build/title-alignment-final-attachments/`.

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

The unique app identifier and development team are saved in `project.yml` and the generated Xcode project. Installation artifacts are `build/iphone-signing-validation-20261020.json`, `build/iphone-install-20261020.json`, and `build/iphone-launch-20261020.json`; the signed build log is `build/leaf-iphone-signed-build-20261020.log`. This is a development-signed installation; its profile expiration is recorded in the signing-validation artifact.

## Dependencies

[foliate-js](https://github.com/johnfactotum/foliate-js) (MIT), [zip.js](https://github.com/gildas-lormeau/zip.js) (BSD-3-Clause), and [fflate](https://github.com/101arrowz/fflate) (MIT) are vendored for offline use. Versions, the pinned foliate-js commit, download provenance, and archive checksums are recorded in `ThirdParty/dependencies.json`; upstream licenses are preserved in the resource tree and available in Settings.

This is an implemented first version, not an App Store submission. Signing, App Store metadata, distribution, cloud sync, OCR, and DRM services require separate setup or development.
