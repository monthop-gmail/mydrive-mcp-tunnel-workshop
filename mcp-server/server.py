"""Minimal MCP server exposing a sandboxed ./workspace folder over streamable HTTP.

Transport-agnostic: any MCP client can use it (ChatGPT via the OpenAI Secure MCP
Tunnel, Claude Code, Gemini CLI, Codex, Cursor, your own SDK code, ...).

Two guardrails:
  * every path argument is resolved and must stay inside WORKSPACE_DIR
  * when MCP_AUTH_TOKEN is set, every request except /healthz needs
    `Authorization: Bearer <token>`
"""

import hmac
import os
from pathlib import Path

import uvicorn
from mcp.server.fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse

WORKSPACE = Path(os.environ.get("WORKSPACE_DIR", "/workspace")).resolve()
MAX_READ_BYTES = int(os.environ.get("MAX_READ_BYTES", "200000"))
AUTH_TOKEN = os.environ.get("MCP_AUTH_TOKEN", "").strip()
PUBLIC_PATHS = ("/healthz",)

mcp = FastMCP(
    "workspace",
    host=os.environ.get("MCP_HOST", "0.0.0.0"),
    port=int(os.environ.get("MCP_PORT", "8000")),
    streamable_http_path="/mcp",
    stateless_http=True,
)


def _resolve(relative_path: str) -> Path:
    """Resolve a user-supplied path inside the workspace, or raise."""
    target = (WORKSPACE / relative_path.lstrip("/")).resolve()
    if target != WORKSPACE and WORKSPACE not in target.parents:
        raise ValueError(f"path escapes the workspace: {relative_path}")
    return target


@mcp.tool()
def list_files(path: str = ".") -> str:
    """List files and folders inside the workspace. `path` is relative to the workspace root."""
    target = _resolve(path)
    if not target.is_dir():
        return f"not a directory: {path}"
    lines = []
    for entry in sorted(target.iterdir(), key=lambda p: (p.is_file(), p.name)):
        kind = "dir " if entry.is_dir() else "file"
        size = entry.stat().st_size if entry.is_file() else 0
        lines.append(f"{kind}  {size:>10}  {entry.relative_to(WORKSPACE)}")
    return "\n".join(lines) or "(empty)"


@mcp.tool()
def read_file(path: str) -> str:
    """Read a UTF-8 text file from the workspace."""
    target = _resolve(path)
    if not target.is_file():
        return f"not a file: {path}"
    data = target.read_bytes()[:MAX_READ_BYTES]
    return data.decode("utf-8", errors="replace")


@mcp.tool()
def write_file(path: str, content: str) -> str:
    """Create or overwrite a UTF-8 text file in the workspace."""
    target = _resolve(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    return f"wrote {len(content)} characters to {target.relative_to(WORKSPACE)}"


@mcp.tool()
def search_text(query: str, path: str = ".", max_results: int = 50) -> str:
    """Search for a literal string in text files under the workspace."""
    root = _resolve(path)
    hits = []
    for candidate in sorted(root.rglob("*")):
        if not candidate.is_file():
            continue
        try:
            text = candidate.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            if query in line:
                hits.append(f"{candidate.relative_to(WORKSPACE)}:{lineno}: {line.strip()[:200]}")
                if len(hits) >= max_results:
                    return "\n".join(hits)
    return "\n".join(hits) or f"no match for {query!r}"


@mcp.tool()
def ping() -> str:
    """Smoke-test tool: confirms the tunnel reaches this MCP server."""
    return f"pong from workspace-mcp; workspace={WORKSPACE}; auth={'on' if AUTH_TOKEN else 'off'}"


@mcp.custom_route("/healthz", methods=["GET"])
async def healthz(_request: Request) -> PlainTextResponse:
    return PlainTextResponse("ok")


class BearerAuthMiddleware:
    """ASGI middleware: require a bearer token on every path except PUBLIC_PATHS."""

    def __init__(self, app, token: str):
        self.app = app
        self.token = token

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope.get("path", "") in PUBLIC_PATHS:
            await self.app(scope, receive, send)
            return

        headers = {k.decode().lower(): v.decode() for k, v in scope.get("headers", [])}
        supplied = headers.get("authorization", "")
        prefix = "Bearer "
        ok = supplied.startswith(prefix) and hmac.compare_digest(
            supplied[len(prefix):].strip(), self.token
        )
        if not ok:
            response = JSONResponse(
                {"error": "unauthorized", "detail": "missing or invalid bearer token"},
                status_code=401,
                headers={"WWW-Authenticate": 'Bearer realm="workspace-mcp"'},
            )
            await response(scope, receive, send)
            return

        await self.app(scope, receive, send)


def build_app():
    app = mcp.streamable_http_app()
    if AUTH_TOKEN:
        return BearerAuthMiddleware(app, AUTH_TOKEN)
    return app


if __name__ == "__main__":
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    print(
        f"workspace-mcp: workspace={WORKSPACE} "
        f"auth={'bearer' if AUTH_TOKEN else 'DISABLED (no MCP_AUTH_TOKEN)'}",
        flush=True,
    )
    uvicorn.run(
        build_app(),
        host=os.environ.get("MCP_HOST", "0.0.0.0"),
        port=int(os.environ.get("MCP_PORT", "8000")),
        log_level=os.environ.get("UVICORN_LOG_LEVEL", "info"),
    )
