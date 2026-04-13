# Vox

AI-powered translator and live subtitle engine for macOS, built on the Claude API.

Vox lives in your menu bar. Press **Cmd+T** to translate selected text from any app, or activate real-time subtitle translation for lectures, movies, and TV shows — all without leaving what you're doing.

## Features

### Instant Translation

**Cmd+T** anywhere on macOS. Select text, press the shortcut, get a streaming translation in a floating card. Vox auto-detects the source language and picks the right target based on your preferences — no manual switching between language pairs.

With **Smart Look Up** enabled, every translation is enriched with:

- **Dictionary** — part of speech, pronunciation (IPA), multiple definitions with example sentences
- **Context** — synonyms with register hints, collocations, false friends, cultural notes
- **Images** — visual references fetched from the web for nouns and concrete concepts

All tabs load in parallel so the card populates as fast as the data arrives.

### Live Subtitles

Real-time speech-to-text with optional AI translation, powered by macOS speech recognition and Claude.

**Transcribe** — pure transcription mode. Captures system audio and displays live captions in a floating overlay. No API calls for transcription itself — everything runs on-device.

**Study Mode** — transcription + sentence-by-sentence translation for lectures, talks, and educational content. Each sentence is detected by a custom boundary engine (punctuation, silence, word count overflow) and translated as a self-contained unit. The streaming translation window provides additional tabs:

- **Polish** — grammar and idiom refinement of the raw translation
- **Summary** — running bullet-point summary of the content so far
- **Study Notes** — structured notes with key concepts, definitions, and takeaways

**TV Mode** — optimized for movies and TV shows. Optionally name the show to generate a glossary of character names, slang, and in-universe terms via Claude. The glossary stays consistent across the entire session — "Vought" won't become "Vote" mid-episode. Includes ASR hint maps for common speech recognition mishearings.

### Translation Quality

- **Multi-turn context** — the last 5 translation pairs are injected into each request for vocabulary and phrasing consistency
- **Quality filter** — rejects hallucinations, untranslated output, and leaked reasoning; auto-retries with adjusted temperature
- **ASR cleanup** — pre-translation pass that corrects misheard proper nouns against the session glossary
- **Topic detection** — auto-identifies the subject matter and injects it as context so translations adapt to the domain
- **Model fallback chain** — Sonnet > Haiku > Opus, with automatic failover on rate limits (429/529)

### Supported Languages

English, Russian, Spanish, French, German, Chinese (Simplified), Japanese — for both transcription and translation targets. Auto-detect resolves the target intelligently using your primary and secondary language preferences.

### Radial Quick Menu

When **Cmd+T** is pressed with no text selected, a radial menu appears at your cursor with four actions:

| Action | Description |
|--------|-------------|
| **Look Up** | Translate from clipboard |
| **Transcribe** | Toggle live captions |
| **Study Mode** | Toggle lecture translation |
| **TV Mode** | Toggle cinema translation |

### History

Every translation and subtitle session is persisted locally. Sessions auto-save every 15 seconds, and each entry gets an AI-generated title for easy browsing. Export your history as JSON or CSV.

### Safari Extension

Translate entire web pages from Safari. The extension sends text to the native app for translation, preserving DOM structure so you can restore the original page at any time.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Menu Bar App (SwiftUI + AppKit)                │
│                                                  │
│  AppCoordinator ── HotkeyService (Cmd+T)        │
│       │                                          │
│       ├── TranslationViewModel (quick translate) │
│       │        └── ClaudeAPIService (streaming)  │
│       │        └── LanguageDetector (on-device)  │
│       │        └── ImageSearchService            │
│       │                                          │
│       ├── SubtitleService (live subtitles)       │
│       │        ├── LiveTranscriber (system audio)│
│       │        ├── SentenceBuffer (boundaries)   │
│       │        ├── SubtitleTranslator (Claude)   │
│       │        └── SubtitlePanel (AppKit overlay) │
│       │                                          │
│       ├── HistoryStore (SwiftData)               │
│       └── RadialMenuPanel                        │
│                                                  │
├──────────────────────────────────────────────────┤
│  Safari Extension                                │
│       └── SharedTypes + native messaging         │
└──────────────────────────────────────────────────┘
```

- **Streaming translation** via Server-Sent Events (URLSession.bytes)
- **Subtitle overlay** is pure AppKit (NSPanel) — no SwiftUI observation overhead
- **Sentence detection** uses a multi-signal approach: punctuation, silence duration, word count, and time overflow
- **Glossary generation** runs once per cinema session and feeds into both translation and ASR cleanup
- **API key** stored in system Keychain, never touches disk or network beyond Anthropic's API

## Requirements

- macOS 26.1+
- Xcode 26+
- Claude API key from [Anthropic](https://console.anthropic.com/)

## Setup

1. Clone the repo
2. Copy `Prompts.swift.example` to `Vox/Config/Prompts.swift` and add your prompt strings
3. Copy the same prompts structure to `Vox Extension/Prompts.swift` for the Safari Extension
4. Open `Vox.xcodeproj` and build
5. Launch the app, open Settings, paste your Claude API key

Prompt files are gitignored — your prompts stay private.

## Models

| Model | Used for |
|-------|----------|
| **Claude Haiku** | Streaming subtitles, ASR cleanup, topic detection, quick translation (default) |
| **Claude Sonnet** | Glossary generation, polish, summary, study notes, Smart Look Up |
| **Claude Opus** | Fallback when Sonnet is rate-limited during glossary generation |

## License

MIT
