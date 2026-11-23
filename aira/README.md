# AIRA — Flutter AI assistant for OpenJarvis

A single Flutter codebase for **Android, iOS, Web, Windows, macOS and Linux** that talks to an
[OpenJarvis](https://github.com/open-jarvis/OpenJarvis) server. The server owns the intelligence:
chat orchestration, tool execution, memory, scheduling and security. The recommended server setup
runs the Hermes Agent runtime with `gemini-3.1-pro-preview` from OmniRoute and exposes an OpenAI
Agents SDK specialist through an MCP bridge; OmniRoute is the OpenAI-compatible cloud backend.

```
Flutter (this app)  ──HTTP/SSE──▶  OpenJarvis server  ──▶  Hermes Agent  ──▶  OmniRoute
                                          └──────────────▶ MCP ─▶ OpenAI Agents SDK sub-agent
```

No provider keys live in this app — only the OpenJarvis server URL and its own API key.

## Features

- **Text chat** — streamed answers, Markdown, multi-session history, model picker.
- **Voice** — record audio, transcribe with `/v1/speech/transcribe`, play answers back with
  `/v1/speech/synthesize` (push-to-talk style button).
- **Tools** — the configured server agent runs its tool registry (files, shell, web, memory…);
  streamed tool calls are shown as chips and the server applies its security policy.
- **Memory** — browse, search and store facts through `/v1/memory/*`.
- **Schedule** — create cron/interval managed agents through `/v1/managed-agents`; the server's
  `AgentScheduler` fires them even when the app is closed.

## Layout

```
lib/
  main.dart                 app entry point
  app.dart                  router + adaptive shell
  core/
    app_config.dart         settings model + secure/persistent storage
    api_client.dart         HTTP + SSE client for the OpenJarvis REST API
    sse.dart                dependency-free SSE decoder (unit tested)
    models.dart             shared data classes
  features/
    chat/                   chat controller, page, message bubble
    voice/                  recording, transcription, playback
    memory/                 memory repository + page
    schedule/               managed-agent repository + page
    settings/               settings page
  shared/                   theme + responsive navigation shell
test/                       pure-Dart unit tests for SSE + models
```

## App identity

- **App name:** AIRA
- **Dart package:** `aira`
- **Android / iOS / macOS / Linux ID:** `com.openjarvis.aira`

## Quick start

See [BUILD_GUIDE.md](BUILD_GUIDE.md) for SDK installation, platform builds and the complete
OpenJarvis + OmniRoute server setup. Use `flutter create --project-name aira --org com.openjarvis ...`
to generate the platform folders with the IDs above.

```bash
cd aira
flutter pub get
flutter test
flutter run -d chrome      # or: -d android, -d windows, -d macos, -d linux
```

On first launch open **Settings**, enter the OpenJarvis server URL (for example
`http://127.0.0.1:8000`) and, if the server requires it, its API key. Tap **Test connection**.
