"""OpenAI Agents SDK sub-agent used as a delegated tool.

This is a real Agents SDK ``Agent``/``Runner`` invocation, not a plain chat
completion. The main agent (Hermes) reaches it through the MCP server in
:mod:`openjarvis.subagents.mcp_server`, so the SDK, credentials and tool loop
all stay inside the OpenJarvis server process.

The SDK is an optional dependency (``openai-agents``); importing this module
does not require it. Missing dependencies or credentials become tool failures
with actionable messages rather than startup crashes.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from typing import Any, Dict, Optional

from openjarvis.core.types import ToolResult
from openjarvis.tools._stubs import BaseTool, ToolSpec

logger = logging.getLogger(__name__)


class OpenAIAgentsUnavailable(RuntimeError):
    """Raised when the optional SDK or credentials are missing."""


def _sdk_module() -> Any:
    try:
        import agents
    except ImportError as exc:  # pragma: no cover - depends on optional extra
        raise OpenAIAgentsUnavailable(
            "The OpenAI Agents SDK is not installed. Install the server extra "
            "`openjarvis[agents-openai]`."
        ) from exc
    return agents


def _config_for(config: Optional[Any]) -> Any:
    if config is not None:
        return config
    from openjarvis.core.config import load_config

    return load_config().subagents.openai


def _usage_dict(result: Any) -> Dict[str, Any]:
    usage = getattr(result, "usage", None)
    if usage is None:
        return {}
    if isinstance(usage, dict):
        return {k: v for k, v in usage.items() if isinstance(v, (int, float))}
    data: Dict[str, Any] = {}
    for name in (
        "input_tokens",
        "output_tokens",
        "total_tokens",
        "cache_read_tokens",
        "cache_write_tokens",
    ):
        value = getattr(usage, name, None)
        if isinstance(value, (int, float)):
            data[name] = value
    return data


class OpenAIAgentRunner:
    """Run one delegated task through the OpenAI Agents SDK."""

    def __init__(self, config: Optional[Any] = None) -> None:
        self._config = _config_for(config)

    @property
    def tool_name(self) -> str:
        return self._config.tool_name or "delegate_to_openai_agent"

    def run(self, task: str, context: str = "") -> ToolResult:
        """Execute ``task`` and return the agent's final answer."""
        started = time.perf_counter()
        try:
            return self._run(task, context, started)
        except OpenAIAgentsUnavailable as exc:
            return ToolResult(
                tool_name=self.tool_name,
                content=str(exc),
                success=False,
                latency_seconds=time.perf_counter() - started,
            )
        except asyncio.TimeoutError:
            return ToolResult(
                tool_name=self.tool_name,
                content=f"OpenAI sub-agent timed out after {self._config.timeout}s.",
                success=False,
                latency_seconds=time.perf_counter() - started,
            )
        except Exception as exc:  # pragma: no cover - upstream SDK failures
            logger.exception("OpenAI sub-agent run failed")
            return ToolResult(
                tool_name=self.tool_name,
                content=f"OpenAI sub-agent failed: {exc}",
                success=False,
                latency_seconds=time.perf_counter() - started,
                metadata={"error_type": type(exc).__name__},
            )

    def _run(self, task: str, context: str, started: float) -> ToolResult:
        cfg = self._config
        if not cfg.enabled:
            raise OpenAIAgentsUnavailable(
                "The OpenAI sub-agent is disabled. Set "
                "`[subagents.openai].enabled = true` in the server config."
            )

        api_key = cfg.api_key or os.environ.get(cfg.api_key_env, "")
        if not api_key:
            api_key = os.environ.get("OPENAI_API_KEY", "")
        if not api_key:
            raise OpenAIAgentsUnavailable(
                f"No OpenAI sub-agent key: set ${cfg.api_key_env} "
                "(or OPENAI_API_KEY) on the server."
            )

        agents = _sdk_module()
        if getattr(cfg, "tracing", False) is False:
            agents.set_tracing_disabled(disabled=True)

        instructions = cfg.instructions or ""
        if context.strip():
            instructions = f"{instructions}\n\nAdditional context:\n{context.strip()}"

        async def _invoke() -> Any:
            client_kwargs: Dict[str, Any] = {"api_key": api_key}
            if cfg.base_url:
                client_kwargs["base_url"] = cfg.base_url
            async with agents.AsyncOpenAI(**client_kwargs) as client:
                model = agents.OpenAIChatCompletionsModel(
                    model=cfg.model,
                    openai_client=client,
                )
                agent = agents.Agent(
                    name=cfg.name,
                    instructions=instructions,
                    model=model,
                    model_settings=agents.ModelSettings(
                        temperature=float(cfg.temperature)
                    ),
                )
                return await agents.Runner.run(
                    agent,
                    task,
                    max_turns=max(1, int(cfg.max_turns)),
                )

        result = asyncio.run(asyncio.wait_for(_invoke(), timeout=cfg.timeout))
        final_output = getattr(result, "final_output", "")
        if isinstance(final_output, str):
            content = final_output
        else:
            content = json.dumps(final_output, default=str)
        return ToolResult(
            tool_name=self.tool_name,
            content=content,
            success=True,
            usage=_usage_dict(result),
            latency_seconds=time.perf_counter() - started,
            metadata={"agent": "openai-agents-sdk", "model": cfg.model},
        )


class OpenAIAgentTool(BaseTool):
    """Expose the OpenAI Agents SDK runner as an OpenJarvis ``BaseTool``."""

    tool_id = "openai_subagent"
    is_local = False

    def __init__(self, config: Optional[Any] = None) -> None:
        self._runner = OpenAIAgentRunner(config)

    @property
    def spec(self) -> ToolSpec:
        name = self._runner.tool_name
        return ToolSpec(
            name=name,
            description=(
                "Delegate a focused task to a second AI agent powered by the "
                "OpenAI Agents SDK. Use it for independent research, drafting "
                "or verification that benefits from a separate model context."
            ),
            parameters={
                "type": "object",
                "properties": {
                    "task": {
                        "type": "string",
                        "description": "The complete task to delegate.",
                    },
                    "context": {
                        "type": "string",
                        "description": "Optional background the sub-agent needs.",
                    },
                },
                "required": ["task"],
                "additionalProperties": False,
            },
            category="agents",
            requires_confirmation=False,
            timeout_seconds=float(getattr(self._runner._config, "timeout", 120)),
            metadata={"subagent": "openai-agents-sdk"},
        )

    def execute(self, **params: Any) -> ToolResult:
        task = str(params.get("task", "")).strip()
        if not task:
            return ToolResult(
                tool_name=self._runner.tool_name,
                content="Missing required parameter: task",
                success=False,
            )
        return self._runner.run(task, str(params.get("context", "") or ""))


def build_openai_subagent_tool(config: Optional[Any] = None) -> OpenAIAgentTool:
    """Create the MCP-visible tool wrapper for the OpenAI sub-agent."""
    return OpenAIAgentTool(config)


__all__ = [
    "OpenAIAgentsUnavailable",
    "OpenAIAgentRunner",
    "OpenAIAgentTool",
    "build_openai_subagent_tool",
]
