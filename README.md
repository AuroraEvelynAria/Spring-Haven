
<div align="center">
  <img src="https://github.com/user-attachments/assets/dc30093f-df9c-4ad8-9225-73855975d766" alt="Spring Haven" width="100%"/>
  
  # 🌿 Spring Haven
  
  <p>
    <strong>Create characters. They live, remember, and miss you — even when you're offline.</strong>
  </p>
  
  <p>
    <img src="https://img.shields.io/badge/status-alpha-FFA726?style=flat-square" alt="Status: Alpha"/>
    <img src="https://img.shields.io/badge/engine-Godot_4.7-478CBF?style=flat-square&logo=godotengine" alt="Engine"/>
    <img src="https://img.shields.io/badge/language-Python_3.11-3776AB?style=flat-square&logo=python" alt="Language"/>
    <img src="https://img.shields.io/badge/license-MIT_&_CC--BY--NC-8B8B8B?style=flat-square" alt="License"/>
    <img src="https://img.shields.io/badge/adult_content-none-4CAF50?style=flat-square" alt="No Adult Content"/>
  </p>
  
  <p>
    <a href="#-what-is-this">About</a> •
    <a href="#-features">Features</a> •
    <a href="#-architecture">Architecture</a> •
    <a href="#-roadmap">Roadmap</a> •
    <a href="#-getting-started">Getting Started</a> •
    <a href="README.zh-CN.md">中文</a>
  </p>
</div>

---

## 💭 What is this?

**Spring Haven** is a **local-first AI life simulator** — a sandbox where you create, customize, and live alongside AI characters that feel alive.

These aren't scripted NPCs. They're characters with **persistent memory, physiological needs, and autonomous daily routines**. They eat when hungry, sleep when tired, wander when bored, and remember every word you've told them.

**You build their personalities. They build their lives. Even when you're not there.**

---

## 🎯 What Makes This Different?

| | Spring Haven | Chatbots / AI Companions |
|---|---|---|
| **Characters** | Created and customized by **you** | Pre-defined, fixed |
| **Memory** | Long-term with decay & semantic recall | Short-term context only |
| **Life** | Eat, sleep, wander — **even when offline** | Only respond when you talk |
| **World** | 3D space they physically live in | Text-only or 2D static |
| **Data** | **Local-first**, you own everything | Cloud-dependent |
| **Modding** | Steam Workshop for characters & worlds | Usually closed |

---

## ✨ Features

### 🧠 Your Characters, Your Rules

- **Create characters from scratch** — personas are plain Markdown files defining name, personality, backstory, voice, and appearance
- **Customize their knowledge base** — a local RAG engine with role-scoped documents, embedding and rerank support
- **Share your creations** with the community via Steam Workshop (planned)
- **Visual character editor** (planned) — customize outfits, expressions, and animations

### 💬 Persistent Memory & Emotions

- **Heartloom**, a timestamped local memory engine with natural decay, recall strengthening, and an **explorable memory network** with explainable links
- **Daily digests, weekly self-reflections, and relationship milestones** — they remember, reflect, and grow over time
- Characters share their lives with each other — important moments naturally travel between them
- Mood, stress, hunger, thirst, stamina, and menstrual cycles
- **They'll miss you** — and send messages when they do

### 🌍 A World They Live In

- Autonomous daily routines — eating, drinking, resting, cooking, tending plants, dancing, socializing — **even when you're offline**
- Optional **real-world weather** shapes their day: rainy days keep them indoors, sunny afternoons draw them out
- 3D exploration scenes with autonomous navigation and obstacle avoidance (prototype)
- **Open world editing** with GridMap-based tools (planned)

### 💬 Active Communication

- Characters talk to each other in the background
- They initiate conversations — not just reply
- Windows notifications for offline messages
- **They observe and comment** on their environment

### 🎙️ Voice Ready

- Speech input and output through pluggable protocol adapters
- **GPT-SoVITS, Voicebox, and CozyVoice** endpoints supported, plus any OpenAI-compatible voice API

### 🔒 Local-First & AI Freedom

- All data stays on your machine — no cloud dependency
- **BYOK (Bring Your Own Key)**: any OpenAI-compatible endpoint — DeepSeek API, LM Studio, Ollama, and more
- Independent **failover chains** for chat, vision, embedding, and rerank providers
- API keys are **encrypted with Windows DPAPI** and never returned to the game after saving
- No tracking, no telemetry
- Privacy-first diagnostic bundle for bug reports — never includes chats or databases

### 🧩 Steam Workshop & UGC (planned)

- Share characters, worlds, and stories
- Download community creations
- Built-in world editor for custom maps

---

## 🏗️ Architecture

┌─────────────────────────────────────────────────────────────┐  
│ Godot 4.7 Client │  
│ • 2D portrait stage / 3D exploration / chat UI │  
│ • Heartloom memory graph / Life Lab / journey saves │  
└────────────────────────┬────────────────────────────────────┘  
│ Local HTTP REST (localhost + access key)  
┌────────────────────────▼────────────────────────────────────┐  
│ Companion Core (Python, self-contained) │  
│ ┌──────────────┐ ┌──────────────┐ ┌──────────────────────┐ │  
│ │ Chat & Role │ │ Heartloom │ │ RAG Knowledge │ │  
│ │ Orchestration│ │ Memory (SQL) │ │ Base (local docs) │ │  
│ └──────────────┘ └──────────────┘ └──────────────────────┘ │  
│ ┌──────────────┐ ┌──────────────┐ ┌──────────────────────┐ │  
│ │ Life │ │ AI Provider │ │ ASR / TTS │ │  
│ │ Scheduler │ │ Failover │ │ Voice Adapters │ │  
│ └──────────────┘ └──────────────┘ └──────────────────────┘ │  
└────────────────────────┬────────────────────────────────────┘  
│  
┌────────────────────────▼────────────────────────────────────┐  
│ Local Storage │  
│ • SQLite (Memory, Knowledge) • JSON (Roles, Saves, Config) │  
└─────────────────────────────────────────────────────────────┘

---

## 🎭 Included Example Characters

To help you get started, Spring Haven includes two fully-realized example characters:

- **小玲 (Suzune)** — A 21-year-old cat-girl with a lazy, tsundere personality. She's slow to warm up but deeply loyal.
- **雪奈 (Yukina)** — A 19-year-old rabbit-girl who's affectionate, clingy, and honest about her feelings.

**These are just examples.** You can customize them, create your own characters from scratch, or download characters made by the community via Workshop.

---

## 🗺️ Roadmap

### ✅ Alpha (Current)
- Dual-character personas with shared context and named multi-journey saves
- Heartloom memory: timestamped recall, memory network visualization, digests & milestones
- Local RAG knowledge base with role scopes
- Physiological needs, menstrual cycles, real weather, and autonomous routines & messages
- DeepSeek API with 76%+ prompt cache hit rate
- Voice input/output via ASR & TTS adapters
- 2D layered portrait rig: gaze, blink, breathing, expressions, and speech animation
- 3D exploration prototype and a two-character Life Lab

### 🚧 Phase 2 (In Progress)
- Resource copyright audit & replacement
- 20-30 minute vertical slice
- Character creation system (JSON-based)
- Watchdog & auto-recovery

### 🌟 Phase 3 (Planned)
- Steam Workshop integration
- Visual character editor
- World editor (GridMap-based)
- DLC system: characters, scenes, outfits
- Video call & screen-sharing perception

### 🔮 Phase 4 (Future)
- Full UGC marketplace
- Multi-character households
- Procedural world generation
- Community-driven expansions

---

## 🚀 Getting Started

### Prerequisites

- Windows 10/11 (DPAPI-protected keys and Windows notifications are Windows-only today; other platforms planned)
- Python 3.11+
- Godot 4.7 (standard build)
- (Optional) An OpenAI-compatible API key — e.g. DeepSeek — or a local LM Studio

### Quick Start

```bash
# Clone the repository
git clone https://github.com/AuroraEvelynAria/Spring-Haven-Core.git
cd Spring-Haven-Core

# Set up the Python backend
cd companion-core
py -3.11 -m venv .venv
.venv\Scripts\python -m pip install -e .

# Launch
# Open godot/project.godot with Godot 4.7 and press Play.
# On first launch the client generates a local access key, starts
# Companion Core automatically, and opens the AI settings where you
# enter your provider credentials.
```

> 🔐 Provider API keys are protected with Windows DPAPI and are never returned to the game after saving. Player databases, imported knowledge, conversation archives, and keys are excluded from version control and release builds.

## 🤝 Contributing

We welcome contributions! Spring Haven is currently in **Alpha** and actively evolving.

1. Check [Issues](https://github.com/AuroraEvelynAria/Spring-Haven-Core/issues) for `good-first-issue` labels
    
2. Comment on an issue or open a new one describing your change
    
3. Ensure code passes the existing tests
    
4. Follow PEP8 (Python) and GDScript style guides
    

> 💬 For architecture discussions, please open an Issue first.

---

## ⚠️ About Adult Content

**Spring Haven does NOT include and is NOT designed to include adult/NSFW content.**

This is not just a policy — it is enforced by the application itself. Adult content generation has been **removed at the application level**: there is no setting, button, or prompt that can re-enable it. The runtime applies a general-audience content policy to every request, and interaction actions are a fixed conservative whitelist.

This project focuses on:

- Meaningful companionship and emotional connection
    
- Creative character expression
    
- Living, breathing AI characters
    

All interactions are intended to be wholesome and family-friendly. Content that violates this principle will not be supported.

---

## 🛠️ Development

### Repository layout

- `godot/`: the Godot 4.7 game, UI, simulation, archives and 3D scenes
- `companion-core/`: the local HTTP runtime, Heartloom, RAG and provider layer
- `tools/Build-Playable.ps1`: repeatable Windows playtest packaging

### Build a Windows playtest

Install Godot 4.7 export templates, then run:

```powershell
.\tools\Build-Playable.ps1 `
  -GodotExecutable "C:\path\to\Godot_v4.7-stable_win64.exe" `
  -InstallBuildDependencies `
  -CreateArchive
```

The result is written to `build/SpringHavenPlaytest/` — the Godot game plus an independent `spring-haven-core.exe`. Local databases, keys, imported knowledge and licensed placeholder models are rejected by the build's release guard.

### Implementation details

- [Companion Core](companion-core/README.md) — the local runtime, provider layer and content policy
- [Architecture](godot/docs/CompanionCoreArchitecture.md) — how the client and the runtime talk
- [Heartloom](godot/docs/HeartloomMemory.md) — the memory engine
- [Journey saves](godot/docs/JourneySaves.md) — save-slot behavior and recovery boundaries
- [Presentation architecture](godot/docs/PresentationArchitecture.md) — one character core across 2D/Live2D/3D
- [Voicebox integration](godot/docs/VoiceboxIntegration.md) — voice server setup and desktop-only limits

---

## 📄 License

- **Source Code**: MIT
    
- **Assets (Art, Models, UI, Music)**: CC BY-NC 4.0
    

> ⚠️ Some placeholder assets are from third-party sources (MMD, etc.) and will be replaced before commercial release.

---

<div align="center"> <sub>Built with ☕ by <a href="https://github.com/AuroraEvelynAria">NachoNeko</a></sub> </div>
