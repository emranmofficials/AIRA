"""Tests for the OpenAI Agents SDK sub-agent and its MCP bridge."""

from __future__ import annotations

import json
from types import SimpleNamespace
from typing import Any

from openjarvis.core.config import OpenAIAgentConfig
from openjarvis.subagents import openai_agent as oa
from openjarvis.subagents import mcp_server as bridge


class _FakeAsyncClient:
    def __init__(self, **kwargs: Any) -> None:
        self.kwargs = kwargs

    async def __aenter__(self) -> "_FakeAsyncClient":
        return self

    async def __aexit__(self, *args: Any) -> bool:
        return False


class _FakeRunner:
    received: dict[str, Any] = {}

    @staticmethod
    async def run(agent: Any, task: str, max_turns: int) -> Any:
        _FakeRunner.received = {
            "name": agent.name,
            "instructions": agent.instructions,
            "model": agent.model,
            "task": task,
            "max_turns": max_turns,
        }
        return SimpleNamespace(
            final_output="Sub-agent answer",
            usage=SimpleNamespace(input_tokens=11, output_tokens=7, total_tokens=18),
        )


class _FakeSDK:
    AsyncOpenAI = _FakeAsyncClient
    OpenAIChatCompletionsModel = staticmethod(lambda **kwargs: SimpleNamespace(**kwargs))
    Agent = staticmethod(lambda **kwargs: SimpleNamespace(**kwargs))
    ModelSettings = staticmethod(lambda **kwargs: SimpleNamespace(**kwargs))
    Runner = _FakeRunner

    @staticmethod
    def set_tracing_disabled(disabled: bool) -> None:
        assert disabled is True


def _config(**overrides: Any) -> OpenAIAgentConfig:
    values: dict[str, Any] = {
        "enabled": True,
        "api_key": "server-side-key",
        "api_key_env": "OPENAI_SUBAGENT_API_KEY",
        "name": "OpenAI Specialist",
        "model": "gpt-4.1-mini",
        "max_turns": 4,
        "timeout": 5,
        "temperature": 0.3,
        "tracing": False,
    }
    values.update(overrides)
    return OpenAIAgentConfig(**values)


def test_runner_invokes_agents_sdk(monkeypatch: Any) -> None:
    monkeypatch.setattr(oa, "_sdk_module", lambda: _FakeSDK)
    result = oa.OpenAIAgentRunner(_config()).run("Explain X", context="Y")

    assert result.success is True
    assert result.content == "Sub-agent answer"
    assert result.usage["total_tokens"] == 18
    assert result.metadata["model"] == "gpt-4.1-mini"
    assert _FakeRunner.received["task"] == "Explain X"
    assert "Y" in _FakeRunner.received["instructions"]
    assert _FakeRunner.received["max_turns"] == 4


def test_runner_reports_missing_key_without_sdk(monkeypatch: Any) -> None:
    monkeypatch.delenv("OPENAI_SUBAGENT_API_KEY", raising=False)
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.setattr(
        oa,
        "_sdk_module",
        lambda: (_ for _ in ()).throw(AssertionError("SDK should not load")),
    )
    result = oa.OpenAIAgentRunner(_config(api_key="", api_key_env="MISSING_KEY")).run(
        "hello"
    )

    assert result.success is False
    assert "No OpenAI sub-agent key" in result.content


def test_mcp_server_lists_configured_tool() -> None:
    cfg = SimpleNamespace(subagents=SimpleNamespace(openai=_config()))
    server = bridge.build_server(cfg)
    line = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
    )
    response = json.loads(bridge.handle_line(server, line))

    assert response["id"] == 1
    names = [tool["name"] for tool in response["result"]["tools"]]
    assert names == ["delegate_to_openai_agent"]


def test_mcp_server_executes_delegation_tool(monkeypatch: Any) -> None:
    monkeypatch.setattr(oa, "_sdk_module", lambda: _FakeSDK)
    cfg = SimpleNamespace(subagents=SimpleNamespace(openai=_config()))
    server = bridge.build_server(cfg)
    line = json.dumps(
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "delegate_to_openai_agent",
                "arguments": {"task": "Say hello", "context": "Bengali"},
            },
        }
    )
    response = json.loads(bridge.handle_line(server, line))

    assert response["id"] == 2
    assert response["result"]["isError"] is False
    assert response["result"]["content"][0]["text"] == "Sub-agent answer"
    assert _FakeRunner.received["task"] == "Say hello"
    assert "Bengali" in _FakeRunner.received["instructions"]


def test_mcp_server_answers_ping() -> None:
    cfg = SimpleNamespace(subagents=SimpleNamespace(openai=_config()))
    server = bridge.build_server(cfg)
    line = json.dumps({"jsonrpc": "2.0", "id": 9, "method": "ping", "params": {}})
    response = json.loads(bridge.handle_line(server, line))

    assert response["id"] == 9
    assert response["result"] == {}


def test_mcp_server_ignores_notifications() -> None:
    cfg = SimpleNamespace(subagents=SimpleNamespace(openai=_config()))
    server = bridge.build_server(cfg)
    line = json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"})
    assert bridge.handle_line(server, line) is None
