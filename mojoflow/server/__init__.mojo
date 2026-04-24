"""
MojoFlow Server — High-performance async HTTP server for Mojo.

A pure-Mojo, zero-Python-interop HTTP/1.1 server designed for
massive concurrency via Fibers, epoll-driven I/O, and MAX
parallelism.

Modules:
    errors  — Structured, categorised error types.
    config  — Server configuration with production-safe defaults.
    types   — Core HTTP primitives (Request, Response, Headers, …).
    server  — Server, Router, and connection handling.

Quick start:
    from mojoflow.server import Server, ServerConfig, Request, Response

    fn main() raises:
        var cfg = ServerConfig(port=3000)
        var srv = Server(cfg)
        srv.get("/", '{"status": "ok"}')
        srv.listen_and_serve()
"""

# ── Errors ────────────────────────────────────────────────────────
from .errors import ErrorKind, ServerError

# ── Configuration ─────────────────────────────────────────────────
from .config import ServerConfig, TLSConfig

# ── HTTP Types ────────────────────────────────────────────────────
from .types import (
    HTTPVersion,
    HTTPMethod,
    StatusCode,
    HeaderEntry,
    Headers,
    QueryParam,
    RouteParam,
    Request,
    Response,
)

# ── Server & Routing ─────────────────────────────────────────────
from .server import (
    Route,
    RouteMatch,
    Router,
    ConnectionState,
    Server,
)
