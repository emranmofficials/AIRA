"""HermesAgent -- wraps NousResearch's Hermes Agent as an OpenJarvis agent.

Hermes is an external runtime (install: ``curl -fsSL
https://hermes-agent.nousresearch.com/install.sh | bash``). It is not bundled;
:meth:`run` returns a clear error when the ``hermes`` binary is missing.

The adapter drives one headless turn through::

    hermes chat --oneshot --query-file - --format stream-json --quiet ...

The prompt goes to stdin (never through a shell), and Hermes emits one JSON
object per stdout line: ``system``, ``text``, ``tool_use``, ``tool_result`` and
a terminal ``result`` record. Those are mapped to OpenJarvis ToolResults and
EventBus events so the existing SSE stream bridge can show progress in a
client. Model/base URL are passed per run, so the configured Gemini model runs
through the OpenJarvis inference engine's OpenAI-compatible endpoint
(typically an OmniRoute proxy).
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import sys
import threading
from pathlib import Path
from typing import Any, Dict, List, Optional

from openjarvis.agents._stubs import AgentContext, AgentResult, BaseAgent
from openjarvis.agents.opencode import _derive_openai_base_url
from openjarvis.core.events import EventBus, EventType
from openjarvis.core.registry import AgentRegistry
from openjarvis.core.types import ToolResult
from openjarvis.engine._stubs import InferenceEngine

logger = logging.getLogger(__name__)

DEFAULT_HERMES_MODEL = "gemini-3.1-pro-preview"


def is_hermes_available() -> bool:
    """Return True when the ``hermes`` binary can be found on PATH."""
    return shutil.which("hermes") is not None


def subagent_mcp_command(module: str = "openjarvis.subagents.mcp_server") -> List[str]:
    """Return the ``hermes mcp add`` command that exposes the OpenAI sub-agent.

    Kept as a helper (rather than mutating a user's Hermes config from
    ``run()``) so setup scripts and docs share one authoritative spelling.
    The current interpreter is used so the MCP server sees the same
    OpenJarvis install and virtualenv as the server process.
    """
    return [
        "hermes",
        "mcp",
        "add",
        "openjarvis_subagent",
        "--command",
        sys.executable,
        "--args",
        "-m",
        module,
    ]


def _load_hermes_config() -> Optional[Any]:
    """Load ``[agent.hermes]`` when present; never fail agent construction."""
    try:
        from openjarvis.core.config import load_config

        return load_config().agent.hermes
    except Exception as exc:  # pragma: no cover - defensive for partial installs
        logger.debug("Could not load Hermes config section: %s", exc)
        return None


def _as_tool_arguments(value: Any) -> str:
    """Normalise a tool_use ``input`` payload to the SSE contract's JSON text."""
    if isinstance(value, str):
        return value
    try:
        return json.dumps(value)
    except (TypeError, ValueError):
        return str(value)


def _parse_stream_line(line: str) -> Optional[Dict[str, Any]]:
    """Parse one Hermes JSONL record; ignore non-JSON diagnostics."""
    text = line.strip()
    if not text:
        return None
    try:
        obj = json.loads(text)
    except json.JSONDecodeError:
        return None
    return obj if isinstance(obj, dict) else None


@AgentRegistry.register("hermes")
class HermesAgent(BaseAgent):
    """Delegate a turn to the external Hermes Agent runtime.

    Hermes owns its own tool loop, skills and session store. OpenJarvis supplies
    the inference endpoint (engine-derived or explicit ``base_url``) and maps
    the JSONL progress stream back onto the EventBus. Because Hermes runs as a
    separate process it does not consume OpenJarvis ``BaseTool`` objects.
    """

    agent_id = "hermes"
    accepts_tools = False
    required_capabilities = ()
    _default_temperature = 0.7
    _default_max_tokens = 1024

    def __init__(
        self,
        engine: InferenceEngine,
        model: str,
        *,
        bus: Optional[EventBus] = None,
        temperature: Optional[float] = None,
        max_tokens: Optional[int] = None,
        workspace: str = "",
        hermes_bin: str = "",
        profile: str = "",
        provider: Optional[str] = None,
        base_url: str = "",
        api_key: str = "",
        api_key_env: str = "",
        max_turns: int = 0,
        timeout: Optional[int] = None,
        yolo: Optional[bool] = None,
        source: str = "",
        session_id: str = "",
        extra_args: Optional[List[str]] = None,
        extra_env: Optional[Dict[str, str]] = None,
        system_prompt: str = "",
        capability_policy: Optional[Any] = None,
        rate_limiter: Optional[Any] = None,
        agent_id: Optional[str] = None,
    ) -> None:
        super().__init__(
            engine,
            model,
            bus=bus,
            temperature=temperature,
            max_tokens=max_tokens,
            capability_policy=capability_policy,
            rate_limiter=rate_limiter,
            agent_id=agent_id,
        )
        cfg = _load_hermes_config()
        api_key_env = api_key_env or (
            getattr(cfg, "api_key_env", "OPENAI_API_KEY") if cfg else "OPENAI_API_KEY"
        )
        self._workspace = workspace or getattr(cfg, "workspace", "") or os.getcwd()
        self._hermes_bin = (
            hermes_bin or getattr(cfg, "bin", "") or shutil.which("hermes") or "hermes"
        )
        self._profile = profile or getattr(cfg, "profile", "")
        self._provider = provider or getattr(cfg, "provider", "") or "custom"
        self._base_url = (
            base_url
            or getattr(cfg, "base_url", "")
            or os.environ.get("OPENAI_BASE_URL", "")
            or _derive_openai_base_url(engine)
        )
        self._api_key = api_key or os.environ.get(api_key_env, "")
        self._max_turns = max(0, int(max_turns or getattr(cfg, "max_turns", 0) or 0))
        self._timeout = max(
            1,
            int(
                timeout
                if timeout is not None
                else getattr(cfg, "timeout", 600)
            ),
        )
        configured_yolo = yolo if yolo is not None else getattr(cfg, "yolo", False)
        self._yolo = bool(configured_yolo)
        self._source = source or getattr(cfg, "source", "") or "openjarvis"
        self._session_id = session_id or getattr(cfg, "session_id", "")
        self._extra_args = list(extra_args or getattr(cfg, "extra_args", []) or [])
        self._extra_env = dict(extra_env or getattr(cfg, "extra_env", {}) or {})
        self._system_prompt = system_prompt or getattr(cfg, "system_prompt", "")
        self._proc: Optional[subprocess.Popen] = None

    # ------------------------------------------------------------------
    # Command / prompt construction
    # ------------------------------------------------------------------

    def _build_command(self) -> List[str]:
        cmd: List[str] = [self._hermes_bin]
        # Global options must precede the subcommand.
        if self._workspace:
            cmd += ["--in", self._workspace]
        if self._profile:
            cmd += ["--profile", self._profile]
        cmd += [
            "chat",
            "--oneshot",
            "--query-file",
            "-",
            "--format",
            "stream-json",
            "--quiet",
            "--source",
            self._source,
            "--provider",
            self._provider,
            "--model",
            self._model or DEFAULT_HERMES_MODEL,
        ]
        if self._base_url:
            cmd += ["--base-url", self._base_url]
        if self._api_key:
            cmd += ["--api-key", self._api_key]
        if self._max_turns:
            cmd += ["--max-turns", str(self._max_turns)]
        if self._yolo:
            cmd += ["--yolo"]
        if self._session_id:
            cmd += ["--resume", self._session_id]
        cmd += self._extra_args
        return cmd

    def _build_prompt(self, input: str, context: Optional[AgentContext]) -> str:
        if not self._system_prompt and (context is None or not context.conversation.messages):
            return input
        parts: List[str] = []
        if self._system_prompt:
            parts.append(f"System instructions:\n{self._system_prompt}")
        if context is not None:
            for msg in context.conversation.messages:
                role = getattr(msg.role, "value", str(msg.role))
                content = getattr(msg, "content", "") or ""
                if content:
                    parts.append(f"{role}: {content}")
        parts.append(f"user: {input}")
        return "\n\n".join(parts)

    # ------------------------------------------------------------------
    # JSONL event handling
    # ------------------------------------------------------------------

    def _handle_event(
        self,
        obj: Dict[str, Any],
        *,
        tool_results: List[ToolResult],
        result: Dict[str, Any],
        inference_started: List[bool],
    ) -> None:
        kind = str(obj.get("type") or obj.get("event") or "").lower()
        subtype = str(obj.get("subtype") or "").lower()

        if kind == "system":
            if "session_id" in obj:
                result["session_id"] = obj["session_id"]
            return

        if kind in {"text", "assistant", "message"}:
            if not inference_started[0]:
                inference_started[0] = True
                self._publish(
                    EventType.INFERENCE_START,
                    {"agent": self.agent_id, "model": self._model},
                )
            result["text_deltas"] = result.get("text_deltas", []) + [
                str(obj.get("text", ""))
            ]
            return

        if kind in {"tool_use", "tool_call"}:
            arguments = _as_tool_arguments(obj.get("input", obj.get("arguments", {})))
            self._publish(
                EventType.TOOL_CALL_START,
                {"tool": obj.get("name", "hermes_tool"), "arguments": arguments},
            )
            return

        if kind in {"tool_result", "tool"}:
            name = str(obj.get("name", "hermes_tool"))
            output = obj.get("output", obj.get("content", ""))
            is_error = bool(obj.get("is_error", False))
            tool_results.append(
                ToolResult(
                    tool_name=name,
                    content=str(output),
                    success=not is_error,
                    latency_seconds=float(obj.get("duration_ms", 0) or 0) / 1000.0,
                )
            )
            self._publish(
                EventType.TOOL_CALL_END,
                {
                    "tool": name,
                    "output": str(output),
                    "success": not is_error,
                },
            )
            return

        if kind == "result":
            result.update(obj)
            if obj.get("session_id"):
                self._session_id = str(obj["session_id"])
            if inference_started[0]:
                self._publish(
                    EventType.INFERENCE_END,
                    {"agent": self.agent_id, "model": self._model, **obj},
                )

    def _publish(self, event_type: EventType, data: Dict[str, Any]) -> None:
        if self._bus is not None:
            self._bus.publish(event_type, data)

    # ------------------------------------------------------------------
    # Run
    # ------------------------------------------------------------------

    def run(
        self,
        input: str,
        context: Optional[AgentContext] = None,
        **kwargs: Any,
    ) -> AgentResult:
        """Run one Hermes turn and return its final answer."""
        denied = self._execution_denied_result()
        if denied is not None:
            return denied
        self._emit_turn_start(input)

        if not is_hermes_available() and not Path(self._hermes_bin).exists():
            return self._error_result(
                "HermesAgent requires the 'hermes' binary. Install it with "
                "`curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash`."
            )
        if self._provider == "custom" and not self._base_url:
            return self._error_result(
                "HermesAgent needs an OpenAI-compatible base URL for the custom "
                "provider. Pass base_url=... or use a provider Hermes knows."
            )

        cmd = self._build_command()
        env = dict(os.environ)
        env.update(self._extra_env)
        prompt = self._build_prompt(input, context)

        try:
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                cwd=self._workspace,
                env=env,
            )
        except (OSError, ValueError) as exc:
            return self._error_result(f"Could not start Hermes: {exc}")

        self._proc = proc
        stderr_lines: List[str] = []
        stop_watchdog = threading.Event()
        timed_out = threading.Event()

        def _drain_stderr() -> None:
            assert proc.stderr is not None
            try:
                for line in proc.stderr:
                    stderr_lines.append(line)
            except Exception:  # pragma: no cover - defensive for odd streams
                logger.debug("Hermes stderr drain failed", exc_info=True)

        def _watchdog() -> None:
            if not stop_watchdog.wait(self._timeout):
                timed_out.set()
                proc.kill()

        stderr_thread = threading.Thread(target=_drain_stderr, daemon=True)
        stderr_thread.start()
        watchdog = threading.Thread(target=_watchdog, daemon=True)
        watchdog.start()

        tool_results: List[ToolResult] = []
        result: Dict[str, Any] = {}
        inference_started = [False]

        try:
            assert proc.stdin is not None
            proc.stdin.write(prompt)
            proc.stdin.close()
            assert proc.stdout is not None
            for line in proc.stdout:
                obj = _parse_stream_line(line)
                if obj is not None:
                    self._handle_event(
                        obj,
                        tool_results=tool_results,
                        result=result,
                        inference_started=inference_started,
                    )
            proc.wait(timeout=10)
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            proc.kill()
            self._emit_turn_end(turns=1, error=True)
            return self._error_result(f"Hermes run failed: {exc}")
        finally:
            stop_watchdog.set()
            self._proc = None
            try:
                stderr_thread.join(timeout=1)
            except RuntimeError:  # pragma: no cover
                pass

        exit_code = int(result.get("exit_code", proc.returncode or 0))
        error = result.get("error")
        if timed_out.is_set():
            self._emit_turn_end(turns=1, error=True)
            return self._error_result(
                f"Hermes timed out after {self._timeout}s"
                + (": " + "".join(stderr_lines[-5:]).strip() if stderr_lines else "")
            )
        if error or (exit_code not in (0, 130)):
            detail = error if isinstance(error, str) else "".join(stderr_lines[-10:])
            self._emit_turn_end(turns=1, error=True)
            return self._error_result(
                f"Hermes exited with code {exit_code}: {detail.strip()}"
            )
        if exit_code == 130:
            self._emit_turn_end(turns=1, error=True)
            return self._error_result("Hermes was interrupted before completing.")

        content = str(result.get("text") or "")
        if not content:
            content = "".join(result.get("text_deltas", []))
        result.pop("text_deltas", None)
        self._emit_turn_end(turns=1)
        return AgentResult(
            content=content,
            tool_results=tool_results,
            turns=1,
            metadata={
                "agent": "hermes",
                "provider": self._provider,
                "model": self._model,
                "session_id": self._session_id,
                "tokens": result.get("tokens", {}),
                "duration_ms": result.get("duration_ms"),
                "hermes_exit_code": exit_code,
            },
        )

    def _error_result(self, message: str) -> AgentResult:
        logger.error("Hermes agent error: %s", message)
        return AgentResult(content=message, turns=1, metadata={"error": True})

    def close(self) -> None:
        """Terminate a running Hermes subprocess, if any."""
        if self._proc is not None and self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=5)
            except subprocess.TimeoutExpired:  # pragma: no cover
                self._proc.kill()
        self._proc = None


__all__ = [
    "DEFAULT_HERMES_MODEL",
    "HermesAgent",
    "is_hermes_available",
    "subagent_mcp_command",
]
