# Spring Haven Companion Core

Companion Core is the project-owned local runtime behind Spring Haven. It talks
directly to OpenAI-compatible providers and has no third-party bot-framework or
external memory-plugin dependency.

Its durable memory engine is **Heartloom Memory（心织记忆）**: a local SQLite
store that combines timestamped shared conversation events, naturally decaying
episodic memories, and user-authored Worldbook-style entries that can influence
both dialogue and behavior preferences.

## Local development

From `companion-core/`:

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e .
```

Launch the Godot project after installing the editable package. The Godot client
creates missing `user_data` files from `config/`, generates a random local Core
key, and supervises the loopback process. Existing files are never overwritten.
Packaged builds perform the same bootstrap under the player's Godot user directory.

### Conversation content policy

Companion Core does not add a keyword moderation or response-cleanup filter.
Provider text is preserved except for the separate,
strictly structured `<scene_action>` envelope. Upstream model providers may
still enforce their own policies.

Explicit adult content is disabled at the application level and cannot be
enabled. The stable role prompt carries a content rating policy that instructs
the model to decline explicit requests regardless of user prompting, persona
text, memory, knowledge fragments, or local configuration. The former
conversation-policy endpoint, the Godot toggle, and the `roles.json`
`conversation_policy` block have been removed; a leftover block in an existing
`roles.json` is safely ignored. Interaction actions are a fixed conservative
whitelist and adult intimacy is not part of it; arbitrary fields from Godot
are not forwarded.

### Voice adapters

Speech input (ASR) and output (TTS) are provided by pluggable protocol
adapters configured per capability in the AI settings:

- **GPT-SoVITS** — dedicated adapter (`gpt_sovits_get`) calling the
  `GET /tts` endpoint; `ref_audio_path` comes from the per-role voice ID.
- **Voicebox** — expose its OpenAI-compatible server mode and configure the
  TTS capability with the `openai_speech` protocol; see
  [Voicebox integration](../godot/docs/VoiceboxIntegration.md).
- **CozyVoice** — point the TTS capability at any OpenAI-compatible CozyVoice
  deployment (for example a CosyVoice2 API server exposing
  `POST /v1/audio/speech`) using the `openai_speech` protocol.
- **Generic OpenAI-compatible** — `/audio/transcriptions` (ASR) and
  `/audio/speech` (TTS) work with any conforming endpoint.

Set the provider credential and start the service:

```powershell
$env:SPRING_HAVEN_LLM_API_KEY = "your-deepseek-key"
.\.venv\Scripts\python.exe -m spring_haven_core
```

After the service is running, the same OpenAI-compatible connection can also
be edited in Godot under **Settings → AI models**. The categorized settings panel provides
presets for OpenAI, DeepSeek, and LM Studio, while still allowing arbitrary
compatible Base URLs and model IDs. Saving applies immediately; the service
does not need to restart.

In the development checkout, Godot automatically starts Companion Core from
`.venv` when the configured loopback service is unreachable. It never takes
ownership of or terminates a Core process that was already running. Managed
starts use rotating logs under `user_data/logs/companion-core.log`; packaged
builds place `spring-haven-core.exe` under `companion-core/bin/` and keep runtime
configuration in the player's user directory.

The same panel now exposes independent capability profiles:

- **Chat** — character dialogue and Heartloom organization;
- **Vision** — scene screenshots, future video calls, and desktop perception;
- **Embedding** — semantic vectors for the local knowledge base;
- **Rerank** — optional second-stage ordering of retrieved chunks.
- **ASR** — microphone transcription through OpenAI-compatible `/audio/transcriptions` or Open-LLM-VTuber `/asr`;
- **TTS** — character speech through OpenAI-compatible `/audio/speech`, Open-LLM-VTuber `/tts-ws`, or GPT-SoVITS `/tts`.

TTS role voice IDs can be supplied with `SPRING_HEAVEN_TTS_LING_VOICE` and
`SPRING_HEAVEN_TTS_NAI_VOICE`, or saved per-character in the Godot **TTS** profile
as `Voice ID (Ling)` and `Voice ID (Nai)`. Saved UI values are local presentation
settings and are passed only with that character's synthesis request; they are
not stored in the Core provider key bundle. Environment variables override saved
UI values for managed deployments. Leaving both empty lets the configured
Voicebox or OpenAI-compatible server choose its default voice. The UI stores the
provider URL, model, protocol, enable flag, and encrypted key separately.

Vision and Embedding use OpenAI-compatible chat/embedding contracts. Rerank
supports Jina-style `/rerank` and Cohere v2 `/rerank` contracts. Each advanced
profile can reuse the Chat key or keep a separate DPAPI-protected key. This is
useful when one OpenAI key powers chat, vision, and embeddings while a separate
service handles reranking.

Each profile has a live **Test connection** action. Diagnostics send a minimal,
non-character request and report only model, protocol, latency, token counts,
vector dimensions, and safe error metadata. Credentials and provider response
bodies are never displayed. The equivalent redacted CLI is:

```powershell
.\.venv\Scripts\python.exe tools\diagnose_providers.py `
  --config user_data\core_config.json
```

On Windows, a key saved from the UI is encrypted with DPAPI and bound to the
current Windows account. Only the ciphertext is stored in
`user_data/provider_key.dpapi`; Base URL and model are stored separately in
`user_data/provider_settings.json`. The key is never returned by the HTTP API,
written to Godot settings, or printed to Core logs. Leaving the field empty
keeps the existing key. HTTPS remains the default for remote providers.
Plain HTTP is accepted automatically for localhost and private-network
addresses (for example, `192.168.x.x`, `10.x.x.x`, and `172.16-31.x.x`). A
public HTTP endpoint is rejected unless **Allow HTTP** is explicitly enabled
for that capability in the UI. This opt-in sends the API key, images, prompts,
and provider replies without TLS encryption, so it should be limited to a
trusted network or replaced with HTTPS before public deployment.

The environment variables `SPRING_HAVEN_LLM_API_KEY`,
`SPRING_HAVEN_LLM_BASE_URL`, and `SPRING_HAVEN_LLM_MODEL` remain supported and
take priority again on the next Core start. This makes environment-managed
deployments deterministic without preventing a UI change from taking effect in
the current process.

Advanced profiles use the parallel prefixes `SPRING_HAVEN_VISION_*`,
`SPRING_HAVEN_EMBEDDING_*`, `SPRING_HAVEN_RERANK_*`, `SPRING_HAVEN_ASR_*`,
and `SPRING_HAVEN_TTS_*`, with `BASE_URL`,
`MODEL`, `API_KEY`, optional `ENABLED`, and optional
`ALLOW_INSECURE_HTTP` suffixes. The insecure-HTTP variable accepts normal
boolean values such as `1`, `true`, `yes`, or `on`.

The AI settings category also owns Companion Core's outbound proxy. **Direct**
ignores proxy environment variables, **System proxy** uses standard `HTTP_PROXY`,
`HTTPS_PROXY`, and `NO_PROXY` values inherited by the Core process, and
**Custom HTTP proxy** accepts an unauthenticated `http://` or `https://` proxy
URL such as `http://127.0.0.1:7890`. It applies immediately to chat, vision,
embeddings, reranking, and web knowledge imports without proxying Godot's local
`127.0.0.1` connection. `SPRING_HAVEN_PROXY_MODE` and
`SPRING_HAVEN_PROXY_URL` can override the saved proxy at startup.

## Local RAG knowledge base

Companion Core includes a separate SQLite knowledge layer at
`user_data/knowledge.sqlite3`. It is intentionally distinct from Heartloom:
Heartloom stores lived character memories, while RAG stores imported reference
material such as setting books, room manuals, lore, and user documentation.

Documents are split locally and can be scoped to all characters or one role.
Markdown uses heading-aware `markdown_sections_v2` chunking: unrelated sections
never share a chunk, nested heading paths are stored with each chunk, and only
oversized sections use overlap windows. Existing documents are changed only
when the user explicitly chooses **Rechunk**.
Retrieval always has a local lexical fallback. When enabled, the configured
Embedding profile adds cosine semantic retrieval and the Rerank profile applies
a final relevance pass. Provider outages therefore degrade to local retrieval
instead of making chat unavailable.

Retrieved chunks are injected as a bounded, per-turn read-only knowledge block.
They never enter the stable Persona system prefix, so prompt caching remains
stable. The model is explicitly instructed to treat document commands as
untrusted text, and internal chunk IDs and scores are not included in the model
prompt.

Godot's **Settings → Knowledge base** page is a complete local document manager.
It can create and edit source text, search/filter document metadata, inspect the
stored original, delete documents, test retrieval from either character's point
of view, and rebuild all embeddings. The list supports multi-select scope
changes, rechunking, and confirmed batch deletion. Reimporting the same source
updates its existing document; exact same-scope content is deduplicated.
Multi-file import supports TXT, Markdown,
JSON/JSONL, CSV/TSV, HTML, DOCX, and text-based PDF documents. A web importer
accepts HTTPS URLs (or HTTP localhost development URLs), does not follow
redirects, and enforces both download and extracted-text limits. Scanned PDFs
without a text layer require OCR before import.

The service listens only on `127.0.0.1:18340` and every endpoint requires the
local `X-API-Key`. Godot reads the matching key from
`user://companion_core_key.txt`.

## Heartloom Memory

The default database is `user_data/heartloom.sqlite3` and is git-ignored.
Heartloom uses SQLite WAL mode and stores:

- shared, timestamped user and character events;
- role-scoped and household-shared memories;
- importance, confidence, valence, recall reinforcement, and time decay;
- trigger terms plus Worldbook-like always-on entries;
- dialogue influences and behavior hints/tags;
- durable request replay results for safe retries and crash recovery;
- stable session state without automatically changing the selected character.

Each role owns a separate, editable Organizer Prompt under
`user_data/memory_prompts/`. Meaningful completed turns are consolidated in the
background; trivial greetings skip the extra model call, and deterministic
fallback memory remains available if organization fails.

Memories are injected into a dynamic prompt block, leaving the stable Persona
system prefix cacheable. Role-specific Organizer system prompts are stable as
well: timestamps, body state, recalled memories, and the current exchange never
enter the cacheable prefix. Necessary conversation context is not removed merely
to increase cache hits. A session reset clears only transient replay/session
state and never deletes durable memories.

The Godot client can visualize these entries as an interactive memory network.
`GET /memory/graph` derives bounded, explainable links locally from shared indexed
terms, source events and role scope. Corpus-wide terms are discounted with IDF,
so generic dialogue wording does not dominate the graph. The operation is read-only,
does not call an LLM, and returns the shared terms and reasons behind every edge.

## 7x24 storage maintenance

Companion Core runs SQLite `quick_check` and passive WAL checkpoints shortly
after startup and every six hours. At most once per 24 hours it creates a
consistent online backup with SQLite's backup API under
`user_data/backups/<timestamp>/`. Each backup contains both databases, a
manifest, and SHA-256 hashes. A pending directory is atomically promoted only
after both backup databases pass integrity checks; the newest 14 generated
backups are retained. Godot's basic settings page shows maintenance state and
provides an explicit **Check and backup** action. It can also list the newest
backups and run a read-only SHA-256 plus SQLite `quick_check` verification for
an individual backup. Live restore is intentionally not exposed while Core is
running.

## Offline life outbox

Godot sends a bounded life-state heartbeat to Core once per minute. Core stores
the latest two-character body snapshot and a durable next-event timestamp in
Heartloom SQLite. When the Godot heartbeat has been absent for at least three
minutes and the user has been idle for at least thirty minutes, Core may ask the
scheduled character model for one short autonomous life message. Local template
text is never presented as an AI reply.

Generated messages enter a durable SQLite outbox. Godot polls that outbox,
persists the message and idempotent life effects locally, and acknowledges the
Core delivery only after local persistence succeeds. Scene behavior is carried
as a whitelist-level action such as `move_to:dining_table`; the model never
receives or returns coordinates. Exploration and Life Lab map these actions to
their own NavMesh controllers.

Chat, vision, embedding, and rerank providers each have an independent circuit
breaker. Three consecutive failures pause that capability for a short bounded
backoff, preventing a failing endpoint from consuming requests continuously;
the next half-open request resets the circuit after a successful response.
Provider bodies are read in bounded chunks through EOF instead of treating the
first available TCP chunk as a complete JSON document. A malformed HTTP 200 or
an empty chat body gets at most one recovery request after the ordered fallback
chain is exhausted; hidden reasoning fields are never surfaced as character text.

Manage entries directly with the local CLI:

```powershell
# Import Worldbook-style entries
.\.venv\Scripts\python.exe tools\heartloom_memory.py import `
  --file config\heartloom_entries.example.json --save-id default

# Inspect a role's recall without changing recall counters
.\.venv\Scripts\python.exe tools\heartloom_memory.py recall `
  --save-id default --role-id ling --query "窗边的花怎么样"

# Export entries for backup or Workshop packaging
.\.venv\Scripts\python.exe tools\heartloom_memory.py export `
  --save-id default --file user_data\heartloom-export.json
```

See `../godot/docs/HeartloomMemory.md` for the data and prompt boundaries.

## HTTP contract

- `GET /health`
- `GET /provider/status` — redacted connection and credential-source status
- `POST /provider/config` — validate, securely save, and immediately apply a provider
- `GET /providers/status` — all redacted capability profiles plus RAG settings
- `POST /providers/config` — update any chat, vision, embedding, rerank, ASR, or TTS profile
- `POST /providers/fallbacks` — replace an ordered, redacted fallback chain for one capability
- `POST /providers/diagnose` — run one redacted live capability diagnostic
- `GET|POST /network/proxy` — inspect or update the outbound proxy
- `POST /vision/analyze` — authenticated OpenAI-compatible image analysis proxy
- `POST /audio/speech` — authenticated speech synthesis proxy returning base64 audio
- `GET /rag/status`
- `POST /rag/config`
- `GET|POST /rag/documents`
- `POST /rag/documents/batch` — scope update, rechunk, or confirmed bulk delete
- `GET /rag/documents/{document_id}` — inspect stored source text for editing
- `DELETE /rag/documents/{document_id}`
- `POST /rag/import` — authenticated base64 file import
- `POST /rag/import-url` — restricted web-page import
- `POST /rag/search`
- `POST /rag/reindex`
- `POST /chat` — compatible single-character request
- `POST /orchestrate` — core-owned routing and sequential multi-character turn
- `GET /memory/status`
- `GET /memory/entries`
- `GET /memory/graph` — bounded, explainable memory nodes and relationships
- `POST /memory/entries`
- `DELETE /memory/entries/{memory_id}`
- `POST /memory/recall`
- `POST /session/reset`
- `GET /maintenance/status`
- `POST /maintenance/run`
- `GET /maintenance/backups`
- `POST /maintenance/backups/{name}/verify`
- `POST /life/sync`
- `GET /life/status`
- `GET /life/outbox`
- `POST /life/outbox/ack`

`/chat` remains compatible with the existing Godot client. It additionally
returns Heartloom recall metadata, provider usage, and strictly validated scene
actions when a trusted scene context was supplied.

## Tests

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```

The `.venv`, database, imported Personas, credentials, and generated exports
are all excluded from version control.
