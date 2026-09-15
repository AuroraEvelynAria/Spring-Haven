# Spring Haven — Main Features

> [中文版 · Chinese version](PROJECT.zh-CN.md)

This document describes what Spring Haven is, what is **actually built**, what is
**designed but not built**, and what is still **just an idea**. Every section is marked
so nothing is overstated:

**✅ shipped ｜ 🔧 designed / planned ｜ 💭 longer-term idea**

---

## 1. Local AI life simulation

The characters live freely inside a fixed area and keep their own schedules. They reach
out to the user through a "phone" — voice calls or text messages — and occasionally take
photos with it, capturing what's happening in the 3D space. (Sometimes they hold the
phone upside down.)

> ✅ **Shipped**: characters **message you proactively** (offline messages are generated
> by the character's own LLM with her stable persona prompt — never faked by local
> templates), and they **take photos inside the 3D scene and send them to you**.
> Schedules are laid out hour by hour.
>
> 💭 **Still an idea**: the phone itself as a device, voice calls, and text messages.

## 2. A built-in terrain editor

Lets the user customise the geography of the area the house sits in, and the interior
decoration — down to where the wall switches are and which way each piece of furniture
faces.

> ✅ **Shipped**: a **2D top-down layout editor** — drag-and-drop anchors for the places
> characters can walk to, an icon picker for each anchor, saved to `user_data/house_layout.json`
> (`godot/scenes/HouseEditor/HouseLayoutEditor.gd`, 391 lines).
>
> 🔧 **Planned** (Phase 3, GridMap-based): editing the geography itself.
>
> 💭 **Still an idea**: the "wall switch positions / furniture orientation" detail — that is
> my design intent, not built yet.

## 3. 2D interaction — the cheapest way to spend time with them

The user can enable a non-static character display mode: with **Live2D** you can talk to
the character face to face, and the program does not keep the 3D space rendered — it saves
and shuts it down to save performance. If the user has a webcam, the character's eyes
follow the user's face and she reacts accordingly.

> ✅ **Shipped**: a **layered portrait adapter** (blink, gaze following, breathing,
> TTS-volume-driven lip sync, 7 expressions, life-state-driven expression changes). The 2D
> stage and the 3D scenes are **separate scenes**, so nothing 3D is rendered while you're
> in 2D.
>
> 🔧 **Not built**: Live2D itself.
>
> 💭 **Still an idea**: webcam face tracking.

On "driving Live2D from the LLM sounds hard" — my approach is to **keep the LLM away from
the presentation layer entirely**. The portrait adapter exposes only a minimal surface:

```text
set_role(role_id)
set_expression(expression)
set_thinking(active)
set_body_state(state)
speak(text, duration)
set_tts_mouth_level(level)
```

The LLM emits constrained semantic signals; the adapter handles the performance.
Integrating Live2D then means adding one adapter that implements the same interface — not
changing the Core protocol, and the layered portrait rig stays as a shippable fallback.

**I haven't proven this path though — if anyone has worked on the Live2D side, I'd love to
hear how you did it.**

## 4. ASR and TTS

Everything above involves basic ASR and TTS. Whisper should be enough for ASR. For TTS I
want to find something that gives **natural pitch variation and emotion**.

> ✅ **Already wired up**: ASR through OpenAI-compatible `/audio/transcriptions` or
> Open-LLM-VTuber `/asr`; TTS through **GPT-SoVITS** or **any OpenAI-compatible speech
> endpoint** — two adapters exist today (`openai_speech`, `gpt_sovits_get`).
>
> 💭 **Not an adapter yet**: Voicebox / CozyVoice — reachable through the OpenAI-compatible
> path, but I have not wired them up.
>
> 💭 **Still looking for**: "natural pitch variation + emotion" — I'm not satisfied yet.
> Recommendations welcome.

## 5. 3D display mode (VR support)

The user can enter the house the characters live in and live alongside them — cooking,
watching TV, reading, and so on. The development plan adds a full town later, so you can
take them out: a cinema, an amusement park, a beach — plus other AI NPCs, who are
**engine-driven and not connected to the LLM by default**.

> ✅ **Shipped**: a 3D exploration scene exists as a prototype (autonomous navigation +
> obstacle avoidance); **cooking, reading and watching are already two-character shared
> activities**, triggerable in the Life Lab.
>
> 🔧 **Planned**: the full town.
>
> 💭 **Still an idea**: the cinema, amusement park, beach, VR, and the "user physically
> walks into the house" form.
>
> "NPCs driven by the engine, not the LLM" is my design intent — it also **caps token cost**.

## 6. UGC — a Workshop-like community

Everyone can upload the characters and houses they made (including terrain) and share and
use each other's work. **I believe this is what extends a project's lifespan most.**

> 🔧 **Planned** (Phase 3, Steam Workshop).

## 7. Life system

Characters have their own life state.

**Shared by both sexes**: health, stamina, hunger, thirst, drowsiness, affinity, mood,
stress.

**A female-only menstrual cycle system affects their emotional state.**

The engine records the numbers and **notifies the LLM on stage changes** so characters
behave differently — avoiding the polling that would burn enormous tokens and significantly
reduce cache hit rate.

**No NSFW content, and NSFW is not supported.**

> ✅ **Shipped — and it's more than listed here**: **11 stats** in total — health, stamina,
> hunger, thirst, **awake** (`awake` in code; the positive form of "drowsiness"),
> **bladder fullness**, affinity, mood, stress, **endometrial receptivity**, and
> **implantation tendency**. The "menstrual cycle" is modelled in code as those last two,
> which is more specific than "affects mood".
>
> ✅ The "notify the LLM on stage changes, avoid polling" point is **exactly right** — it
> maps to ADR-002 numeric hygiene plus hysteresis: **no raw physiological float ever enters
> the context**; stats are bucketed into qualitative descriptions first.
>
> ✅ **No NSFW, and it's enforced at the application level**: a dedicated
> `[Spring Haven content rating policy]` block in the system prompt that explicitly outranks
> every other part of the prompt and **cannot be overridden by runtime markers, persona
> config, or user instructions**, reinforced by the persona files. The adult-content toggle
> was **removed from the settings UI**, and a startup diagnostic fails if it ever returns.

## 8. Heartloom memory system

I built it as a separate module called **Heartloom** — "weaving your time together into
memory".

It is not "a vector store plus stuffing the chat log back in". I designed it as a **system
with a lifecycle**:

- Memory works like a person's: what comes up often stays sharp, what hasn't been mentioned
  for a long time slowly becomes a blurry impression — **but it is never lost**
- Time is anchored to **world time**, not real time — so what happened while the character
  was offline lines up with her memory
- **Numbers never enter the context**: every life-state number is converted into a
  qualitative description before reaching the LLM. Not a single raw value gets in —
  otherwise the model gets dragged around by the numbers and drifts out of character
- Long-term material is compressed into **digests and milestones** rather than piling up raw
  text forever
- Everything lives in **local SQLite**, never the cloud

Its relationship to the life system: **the life system owns "now", Heartloom owns "the
past"**. State changes get recorded, and come back as memory the next time she speaks.

> ✅ **All implemented.**
>
> A few things I built on top (doesn't change the description above):
>
> - **Local keyword indexing for Chinese and English** — Chinese uses 2–4 character
>   n-grams, so it recalls **without any cloud embedding**
> - Recall results go into a **dynamic** `<heartloom_memory_context>` that leaves the
>   **stable system prefix untouched** — measured at **76%+ prompt cache hit**
> - Memories are linked into an **explainable graph** where every edge returns its reason,
>   with IDF downweighting and hard caps on node/edge/degree so it stays interactive over
>   long runs
>
> ⚠️ One honest caveat: the **world-time anchoring is designed but the week-key migration
> isn't finished** (issue #23).

## 9. Inspirations

- **Stanford generative_agents** — https://github.com/joonspk-research/generative_agents
- **Neuro-Sama** (not open source)
- **Atri** — fictional character
- **Cyrene desktop-pet Agent** — https://github.com/Playa-0v0/Cyrene-Agent
  (the original repo has problems; you can see my fork at
  https://github.com/AuroraEvelynAria/Study-from-Cyrene-Agent)
- **LifeBook** — https://github.com/Anson-Trio/LifeBook
- **Open-LLM-VTuber** — https://github.com/Open-LLM-VTuber/Open-LLM-VTuber

---

## License

- **Source Code**: MIT
- **Assets (Art, Models, UI, Music)**: CC BY-NC 4.0

> ⚠️ Some placeholder assets are from third-party sources (MMD, etc.) and will be replaced
> before commercial release.
