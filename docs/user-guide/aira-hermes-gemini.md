# AIRA: Hermes Agent + Gemini via OmniRoute

This setup keeps the existing OpenJarvis server and Flutter client. It changes only the **agent runtime** behind `/v1/chat/completions`:

```
Flutter app ──HTTP/SSE──▶ OpenJarvis server ──▶ Hermes Agent (subprocess)
                                  │                    │
                                  │                    └─▶ MCP ─▶ OpenAI Agents SDK sub-agent
                                  └─▶ OmniRoute / OpenAI-compatible endpoint
                                             (gemini-3.1-pro-preview)
```

- **Main agent:** [Hermes Agent](https://hermes-agent.nousresearch.com/) — owns its own tool loop, skills and sessions.
- **Model:** `gemini-3.1-pro-preview`, reached through OmniRoute's OpenAI-compatible `/v1` endpoint.
- **Sub-agent:** a real OpenAI Agents SDK `Agent`/`Runner` invocation, exposed to Hermes as one MCP tool.
- **Credentials:** environment variables on the server only. The Flutter app stores only the OpenJarvis API key (in the platform keystore).

## 1. Install on the server

```bash
# Hermes runtime (external, not bundled with OpenJarvis)
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash

# OpenJarvis with the optional OpenAI Agents SDK extra
uv sync --extra agents-openai
# or: pip install -e '.[agents-openai]'
```

Copy the preset and set environment variables **in the server process**:

```bash
cp configs/openjarvis/examples/aira-hermes-gemini.toml ~/.openjarvis/config.toml

export OPENAI_BASE_URL="https://<omniroute-host>/v1"
export OPENAI_API_KEY="<omniroute-key>"             # used by Hermes + CloudEngine
export OPENJARVIS_API_KEY="$(jarvis auth generate-key)"  # client -> OpenJarvis auth
# Needed only when the sub-agent is enabled:
export OPENAI_SUBAGENT_API_KEY="<openai-or-omniroute-key>"
```

Start the server as usual:

```bash
jarvis serve
```

The preset selects `engine.default = "cloud"`, `server.agent = "hermes"` and `intelligence.default_model = "gemini-3.1-pro-preview"`, so no CLI override is required.

## 2. Register the sub-agent with Hermes (one time)

The bridge runs as a local stdio MCP server and uses the same Python interpreter as OpenJarvis:

```bash
python -c 'from openjarvis.agents.hermes import subagent_mcp_command; print(" ".join(subagent_mcp_command()))'
hermes mcp add openjarvis_subagent --command "$(command -v python)" --args -m openjarvis.subagents.mcp_server
hermes mcp test openjarvis_subagent
```

To use a non-default config path, append `--config /path/to/config.toml` to the `args` when registering. The server refuses to start unless `[subagents.openai].enabled = true`.

Hermes then sees one tool, `delegate_to_openai_agent` (configurable via `tool_name`), taking `task` and optional `context`. The OpenAI Agents SDK call, its tool loop and its API key all stay inside the OpenJarvis server process.

If your Hermes build cannot use MCP, the same capability is reachable through the A2A endpoint that OpenJarvis already exposes; prefer MCP because it preserves tool-level streaming and error reporting.

## 3. Configuration reference

`[agent.hermes]`:

| Key | Default | Meaning |
|-----|---------|---------|
| `bin` | `""` | Hermes binary; empty uses `PATH` |
| `workspace` | `""` | Working directory for Hermes; empty uses the server's cwd |
| `profile` | `""` | Optional Hermes profile |
| `provider` | `"custom"` | Hermes provider; `custom` requires `base_url` |
| `base_url` | `""` | Falls back to `OPENAI_BASE_URL`, then the engine's OpenAI-compatible URL |
| `api_key_env` | `"OPENAI_API_KEY"` | Server-side env var holding the key passed to Hermes |
| `max_turns` | `0` | Hermes turn limit; `0` lets Hermes decide |
| `timeout` | `600` | Seconds before the subprocess is killed |
| `yolo` | `false` | Auto-approve Hermes tool calls; leave off for headless chats |
| `source` | `"openjarvis"` | Value of Hermes' `--source` flag |
| `session_id` / `extra_args` / `extra_env` / `system_prompt` | empty | Advanced overrides |

`[subagents.openai]`:

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `false` | Set `true` to expose the bridge |
| `name` | `"OpenAI Specialist"` | Agents SDK agent name |
| `instructions` | built-in | Delegation instructions; `context` is appended |
| `tool_name` | `"delegate_to_openai_agent"` | MCP tool name seen by Hermes |
| `model` | `"gpt-4.1-mini"` | Model used by the Agents SDK runner |
| `base_url` | `""` | Empty uses OpenAI; set to OmniRoute to route there |
| `api_key_env` | `"OPENAI_SUBAGENT_API_KEY"` | Server-side key env var (falls back to `OPENAI_API_KEY`) |
| `max_turns` / `timeout` / `temperature` | `6` / `120` / `0.3` | Runner limits |
| `tracing` | `false` | Tracing disabled by default for non-OpenAI endpoints |

## 4. How streaming works

Hermes is launched with `hermes chat --oneshot --query-file - --format stream-json --quiet ...`. The prompt is written to **stdin** (never via a shell), and Hermes writes JSONL to stdout. The adapter maps those records onto the existing event bus:

| Hermes record | OpenJarvis event |
|---------------|------------------|
| `system` | session id captured |
| `text` | `INFERENCE_START`, then streamed content |
| `tool_use` | `TOOL_CALL_START` |
| `tool_result` | `TOOL_CALL_END` + `ToolResult` |
| `result` | `INFERENCE_END`, final answer and metadata |

`AgentStreamBridge` converts those events into the standard SSE `chat.completion.chunk` frames the Flutter app already consumes, so no client changes are needed for tool progress.

## 5. Troubleshooting

- **`HermesAgent requires the 'hermes' binary`** — install Hermes or set `[agent.hermes].bin` to an absolute path.
- **`needs an OpenAI-compatible base URL`** — set `OPENAI_BASE_URL` or `[agent.hermes].base_url`; the `custom` provider cannot infer it.
- **`Hermes exited with code ...`** — run the same command manually and check stderr; common causes are an unknown model alias or an invalid key.
- **`OpenAI sub-agent is disabled`** — set `[subagents.openai].enabled = true` and re-register the MCP server.
- **`No OpenAI sub-agent key`** — export `OPENAI_SUBAGENT_API_KEY` (or `OPENAI_API_KEY`) in the server environment and restart it.
- **No tool chips in the app** — confirm the server was started with the preset and that Hermes JSONL contains `tool_use`/`tool_result` records.
