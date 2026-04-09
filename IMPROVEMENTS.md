# Vox — Improvement Ideas

Research date: 2026-04-09
Based on analysis of 20+ open-source projects and competitor apps.

Constraint: NO local LLM/ML models (too heavy for MacBook).

---

## Quick Wins (1-2 hours, high impact)

### 1. Prompt Caching
**Status**: [x] Rejected (2026-04-09) — caching works but degrades translation quality
**Files**: `ClaudeAPIService.swift`
**Result**: Implemented and tested. Cache hits confirmed (4853 tokens cached, reads working). However, the ~4300-token reference block needed to hit Haiku's 4096 minimum overwhelms the 50-token translation prompt, causing worse translations (e.g. "Homelander" → "Домолендер" instead of "Хоумлендер"). Rolled back. Not viable unless prompts are naturally large enough.

Claude API supports prefix caching. Same system prompt on every call = 90% discount on input tokens + faster TTFT.

**Problem**: current system prompt is ~100-200 tokens. Minimum for caching:
- Haiku 4.5: 4,096 tokens
- Sonnet 4/4.5: 1,024-2,048 tokens

**Implementation**:
- Add `cache_control: {"type": "ephemeral"}` to API requests
- Expand system prompt to hit cache threshold — add translation examples, quality rules, edge case handling
- TTL 5 min default — stays warm during continuous subtitles
- Check response for `cache_read_input_tokens` > 0 to verify it's working

**Source**: [Anthropic Prompt Caching docs](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)

---

### 2. Effort Low + Thinking Disabled
**Status**: [ ] Not started
**Files**: `ClaudeAPIService.swift`

For short translation (5-15 words), Claude's thinking overhead is unnecessary.

**Implementation**:
```json
{"thinking": {"type": "disabled"}, "output_config": {"effort": "low"}}
```

Add these params to translation requests (both draft and final). Do NOT add to polish/summarize/study notes — those benefit from thinking.

**Source**: [Anthropic Latency Reduction guide](https://platform.claude.com/docs/en/test-and-evaluate/strengthen-guardrails/reduce-latency)

---

### 3. Temperature Tuning
**Status**: [x] Done (2026-04-09)  
**Files**: `ClaudeAPIService.swift`, `SubtitleTranslator.swift`
**Result**: Translations stable and deterministic, no reasoning leaks or hallucinations. Topic detection correctly identified "The Boys superhero dark comedy TV series" from dialogue. Also fixed topic detection prompt — added "always give your best guess" + refusal filter, bumped topic temp to 0.3 (0.1 was too conservative, model refused to guess).

**Final values**:
- Translation (draft + final + cleanup): `temperature: 0.2`
- Topic detection: `temperature: 0.3`
- Polish/Summarize/Study Notes: `temperature: 0.7`
- `buildRequest` (Safari extension): `temperature: 0.2`

**Source**: llm-subtrans uses 0.3 base + 0.1 increment on retry

---

### 4. Quality Filter Heuristics (no LLM needed)
**Status**: [x] Done (2026-04-09)
**Files**: `SubtitleTranslator.swift`
**Result**: Added `validateTranslation()` with 5 heuristics (empty, identical to original, leaked reasoning, 3x length hallucination, >60% same words). On rejection: silent retry with temperature +0.1 (max 1). Double rejection returns empty string — SubtitleService skips display. Extracted `executeTranslationRequest` for clean retry support.

Simple checks on translation result before displaying:

```
REJECT if:
- translation == original (not translated)
- contains "I'll translate" / "Here's the translation" (leaked reasoning)
- length > 3x original (hallucination)
- >60% same words as original (not translated)  
- empty or just whitespace/punctuation
```

On rejection: silent retry with temperature +0.1 (max 1 retry).

**Source**: realtime-subtitle hallucination filter, llm-subtrans retry strategy

---

## Medium Tasks (3-6 hours, high impact)

### 5. Extended Translation Context (3-5 previous turns)
**Status**: [ ] Not started
**Files**: `SubtitleTranslator.swift`

Current: sends 1 previous pair (original + translation).
Proposed: send 3-5 previous pairs as message history.

**Why**: names, terms, style stay consistent across sentences. Especially important for lectures (terminology) and shows (character names).

**Token cost**: ~200-500 extra input tokens per call. With prompt caching, this is negligible.

**Source**: llm-subtrans, LLPlayer both use multi-turn context

---

### 6. Glossary Injection After Topic Detection
**Status**: [ ] Not started
**Files**: `SubtitleTranslator.swift`

After topic detection fires (3-5 sentences in), make one extra Haiku call:
"From these sentences, extract key proper nouns, terms, and their translations as a glossary."

Cache result. Inject into system prompt: `Key terms: Stark=Старк, neural network=нейросеть, ...`

**Why**: prevents inconsistent name/term translation across session.

**Source**: llm-subtrans substitution system, though theirs is manual. This automates it.

---

### 7. Dual-Tier Display in Cinema Mode (tentative + confirmed)
**Status**: [ ] Not started
**Files**: `SubtitlePanel.swift`, `LiveTranscriber.swift`

**Problem**: cinema mode shows nothing until final translation arrives. User sees blank screen during speech.

**Implementation**:
- Show volatile ASR text in dim/small font (14pt, 30% opacity) as "preview"
- When translation arrives — smooth transition to translated text
- Optional: LocalAgreement filter on Apple ASR partials — compare consecutive results, only show stable prefix

**Source**: SimulStreaming/WhisperLiveKit dual-track display, LiveCaptions confirmed/tentative pattern

---

### 8. Hallucination Filter + Auto-Retry
**Status**: [ ] Not started
**Files**: `SubtitleTranslator.swift`

Extends item #4 with retry logic:
- On quality filter rejection: retry once with temperature +0.1
- On retry failure: show original (untranslated) text rather than garbage
- Log failures for debugging

**Source**: llm-subtrans retry with temperature bump, realtime-subtitle hallucination detection

---

## Larger Tasks (half day+, medium-high impact)

### 9. Compressed Context (Rolling Summary)
**Status**: [ ] Not started
**Files**: `SubtitleTranslator.swift`

Instead of sending N raw previous translations (expensive), periodically generate a compressed summary.

**Implementation**:
- Every 5 translated sentences: one Haiku call to summarize context (1-2 lines)
- Rolling window of up to 10 summaries x 240 chars = ~2400 chars max
- Inject into system prompt alongside 1 immediate previous pair
- Covers narrative arc without token bloat

**Why this beats raw context**: 10 summaries cover ~50 sentences of history in ~400 tokens vs ~2500 tokens for 5 raw pairs.

**Source**: llm-subtrans scene/summary tags architecture

---

### 10. Shorter Sentence Boundaries
**Status**: [ ] Not started
**Files**: `SentenceBuffer.swift`

Current overflow: 18 words. Standard subtitle: 8-12 words.

**Implementation**:
- Reduce hard overflow to 12-14 words
- Add soft boundary: comma or conjunction ("and", "but", "so") at 8+ words → split
- Test impact on translation quality (shorter = usually better for Claude)

**Caution**: NEVER touch the core chunk batching/refine/overlap trimming logic — it's perfectly tuned.

---

### 11. Scene-Aware Splitting
**Status**: [ ] Not started
**Files**: `SentenceBuffer.swift`, `SubtitleTranslator.swift`

**Implementation**:
- Pause >5 sec → hard boundary, reset draft counter
- On topic change detection → clear translation context (previous pairs, glossary)
- Prevents context "bleed" between different segments

**Source**: llm-subtrans scene detection via temporal gaps (their threshold: 30 sec for pre-recorded, we need shorter for live)

---

### 12. Progressive Translation Animation
**Status**: [ ] Not started
**Files**: `SubtitlePanel.swift`

When draft→final replacement happens in lecture mode:
- If texts differ <30%: word-by-word morph animation
- If texts differ >30%: smooth fade transition instead of hard swap

**Why**: reduces "jarring" text replacement that makes users lose reading position.

---

### 13. Translation Caching
**Status**: [ ] Not started
**Files**: `SubtitleTranslator.swift`

LRU cache (~100 entries) for exact-match normalized text → cached translation.

**Why**: lectures repeat phrases ("as I mentioned", "basically", standard intros). Instant translation + saves API calls.

**Implementation**: normalize (lowercase, trim, remove extra spaces) → check cache → hit = instant, miss = API call → store result.

---

### 14. Sonnet Option in Cinema Mode
**Status**: [ ] Not started
**Files**: `SubtitleTranslator.swift`, `AppSettings.swift`

Add user setting: "Translation Quality" — Fast (Haiku) vs Quality (Sonnet).
Default = Fast (current behavior). Quality adds ~0.5-1s latency but noticeably better for idioms, humor, colloquial speech.

---

### 15. Prefill Assistant Response
**Status**: [ ] Not started
**Files**: `ClaudeAPIService.swift`

For Haiku 4.5 / Sonnet 4.5: add empty assistant message to skip preamble.
Note: deprecated on Claude 4.6+. Short-term optimization only.

---

### 16. ASR Preview in Cinema Mode
**Status**: [ ] Not started
**Files**: `SubtitlePanel.swift`, `SubtitleService.swift`

Same as #7 but specifically: pipe volatile ASR words to SubtitlePanel as dim preview text even when translation is pending. User sees the system is "listening" and can read the original while waiting for translation.

---

## Research Sources

### Direct Competitors (macOS)
- **Transcrybe** — [App Store](https://apps.apple.com/us/app/transcrybe-live-translation/id6670778781) — Apple Translation (~85%), closest form factor
- **Transync AI** — [transyncai.com](https://www.transyncai.com/) — claims <0.5s delay, voice output
- **realtime-subtitle** — [GitHub](https://github.com/Vanyoo/realtime-subtitle) — macOS overlay, OpenAI API translation
- **realtime-audio-transcriber** — [GitHub](https://github.com/loop-rogue/realtime-audio-transcriber) — Whisper + Ollama

### Key Open-Source Projects
- **whisper.cpp** — [GitHub](https://github.com/ggml-org/whisper.cpp) — ~36k stars, C++ Whisper, Metal
- **faster-whisper** — [GitHub](https://github.com/SYSTRAN/faster-whisper) — ~13k stars, 4x faster Whisper
- **WhisperKit** — [GitHub](https://github.com/argmaxinc/WhisperKit) — ~5.9k stars, Swift CoreML
- **Buzz** — [GitHub](https://github.com/chidiwilliams/buzz) — ~13k stars, desktop transcription
- **SeamlessM4T** — [GitHub](https://github.com/facebookresearch/seamless_communication) — ~11k stars, Meta e2e translation
- **WhisperLiveKit** — [GitHub](https://github.com/QuentinFuxa/WhisperLiveKit) — SimulStreaming SOTA 2025
- **whisper_streaming** — [GitHub](https://github.com/ufal/whisper_streaming) — LocalAgreement policy
- **llm-subtrans** — [GitHub](https://github.com/machinewrapped/llm-subtrans) — LLM subtitle translation (GPT/Claude/Gemini)
- **LLPlayer** — [GitHub](https://github.com/umlx5h/LLPlayer) — media player with Claude/GPT translation
- **LiveCaptions-Translator** — [GitHub](https://github.com/SakiRinn/LiveCaptions-Translator) — piggybacks on Win LiveCaptions
- **RTranslator** — [GitHub](https://github.com/niedev/RTranslator) — ~9.7k stars, offline Android, NLLB+Whisper
- **obs-localvocal** — [GitHub](https://github.com/royshil/obs-localvocal) — OBS plugin, whisper.cpp + CTranslate2
- **RealtimeSTT** — [GitHub](https://github.com/KoljaB/RealtimeSTT) — best OSS STT library for pipelines
- **StreamSpeech** — [GitHub](https://github.com/ictnlp/StreamSpeech) — simultaneous S2ST, ACL 2024
- **Speech-Translate** — [GitHub](https://github.com/Dadangdut33/Speech-Translate) — Whisper + free translation APIs
- **Synthalingua** — [GitHub](https://github.com/cyberofficial/Synthalingua) — streams + translation + vocal isolation

### Curated Lists
- [awesome-whisper](https://github.com/sindresorhus/awesome-whisper)
- [Awesome-Whisper-Apps](https://github.com/danielrosehill/Awesome-Whisper-Apps)
