# Listen: natural-sounding voices for Chinese and English

Status: proposal, 2026-10-23. Scope: the read-aloud ("Listen") feature shipped in 1.11/1.12 (`ReadAloudSession`, `ReaderAudioPlayer`, `read-aloud.js`, `PDFReadAloudSource`).

## 1. Why it sounds bad today

Everything below is from the current code, not speculation.

1. **Leaf always gets Apple's lowest-tier voice.** `SystemReadAloudSpeaker.speak` resolves the voice with `AVSpeechSynthesisVoice(language:)` ([ReadAloudSession.swift:56-59](../LeafReader/Services/ReadAloudSession.swift:56)). That initializer returns the *default* (compact) voice for the language, which is the small, robotic one. The `quality` property (`.default` / `.enhanced` / `.premium`) is never consulted, and the voice picker lists voices flat by language with no quality label, so even a user who downloaded "Tingting (Enhanced)" or "Ava (Premium)" gets the compact voice unless they find the exact entry.
2. **Mixed-language text is read by one voice.** `NLLanguageRecognizer` picks the dominant language of the whole 800-character passage. English terms inside a Chinese book are spelled out with Chinese phonemes, and Chinese names inside an English book are skipped or mangled.
3. **Every passage is a separate utterance with a hard stop.** `advance()` calls `speaker.stop()` then `load()` then `speak()`. The synthesizer is never pre-queued, so there is an audible gap and a prosody reset every ~800 characters, often mid-paragraph.
4. **No text conditioning.** Hyphenated line breaks, footnote markers, page numbers, and CJK full-width punctuation go to the synthesizer verbatim. The default voices do not pause correctly on `，。、；：` and read "1.5" and dates inconsistently.
5. **Ceiling of the engine.** Even with the fixes above, Apple's third-party TTS voices are not the Siri voices (Apple blocks those from apps) and are far from 2025-era neural narration. "Natural" in the sense the user means requires a neural model, on device or in the cloud.
6. **Background playback is off.** The settings footer says playback pauses in the background; `Info.plist` has no `UIBackgroundModes`. Any cloud engine needs background audio anyway, so this is folded into the plan.

## 2. Options evaluated

Requirement: Chinese (Simplified at minimum) and English both sound natural, code-switching works, text following (highlight the spoken passage) keeps working, cost is predictable, and the feature degrades gracefully offline.

### A. Apple on-device voices, used properly (free, days)

- Prefer `.premium` > `.enhanced` > `.default` among installed voices per language; show the quality tier in the picker; add a one-tap guide to Settings > Accessibility > Spoken Content > Voices to download Enhanced/Premium voices (no API exists to trigger the download or list undownloaded voices).
- Segment each passage into script runs (Han vs Latin) and queue one utterance per run with the matching voice; `AVSpeechSynthesizer` queues utterances back to back, which also removes the inter-passage gap when the next passage is pre-queued.
- Normalize text before speaking (join hyphen breaks, drop footnote superscripts, map CJK punctuation to pauses, keep sentence breaks for `willSpeakRangeOfSpeechString` mapping).
- Limits: still Apple voices. English Premium voices (Ava, Zoe, Evan, Nathan, Noelle) are acceptable for long listening; Chinese tops out at Enhanced (Tingting, Lili, Lilian), which is clear but flat. An iOS 26 regression where `AVSpeechSynthesisVoice(language:)` ignores the user's Spoken Content choice was reported on the Apple forums (FB20271264); selecting by identifier avoids it.

Verdict: do it first. It is the floor every other option falls back to.

### B. On-device neural model (Kokoro-82M via sherpa-onnx)

- Kokoro v1.1 zh+en: 103 voices, Chinese and English in one model, int8 build is ~215 MB on disk (`model.int8.onnx` 114 MB, `voices.bin` 54 MB, lexicons and espeak data). Apache-2.0. Output 24 kHz. English quality is close to cloud; Mandarin is good but with occasional tone errors on rare characters.
- Integration cost: sherpa-onnx is a C++ runtime shipped as an xcframework. Leaf currently has no binary dependencies at all (`ThirdParty/dependencies.json` vendors JS only), so this adds a build step, ~30 MB of app binary, and a 215 MB optional download.
- Risk: speed. The only published RTF numbers are Raspberry Pi 4 (RTF 3.2–7.6, i.e. several times slower than real time). An A17/A18 core is roughly 6–10× a Pi 4 core, so an iPhone should land somewhere between 0.3 and 1.0 RTF with 4 threads. That is usable with sentence-level prefetch but not proven, and sustained CPU at that level costs battery. Memory ~300–400 MB resident. No word timestamps from the runtime (sentence-level only).
- Alternatives checked: Supertonic 2 (66M, very fast) has no Chinese. Piper's Chinese voice is weak. CosyVoice, Fish-Speech, Index-TTS and Qwen3-TTS need a GPU-class budget and are not phone options.

Verdict: a time-boxed spike after the cloud path ships. Go/no-go on measured iPhone RTF < 0.5 and peak memory < 400 MB. If it passes, offer it as "Offline natural voice (215 MB download)".

#### Measured on the Mac (2026-10-23, M1 Pro, sherpa-onnx 1.13.8, Kokoro v1.1 zh+en)

Six samples (Chinese female/male, English US/British, two mixed passages) were synthesized and sent to the user for listening. Speed, as real-time factor (synthesis seconds per audio second; lower is faster):

| Model | Threads | Chinese RTF | English RTF |
|---|---|---|---|
| int8 (211 MB) | 1 | 0.67 | 0.68 |
| int8 | 4 | 0.75 | 0.74 |
| int8 | 8 | 0.77 | 0.77 |
| int8, CoreML provider | 4 | 0.81 | 0.78 |
| **fp32 (418 MB)** | **4** | **0.30** | **0.30** |
| fp32 | 1 | 0.93 | 0.95 |

Findings that change the plan:

- **int8 is the wrong build for Apple silicon.** The quantized model does not get faster with more threads and is 2.5× slower than fp32; onnxruntime's int8 convolution path is poorly optimized on ARM. The fp32 model must be the one shipped, which raises the download to ~420 MB (model 326 MB, voices 54 MB, dictionaries 14 MB, espeak data 18 MB, lexicons 14 MB).
- **Memory:** 704 MB peak resident for the fp32 run in Python (includes ~100 MB interpreter overhead). Expect 500–600 MB inside the app. That is fine on 8 GB iPhones (15 Pro and later) and risky on 4 GB devices.
- **iPhone estimate:** an A17/A18 performance core is in the same class as an M1 core, but the phone has 2 performance + 4 efficiency cores versus the 8 performance cores used here. Expect RTF 0.5–0.8 on the phone with fp32, so the 0.5 go/no-go is at the edge and must be measured on the device. First-sentence latency would be RTF × sentence length, about 2–4 s, hidden by sentence-level prefetch after the first one.
- **Runtime size:** the community Swift package `willwade/sherpa-onnx-spm` (tracks sherpa-onnx 1.13.8, iOS 13+) ships `onnxruntime.xcframework.zip` 65 MB and `sherpa-onnx.xcframework.zip` 30 MB; roughly 40–50 MB of app binary after thinning.
- **Voices:** v1.1 zh+en has 3 English voices (two American female, one British female) and 100 Chinese (55 female, 45 male). There is no English male voice; v1.0 (53 speakers) has them but weaker Chinese.
- **Phoneme gap:** sherpa-onnx logs "Skip unknown phonemes U+025A" (ɚ, the r-colored schwa) on English words outside the lexicon, so those syllables lose the final r sound. Fixable by adding a user lexicon or an ɚ→əɹ mapping before tokenization.
- **Determinism:** the int8 build produced a 34 s rendering of the Chinese passage with 1 thread versus 24.7 s with 4 threads (different pacing for identical input); fp32 was consistent at 24.8 s.

### C. Cloud TTS (best quality, per-character cost)

| Provider | zh / en quality | Timestamps for text following | Streaming | Price (list, approx.) | Setup friction | Notes |
|---|---|---|---|---|---|---|
| **OpenAI `gpt-4o-mini-tts`** | en very good; zh usable, reported accent | none | yes (chunked) | ~$12 per 1M audio tokens ≈ $0.015/min ≈ $0.90/hour | **none**: Leaf already stores an OpenAI key for the "Chat Completions compatible" provider | Shuts down 2027-01-06; successor is `gpt-realtime-2.1-mini` on the Realtime API (different transport). 13 voices, `marin`/`cedar` best. |
| **MiniMax `speech-2.8-hd` / `2.6-hd`** | zh best-in-class; en good | **word-level, including in streaming** (`subtitle_type: word_streaming`) | yes | third-party listings $60–100 per 1M chars HD; Chinese characters count double | API key | 10k chars/request, 40 languages, `language_boost`. Cantonese via `Chinese,Yue`. |
| **Azure Speech (Neural / DragonHD Flash)** | zh excellent (Xiaoxiao family); en excellent | word boundary events (SDK) | yes | ~$15 per 1M chars neural, 500k free/month; HD rate not published on cached pages | Azure portal, resource, region key (highest friction) | DragonHD Flash supports exactly zh-cn and en-US. Most mature SSML. |
| **Alibaba Qwen3-TTS-Flash** | zh excellent incl. dialects; en good | not documented | not documented for Flash | $0.10 per 10k chars = $10 per 1M | Model Studio key; Singapore vs Beijing keys are not interchangeable | 17 voices, 180 rpm. Cheapest strong-Mandarin option. |
| ElevenLabs Flash v2.5 / v3 | en best; zh adequate | character alignment endpoint | yes | $40–100 per 1M chars | API key | Expensive for whole books. |
| Google Chirp 3 HD / Gemini TTS | good both | no (Chirp), no (Gemini) | yes | $30 per 1M chars; Gemini by tokens | GCP project | No standout reason to pick. |

Cost reality check for a whole book: a 300k-character Chinese novel is roughly 6 hours of audio. OpenAI ≈ $5, Qwen ≈ $3, Azure ≈ $4.50, MiniMax HD ≈ $36–60 (double-counted characters). A 500k-character English novel (~9 hours): OpenAI ≈ $8, Azure ≈ $7.50, ElevenLabs ≈ $20–50. Cache every synthesized chunk on disk so re-listening, "previous passage", and speed changes never pay twice.

## 3. Recommendation

Ship in three layers; each is independently useful and the earlier ones are the fallback for the later ones.

**Phase 1: fix the system voice (1–2 days, no account, no cost).** Items A above. Expect a clear step up in both languages for anyone who downloads an Enhanced/Premium voice, and no more one-voice-for-mixed-text or passage gaps. Version bump only.

**Phase 2: "Natural voice" cloud engine (1–2 weeks). This is the real answer to the request.**

- Build a provider-agnostic `StreamedSpeechEngine` and launch with two providers:
  - **OpenAI** first, because every user who has already set up Leaf's OpenAI chat key gets natural voices with zero extra configuration, and it is the cheapest to integrate (same `KeychainChatCredentials`, same HTTPS profile pattern). Mark it "English-first". Plan the Realtime-API migration before 2027-01 as a known follow-up.
  - **MiniMax** second, labelled "Chinese-first", because it has the best Mandarin narration and delivers word timestamps while streaming, so text following stays exact instead of estimated.
  - Keep the provider table data-driven so Azure (if the user has a subscription) and Qwen3-TTS-Flash (cheapest strong Mandarin) can be added without touching the engine.
- Language routing: cloud models handle code-switching inside one request, so send the whole sentence; choose the provider/voice per book language (Leaf already knows the book language from the EPUB metadata and the passage detector) with a manual override.

**Phase 3: on-device neural spike (2–3 days, time-boxed).** Measure Kokoro v1.1 zh+en int8 through sherpa-onnx on the user's iPhone. Ship only if RTF < 0.5 and memory < 400 MB; otherwise keep Phase 1 as the offline tier.

## 4. Phase 2 design

Keep `ReadAloudSession` (locator cursor, bookmark, prefetch, history, follow-text) unchanged; it already separates "what to say" from "how to say it" through `ReadAloudSpeaking`. The new engine is a second implementation of that protocol plus a small amount of plumbing.

- **Chunking.** Split each 800-character passage into sentences at `.!?。！？；` with a 120–400 character target (cloud latency and cost are per request; shorter chunks start faster, longer chunks sound more connected). Chunk boundaries carry the UTF-16 offset into the passage so `progressed(NSRange)` keeps meaning.
- **Synthesis pipeline.** `AsyncStream` of chunks → provider request (PCM 24 kHz or Opus) → disk cache keyed by `(provider, voice, speed-independent, sha256(text))` → `AVAudioEngine` player node. Prefetch depth 2 chunks ahead across passage boundaries (the session already prefetches the next passage's text). Speed is applied with `AVAudioUnitTimePitch` at playback, so changing speed never re-synthesizes or restarts.
- **Text following.** With MiniMax word timestamps, map word → chunk offset exactly. With OpenAI, interpolate linearly by character count within the chunk, snapped to sentence starts; the current UI only highlights the passage, so sentence granularity is enough for v1.
- **Background audio.** Add `UIBackgroundModes: audio`, `MPNowPlayingInfoCenter` (title, chapter, cover) and `MPRemoteCommandCenter` (play/pause/skip = next/previous passage). Network fetches continue while the audio session is active. This also removes the "pauses in background" limitation for the system voice.
- **Fallback.** If a chunk request fails twice (offline, quota, 4xx), speak that chunk with the Phase 1 system voice and show a one-line status ("Network voice unavailable, using iPhone voice"); resume the cloud voice on the next chunk that succeeds. Never stop playback for a network error.
- **Settings.** In Listen settings: Voice engine {iPhone voice, Natural voice (OpenAI), Natural voice (MiniMax)}; voice list fetched per provider; a cost estimate line ("about $0.90 per hour of listening with this voice"); keys stored through the existing `ChatCredentialStore`; a disclosure that passage text is sent to the provider, mirroring the chat `sharePage` consent wording. OpenAI's usage policy requires telling users the voice is AI-generated; one line in the footer covers it.
- **Privacy/diagnostics.** Same rule as the catalog work: diagnostics never include text, keys, or URLs with tokens; log provider, chunk index, status code, and latency only.

## 5. Verification

- Unit: sentence chunker on Chinese, English, mixed, numbers, quotes, no-punctuation runs; cache key stability; offset mapping; speed changes not re-fetching; fallback switching mid-passage.
- Loopback: a `CatalogLoopbackServer`-style fixture TTS server that streams PCM (and MiniMax-style word timestamps) with injected failures, so the whole pipeline is exercised in `LeafReaderTests` without a key, the same pattern used for the Z-Library tests.
- UI (simulator, via coordinator lease): player states, settings picker, follow-text in Pages and Scroll, background/lock-screen controls, interruption (call/alarm) and route change (headphones unplugged).
- Listening matrix on the phone (manual, with the user): one Chinese novel chapter, one English chapter, one mixed technical text, dialogue-heavy text, a PDF page; score naturalness, tone errors, code-switching, pauses at paragraph ends. This is the acceptance test; automated checks cannot judge naturalness.
- Phase 3 spike reports RTF, memory, battery drain over 30 minutes, and first-audio latency on the user's device.

## 6. Decisions needed from you

1. Launch providers: OpenAI + MiniMax as proposed, or Azure/Qwen instead of MiniMax? (MiniMax is the best Mandarin and the only one with streaming word timestamps; Qwen is 6–10× cheaper; Azure needs an Azure subscription.)
2. Is a 215 MB optional download acceptable for an offline natural voice, if the Phase 3 spike passes?
3. Budget comfort: cloud narration costs roughly $1–10 per book depending on provider; the plan shows a per-hour estimate in settings, but there is no hard cap unless you want one (for example, confirm before synthesizing past N characters per day).

## Sources

- Apple forums: Siri voices unavailable to apps ([thread 682438](https://developer.apple.com/forums/thread/682438)); no API to list undownloaded voices ([thread 758460](https://developer.apple.com/forums/thread/758460)); iOS 26 `AVSpeechSynthesisVoice(language:)` regression ([thread 804648](https://developer.apple.com/forums/thread/804648)); voice quality tiers ([Ben Dodson](https://bendodson.com/weblog/2024/04/03/using-your-personal-voice-in-an-ios-app/)).
- Kokoro via sherpa-onnx: [model list and Pi 4 RTF](https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/kokoro.html), [v1.1 zh+en int8 files](https://huggingface.co/csukuangfj/kokoro-int8-multi-lang-v1_1/tree/main), [iOS spike repo](https://github.com/a2sandoval/kokoro-tts-ios), [Supertonic 2 languages](https://huggingface.co/csukuangfj2/sherpa-onnx-supertonic-tts-int8-2026-03-06).
- OpenAI: [TTS guide](https://developers.openai.com/api/docs/guides/text-to-speech) (deprecation 2027-01-06, streaming, no timestamps), [model pricing](https://developers.openai.com/api/docs/models/gpt-4o-mini-tts).
- MiniMax: [T2A API reference](https://platform.minimax.io/docs/api-reference/speech-t2a-http) (models, `subtitle_type: word_streaming`, 10k chars), third-party pricing ([Segmind](https://www.segmind.com/models/minimax-speech/pricing), [invideo](https://invideo.io/blog/minimax-ai-voice-models/)).
- Azure: [HD voices](https://learn.microsoft.com/en-my/Azure/ai-services/speech-service/high-definition-voices) (DragonHD Flash zh-cn/en-US, word boundary), [pricing page](https://azure.microsoft.com/en-us/pricing/details/speech/), [third-party rate tracker](https://www.developersdigest.tech/models/speech/azure).
- Alibaba: [Qwen3-TTS-Flash](https://www.alibabacloud.com/help/en/model-studio/qwen3-tts-flash) (regions, $0.10/10k chars, 17 voices).
- ElevenLabs: [with-timestamps endpoint](https://elevenlabs.io/docs/api-reference/text-to-speech/convert-with-timestamps), [OpenRouter Flash v2.5 listing](https://openrouter.ai/elevenlabs/eleven-flash-v2.5).
- Google: [Text-to-Speech pricing](https://cloud.google.com/text-to-speech/pricing).
- Overviews consulted: [Qwen-TTS vs others](https://tomodahinata.com/en/blog/qwen-tts-vs-elevenlabs-openai-google-azure-tts-comparison), [best TTS APIs 2026](https://www.speechmatics.com/company/articles-and-news/best-tts-apis-in-2025-top-12-text-to-speech-services-for-developers).
