"""
MojoFlow Server — High-performance async HTTP server for Mojo.

A pure-Mojo, zero-Python-interop HTTP/1.1 server designed for
massive concurrency via Fibers, epoll-driven I/O, and MAX
parallelism.

Modules:
    errors   — Structured, categorised error types.
    config   — Server configuration with compile-time defaults.
    types    — Core HTTP primitives (Request, Response, Headers, …).
    net      — Low-level async networking (sockets, event loop, I/O).
    runtime  — Fiber pool, task queue, and async runtime scheduler.
    server   — Server, Router, and request handling.

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

# ── Networking ────────────────────────────────────────────────────
from .net import (
    AsyncSocket,
    AsyncListener,
    AsyncConnection,
    EventLoop,
    IOEvent,
)

# ── Runtime ───────────────────────────────────────────────────────
from .runtime import (
    FiberState,
    FiberHandle,
    FiberPool,
    TaskQueue,
    TaskGroup,
    AsyncRuntime,
    run_forever,
    spawn_fiber,
    await_all,
    parallelize_work,
)

# ── HTTP Parser / Serializer ──────────────────────────────────────
from .http_parser import (
    ByteView,
    ParseStatus,
    ParseResult,
    parse_request,
    parse_request_view,
    serialize_response,
    serialize_chunked,
    decode_chunked,
    test_parse as test_http_parser,
)

# ── Server & Routing ─────────────────────────────────────────────
from .server import (
    Route,
    RouteMatch,
    Router,
    ConnectionState,
    Server,
)
