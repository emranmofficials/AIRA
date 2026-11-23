"""Stdio MCP server exposing the OpenAI Agents SDK sub-agent to Hermes.

Run indirectly through Hermes (``hermes mcp add ...``) or directly with::

    python -m openjarvis.subagents.mcp_server [--config /path/to/config.toml]

Only the single configurable delegation tool is exposed. All credentials stay
in the server process; no keys are passed through the MCP wire.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path
from typing import Any, Optional

from openjarvis.mcp.protocol import (
    PARSE_ERROR,
    MCPRequest,
    MCPResponse,
)
from openjarvis.mcp.server import MCPServer
from openjarvis.subagents.openai_agent import build_openai_subagent_tool

logger = logging.getLogger(__name__)


class SubagentMCPServer(MCPServer):
    """MCP server with a single delegated OpenAI Agents SDK tool."""

    SERVER_NAME = "openjarvis-subagent"
    SERVER_VERSION = "0.1.0"
    SERVER_TITLE = "OpenJarvis Sub-agent Bridge"

    def handle(self, request: "MCPRequest") -> Any:
        """Answer MCP ``ping`` as well as the tool methods in the base server."""
        if request.method == "ping":
            return MCPResponse(result={}, id=request.id)
        return super().handle(request)

    def _handle_initialize(self, req: "MCPRequest") -> MCPResponse:
        """Identify this process as the sub-agent bridge, not the tool server."""
        return MCPResponse(
            result={
                "protocolVersion": self.PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": True}},
                "serverInfo": {
                    "name": self.SERVER_NAME,
                    "version": self.SERVER_VERSION,
                    "title": self.SERVER_TITLE,
                },
            },
            id=req.id,
        )


def build_server(config: Optional[Any] = None) -> SubagentMCPServer:
    """Create the MCP server after verifying the sub-agent is enabled."""
    if config is None:
        from openjarvis.core.config import load_config

        config = load_config()
    openai_cfg = config.subagents.openai
    if not openai_cfg.enabled:
        raise RuntimeError(
            "OpenAI sub-agent is disabled; set [subagents.openai].enabled = true"
        )
    return SubagentMCPServer([build_openai_subagent_tool(openai_cfg)])


def handle_line(server: SubagentMCPServer, line: str) -> Optional[str]:
    """Return a JSON-RPC response line, or None for notifications."""
    raw = line.strip()
    if not raw:
        return None
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        return MCPResponse.error_response(0, PARSE_ERROR, f"Invalid JSON: {exc}").to_json()
    if not isinstance(payload, dict):
        return MCPResponse.error_response(
            0, PARSE_ERROR, "MCP request must be a JSON object"
        ).to_json()

    is_notification = "id" not in payload
    method = payload.get("method", "")
    if is_notification and str(method).startswith("notifications/"):
        return None
    request = MCPRequest(
        method=str(method),
        params=payload.get("params") or {},
        id=payload.get("id", 0),
        jsonrpc=payload.get("jsonrpc", "2.0"),
    )
    response = server.handle(request)
    return None if is_notification else response.to_json()


def main(argv: Optional[list[str]] = None) -> int:
    """Serve MCP JSON-RPC messages over stdin/stdout."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", help="Path to OpenJarvis config.toml")
    args = parser.parse_args(argv)

    # stdout is reserved for the JSON-RPC stream.
    logging.basicConfig(level=logging.WARNING, stream=sys.stderr)
    try:
        config = None
        if args.config:
            from openjarvis.core.config import load_config

            config = load_config(Path(args.config))
        server = build_server(config)
    except Exception as exc:
        print(f"openjarvis-subagent MCP server: {exc}", file=sys.stderr)
        return 1

    for line in sys.stdin:
        try:
            response = handle_line(server, line)
        except Exception as exc:  # pragma: no cover - defensive protocol guard
            logger.exception("Unhandled MCP error")
            response = MCPResponse.error_response(
                0, -32603, f"Internal error: {exc}"
            ).to_json()
        if response is not None:
            sys.stdout.write(response + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
