# Self-introduction — AuroraEvelynAria

> [中文版 · Chinese version](SELF-INTRO.zh-CN.md)

Written for [AIRI Discussion #33](https://github.com/moeru-ai/airi/discussions/33).

Hi — I'm **Jin Xi** (GitHub [`AuroraEvelynAria`](https://github.com/AuroraEvelynAria)), a
solo hobbyist developer. I've been building a self-hosted companion-AI project called
**Spring Haven (春日庭院)**, and I'd like to introduce myself because one part of it
overlaps with something AIRI is still working on: **long-term memory**.

## What I'm building

**Spring Haven** is a companion you host yourself: two characters with their own life
state, their own schedules and their own memory, living in a small 3D house you can walk
into.

| Part | Stack | Size |
|---|---|---|
| Client | Godot 4.7 / GDScript | **118 `.gd` files · 32,964 lines** |
| Backend | Python 3.11+ (aiohttp + SQLite/WAL) | **17 modules · 11,293 lines** |
| Tests | `unittest` | **20 files · 5,492 lines · 183 tests passing** |

From the fields listed in this thread, these parts are already running:

- **Speech Recognition** — ASR through an OpenAI-compatible `/audio/transcriptions`
  (Whisper) or Open-LLM-VTuber's `/asr`.
- **Speech Synthesis** — TTS through **GPT-SoVITS** or any OpenAI-compatible speech
  endpoint. I'm still not satisfied with "natural pitch variation + emotion", so if you
  have found something better I'd genuinely like to hear it.
- **Presentation** — a layered 2D portrait adapter: blink, gaze following, breathing,
  TTS-volume-driven lip sync, 7 expressions, and life-state-driven expression changes.
  Live2D itself is **not built** — the adapter exposes a minimal interface
  (`set_role / set_expression / set_thinking / set_body_state / speak / set_tts_mouth_level`)
  precisely so that adding Live2D means writing one more adapter instead of changing the
  protocol. **I haven't proven that path, though.**

## The part that might be useful to AIRI: 心织 (Heartloom)

AIRI's **Memory Alaya** is still WIP. I ran into the same problem from a different angle and
ended up building a separate memory module for it, called **心织 / Heartloom** — "weaving
time together into memory".

It is **not** a vector store with the chat history shoved back in. I designed it as a system
with a life cycle:

- **Memory ages the way a person's does.** Memories you bring up often stay sharp; ones you
  haven't touched for a long time fade into a blurry impression — **but they are never
  deleted.** Forgetting lowers recall weight; it never removes the row.
- **Anchored to world time, not wall-clock time.** Time that passes while the character is
  offline still lines up with her memory.
- **No raw numbers ever reach the context.** Every life-state float is bucketed into a
  qualitative description first — otherwise the numbers drag the persona around.
- **Long-running things get compressed** into summaries and milestones instead of piling up
  raw text.
- **Local SQLite only.** Nothing goes to the cloud.
- **A local keyword index, no cloud embedding.** Chinese uses 2–4 character n-grams, so
  recall works fully offline.
- **Recall is injected into a *dynamic* context block**, never into the stable system
  prefix — so the prefix cache stays intact (**76%+ measured hit rate**).
- **An explainable relation graph between memories.** Every edge returns why it exists, IDF
  suppresses words that are common across the whole store, and node / edge / per-node-degree
  caps keep it interactive after long runs.

It exposes `GET /memory/status` and `GET /memory/graph`.

The relationship with the life system is: **the life system owns "now", Heartloom owns "the
past".** State changes get written down, and they come back in the form of memory the next
time she speaks.

## What I haven't done

I'd rather be explicit about this than overstate anything:

- **Live2D** — adapter interface designed, not implemented.
- **VR, a full town, UGC** — designed, not built.
- **Week-key → world-week migration** in the memory time anchoring (issue #23) — designed,
  not finished.
- **Webcam face tracking** — still an idea.

The full feature list, marked section by section as `✅ shipped / 🔧 designed / 💭 idea`, is
in [`PROJECT.md`](PROJECT.md). That document is deliberately written so nothing is
overstated — including in the direction of underselling what is already working.

## What I think I can actually help with

My stack is GDScript + Python, not Vue/TypeScript, so I'm not going to pretend I can drop
into the AIRI frontend. Where I think I can be genuinely useful:

- **The memory layer / Memory Alaya** — this is the part I've spent the most time on by far,
  and the one I'd most like to compare notes on.
- **ASR / TTS adapters** — I've already wired both up against real providers, including
  GPT-SoVITS.
- **Backend test coverage** — 183 tests is the habit I'd bring with me.

If any of that is useful, I'm happy to work on it. And if you've done the Live2D side, I'd
really like to hear how you approached it.

**Looking forward to contribute.**
