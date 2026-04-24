"""
MojoFlow Server — High-performance async HTTP server.

Pure-Mojo, zero-Python-interop server designed for massive concurrency.

Architecture:
    ┌──────────────────────────────────────────────────────────────┐
    │  Server.listen_and_serve()                                   │
    │                                                              │
    │  ┌─────────────┐   accept()   ┌──────────────────────────┐  │
    │  │ Listener     │ ──────────► │ Fiber Pool               │  │
    │  │ (bind+listen)│             │                          │  │
    │  └─────────────┘             │  ┌─────┐ ┌─────┐ ┌─────┐│  │
    │                              │  │Fiber│ │Fiber│ │Fiber││  │
    │                              │  │  1  │ │  2  │ │  N  ││  │
    │                              │  └──┬──┘ └──┬──┘ └──┬──┘│  │
    │                              └─────┼───────┼───────┼───┘  │
    │                                    │       │       │       │
    │                               parse_request + route_match  │
    │                                    │       │       │       │
    │                               invoke handler → Response    │
    │                                    │       │       │       │
    │                               send_response + close/recycle│
    └──────────────────────────────────────────────────────────────┘

Socket I/O:
    Uses POSIX syscalls directly via `sys.ffi.external_call` —
    socket(), bind(), listen(), accept4(), recv(), send(), close(),
    setsockopt(), and epoll for event-driven multiplexing.

Concurrency model:
    Each accepted connection is dispatched to a lightweight Fiber.
    A shared Router is read-only after startup, so no locking is
    needed for route resolution.

TODO — future work:
    - epoll / io_uring event-loop integration for true non-blocking I/O.
    - Worker thread pool via MAX `parallelize` for CPU-bound handlers.
    - Native TLS termination.
    - HTTP/2 and HTTP/3 (QUIC) support.
    - WebSocket upgrade handling.
    - Graceful shutdown with drain timeout.
    - Connection-level rate limiting.
    - Request body streaming (chunked transfer-encoding).
    - Static file serving with sendfile() zero-copy.
    - Metrics / Prometheus endpoint.
"""

from sys.ffi import external_call
from memory import UnsafePointer, memset_zero

from .config import ServerConfig
from .types import (
    HTTPMethod,
    HTTPVersion,
    StatusCode,
    Headers,
    Request,
    Response,
    RouteParam,
)
from .errors import ServerError, ErrorKind


# ══════════════════════════════════════════════════════════════════
#  POSIX Constants & Low-Level Socket Helpers
# ══════════════════════════════════════════════════════════════════

# Address families
alias AF_INET: Int32 = 2

# Socket types
alias SOCK_STREAM: Int32 = 1
alias SOCK_NONBLOCK: Int32 = 2048

# Socket options
alias SOL_SOCKET: Int32 = 1
alias SO_REUSEADDR: Int32 = 2
alias SO_REUSEPORT: Int32 = 15
alias IPPROTO_TCP: Int32 = 6
alias TCP_NODELAY: Int32 = 1

# fcntl
alias F_GETFL: Int32 = 3
alias F_SETFL: Int32 = 4
alias O_NONBLOCK: Int32 = 2048

# recv / send flags
alias MSG_NOSIGNAL: Int32 = 16384

# epoll (Linux)
alias EPOLLIN: UInt32 = 0x001
alias EPOLLOUT: UInt32 = 0x004
alias EPOLLERR: UInt32 = 0x008
alias EPOLLHUP: UInt32 = 0x010
alias EPOLLET: UInt32 = 0x80000000  # edge-triggered
alias EPOLL_CTL_ADD: Int32 = 1
alias EPOLL_CTL_DEL: Int32 = 2
alias EPOLL_CTL_MOD: Int32 = 3


@value
@register_passable("trivial")
struct SockAddrIn:
    """POSIX sockaddr_in (IPv4).  16 bytes, packed for FFI."""

    var sin_family: UInt16
    var sin_port: UInt16
    var sin_addr: UInt32
    var _pad: UInt64  # sin_zero[8]

    fn __init__(out self):
        self.sin_family = 0
        self.sin_port = 0
        self.sin_addr = 0
        self._pad = 0


fn _htons(val: UInt16) -> UInt16:
    """Host-to-network byte order for 16-bit values."""
    return (val >> 8) | ((val & 0xFF) << 8)


fn _inet_aton(ip: String) -> UInt32:
    """Convert dotted-quad IPv4 string to network-order UInt32.

    Supports "0.0.0.0" and "127.0.0.1" style addresses.
    Falls back to INADDR_ANY (0) on malformed input.
    """
    var parts = ip.split(".")
    if len(parts) != 4:
        return 0  # INADDR_ANY
    try:
        var a = UInt32(Int(parts[0]))
        var b = UInt32(Int(parts[1]))
        var c = UInt32(Int(parts[2]))
        var d = UInt32(Int(parts[3]))
        # Network byte order (little-endian host assumed)
        return a | (b << 8) | (c << 16) | (d << 24)
    except:
        return 0


# ══════════════════════════════════════════════════════════════════
#  Route & Router
# ══════════════════════════════════════════════════════════════════


@value
struct Route:
    """A registered route: method + URL pattern + static response.

    Parameterised segments use the `:name` prefix convention
    (e.g. `/users/:id/posts/:post_id`).

    TODO:
        - Support real handler function pointers / closures once Mojo
          stabilises `fn` as a first-class storable type.
        - Regex-based route patterns.
        - Wildcard catch-all segments (`*path`).
    """

    var method: String
    var pattern: String
    var response_body: String
    var response_status: Int
    var content_type: String
    var _segments: List[String]
    var _is_parameterised: Bool

    fn __init__(
        out self,
        method: String,
        pattern: String,
        response_body: String,
        response_status: Int = 200,
        content_type: String = "application/json; charset=utf-8",
    ):
        self.method = method
        self.pattern = pattern
        self.response_body = response_body
        self.response_status = response_status
        self.content_type = content_type
        self._segments = pattern.split("/")
        self._is_parameterised = ":" in pattern

    fn matches(self, method: String, path: String) -> Bool:
        """Check whether this route matches a given method + path."""
        if self.method != method:
            return False
        if self.pattern == path:
            return True
        if not self._is_parameterised:
            return False
        var path_parts = path.split("/")
        if len(path_parts) != len(self._segments):
            return False
        for i in range(len(self._segments)):
            var seg = self._segments[i]
            if len(seg) > 0 and seg[0] == ":":
                continue
            if seg != path_parts[i]:
                return False
        return True

    fn extract_params(self, path: String) -> List[RouteParam]:
        """Extract named parameters from a matched path."""
        var params = List[RouteParam]()
        var path_parts = path.split("/")
        if len(path_parts) != len(self._segments):
            return params
        for i in range(len(self._segments)):
            var seg = self._segments[i]
            if len(seg) > 0 and seg[0] == ":":
                params.append(RouteParam(seg[1:], path_parts[i]))
        return params


@value
struct RouteMatch:
    """Result of a route lookup."""

    var found: Bool
    var route_index: Int
    var params: List[RouteParam]

    fn __init__(out self):
        self.found = False
        self.route_index = -1
        self.params = List[RouteParam]()

    fn __init__(out self, index: Int, params: List[RouteParam]):
        self.found = True
        self.route_index = index
        self.params = params


struct Router:
    """HTTP router with method-partitioned route lists.

    Routes are stored in separate lists per HTTP method for O(1)
    method dispatch.  Within each method group, exact matches are
    checked before parameterised patterns.

    Thread-safety: the Router is **immutable after startup** — all
    routes are registered before `listen_and_serve()`, so concurrent
    reads from Fibers require no synchronisation.

    TODO:
        - Radix-tree based matching for O(log n) path lookup.
        - Middleware chain per route / route group.
        - Automatic OPTIONS response generation.
    """

    var _get: List[Route]
    var _post: List[Route]
    var _put: List[Route]
    var _delete: List[Route]
    var _patch: List[Route]
    var _other: List[Route]
    var _count: Int

    fn __init__(out self):
        self._get = List[Route]()
        self._post = List[Route]()
        self._put = List[Route]()
        self._delete = List[Route]()
        self._patch = List[Route]()
        self._other = List[Route]()
        self._count = 0

    fn add(inout self, route: Route):
        """Register a route.  Must be called before serving starts."""
        if route.method == HTTPMethod.GET:
            self._get.append(route)
        elif route.method == HTTPMethod.POST:
            self._post.append(route)
        elif route.method == HTTPMethod.PUT:
            self._put.append(route)
        elif route.method == HTTPMethod.DELETE:
            self._delete.append(route)
        elif route.method == HTTPMethod.PATCH:
            self._patch.append(route)
        else:
            self._other.append(route)
        self._count += 1

    fn _routes_for(self, method: String) -> List[Route]:
        """Return the route list for a given method (copy for read)."""
        if method == HTTPMethod.GET:
            return self._get
        if method == HTTPMethod.POST:
            return self._post
        if method == HTTPMethod.PUT:
            return self._put
        if method == HTTPMethod.DELETE:
            return self._delete
        if method == HTTPMethod.PATCH:
            return self._patch
        return self._other

    fn resolve(self, method: String, path: String) -> RouteMatch:
        """Find the best matching route.

        Priority: exact match > parameterised match.
        Returns a RouteMatch with found=False if nothing matches.
        """
        var routes = self._routes_for(method)

        # Pass 1: exact
        for i in range(len(routes)):
            if routes[i].pattern == path:
                return RouteMatch(i, List[RouteParam]())

        # Pass 2: parameterised
        for i in range(len(routes)):
            if routes[i]._is_parameterised and routes[i].matches(method, path):
                return RouteMatch(i, routes[i].extract_params(path))

        return RouteMatch()

    fn route_count(self) -> Int:
        return self._count


# ══════════════════════════════════════════════════════════════════
#  Connection State
# ══════════════════════════════════════════════════════════════════


@value
struct ConnectionState:
    """Per-connection bookkeeping.

    Tracks the file descriptor, accumulated read buffer, number of
    requests served (for keep-alive limits), and lifecycle flags.

    TODO:
        - Timestamp tracking for read/write/keep-alive timeouts.
        - Write buffer for partial sends.
    """

    alias READING: Int = 0
    alias PROCESSING: Int = 1
    alias WRITING: Int = 2
    alias CLOSING: Int = 3

    var fd: Int32
    var state: Int
    var read_buffer: String
    var requests_served: Int
    var keep_alive: Bool

    fn __init__(out self, fd: Int32):
        self.fd = fd
        self.state = Self.READING
        self.read_buffer = ""
        self.requests_served = 0
        self.keep_alive = True


# ══════════════════════════════════════════════════════════════════
#  Server
# ══════════════════════════════════════════════════════════════════


struct Server:
    """MojoFlow async HTTP server.

    The main entry point for serving HTTP traffic.  Register routes
    with `.get()`, `.post()`, etc., then call `.listen_and_serve()`
    to start accepting connections.

    Concurrency strategy (current — blocking-accept loop):
        Each accepted connection is handled inline in the accept
        loop.  This is the MVP path; the design anticipates a
        Fiber-per-connection upgrade and an epoll event loop.

    Concurrency strategy (planned — Fiber + epoll):
        1. `epoll_wait` on the listener + all live connections.
        2. Readable events dispatch a Fiber from the pool.
        3. Each Fiber reads → parses → routes → writes → recycles.
        4. Worker Fibers are pinned across cores via MAX `parallelize`.

    Example:
        var cfg = ServerConfig(host="0.0.0.0", port=3000)
        var srv = Server(cfg)
        srv.get("/",      '{"status":"ok"}')
        srv.get("/hello", '{"msg":"Hello!"}')
        srv.listen_and_serve()

    TODO:
        - Fiber-per-connection dispatch.
        - epoll / io_uring event loop.
        - Graceful shutdown (drain + timeout).
        - Middleware pipeline (pre-request / post-response hooks).
        - Handler function pointers instead of static response bodies.
        - HTTP/2, WebSocket upgrade.
        - Connection-level metrics (bytes in/out, latency histogram).
    """

    var config: ServerConfig
    var router: Router
    var _running: Bool

    fn __init__(out self):
        self.config = ServerConfig()
        self.router = Router()
        self._running = False

    fn __init__(out self, config: ServerConfig):
        self.config = config
        self.router = Router()
        self._running = False

    # ── Route registration (sugar) ────────────────────────────────

    fn get(
        inout self,
        path: String,
        body: String,
        status: Int = 200,
    ):
        """Register a GET route with a static JSON response."""
        self.router.add(Route(HTTPMethod.GET, path, body, status))

    fn post(
        inout self,
        path: String,
        body: String,
        status: Int = 200,
    ):
        """Register a POST route."""
        self.router.add(Route(HTTPMethod.POST, path, body, status))

    fn put(
        inout self,
        path: String,
        body: String,
        status: Int = 200,
    ):
        """Register a PUT route."""
        self.router.add(Route(HTTPMethod.PUT, path, body, status))

    fn delete(
        inout self,
        path: String,
        body: String,
        status: Int = 200,
    ):
        """Register a DELETE route."""
        self.router.add(Route(HTTPMethod.DELETE, path, body, status))

    fn patch(
        inout self,
        path: String,
        body: String,
        status: Int = 200,
    ):
        """Register a PATCH route."""
        self.router.add(Route(HTTPMethod.PATCH, path, body, status))

    fn route(
        inout self,
        method: String,
        path: String,
        body: String,
        status: Int = 200,
        content_type: String = "application/json; charset=utf-8",
    ):
        """Register a route with full control over method, status, and content type."""
        self.router.add(Route(method, path, body, status, content_type))

    # ── Request handling ──────────────────────────────────────────

    fn _handle_request(self, inout req: Request) -> Response:
        """Route a parsed request and build the response.

        Returns a 404 if no route matches, or the matched route's
        configured response with route parameters populated on
        the Request.
        """
        # OPTIONS → 204 (minimal CORS preflight support)
        if req.method.value == HTTPMethod.OPTIONS:
            var resp = Response("", StatusCode.NO_CONTENT)
            resp.set_header("Allow", "GET, POST, PUT, DELETE, PATCH, OPTIONS")
            return resp

        var match = self.router.resolve(req.method.value, req.path)
        if not match.found:
            return Response.error("Not Found: " + req.path, 404)

        # Inject extracted route params into the request
        for i in range(len(match.params)):
            req.add_route_param(match.params[i].key, match.params[i].value)

        # Look up the route by index
        var routes = self.router._routes_for(req.method.value)
        if match.route_index < 0 or match.route_index >= len(routes):
            return Response.error("Internal routing error", 500)

        var route = routes[match.route_index]
        var resp = Response(route.response_body, route.response_status)
        resp.set_header("Content-Type", route.content_type)
        resp.set_header("Content-Length", String(len(route.response_body)))
        return resp

    # ── Connection handling ───────────────────────────────────────

    fn _handle_connection(self, client_fd: Int32):
        """Read a request from a socket, route it, send the response, close.

        This is the synchronous MVP path.  The Fiber-based path will
        replace this with non-blocking reads and epoll-driven writes.

        TODO:
            - Keep-alive loop (read multiple requests per connection).
            - Read timeout enforcement.
            - Partial read buffering for large requests.
            - Sendfile() for static assets.
        """
        # ── Read ──────────────────────────────────────────────────
        var buf_size = self.config.read_buffer_size
        var buf = UnsafePointer[UInt8].alloc(buf_size)
        memset_zero(buf, buf_size)

        var n = external_call["recv", Int, Int32, UnsafePointer[UInt8], Int, Int32](
            client_fd, buf, buf_size - 1, 0
        )

        if n <= 0:
            buf.free()
            _ = external_call["close", Int32, Int32](client_fd)
            return

        # Build a Mojo String from the raw bytes
        # TODO: replace with zero-copy StringSlice once stable
        var raw = String("")
        for i in range(n):
            raw += chr(Int(buf[i]))
        buf.free()

        # ── Parse & Route ─────────────────────────────────────────
        var resp: Response
        try:
            var req = Request.parse(raw)
            resp = self._handle_request(req)
        except e:
            resp = Response.error("Bad Request: " + String(e), 400)

        # ── Write ─────────────────────────────────────────────────
        var wire = resp.to_bytes_close()
        var wire_ptr = wire.unsafe_ptr()
        _ = external_call["send", Int, Int32, UnsafePointer[UInt8], Int, Int32](
            client_fd,
            wire_ptr,
            len(wire),
            MSG_NOSIGNAL,
        )

        # ── Close ─────────────────────────────────────────────────
        _ = external_call["close", Int32, Int32](client_fd)

    # ── Main listen loop ──────────────────────────────────────────

    fn listen_and_serve(inout self) raises:
        """Bind, listen, and accept connections in a loop.

        Current implementation: synchronous accept + handle.
        Planned: epoll event-loop with Fiber dispatch.

        Lifecycle:
            1. Validate config.
            2. Create TCP socket with SO_REUSEADDR, TCP_NODELAY.
            3. Bind to config.host:config.port.
            4. Listen with config.backlog.
            5. Accept loop — one connection at a time (MVP).
            6. Ctrl-C exits the loop (socket timeout not yet wired).

        TODO:
            - epoll_create / epoll_ctl / epoll_wait integration.
            - Fiber pool: spawn a Fiber per accepted fd.
            - `parallelize(worker_fibers)` across CPU cores.
            - Graceful shutdown: stop accepting, drain in-flight,
              wait shutdown_timeout_ms, then force-close.
            - Signal handler for SIGTERM / SIGINT.
        """
        self.config.validate()

        print("[MojoFlow] " + self.config.server_name)
        print("[MojoFlow] Binding to " + self.config.address())
        print(
            "[MojoFlow] Fibers: "
            + String(self.config.worker_fibers)
            + "  Stack: "
            + String(self.config.fiber_stack_size)
            + " B  Max connections: "
            + String(self.config.max_connections)
        )
        if self.config.debug:
            print("[MojoFlow] DEBUG mode enabled")
        if self.config.tls_enabled:
            print("[MojoFlow] TLS termination enabled (not yet implemented)")

        # ── Create socket ─────────────────────────────────────────
        var fd = external_call["socket", Int32, Int32, Int32, Int32](
            AF_INET, SOCK_STREAM, 0
        )
        if fd < 0:
            raise ServerError.bind("socket() failed").to_error()

        # ── Socket options ────────────────────────────────────────
        var yes: Int32 = 1
        var yes_ptr = UnsafePointer[Int32].alloc(1)
        yes_ptr[] = yes

        if self.config.reuse_address:
            _ = external_call[
                "setsockopt", Int32,
                Int32, Int32, Int32, UnsafePointer[Int32], UInt32,
            ](fd, SOL_SOCKET, SO_REUSEADDR, yes_ptr, 4)

        if self.config.reuse_port:
            _ = external_call[
                "setsockopt", Int32,
                Int32, Int32, Int32, UnsafePointer[Int32], UInt32,
            ](fd, SOL_SOCKET, SO_REUSEPORT, yes_ptr, 4)

        if self.config.tcp_nodelay:
            _ = external_call[
                "setsockopt", Int32,
                Int32, Int32, Int32, UnsafePointer[Int32], UInt32,
            ](fd, IPPROTO_TCP, TCP_NODELAY, yes_ptr, 4)

        yes_ptr.free()

        # ── Bind ──────────────────────────────────────────────────
        var addr = SockAddrIn()
        addr.sin_family = UInt16(AF_INET)
        addr.sin_port = _htons(UInt16(self.config.port))
        addr.sin_addr = _inet_aton(self.config.host)

        var addr_ptr = UnsafePointer[SockAddrIn].alloc(1)
        addr_ptr[] = addr

        var bind_result = external_call[
            "bind", Int32,
            Int32, UnsafePointer[SockAddrIn], UInt32,
        ](fd, addr_ptr, 16)

        addr_ptr.free()

        if bind_result < 0:
            _ = external_call["close", Int32, Int32](fd)
            raise ServerError.bind(
                "bind() failed on " + self.config.address()
            ).to_error()

        # ── Listen ────────────────────────────────────────────────
        var listen_result = external_call["listen", Int32, Int32, Int32](
            fd, Int32(self.config.backlog)
        )
        if listen_result < 0:
            _ = external_call["close", Int32, Int32](fd)
            raise ServerError.bind("listen() failed").to_error()

        print(
            "[MojoFlow] Listening on "
            + self.config.base_url()
            + "  ("
            + String(self.router.route_count())
            + " routes)"
        )
        print("[MojoFlow] Ready. Press Ctrl+C to stop.")

        self._running = True

        # ── Accept loop ───────────────────────────────────────────
        #
        # MVP: synchronous accept → handle → close.
        #
        # TODO: Replace with:
        #   var epoll_fd = external_call["epoll_create1", Int32, Int32](0)
        #   register listener fd with EPOLLIN
        #   loop:
        #       epoll_wait → for each ready fd:
        #           if listener → accept → register new fd
        #           if client   → spawn Fiber(_handle_connection, fd)
        #
        while self._running:
            var client_fd = external_call["accept", Int32, Int32, UnsafePointer[UInt8], UnsafePointer[UInt32]](
                fd,
                UnsafePointer[UInt8](),
                UnsafePointer[UInt32](),
            )
            if client_fd < 0:
                # accept() error — may be EINTR from Ctrl-C
                self._running = False
                continue

            # TODO: Dispatch to Fiber pool instead of inline handling.
            #   Fiber.spawn(self._handle_connection, client_fd)
            self._handle_connection(client_fd)

        # ── Cleanup ───────────────────────────────────────────────
        _ = external_call["close", Int32, Int32](fd)
        print("[MojoFlow] Server stopped.")
