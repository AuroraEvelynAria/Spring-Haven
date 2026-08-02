# Spring Haven Core

A local-first AI life sim where two characters with memory and daily routines
share a 2D character stage today and can inhabit a 3D world tomorrow. They live,
remember, and miss you even when you are offline.

This repository contains the independent Spring Haven runtime and its Godot
client. Chat, memory, role orchestration, RAG, life simulation and provider
configuration are project-owned components; no third-party bot framework or
memory plugin is required at runtime.

## What is playable

- Two independent characters with distinct Persona and memory-organizer prompts.
- Selected, named, delegated and ordered dual-character replies with shared context.
- Heartloom, a timestamped local SQLite memory and conversation layer.
- Named multi-journey saves with archive, restore and legacy conversation recovery.
- An interactive Heartloom memory network with explainable links, role filters, search, pan and zoom.
- Local RAG document management with role scopes, embedding and rerank support.
- Daily needs, menstrual cycles, relationship state, autonomous messages and Windows notifications.
- Conservative natural-language interactions that update role-specific stats, with configurable deltas and intensity wording.
- A third-person exploration prototype and a lightweight two-character Life Lab.
- A playable 2D portrait rig with layered-art manifests, gaze, blink, breathing, expression and speech animation hooks.
- Semantic perception and whitelisted high-level scene actions for non-visual LLMs.
- Independent chat, vision, embedding and rerank providers with ordered failover.
- Independent ASR and TTS providers with Open-LLM-VTuber, Voicebox/OpenAI-compatible,
  and GPT-SoVITS protocol adapters.
- A privacy-first diagnostic bundle for playtest feedback, without chat or local databases.

## Repository layout

- `godot/`: the Godot 4.7 game, UI, simulation, archives and 3D scenes.
- `companion-core/`: the local HTTP runtime, Heartloom, RAG and provider layer.
- `tools/Build-Playable.ps1`: repeatable Windows playtest packaging.

## Development start

```powershell
cd companion-core
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e .
```

Open `godot/project.godot` with Godot 4.7. On first launch the client creates a
random local Core key and missing runtime files, starts Companion Core, and opens
the AI settings when no chat provider is configured. Existing `user_data`, saves,
Personas and provider credentials always take precedence and are never overwritten.

Provider API keys entered in the game are protected with Windows DPAPI and are
never returned to Godot after saving. Player databases, imported knowledge,
conversation archives and keys are excluded from version control and release builds.

## Build a Windows playtest

Install Godot 4.7 export templates, then run:

```powershell
.\tools\Build-Playable.ps1 `
  -GodotExecutable "C:\path\to\Godot_v4.7-stable_win64.exe" `
  -InstallBuildDependencies `
  -CreateArchive
```

The result is written to `build/SpringHavenPlaytest/`. It contains the Godot game,
an independent `spring-haven-core.exe`, and public default character templates.
Local databases, keys, imported knowledge and licensed placeholder models are
rejected by the build's release guard.

The public defaults keep consensual adult content disabled. A user must explicitly
confirm an adult user and adult roles in their local role registry before enabling it.

See [Companion Core](companion-core/README.md),
[architecture](godot/docs/CompanionCoreArchitecture.md), and
[Heartloom](godot/docs/HeartloomMemory.md) for implementation details. Save-slot
behavior and recovery boundaries are documented in
[Journey saves](godot/docs/JourneySaves.md). The
[presentation architecture](godot/docs/PresentationArchitecture.md) defines how
the current 2D stage and future Live2D/3D executors share one character core.
