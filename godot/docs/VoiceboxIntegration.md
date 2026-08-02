# Voicebox integration

Spring Haven does not automate the Voicebox desktop window or inspect its local
database. The TTS bridge uses a network provider contract so it remains usable
in a packaged build and does not depend on a GUI process being focused.

## Server mode

When Voicebox exposes an OpenAI-compatible server, configure the TTS capability
under **Settings -> AI services -> TTS**:

- Base URL: the server root, normally ending in `/v1`;
- Protocol: `OpenAI-compatible /audio/speech`;
- Model: the Voicebox engine/model identifier;
- Voice ID (Ling) and Voice ID (Nai): optional profile or speaker identifiers.

The two voice IDs are stored in the local Godot settings file. Provider keys
remain in Companion Core's encrypted credential store. The environment variables
`SPRING_HEAVEN_TTS_LING_VOICE` and `SPRING_HEAVEN_TTS_NAI_VOICE` override saved
voice IDs for managed deployments.

Before configuring the game, verify the endpoint with a short request (replace
the URL, key, model and voice with local values):

```powershell
$body = @{ model = "your-model"; input = "Spring Haven test"; voice = "your-voice"; response_format = "wav" } | ConvertTo-Json
Invoke-WebRequest -Method Post -Uri "http://127.0.0.1:PORT/v1/audio/speech" `
  -Headers @{ Authorization = "Bearer $env:VOICEBOX_API_KEY" } `
  -ContentType "application/json" -Body $body -OutFile "$env:TEMP\spring-haven-voice.wav"
```

The response must be audio bytes, or JSON containing `audio_base64`/`audio`.
Companion Core accepts WAV, MP3 and OGG responses and reports a redacted error
when the service is unavailable.

## Desktop-only Voicebox

The desktop Voicebox process is not an API by itself. If it has no server mode,
use its documented local bridge or export a small OpenAI-compatible gateway;
Spring Haven will then connect to that gateway without changing the game client.
Do not point the game at the Voicebox SQLite file or attempt to drive the GUI.

The GPT-SoVITS `/tts` and Open-LLM-VTuber `/tts-ws` protocols remain available
as independent TTS candidates and can be placed in the ordered fallback chain.
