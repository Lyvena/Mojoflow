"""
MojoFlow Server — Configuration for the async HTTP server.

All tunables for socket behaviour, connection limits, timeouts,
buffer sizes, and worker parallelism live here.  Every field has
a sensible production default so `ServerConfig()` is safe to use
out of the box.

Design goals:
    - Pure Mojo value type — no Python, no I/O in the struct itself.
    - Every field documented with its unit and rationale.
    - `address()` helper for the common host:port pattern.

TODO:
    - TLSConfig for native TLS termination (rustls-style).
    - Per-route timeout overrides.
    - Hot-reload of config without server restart.
    - Config file parsing (TOML / JSON) once Mojo has a parser.
"""

from .errors import ServerError, ErrorKind


# ──────────────────────────────────────────────────────────────────
# TLS Configuration (placeholder for future TLS support)
# ──────────────────────────────────────────────────────────────────


@value
struct TLSConfig:
    """TLS termination settings (planned — not yet implemented).

    TODO:
        - Certificate and key loading from PEM files.
        - ALPN negotiation for HTTP/2.
        - mTLS with client certificate verification.
        - Session ticket rotation for forward secrecy.
    """

    var enabled: Bool
    var cert_path: String
    var key_path: String
    var ca_path: String

    fn __init__(out self):
        self.enabled = False
        self.cert_path = ""
        self.key_path = ""
        self.ca_path = ""

    fn __init__(
        out self,
        cert_path: String,
        key_path: String,
        ca_path: String = "",
    ):
        self.enabled = True
        self.cert_path = cert_path
        self.key_path = key_path
        self.ca_path = ca_path


# ──────────────────────────────────────────────────────────────────
# Server Configuration
# ──────────────────────────────────────────────────────────────────


@value
struct ServerConfig:
    """Complete configuration for the MojoFlow async HTTP server.

    Fields:
        host                — Bind address (e.g. "0.0.0.0" for all interfaces).
        port                — TCP port number.
        backlog             — `listen()` backlog for pending connections.
        max_connections     — Hard cap on simultaneous open sockets.
        num_workers         — Fiber / worker count for parallel request handling.
        read_timeout_ms     — Max milliseconds to wait for a complete request.
        write_timeout_ms    — Max milliseconds allowed for sending a response.
        keep_alive_timeout_ms — Idle timeout before closing a keep-alive socket.
        max_keep_alive_requests — Max requests per keep-alive connection (0 = unlimited).
        max_header_size     — Bytes.  Reject requests with headers exceeding this.
        max_body_size       — Bytes.  Reject request bodies exceeding this.
        read_buffer_size    — Per-connection kernel read buffer hint (bytes).
        write_buffer_size   — Per-connection kernel write buffer hint (bytes).
        tcp_nodelay         — Disable Nagle's algorithm (lower latency).
        reuse_address       — SO_REUSEADDR — allow quick restarts.
        reuse_port          — SO_REUSEPORT — allow multiple listeners on the same port.
        server_name         — Value sent in the `Server` response header.
        debug               — Enables verbose logging and error detail in responses.
        tls                 — TLS termination settings (disabled by default).

    Example:
        var cfg = ServerConfig(host="0.0.0.0", port=3000, num_workers=8)
        var server = Server(cfg)
    """

    var host: String
    var port: Int
    var backlog: Int
    var max_connections: Int
    var num_workers: Int
    var read_timeout_ms: Int
    var write_timeout_ms: Int
    var keep_alive_timeout_ms: Int
    var max_keep_alive_requests: Int
    var max_header_size: Int
    var max_body_size: Int
    var read_buffer_size: Int
    var write_buffer_size: Int
    var tcp_nodelay: Bool
    var reuse_address: Bool
    var reuse_port: Bool
    var server_name: String
    var debug: Bool
    var tls: TLSConfig

    fn __init__(out self):
        """Create a config with production-safe defaults."""
        self.host = "127.0.0.1"
        self.port = 8080
        self.backlog = 4096
        self.max_connections = 65_536
        self.num_workers = 4
        self.read_timeout_ms = 30_000
        self.write_timeout_ms = 30_000
        self.keep_alive_timeout_ms = 75_000
        self.max_keep_alive_requests = 1000
        self.max_header_size = 8 * 1024         # 8 KiB
        self.max_body_size = 10 * 1024 * 1024   # 10 MiB
        self.read_buffer_size = 8 * 1024        # 8 KiB
        self.write_buffer_size = 16 * 1024      # 16 KiB
        self.tcp_nodelay = True
        self.reuse_address = True
        self.reuse_port = False
        self.server_name = "MojoFlow/0.2.0"
        self.debug = False
        self.tls = TLSConfig()

    fn __init__(
        out self,
        host: String = "127.0.0.1",
        port: Int = 8080,
        backlog: Int = 4096,
        max_connections: Int = 65_536,
        num_workers: Int = 4,
        read_timeout_ms: Int = 30_000,
        write_timeout_ms: Int = 30_000,
        keep_alive_timeout_ms: Int = 75_000,
        max_keep_alive_requests: Int = 1000,
        max_header_size: Int = 8192,
        max_body_size: Int = 10_485_760,
        read_buffer_size: Int = 8192,
        write_buffer_size: Int = 16_384,
        tcp_nodelay: Bool = True,
        reuse_address: Bool = True,
        reuse_port: Bool = False,
        server_name: String = "MojoFlow/0.2.0",
        debug: Bool = False,
        tls: TLSConfig = TLSConfig(),
    ):
        self.host = host
        self.port = port
        self.backlog = backlog
        self.max_connections = max_connections
        self.num_workers = num_workers
        self.read_timeout_ms = read_timeout_ms
        self.write_timeout_ms = write_timeout_ms
        self.keep_alive_timeout_ms = keep_alive_timeout_ms
        self.max_keep_alive_requests = max_keep_alive_requests
        self.max_header_size = max_header_size
        self.max_body_size = max_body_size
        self.read_buffer_size = read_buffer_size
        self.write_buffer_size = write_buffer_size
        self.tcp_nodelay = tcp_nodelay
        self.reuse_address = reuse_address
        self.reuse_port = reuse_port
        self.server_name = server_name
        self.debug = debug
        self.tls = tls

    # ── Helpers ───────────────────────────────────────────────────

    fn address(self) -> String:
        """Return `host:port` string for display and socket binding."""
        return self.host + ":" + String(self.port)

    fn validate(self) raises:
        """Raise if the configuration is invalid.

        Checks:
            - Port in valid range (1–65535).
            - Positive buffer sizes and timeouts.
            - Worker count ≥ 1.
        """
        if self.port < 1 or self.port > 65535:
            raise ServerError.configuration(
                "Port out of range", String(self.port)
            ).to_error()

        if self.num_workers < 1:
            raise ServerError.configuration(
                "num_workers must be ≥ 1", String(self.num_workers)
            ).to_error()

        if self.read_buffer_size < 512:
            raise ServerError.configuration(
                "read_buffer_size too small", String(self.read_buffer_size)
            ).to_error()

        if self.max_header_size < 256:
            raise ServerError.configuration(
                "max_header_size too small", String(self.max_header_size)
            ).to_error()

        if self.backlog < 1:
            raise ServerError.configuration(
                "backlog must be ≥ 1", String(self.backlog)
            ).to_error()

    fn __str__(self) -> String:
        return (
            "ServerConfig("
            + self.address()
            + ", workers="
            + String(self.num_workers)
            + ", max_conn="
            + String(self.max_connections)
            + ")"
        )
