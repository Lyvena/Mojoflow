"""
MojoFlow Server — Configuration for the async HTTP server.

All tunables for socket behaviour, connection limits, timeouts,
buffer sizes, fiber scheduling, and TLS live here.

Performance-critical defaults are declared as module-level `alias`
constants so they are **inlined at compile time** — the compiler can
propagate them into hot-path allocation sizes and loop bounds with
zero runtime lookup cost.

Design goals:
    - Pure Mojo value type — no Python, no I/O in the struct itself.
    - `alias` compile-time defaults for every numeric/size constant.
    - `ServerConfig.default()` returns a production-safe config in one call.
    - `validate()` catches misconfigurations before the first `accept()`.

TODO:
    - Hot-reload of mutable fields without server restart.
    - Config file parsing (TOML / JSON) once Mojo has a parser.
    - Per-route timeout / body-limit overrides.
    - Environment variable overlay (`MOJOFLOW_PORT`, etc.) — pure Mojo,
      using `sys.env` once stabilised.
"""

from .errors import ServerError, ErrorKind


# ══════════════════════════════════════════════════════════════════
#  Compile-time default constants
#
#  Using `alias` makes these true compile-time values.  The compiler
#  can constant-fold them into struct layouts, buffer allocations,
#  and branch conditions — no dictionary lookup, no pointer chase.
# ══════════════════════════════════════════════════════════════════

# ── Network ───────────────────────────────────────────────────────

alias DEFAULT_HOST: StringLiteral = "127.0.0.1"
"""Bind address.  Use "0.0.0.0" to listen on all interfaces."""

alias DEFAULT_PORT: Int = 8080
"""TCP port.  Unprivileged range (>1024) by default."""

alias DEFAULT_BACKLOG: Int = 4096
"""listen() backlog — max pending connections queued in the kernel.
Sized for burst traffic; the kernel may silently cap this to
/proc/sys/net/core/somaxconn on Linux."""

# ── Connection limits ─────────────────────────────────────────────

alias DEFAULT_MAX_CONNECTIONS: Int = 65_536
"""Hard cap on simultaneous open file descriptors.
Matches typical ulimit -n on production Linux boxes.
Increase alongside `ulimit -n` and `fs.file-max`."""

alias DEFAULT_MAX_KEEP_ALIVE_REQUESTS: Int = 1000
"""Max HTTP requests served on a single keep-alive connection
before the server sends `Connection: close`.
Prevents a single client from monopolising a socket forever.
Set to 0 for unlimited (not recommended in production)."""

# ── Fiber / worker concurrency ────────────────────────────────────

alias DEFAULT_WORKER_FIBERS: Int = 4
"""Number of Fibers (lightweight green-threads) that run the
accept → parse → route → respond loop concurrently.
Scale with CPU core count for optimal throughput.
Each Fiber processes one connection at a time; thousands of
connections can be multiplexed across a small Fiber pool
via the epoll event loop (planned)."""

alias DEFAULT_FIBER_STACK_SIZE: Int = 65_536  # 64 KiB
"""Stack size in bytes for each worker Fiber.
64 KiB is generous for an HTTP handler that does JSON
serialisation; reduce to 16 KiB if handlers are trivial,
increase to 256 KiB if handlers recurse deeply.
Must be page-aligned (4096) on Linux."""

alias DEFAULT_WORKER_THREADS: Int = 1
"""Number of OS worker threads.  Each owns a Fiber runtime."""

alias DEFAULT_MAX_PENDING_CONNECTIONS: Int = 16_384
"""Bounded overflow queue used for backpressure before 503 responses."""

alias DEFAULT_ACCEPT_BATCH_SIZE: Int = 256
"""Max accepted sockets drained per readiness event."""

alias DEFAULT_EVENT_LOOP_POLL_TIMEOUT_MS: Int = 1
"""Poll timeout for the hot event loop. Low value targets sub-ms wakeups."""

# ── Timeouts (milliseconds) ──────────────────────────────────────

alias DEFAULT_READ_TIMEOUT_MS: Int = 30_000
"""Max time to wait for a complete HTTP request after accept().
Protects against slowloris attacks."""

alias DEFAULT_WRITE_TIMEOUT_MS: Int = 30_000
"""Max time allowed to send the full response.
Prevents stalled clients from pinning server resources."""

alias DEFAULT_KEEP_ALIVE_TIMEOUT_MS: Int = 75_000
"""Idle timeout on a keep-alive connection with no new request.
75 s matches nginx's default; shorter values reclaim sockets
faster under load."""

alias DEFAULT_SHUTDOWN_TIMEOUT_MS: Int = 10_000
"""Grace period during shutdown for in-flight requests to finish
before connections are forcefully closed."""

# ── Buffer sizes (bytes) ─────────────────────────────────────────

alias DEFAULT_READ_BUFFER_SIZE: Int = 8_192    # 8 KiB
"""Per-connection read buffer.  Sized to hold a typical HTTP
request (method + path + headers) in a single recv() call.
The kernel may coalesce TCP segments into this window."""

alias DEFAULT_WRITE_BUFFER_SIZE: Int = 16_384  # 16 KiB
"""Per-connection write buffer.  16 KiB covers most JSON API
responses in a single send() call, avoiding partial writes."""

# ── Request limits (bytes) ───────────────────────────────────────

alias DEFAULT_MAX_HEADER_SIZE: Int = 8_192     # 8 KiB
"""Max total bytes for the header section (all headers combined).
Matches Apache's default.  Rejects abusive header floods early."""

alias DEFAULT_MAX_BODY_SIZE: Int = 10_485_760  # 10 MiB
"""Max request body size.  Applies to POST/PUT/PATCH payloads.
Override per-route for file upload endpoints."""

alias DEFAULT_MAX_URI_LENGTH: Int = 8_192      # 8 KiB
"""Max length of the Request-URI (path + query string).
RFC 7230 recommends supporting at least 8000 octets."""

# ── TCP tuning ────────────────────────────────────────────────────

alias DEFAULT_TCP_NODELAY: Bool = True
"""Disable Nagle's algorithm.  Sends small packets immediately
instead of coalescing them.  Essential for low-latency APIs."""

alias DEFAULT_REUSE_ADDRESS: Bool = True
"""SO_REUSEADDR — allows the server to bind immediately after a
restart without waiting for TIME_WAIT sockets to expire."""

alias DEFAULT_REUSE_PORT: Bool = False
"""SO_REUSEPORT — allows multiple processes to bind to the same
port.  Enable for multi-process deployments (one process per core)."""

# ── Identity ──────────────────────────────────────────────────────

alias DEFAULT_SERVER_NAME: StringLiteral = "MojoFlow/0.2.0"
"""Value of the `Server` response header."""

# ── Observability ────────────────────────────────────────────────

alias DEFAULT_LOG_LEVEL: StringLiteral = "info"
"""Request log level. One of off, error, warn, info, debug, trace."""

alias DEFAULT_OPENAPI_PATH: StringLiteral = "/openapi.json"
"""Built-in OpenAPI document path when OpenAPI generation is enabled."""


# ══════════════════════════════════════════════════════════════════
#  TLS Configuration (future — not yet implemented)
# ══════════════════════════════════════════════════════════════════


@value
struct TLSConfig:
    """TLS termination settings.

    Currently a placeholder.  When native TLS lands, this struct
    will control certificate loading, ALPN, mTLS, and session
    ticket rotation.

    TODO:
        - Certificate and private key loading from PEM / DER files.
        - ALPN negotiation for HTTP/2 (`h2`, `http/1.1`).
        - Mutual TLS with client certificate verification.
        - Minimum TLS version enforcement (1.2 / 1.3).
        - Cipher suite selection.
        - OCSP stapling.
        - Session ticket key rotation interval.
    """

    var enabled: Bool
    var cert_path: String
    var key_path: String
    var ca_path: String
    var min_version: String

    fn __init__(out self):
        """TLS disabled by default."""
        self.enabled = False
        self.cert_path = ""
        self.key_path = ""
        self.ca_path = ""
        self.min_version = "1.3"

    fn __init__(
        out self,
        cert_path: String,
        key_path: String,
        ca_path: String = "",
        min_version: String = "1.3",
    ):
        """Enable TLS with the given certificate and key paths."""
        self.enabled = True
        self.cert_path = cert_path
        self.key_path = key_path
        self.ca_path = ca_path
        self.min_version = min_version

    fn validate(self) raises:
        """Basic sanity checks on TLS config."""
        if not self.enabled:
            return
        if self.cert_path == "":
            raise ServerError.configuration(
                "TLS enabled but cert_path is empty"
            ).to_error()
        if self.key_path == "":
            raise ServerError.configuration(
                "TLS enabled but key_path is empty"
            ).to_error()
        if self.min_version != "1.2" and self.min_version != "1.3":
            raise ServerError.configuration(
                "min_version must be '1.2' or '1.3'",
                "got: " + self.min_version,
            ).to_error()


# ══════════════════════════════════════════════════════════════════
#  ServerConfig
# ══════════════════════════════════════════════════════════════════


@value
struct ServerConfig:
    """Complete configuration for the MojoFlow async HTTP server.

    Every field has a compile-time `alias` default (see module top)
    so the compiler can constant-fold hot-path values.  Use the
    `default()` static method for a one-liner production config, or
    construct with keyword overrides for customisation.

    Fields — Network:
        host                    Bind address (IPv4 dotted-quad).
        port                    TCP listen port (1–65 535).
        backlog                 Kernel listen() queue depth.

    Fields — Connection limits:
        max_connections         Simultaneous open sockets hard cap.
        max_keep_alive_requests Requests per keep-alive socket (0 = unlimited).

    Fields — Fiber / concurrency:
        worker_fibers           Number of Fibers running the request loop.
        fiber_stack_size        Per-Fiber stack allocation in bytes.
        worker_threads          OS threads, each with its own Fiber runtime.
        max_pending_connections Backpressure queue cap before 503.
        accept_batch_size       Accepts drained per listener event.
        event_loop_poll_timeout_ms Poll timeout for the hot loop.

    Fields — Timeouts (milliseconds):
        read_timeout_ms         Complete-request read deadline.
        write_timeout_ms        Full-response write deadline.
        keep_alive_timeout_ms   Idle keep-alive socket deadline.
        shutdown_timeout_ms     Graceful-shutdown drain window.

    Fields — Buffers & limits (bytes):
        read_buffer_size        Per-connection recv() buffer.
        write_buffer_size       Per-connection send() buffer.
        max_header_size         Max header section size.
        max_body_size           Max request body size.
        max_uri_length          Max Request-URI length.

    Fields — TCP tuning:
        tcp_nodelay             Disable Nagle's algorithm.
        reuse_address           SO_REUSEADDR.
        reuse_port              SO_REUSEPORT.

    Fields — Identity & debug:
        server_name             `Server` response header value.
        debug                   Verbose logging + error detail in responses.

    Fields — Observability:
        observability_enabled   Master switch for built-in observability.
        log_level               Request log level.
        request_logging_enabled Emit per-request logs.
        metrics_enabled         Track connection/RPS/latency counters.
        openapi_enabled         Serve generated OpenAPI JSON.
        openapi_path            Path for the generated OpenAPI JSON.

    Fields — TLS:
        tls_enabled             Master switch for TLS termination (future).
        tls                     Full TLS configuration struct.

    Example:
        # Production with defaults:
        var cfg = ServerConfig.default()

        # Custom:
        var cfg = ServerConfig(
            host="0.0.0.0",
            port=3000,
            worker_fibers=8,
            fiber_stack_size=131072,  # 128 KiB
            debug=True,
        )

        cfg.validate()
        var server = Server(cfg)
    """

    # ── Network ───────────────────────────────────────────────────
    var host: String
    var port: Int
    var backlog: Int

    # ── Connection limits ─────────────────────────────────────────
    var max_connections: Int
    var max_keep_alive_requests: Int

    # ── Fiber / concurrency ───────────────────────────────────────
    var worker_fibers: Int
    var fiber_stack_size: Int
    var worker_threads: Int
    var max_pending_connections: Int
    var accept_batch_size: Int
    var event_loop_poll_timeout_ms: Int

    # ── Timeouts (ms) ─────────────────────────────────────────────
    var read_timeout_ms: Int
    var write_timeout_ms: Int
    var keep_alive_timeout_ms: Int
    var shutdown_timeout_ms: Int

    # ── Buffers & limits (bytes) ──────────────────────────────────
    var read_buffer_size: Int
    var write_buffer_size: Int
    var max_header_size: Int
    var max_body_size: Int
    var max_uri_length: Int

    # ── TCP tuning ────────────────────────────────────────────────
    var tcp_nodelay: Bool
    var reuse_address: Bool
    var reuse_port: Bool

    # ── Identity & debug ──────────────────────────────────────────
    var server_name: String
    var debug: Bool

    # ── Observability ────────────────────────────────────────────
    var observability_enabled: Bool
    var log_level: String
    var request_logging_enabled: Bool
    var metrics_enabled: Bool
    var openapi_enabled: Bool
    var openapi_path: String

    # ── TLS ───────────────────────────────────────────────────────
    var tls_enabled: Bool
    var tls: TLSConfig

    # ── Constructors ──────────────────────────────────────────────

    fn __init__(out self):
        """Create a config with all compile-time defaults."""
        self.host = DEFAULT_HOST
        self.port = DEFAULT_PORT
        self.backlog = DEFAULT_BACKLOG
        self.max_connections = DEFAULT_MAX_CONNECTIONS
        self.max_keep_alive_requests = DEFAULT_MAX_KEEP_ALIVE_REQUESTS
        self.worker_fibers = DEFAULT_WORKER_FIBERS
        self.fiber_stack_size = DEFAULT_FIBER_STACK_SIZE
        self.worker_threads = DEFAULT_WORKER_THREADS
        self.max_pending_connections = DEFAULT_MAX_PENDING_CONNECTIONS
        self.accept_batch_size = DEFAULT_ACCEPT_BATCH_SIZE
        self.event_loop_poll_timeout_ms = DEFAULT_EVENT_LOOP_POLL_TIMEOUT_MS
        self.read_timeout_ms = DEFAULT_READ_TIMEOUT_MS
        self.write_timeout_ms = DEFAULT_WRITE_TIMEOUT_MS
        self.keep_alive_timeout_ms = DEFAULT_KEEP_ALIVE_TIMEOUT_MS
        self.shutdown_timeout_ms = DEFAULT_SHUTDOWN_TIMEOUT_MS
        self.read_buffer_size = DEFAULT_READ_BUFFER_SIZE
        self.write_buffer_size = DEFAULT_WRITE_BUFFER_SIZE
        self.max_header_size = DEFAULT_MAX_HEADER_SIZE
        self.max_body_size = DEFAULT_MAX_BODY_SIZE
        self.max_uri_length = DEFAULT_MAX_URI_LENGTH
        self.tcp_nodelay = DEFAULT_TCP_NODELAY
        self.reuse_address = DEFAULT_REUSE_ADDRESS
        self.reuse_port = DEFAULT_REUSE_PORT
        self.server_name = DEFAULT_SERVER_NAME
        self.debug = False
        self.observability_enabled = True
        self.log_level = DEFAULT_LOG_LEVEL
        self.request_logging_enabled = True
        self.metrics_enabled = True
        self.openapi_enabled = False
        self.openapi_path = DEFAULT_OPENAPI_PATH
        self.tls_enabled = False
        self.tls = TLSConfig()

    fn __init__(
        out self,
        host: String = DEFAULT_HOST,
        port: Int = DEFAULT_PORT,
        backlog: Int = DEFAULT_BACKLOG,
        max_connections: Int = DEFAULT_MAX_CONNECTIONS,
        max_keep_alive_requests: Int = DEFAULT_MAX_KEEP_ALIVE_REQUESTS,
        worker_fibers: Int = DEFAULT_WORKER_FIBERS,
        fiber_stack_size: Int = DEFAULT_FIBER_STACK_SIZE,
        worker_threads: Int = DEFAULT_WORKER_THREADS,
        max_pending_connections: Int = DEFAULT_MAX_PENDING_CONNECTIONS,
        accept_batch_size: Int = DEFAULT_ACCEPT_BATCH_SIZE,
        event_loop_poll_timeout_ms: Int = DEFAULT_EVENT_LOOP_POLL_TIMEOUT_MS,
        read_timeout_ms: Int = DEFAULT_READ_TIMEOUT_MS,
        write_timeout_ms: Int = DEFAULT_WRITE_TIMEOUT_MS,
        keep_alive_timeout_ms: Int = DEFAULT_KEEP_ALIVE_TIMEOUT_MS,
        shutdown_timeout_ms: Int = DEFAULT_SHUTDOWN_TIMEOUT_MS,
        read_buffer_size: Int = DEFAULT_READ_BUFFER_SIZE,
        write_buffer_size: Int = DEFAULT_WRITE_BUFFER_SIZE,
        max_header_size: Int = DEFAULT_MAX_HEADER_SIZE,
        max_body_size: Int = DEFAULT_MAX_BODY_SIZE,
        max_uri_length: Int = DEFAULT_MAX_URI_LENGTH,
        tcp_nodelay: Bool = DEFAULT_TCP_NODELAY,
        reuse_address: Bool = DEFAULT_REUSE_ADDRESS,
        reuse_port: Bool = DEFAULT_REUSE_PORT,
        server_name: String = DEFAULT_SERVER_NAME,
        debug: Bool = False,
        observability_enabled: Bool = True,
        log_level: String = DEFAULT_LOG_LEVEL,
        request_logging_enabled: Bool = True,
        metrics_enabled: Bool = True,
        openapi_enabled: Bool = False,
        openapi_path: String = DEFAULT_OPENAPI_PATH,
        tls_enabled: Bool = False,
        tls: TLSConfig = TLSConfig(),
    ):
        """Create a config with keyword overrides.

        Any parameter not specified uses its compile-time default alias.
        """
        self.host = host
        self.port = port
        self.backlog = backlog
        self.max_connections = max_connections
        self.max_keep_alive_requests = max_keep_alive_requests
        self.worker_fibers = worker_fibers
        self.fiber_stack_size = fiber_stack_size
        self.worker_threads = worker_threads
        self.max_pending_connections = max_pending_connections
        self.accept_batch_size = accept_batch_size
        self.event_loop_poll_timeout_ms = event_loop_poll_timeout_ms
        self.read_timeout_ms = read_timeout_ms
        self.write_timeout_ms = write_timeout_ms
        self.keep_alive_timeout_ms = keep_alive_timeout_ms
        self.shutdown_timeout_ms = shutdown_timeout_ms
        self.read_buffer_size = read_buffer_size
        self.write_buffer_size = write_buffer_size
        self.max_header_size = max_header_size
        self.max_body_size = max_body_size
        self.max_uri_length = max_uri_length
        self.tcp_nodelay = tcp_nodelay
        self.reuse_address = reuse_address
        self.reuse_port = reuse_port
        self.server_name = server_name
        self.debug = debug
        self.observability_enabled = observability_enabled
        self.log_level = log_level
        self.request_logging_enabled = request_logging_enabled
        self.metrics_enabled = metrics_enabled
        self.openapi_enabled = openapi_enabled
        self.openapi_path = openapi_path
        self.tls_enabled = tls_enabled
        self.tls = tls

    # ── Static constructors ───────────────────────────────────────

    @staticmethod
    fn default() -> ServerConfig:
        """Return a production-safe configuration with all compile-time defaults.

        This is the recommended starting point.  All defaults are tuned
        for a typical JSON API workload on a 4-core Linux server.

        Example:
            var cfg = ServerConfig.default()
            var server = Server(cfg)
            server.listen_and_serve()
        """
        return ServerConfig()

    @staticmethod
    fn development(port: Int = DEFAULT_PORT) -> ServerConfig:
        """Convenience constructor for local development.

        Differences from production defaults:
            - debug = True  (verbose logs, error details in responses).
            - shutdown_timeout_ms = 1000  (fast restarts).
            - keep_alive_timeout_ms = 5000  (reclaim sockets quickly).
        """
        return ServerConfig(
            port=port,
            debug=True,
            log_level="debug",
            shutdown_timeout_ms=1_000,
            keep_alive_timeout_ms=5_000,
        )

    @staticmethod
    fn high_concurrency(
        worker_fibers: Int = 16,
        max_connections: Int = 131_072,
    ) -> ServerConfig:
        """Tuned for maximum concurrent connections.

        Increases Fiber count and connection cap.  Suitable for
        long-polling, SSE, or WebSocket workloads where many
        connections are idle most of the time.

        Requires matching OS tuning:
            sysctl -w net.core.somaxconn=65535
            ulimit -n 200000
        """
        return ServerConfig(
            host="0.0.0.0",
            backlog=65_535,
            worker_fibers=worker_fibers,
            worker_threads=4,
            max_pending_connections=65_536,
            accept_batch_size=1024,
            event_loop_poll_timeout_ms=0,
            max_connections=max_connections,
            reuse_port=True,
        )

    # ── Helpers ───────────────────────────────────────────────────

    fn address(self) -> String:
        """Return `host:port` string for display and socket binding."""
        return self.host + ":" + String(self.port)

    fn total_fiber_memory(self) -> Int:
        """Estimate total memory reserved for Fiber stacks (bytes).

        Useful for capacity planning:
            4 fibers × 64 KiB = 256 KiB (default)
            16 fibers × 64 KiB = 1 MiB (high-concurrency)
        """
        return self.total_fiber_slots() * self.fiber_stack_size

    fn total_fiber_slots(self) -> Int:
        """Total Fiber slots across every configured OS worker thread."""
        return self.worker_threads * self.worker_fibers

    fn is_tls(self) -> Bool:
        """Whether TLS termination is active."""
        return self.tls_enabled and self.tls.enabled

    fn scheme(self) -> String:
        """Return "https" if TLS is active, otherwise "http"."""
        if self.is_tls():
            return "https"
        return "http"

    fn base_url(self) -> String:
        """Full base URL, e.g. "http://127.0.0.1:8080"."""
        return self.scheme() + "://" + self.address()

    # ── Validation ────────────────────────────────────────────────

    fn validate(self) raises:
        """Validate every field and raise on the first violation.

        Should be called once before the server starts accepting
        connections.  Catches misconfigurations that would otherwise
        manifest as cryptic POSIX errors or silent misbehaviour.

        Checks:
            - Port in range 1–65 535.
            - worker_fibers ≥ 1.
            - fiber_stack_size ≥ 4096 and page-aligned.
            - Buffer sizes ≥ 512 bytes.
            - max_header_size ≥ 256 bytes.
            - max_body_size ≥ 0.
            - max_uri_length ≥ 64.
            - Timeouts > 0.
            - backlog ≥ 1.
            - max_connections ≥ 1.
            - max_keep_alive_requests ≥ 0 (0 = unlimited).
            - TLS config valid if tls_enabled.
        """
        # ── Port ──────────────────────────────────────────────────
        if self.port < 1 or self.port > 65535:
            raise ServerError.configuration(
                "port must be 1–65535", "got " + String(self.port)
            ).to_error()

        # ── Concurrency ──────────────────────────────────────────
        if self.worker_fibers < 1:
            raise ServerError.configuration(
                "worker_fibers must be ≥ 1",
                "got " + String(self.worker_fibers),
            ).to_error()

        if self.fiber_stack_size < 4096:
            raise ServerError.configuration(
                "fiber_stack_size must be ≥ 4096 (one page)",
                "got " + String(self.fiber_stack_size),
            ).to_error()

        if self.fiber_stack_size % 4096 != 0:
            raise ServerError.configuration(
                "fiber_stack_size must be page-aligned (multiple of 4096)",
                "got " + String(self.fiber_stack_size),
            ).to_error()

        if self.worker_threads < 1:
            raise ServerError.configuration(
                "worker_threads must be ≥ 1",
                "got " + String(self.worker_threads),
            ).to_error()

        if self.max_pending_connections < 0:
            raise ServerError.configuration(
                "max_pending_connections must be ≥ 0",
                "got " + String(self.max_pending_connections),
            ).to_error()

        if self.accept_batch_size < 1:
            raise ServerError.configuration(
                "accept_batch_size must be ≥ 1",
                "got " + String(self.accept_batch_size),
            ).to_error()

        if self.event_loop_poll_timeout_ms < 0:
            raise ServerError.configuration(
                "event_loop_poll_timeout_ms must be ≥ 0",
                "got " + String(self.event_loop_poll_timeout_ms),
            ).to_error()

        # ── Connections ──────────────────────────────────────────
        if self.max_connections < 1:
            raise ServerError.configuration(
                "max_connections must be ≥ 1",
                "got " + String(self.max_connections),
            ).to_error()

        if self.max_keep_alive_requests < 0:
            raise ServerError.configuration(
                "max_keep_alive_requests must be ≥ 0",
                "got " + String(self.max_keep_alive_requests),
            ).to_error()

        if self.backlog < 1:
            raise ServerError.configuration(
                "backlog must be ≥ 1", "got " + String(self.backlog)
            ).to_error()

        # ── Buffers ──────────────────────────────────────────────
        if self.read_buffer_size < 512:
            raise ServerError.configuration(
                "read_buffer_size must be ≥ 512",
                "got " + String(self.read_buffer_size),
            ).to_error()

        if self.write_buffer_size < 512:
            raise ServerError.configuration(
                "write_buffer_size must be ≥ 512",
                "got " + String(self.write_buffer_size),
            ).to_error()

        # ── Request limits ───────────────────────────────────────
        if self.max_header_size < 256:
            raise ServerError.configuration(
                "max_header_size must be ≥ 256",
                "got " + String(self.max_header_size),
            ).to_error()

        if self.max_body_size < 0:
            raise ServerError.configuration(
                "max_body_size must be ≥ 0",
                "got " + String(self.max_body_size),
            ).to_error()

        if self.max_uri_length < 64:
            raise ServerError.configuration(
                "max_uri_length must be ≥ 64",
                "got " + String(self.max_uri_length),
            ).to_error()

        # ── Timeouts ─────────────────────────────────────────────
        if self.read_timeout_ms <= 0:
            raise ServerError.configuration(
                "read_timeout_ms must be > 0",
                "got " + String(self.read_timeout_ms),
            ).to_error()

        if self.write_timeout_ms <= 0:
            raise ServerError.configuration(
                "write_timeout_ms must be > 0",
                "got " + String(self.write_timeout_ms),
            ).to_error()

        if self.keep_alive_timeout_ms <= 0:
            raise ServerError.configuration(
                "keep_alive_timeout_ms must be > 0",
                "got " + String(self.keep_alive_timeout_ms),
            ).to_error()

        if self.shutdown_timeout_ms <= 0:
            raise ServerError.configuration(
                "shutdown_timeout_ms must be > 0",
                "got " + String(self.shutdown_timeout_ms),
            ).to_error()

        # ── Observability ────────────────────────────────────────
        if self.log_level != "off" and self.log_level != "OFF" and self.log_level != "error" and self.log_level != "ERROR" and self.log_level != "warn" and self.log_level != "WARN" and self.log_level != "info" and self.log_level != "INFO" and self.log_level != "debug" and self.log_level != "DEBUG" and self.log_level != "trace" and self.log_level != "TRACE":
            raise ServerError.configuration(
                "log_level must be one of off, error, warn, info, debug, trace",
                "got " + self.log_level,
            ).to_error()

        if self.openapi_enabled and self.openapi_path == "":
            raise ServerError.configuration(
                "openapi_path must not be empty when OpenAPI is enabled"
            ).to_error()

        # ── TLS ──────────────────────────────────────────────────
        if self.tls_enabled:
            self.tls.validate()

    # ── Display ───────────────────────────────────────────────────

    fn __str__(self) -> String:
        """Human-readable summary for startup banners and debug logs."""
        var s = "ServerConfig(\n"
        s += "  bind          = " + self.base_url() + "\n"
        s += "  backlog       = " + String(self.backlog) + "\n"
        s += "  max_conn      = " + String(self.max_connections) + "\n"
        s += "  keep_alive    = " + String(self.max_keep_alive_requests) + " reqs\n"
        s += "  fibers        = " + String(self.worker_fibers) + "\n"
        s += "  worker_threads= " + String(self.worker_threads) + "\n"
        s += "  pending_cap   = " + String(self.max_pending_connections) + "\n"
        s += "  accept_batch  = " + String(self.accept_batch_size) + "\n"
        s += "  poll_timeout  = " + String(self.event_loop_poll_timeout_ms) + " ms\n"
        s += "  fiber_stack   = " + String(self.fiber_stack_size) + " B\n"
        s += "  read_timeout  = " + String(self.read_timeout_ms) + " ms\n"
        s += "  write_timeout = " + String(self.write_timeout_ms) + " ms\n"
        s += "  ka_timeout    = " + String(self.keep_alive_timeout_ms) + " ms\n"
        s += "  shut_timeout  = " + String(self.shutdown_timeout_ms) + " ms\n"
        s += "  read_buf      = " + String(self.read_buffer_size) + " B\n"
        s += "  write_buf     = " + String(self.write_buffer_size) + " B\n"
        s += "  max_headers   = " + String(self.max_header_size) + " B\n"
        s += "  max_body      = " + String(self.max_body_size) + " B\n"
        s += "  max_uri       = " + String(self.max_uri_length) + " B\n"
        s += "  tcp_nodelay   = " + String(self.tcp_nodelay) + "\n"
        s += "  reuse_addr    = " + String(self.reuse_address) + "\n"
        s += "  reuse_port    = " + String(self.reuse_port) + "\n"
        s += "  tls           = " + String(self.tls_enabled) + "\n"
        s += "  debug         = " + String(self.debug) + "\n"
        s += "  observability = " + String(self.observability_enabled) + "\n"
        s += "  log_level     = " + self.log_level + "\n"
        s += "  metrics       = " + String(self.metrics_enabled) + "\n"
        s += "  openapi       = " + String(self.openapi_enabled) + "\n"
        s += ")"
        return s
