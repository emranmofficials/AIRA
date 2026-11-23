"""Tests for the Hermes Agent adapter."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from openjarvis.agents import hermes as hermes_module
from openjarvis.agents.hermes import HermesAgent, _parse_stream_line


def _agent(**kwargs: object) -> HermesAgent:
    defaults = dict(
        engine=None,
        model="gemini-3.1-pro-preview",
        hermes_bin="hermes",
        base_url="http://127.0.0.1:8000/v1",
        api_key="test-key",
        provider="custom",
        yolo=False,
        timeout=30,
    )
    defaults.update(kwargs)
    return HermesAgent(**defaults)  # type: ignore[arg-type]


def test_build_command_uses_verified_hermes_flags() -> None:
    agent = _agent(
        workspace="/tmp/jarvis",
        profile="jarvis",
        max_turns=5,
        source="tool",
        extra_args=["--ignore-user-config"],
    )
    cmd = agent._build_command()
    assert cmd[:4] == ["hermes", "--in", "/tmp/jarvis", "--profile"]
    assert cmd[cmd.index("chat") :] == [
        "chat",
        "--oneshot",
        "--query-file",
        "-",
        "--format",
        "stream-json",
        "--quiet",
        "--source",
        "tool",
        "--provider",
        "custom",
        "--model",
        "gemini-3.1-pro-preview",
        "--base-url",
        "http://127.0.0.1:8000/v1",
        "--api-key",
        "test-key",
        "--max-turns",
        "5",
        "--ignore-user-config",
    ]


def test_stream_line_parser_ignores_noise() -> None:
    assert _parse_stream_line("not json") is None
    assert _parse_stream_line("[]") is None
    assert _parse_stream_line('{"type":"text","text":"hi"}') == {
        "type": "text",
        "text": "hi",
    }


class _FakeStdin:
    def __init__(self) -> None:
        self.written = ""
        self.closed = False

    def write(self, value: str) -> None:
        self.written += value

    def close(self) -> None:
        self.closed = True


class _FakeProc:
    def __init__(self, lines: list[str]) -> None:
        self.stdin = _FakeStdin()
        self.stdout = lines
        self.stderr: list[str] = []
        self.returncode = 0

    def wait(self, timeout: int = 0) -> int:
        return self.returncode

    def poll(self) -> int:
        return self.returncode

    def kill(self) -> None:
        self.returncode = 137

    def terminate(self) -> None:
        self.returncode = 143


def test_run_maps_hermes_jsonl_to_result(monkeypatch: Any) -> None:
    lines = [
        json.dumps({"type": "system", "subtype": "init", "session_id": "s-1"}),
        json.dumps({"type": "text", "text": "Assalamu "}),
        json.dumps({"type": "tool_use", "name": "calculator", "input": {"x": 1}}),
        json.dumps(
            {
                "type": "tool_result",
                "name": "calculator",
                "output": "2",
                "duration_ms": 120,
            }
        ),
        json.dumps({"type": "text", "text": "alaikum"}),
        json.dumps(
            {
                "type": "result",
                "session_id": "s-1",
                "exit_code": 0,
                "tokens": {"total": 42},
                "duration_ms": 900,
            }
        ),
    ]
    proc = _FakeProc(lines)
    monkeypatch.setattr(hermes_module, "is_hermes_available", lambda: True)  # type: ignore[attr-defined]
    monkeypatch.setattr(  # type: ignore[attr-defined]
        hermes_module.subprocess, "Popen", lambda *a, **k: proc
    )

    agent = _agent()
    result = agent.run("Assalamu alaikum")

    assert result.content == "Assalamu alaikum"
    assert result.turns == 1
    assert [item.tool_name for item in result.tool_results] == ["calculator"]
    assert result.tool_results[0].content == "2"
    assert result.metadata["session_id"] == "s-1"
    assert proc.stdin.written == "Assalamu alaikum"
    assert proc.stdin.closed


def test_preset_loads_hermes_and_subagent_sections() -> None:
    from openjarvis.core.config import load_config

    load_config.cache_clear()
    preset = (
        Path(__file__).parents[2]
        / "configs"
        / "openjarvis"
        / "examples"
        / "aira-hermes-gemini.toml"
    )
    cfg = load_config(preset)

    assert cfg.engine.default == "cloud"
    assert cfg.intelligence.default_model == "gemini-3.1-pro-preview"
    assert cfg.server.agent == "hermes"
    assert cfg.agent.hermes.provider == "custom"
    assert cfg.subagents.openai.enabled is True
    assert cfg.subagents.openai.tool_name == "delegate_to_openai_agent"
    assert cfg.subagents.openai.model == "gpt-4.1-mini"
