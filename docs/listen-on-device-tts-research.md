# On-device natural voices for Listen: what others have done

Research notes, 2026-10-23. Question: is there a good *local* (on-iPhone) solution that reads Chinese and English naturally and smoothly, and how have other apps built it? No local experiments in this document; everything is from shipped apps, their developers, and community reports. Companion to `listen-natural-voice-plan.md`.

## 1. Short answer

- **Nobody ships natural-sounding on-device Chinese narration on iPhone today.** Every shipping iOS "AI voice" reader with offline Chinese uses **Kokoro-82M v1.0** (KO Reader, the Soniqo speech-swift engine, On-Device AI). Chinese users rate Kokoro's Chinese as clear but mechanical (a May 2026 Chinese evaluation gives it MOS 3.9/5 versus 4.7 for CosyVoice 2). The newer **Kokoro v1.1-zh** (100 Chinese voices, Chinese-first training) is "much better than v1.0 but still has word-break and heteronym errors" according to Chinese testers, and **no iOS app ships it yet**.
- **The one app that ships a genuinely natural Chinese model on-device (Echovo, Qwen3-TTS via MLX) is not real-time**: a 1.9 GB download per model, A17 Pro or newer, and a measured real-time factor of about 4 on an iPhone 17 Pro Max, i.e. four seconds of compute per second of speech. It is a text box, not a reader, and its App Store rating is 3.3 with crash complaints.
- **The models that sound natural in Chinese (CosyVoice 2/3, Qwen3-TTS, Fish S2, IndexTTS2) are LLM-based and need GPU-class compute.** Their official iOS SDKs (Alibaba CosyVoice iOS SDK) call the cloud. Phone-sized Chinese-capable models are Kokoro (82M) and the brand-new MOSS-TTS-Nano (100M, April 2026), which has no shipped app or published quality score yet.
- So the realistic local ceiling for Chinese right now is **Kokoro v1.1-zh**, which Leaf would be the first iOS reader to ship. For "natural and smooth" Chinese beyond that, the honest answer is a cloud voice (MiniMax, Qwen3-TTS-Flash, Azure) with the on-device voice as the offline fallback, as in the earlier plan.

## 2. Shipping iOS apps with on-device neural voices

| App | Engine / runtime | Chinese | Background playback | Size, requirements | Notes |
|---|---|---|---|---|---|
| **KO Reader** ($3.99) | Kokoro v1.0, "optional CoreML acceleration" | **Mandarin yes** (9 languages, 53 voices = v1.0 voice set) | "Background audio" + CarPlay, plus **chapter pre-generation** | 28 MB app + 350 MB model on first launch; iOS 18.6 | Closest existing product to what Leaf wants. m4a/m4b export, pronunciation dictionary. |
| **Sandbook** (free) | Kokoro v1.0 on **MLX (GPU)**, eSpeak-NG phonemes on CPU, weights bundled | No (6 languages) | **Live reading pauses when the screen locks**; only a pre-rendered chapter plays locked. Developer: "Apple forbids apps that use high GPU/VRAM from running in the background." | 281 MB; iPhone 12+/A14, iOS 18.2 | Sentence-by-sentence synthesis, playback starts after the first sentence, heard passages cached, speed via phoneme durations. |
| **Local Narrator** | Kokoro on Apple Neural Engine (CoreML) | No (EN, ES beta) | Yes, lock-screen controls | Neural voices need iPhone 15+ | Falls back to Apple system voices. |
| **Éist, Play Text, Neuvoice, VoiceMake, Local TTS, Narrate, BookNPC** | Kokoro (some add Piper or Supertonic 3) | No, or Chinese falls back to the system voice (BookNPC) | Varies | 200–480 MB | BookNPC explicitly: AI voices English only, other languages use the device voice. |
| **On-Device AI** ($49.99 lifetime) | Kokoro is one of six TTS options | Claimed; a Zhihu reviewer could not download it in China, quality unverified | ? | 1.9 GB | General local-AI suite, English UI. |
| **Echovo** ($4.99) | **Qwen3-TTS via MLX** (GPU + ANE), Base and CustomVoice variants | **Yes**, 11 languages; a Zhihu reviewer called the Chinese "good" | Not mentioned | 1.9 GB per model, iOS 17, A17 Pro+ recommended | RTF ≈ 4.07 on iPhone 17 Pro Max for a cloned clip (heise). Text only. 3.3 stars, crash reports. The reviewer's model download failed 30–40 times. |
| **VocaRead** (one-time purchase) | sherpa-onnx with **Piper** voices | Not stated | Yes | — | Developer switched from `AVSpeechSynthesizer` "because the voices sounded way too robotic." Piper's Chinese voice is weak. |
| **Readest** (open source) | System voice offline; **Edge TTS (cloud)** by default when online; optional OpenAI-compatible custom server (e.g. a Kokoro server) | Yes via Edge/cloud | Yes | — | A well-known open-source reader chose cloud neural voices as the default and left on-device to the system voice. |

Chinese-market apps (微信读书, 番茄, 听书神器, Aurader) use cloud AI narration; a Zhihu writer who spent a day looking for an *offline Chinese AI audiobook app* on iPhone in 2026 concluded none met the bar and recommended relaxing the offline requirement.

## 3. Candidate models for Chinese + English on a phone

| Model | Size | Chinese | Runs on iPhone today | Quality evidence | Verdict |
|---|---|---|---|---|---|
| **Kokoro-82M v1.0** | 82M, ~170–350 MB | 8 Mandarin voices | Yes: CoreML (speech-swift: 0.08 RTF, 676 MB peak on iPhone 16 Pro), MLX Swift (3.3× real time on iPhone 13 Pro), sherpa-onnx CPU | Chinese MOS 3.9/5 (声网, May 2026); Chinese testers: "clear but mechanical", English much better | Proven on iOS, Chinese is the weak side. |
| **Kokoro-82M v1.1-zh** | 82M, ~420 MB fp32 (int8 is slow on Apple CPUs) | 100 Chinese voices, 3 English (all female) | Not shipped by any iOS app; sherpa-onnx has the Chinese frontend (jieba + lexicon) in C++; CoreML/MLX ports would need a Swift Chinese G2P | "v1.1-zh much better than v1.0, still 断字/多音字 errors" (Zhihu); author calls it an early release | Best *available* on-device Chinese; Leaf would be first on iOS. |
| **Qwen3-TTS 0.6B** | 0.6B, 1.7–2.4 GB quantized, ~2 GB RAM | Excellent, incl. dialects | Only via MLX in Echovo; RTF ≈ 4 on iPhone 17 Pro Max; MLX GPU cannot run in background; A17 Pro+ | Top-tier Chinese by every 2026 review | Not real-time on a phone. Pre-render only, foreground only. |
| **CosyVoice 2/3 0.5B, IndexTTS2, Fish S2** | 0.5–4B | Excellent | No iOS runtime beyond experimental MLX on Mac; Alibaba's CosyVoice iOS SDK is cloud | Chinese MOS 4.7 for CosyVoice 2 | Cloud class. |
| **MOSS-TTS-Nano** (OpenMOSS, Apr 2026) | 100M (+20M tokenizer) | Chinese + English + 18 more, zh/en mixing | CoreML conversion exists (speech-swift, `aufklarer/MOSS-TTS-Nano-100M-CoreML`), ONNX runs on one M4 core; Android ONNX sample; no iPhone benchmark published | No MOS or listening comparison published; "good enough real-time product quality" per authors | The only new phone-sized Chinese candidate. Unproven, license file not yet published upstream. |
| **Supertonic 3** | 99M | **No Mandarin** (31 languages, zh absent; unofficial community preview only); vendor reportedly dissolving | CoreML 0.15 RTF on iPhone 16 Pro | Slightly less natural than Kokoro (Software Mansion) | Out. |
| **Kyutai Pocket TTS** | 100M | No (6 European languages; community Chinese fork, unverified) | CPU real-time | — | Out. |
| **NeuTTS Air, KittenTTS, Piper** | 15–500M | No / weak | Yes | — | Out for Chinese. |
| **Apple system voices** | — | Enhanced Tingting/Lili only; Siri voices blocked for apps | Yes | Zotero team: "extremely bad and antiquated in general" | Fallback only (Phase 1 of the plan still worth doing). |

## 4. Engineering lessons from the shipped apps

1. **Synthesize sentence by sentence and prefetch** (Sandbook, KO Reader, Software Mansion's ExecuTorch TTS). Playback starts after the first sentence; a chapter is pre-rendered in the background of the foreground session.
2. **GPU inference stops when the app leaves the foreground.** iOS denies Metal work to backgrounded apps (MLX apps hang or crash on iOS 26 when backgrounded mid-job; Sandbook's lock-screen limitation). CoreML on the Neural Engine is also reported unreliable in the background; the community recommendation for audio-session work is `computeUnits = .cpuOnly`. Practical pattern: **pre-render whole chapters while the screen is on, play files in the background** (KO Reader's "chapter pre-generation"), or keep a CPU-only path for background continuation.
3. **Runtime choice on iPhone:** CoreML/ANE is 2–3× faster than MLX Swift for Kokoro and survives 4 GB phones (MLX gets killed on 30 s clips on an iPhone 12 Pro). sherpa-onnx CPU is the slowest but has the Chinese text frontend built in and works in the background. int8 ONNX is slower than fp32 on Apple CPUs.
4. **Chinese is expensive for Kokoro's tokenizer:** 42 Chinese characters ≈ 545 phoneme tokens versus ≈ 42 for English, so Chinese chunks must be short (the CoreML builds bucket input at ≤ 128 phonemes and output at 5/10/15 s).
5. **Device floor:** A14/iPhone 12 for Kokoro on GPU/ANE; A17 Pro for LLM-class TTS. Peak memory 400–700 MB for Kokoro, ~2 GB for Qwen3-TTS 0.6B.
6. **Downloads, not bundles:** 170–420 MB models are downloaded on first use with resume support (Echovo's non-resumable 1.9 GB download is its most-cited failure).
7. **Keep the system voice as a fallback** (Local Narrator, BookNPC) for unsupported languages and old devices.

## 5. What this means for Leaf

- A fully local, natural-and-smooth Chinese narrator does not exist on iPhone yet; the state of the art on-device is Kokoro, and Leaf would be ahead of every shipping reader by using **v1.1-zh** instead of v1.0.
- If on-device Chinese is the priority: build Kokoro v1.1-zh with sentence streaming, chapter pre-rendering, CPU fallback for background, and the system voice as a floor. Expect Chinese that is clearly better than Apple's voices but still short of cloud narration (occasional wrong heteronyms and breaks).
- If "natural and smooth" is the priority: cloud narration for Chinese (MiniMax, Qwen3-TTS-Flash, Azure) with on-device Kokoro for English and offline use, which is what the plan already proposes.
- Worth a short listening check before deciding: **MOSS-TTS-Nano** (phone-sized, Chinese-first lab, CoreML build exists). It is the only candidate that could change the on-device answer, and nobody has published how it sounds.

## Sources

Shipping apps: [KO Reader](https://apps.apple.com/us/app/ko-reader/id6761862109), [Sandbook](https://sandbook.app/), [Every Kokoro TTS app for iPhone (Sandbook, Sept 2026)](https://sandbook.app/blog/kokoro-tts-apps-for-iphone), [Echovo App Store](https://apps.apple.com/app/id6758773035), [heise on Echovo](https://heise.de/-11172097), [VocaRead developer write-up](https://www.indiehackers.com/product/vocaread), [Readest Listen docs](https://readest.com/docs/listen), [Zhihu: 为了找一个离线中文AI听书App，我折腾了一整天](https://zhuanlan.zhihu.com/p/2013204596554740834), [Vocello/QwenVoice](https://www.sourcepulse.org/projects/29000857), [BookNPC](https://www.booknpc.com/).

Runtimes and ports: [speech-swift (Soniqo)](https://github.com/soniqo/speech-swift), [its iPhone 16 Pro benchmarks](https://github.com/soniqo/speech-swift/blob/main/docs/benchmarks/ios-coreml.md), [Soniqo Kokoro guide (zh voices)](https://soniqo.audio/zh/guides/kokoro), [Kokoro CoreML vs MLX on iPhone](https://huggingface.co/mattmireles/kokoro-coreml), [mlalma/kokoro-ios (MLX Swift)](https://github.com/mlalma/kokoro-ios), [Otosaku/KokoroTTS-iOS](https://github.com/Otosaku/KokoroTTS-iOS), [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), [Software Mansion ExecuTorch TTS](https://docs.swmansion.com/react-native-executorch/docs/extensions/text-to-speech), [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift), [Qwen3-TTS pure C engine benchmarks](https://github.com/gabriele-mastrapasqua/qwen3-tts).

Background limits: [whisper.cpp iOS 26 background GPU crash](https://github.com/ggml-org/whisper.cpp/issues/3531), [Apple forums: Neural Engine in background](https://developer.apple.com/forums/thread/831934), [Apple forums: GPU permission in background](https://developer.apple.com/forums/thread/765376).

Models: [Kokoro v1.1-zh](https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh), [Zhihu on v1.1-zh](https://zhuanlan.zhihu.com/p/26741934462), [声网 2026 TTS evaluation (MOS)](https://www.shengwang.cn/blog/blogdetail/2026-TTS-evaluation/), [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS), [MOSS-TTS-Nano](https://github.com/OpenMOSS/MOSS-TTS-Nano/blob/main/README_zh.md), [MOSS-TTS-Nano CoreML guide](https://soniqo.audio/guides/moss-tts-nano), [Supertonic 3 Mandarin discussion](https://huggingface.co/Supertone/supertonic-3/discussions/27), [Kyutai Pocket TTS](https://github.com/kyutai-labs/pocket-tts), [Alibaba CosyVoice iOS SDK (cloud)](https://help.aliyun.com/en/model-studio/cosyvoice-ios-sdk), [Zotero forum on Apple voices](https://forums.zotero.org/discussion/133424/read-aloud-ios-three-voice-related-issues).
