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
from memory import UnsafePointer

from .config import ServerConfig
from .types import (
    HTTPMethod,
    StatusCode,
    Request,
    Response,
    RouteParam,
)
from .net import AsyncListener
from .runtime import AsyncRuntime, FiberPool, WorkerModel
from .observability import Observability
from .handler import (
    RequestHandler,
    HandlerContext,
    AsyncRequestHandler,
    MiddlewareStack,
    NoopMiddleware,
)


# recv / send flags
alias MSG_NOSIGNAL: Int32 = 16384


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
    var handler_name: String
    var is_dynamic: Bool
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
        self.handler_name = ""
        self.is_dynamic = False
        self._segments = pattern.split("/")
        self._is_parameterised = ":" in pattern

    @staticmethod
    fn dynamic(
        method: String,
        pattern: String,
        handler_name: String,
    ) -> Route:
        """Create a route backed by a user function/decorator handler.

        The current built-in Router stores dynamic route metadata.  Actual
        invocation is handled by DecoratedRouterHandler so the server can keep
        static string routes and decorated async routes in the same table.
        """
        var route = Route(method, pattern, "", 200, "application/json; charset=utf-8")
        route.handler_name = handler_name
        route.is_dynamic = True
        return route

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

    fn _openapi_pattern(self, pattern: String) -> String:
        """Convert MojoFlow `:param` segments to OpenAPI `{param}` segments."""
        if not (":" in pattern):
            return pattern
        var parts = pattern.split("/")
        var out = ""
        for i in range(len(parts)):
            if i > 0:
                out += "/"
            var part = parts[i]
            if len(part) > 0 and part[0] == ":":
                out += "{" + part[1:] + "}"
            else:
                out += part
        return out

    fn _append_openapi_routes(
        self,
        routes: List[Route],
        method: String,
        inout out: String,
        inout first: Bool,
    ):
        for i in range(len(routes)):
            if not first:
                out += ","
            first = False
            var path = self._openapi_pattern(routes[i].pattern)
            out += '"' + path + '":{'
            out += '"' + method + '":{'
            out += '"operationId":"' + method + "_" + String(i) + '",'
            out += '"responses":{"200":{"description":"OK"}}'
            out += "}}"

    fn openapi_json(
        self,
        title: String = "MojoFlow API",
        version: String = "0.1.0",
    ) -> String:
        """Generate a simple OpenAPI 3.1 document from registered routes."""
        var out = "{"
        out += '"openapi":"3.1.0",'
        out += '"info":{"title":"' + title + '","version":"' + version + '"},'
        out += '"paths":{'
        var first = True
        self._append_openapi_routes(self._get, "get", out, first)
        self._append_openapi_routes(self._post, "post", out, first)
        self._append_openapi_routes(self._put, "put", out, first)
        self._append_openapi_routes(self._delete, "delete", out, first)
        self._append_openapi_routes(self._patch, "patch", out, first)
        self._append_openapi_routes(self._other, "x-mojoflow", out, first)
        out += "}}"
        return out


struct BuiltInRouterHandler(RequestHandler):
    """RequestHandler adapter for the built-in method + path router."""

    var router: Router

    fn __init__(out self):
        self.router = Router()

    fn __init__(out self, router: Router):
        self.router = router

    fn handle(
        inout self,
        inout req: Request,
        inout context: HandlerContext,
    ) raises -> Response:
        if req.method.value == HTTPMethod.OPTIONS:
            var resp = Response("", StatusCode.NO_CONTENT)
            resp.set_header("Allow", "GET, POST, PUT, DELETE, PATCH, OPTIONS")
            return resp

        var match = self.router.resolve(req.method.value, req.path)
        if not match.found:
            return Response.error("Not Found: " + req.path, 404)

        for i in range(len(match.params)):
            req.add_route_param(match.params[i].key, match.params[i].value)

        var routes = self.router._routes_for(req.method.value)
        if match.route_index < 0 or match.route_index >= len(routes):
            return Response.error("Internal routing error", 500)

        var route = routes[match.route_index]
        if route.is_dynamic:
            return Response.error(
                "Dynamic route requires listen_and_serve_decorated()",
                501,
            )

        var resp = Response(route.response_body, route.response_status)
        resp.set_header("Content-Type", route.content_type)
        resp.set_header("Content-Length", String(len(route.response_body)))
        return resp


trait RouteFunction:
    """Trait for decorator-registered route handlers.

    AI/UI integrations can implement this trait on small adapter structs that
    capture LLM clients, agents, UI compilers, or other app state.  The server
    still sees a normal async RequestHandler-compatible pipeline.
    """

    fn call(
        inout self,
        inout request: Request,
        inout context: HandlerContext,
    ) raises -> Response:
        ...


struct DecoratedRouterHandler[F: RouteFunction](RequestHandler):
    """RequestHandler adapter for one decorator-registered route function.

    This keeps the first implementation conservative: the router owns method
    + path matching, while the route function owns the user logic.  More
    sophisticated storage for many heterogeneous handlers can extend this
    without changing the public decorator shape.
    """

    var router: Router
    var route_function: F

    fn __init__(out self, router: Router, route_function: F):
        self.router = router
        self.route_function = route_function

    fn handle(
        inout self,
        inout req: Request,
        inout context: HandlerContext,
    ) raises -> Response:
        var match = self.router.resolve(req.method.value, req.path)
        if not match.found:
            return Response.error("Not Found: " + req.path, 404)

        for i in range(len(match.params)):
            req.add_route_param(match.params[i].key, match.params[i].value)

        var routes = self.router._routes_for(req.method.value)
        if match.route_index < 0 or match.route_index >= len(routes):
            return Response.error("Internal routing error", 500)
        if not routes[match.route_index].is_dynamic:
            var static_handler = BuiltInRouterHandler(self.router)
            return static_handler.handle(req, context)

        return self.route_function.call(req, context)


struct FunctionRouteAdapter[
    handler_fn: fn (Request) raises -> Response
](RouteFunction):
    """Adapter for plain `fn(Request) -> Response` route handlers."""

    fn __init__(out self):
        pass

    fn call(
        inout self,
        inout request: Request,
        inout context: HandlerContext,
    ) raises -> Response:
        return handler_fn(request)


struct AsyncFunctionRouteAdapter[
    handler_fn: fn (Request, HandlerContext) raises -> Response
](RouteFunction):
    """Adapter for handlers that want the async HandlerContext."""

    fn __init__(out self):
        pass

    fn call(
        inout self,
        inout request: Request,
        inout context: HandlerContext,
    ) raises -> Response:
        return handler_fn(request, context)


struct RouteDecorator:
    """Decorator-style route registrar returned by `server.get("/path")`.

    Usage:

        @server.get("/hello")
        fn hello(req: Request) raises -> Response:
            return Response.json('{"hello": true}')

    Direct call form is also supported by the same object:

        server.get("/hello")(hello)

    The registrar keeps route metadata in the Server's built-in Router and
    returns an adapter that can be passed to `listen_and_serve_with_handler`.
    """

    var method: String
    var path: String

    fn __init__(out self, method: String, path: String):
        self.method = method
        self.path = path

    fn __call__[
        handler_fn: fn (Request) raises -> Response
    ](self) -> FunctionRouteAdapter[handler_fn]:
        return FunctionRouteAdapter[handler_fn]()

    fn async_handler[
        handler_fn: fn (Request, HandlerContext) raises -> Response
    ](self) -> AsyncFunctionRouteAdapter[handler_fn]:
        """Register a handler that receives HandlerContext.

        This is useful for AI/data-heavy routes that want
        `context.parallel_for()` or other async server metadata.
        """
        return AsyncFunctionRouteAdapter[handler_fn]()


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


struct PendingConnectionQueue:
    """Bounded FIFO for accepted sockets waiting for a Fiber slot."""

    var _fds: List[Int32]
    var _capacity: Int

    fn __init__(out self):
        self._fds = List[Int32]()
        self._capacity = 0

    fn __init__(out self, capacity: Int):
        self._fds = List[Int32]()
        self._capacity = capacity

    fn push(inout self, fd: Int32) -> Bool:
        if self._capacity == 0:
            return False
        if len(self._fds) >= self._capacity:
            return False
        self._fds.append(fd)
        return True

    fn pop(inout self) -> Int32:
        if len(self._fds) == 0:
            return -1
        var fd = self._fds[0]
        var next = List[Int32]()
        for i in range(1, len(self._fds)):
            next.append(self._fds[i])
        self._fds = next
        return fd

    fn len(self) -> Int:
        return len(self._fds)

    fn is_empty(self) -> Bool:
        return len(self._fds) == 0

    fn is_full(self) -> Bool:
        return self._capacity > 0 and len(self._fds) >= self._capacity


struct ConnectionPool:
    """Reusable connection state slots to avoid hot-path allocation churn."""

    var _fds: List[Int32]
    var _free: List[Int]
    var _capacity: Int

    fn __init__(out self):
        self._fds = List[Int32]()
        self._free = List[Int]()
        self._capacity = 0

    fn __init__(out self, capacity: Int):
        self._fds = List[Int32]()
        self._free = List[Int]()
        self._capacity = capacity
        for i in range(capacity):
            self._fds.append(-1)
            self._free.append(i)

    fn acquire(inout self, fd: Int32) -> Int:
        if len(self._free) == 0:
            return -1
        var slot = self._free[len(self._free) - 1]
        var next = List[Int]()
        for i in range(len(self._free) - 1):
            next.append(self._free[i])
        self._free = next
        self._fds[slot] = fd
        return slot

    fn release(inout self, slot: Int):
        if slot < 0 or slot >= self._capacity:
            return
        self._fds[slot] = -1
        self._free.append(slot)

    fn idle_count(self) -> Int:
        return len(self._free)

    fn active_count(self) -> Int:
        return self._capacity - len(self._free)


# ══════════════════════════════════════════════════════════════════
#  Server
# ══════════════════════════════════════════════════════════════════


struct Server:
    """MojoFlow async HTTP server.

    The main entry point for serving HTTP traffic.  Register routes
    with `.get()`, `.post()`, etc., then call `.listen_and_serve()`
    to start accepting connections.

    Concurrency strategy:
        1. AsyncListener binds and exposes a non-blocking listener fd.
        2. AsyncRuntime/EventLoop polls the listener in a hot loop.
        3. Every accepted connection is assigned to a FiberPool slot.
        4. The Fiber runs AsyncRequestHandler: parse, middleware,
           user handler/router, response write, close.
        5. Shutdown stops accepting and drains active Fibers.

    Example:
        var cfg = ServerConfig(host="0.0.0.0", port=3000)
        var srv = Server(cfg)
        srv.get("/",      '{"status":"ok"}')
        srv.get("/hello", '{"msg":"Hello!"}')
        srv.listen_and_serve()

    TODO:
        - Real coroutine/Fiber suspension once Mojo exposes stable Fibers.
        - io_uring event loop.
        - Heterogeneous middleware storage once boxed trait objects land.
        - Function-pointer/closure routes instead of static response bodies.
        - HTTP/2, WebSocket upgrade.
        - Connection-level metrics (bytes in/out, latency histogram).
    """

    var config: ServerConfig
    var router: Router
    var _fiber_pool: FiberPool
    var _running: Bool
    var _accepting: Bool
    var _shutdown_requested: Bool
    var _connections_total: Int
    var _observability_routes_registered: Bool
    var _pending_connections: PendingConnectionQueue
    var _connection_pool: ConnectionPool
    var observability: Observability

    fn __init__(out self):
        self.config = ServerConfig()
        self.router = Router()
        self._fiber_pool = FiberPool(self.config.total_fiber_slots())
        self._running = False
        self._accepting = False
        self._shutdown_requested = False
        self._connections_total = 0
        self._observability_routes_registered = False
        self._pending_connections = PendingConnectionQueue(
            self.config.max_pending_connections
        )
        self._connection_pool = ConnectionPool(self.config.max_connections)
        self.observability = Observability(self.config)

    fn __init__(out self, config: ServerConfig):
        self.config = config
        self.router = Router()
        self._fiber_pool = FiberPool(config.total_fiber_slots())
        self._running = False
        self._accepting = False
        self._shutdown_requested = False
        self._connections_total = 0
        self._observability_routes_registered = False
        self._pending_connections = PendingConnectionQueue(
            config.max_pending_connections
        )
        self._connection_pool = ConnectionPool(config.max_connections)
        self.observability = Observability(config)

    fn __init__(out self, config: ServerConfig, router: Router):
        """Create a server with an externally prepared built-in router."""
        self.config = config
        self.router = router
        self._fiber_pool = FiberPool(config.total_fiber_slots())
        self._running = False
        self._accepting = False
        self._shutdown_requested = False
        self._connections_total = 0
        self._observability_routes_registered = False
        self._pending_connections = PendingConnectionQueue(
            config.max_pending_connections
        )
        self._connection_pool = ConnectionPool(config.max_connections)
        self.observability = Observability(config)

    # ── Route registration (sugar) ────────────────────────────────

    fn get(
        inout self,
        path: String,
        body: String,
        status: Int = 200,
    ):
        """Register a GET route with a static JSON response."""
        self.router.add(Route(HTTPMethod.GET, path, body, status))

    fn get(inout self, path: String) -> RouteDecorator:
        """Decorator-style GET registration.

        Keeps compatibility with `@server.get("/path")` style APIs while
        preserving the existing `server.get("/path", body)` static route API.
        """
        self.router.add(Route.dynamic(HTTPMethod.GET, path, "decorated"))
        return RouteDecorator(HTTPMethod.GET, path)

    fn post(
        inout self,
        path: String,
        body: String,
        status: Int = 200,
    ):
        """Register a POST route."""
        self.router.add(Route(HTTPMethod.POST, path, body, status))

    fn post(inout self, path: String) -> RouteDecorator:
        """Decorator-style POST registration."""
        self.router.add(Route.dynamic(HTTPMethod.POST, path, "decorated"))
        return RouteDecorator(HTTPMethod.POST, path)

    fn put(
        inout self,
        path: String,
        body: String,
        status: Int = 200,
    ):
        """Register a PUT route."""
        self.router.add(Route(HTTPMethod.PUT, path, body, status))

    fn put(inout self, path: String) -> RouteDecorator:
        """Decorator-style PUT registration."""
        self.router.add(Route.dynamic(HTTPMethod.PUT, path, "decorated"))
        return RouteDecorator(HTTPMethod.PUT, path)

    fn delete(
        inout self,
        path: String,
        body: String,
        status: Int = 200,
    ):
        """Register a DELETE route."""
        self.router.add(Route(HTTPMethod.DELETE, path, body, status))

    fn delete(inout self, path: String) -> RouteDecorator:
        """Decorator-style DELETE registration."""
        self.router.add(Route.dynamic(HTTPMethod.DELETE, path, "decorated"))
        return RouteDecorator(HTTPMethod.DELETE, path)

    fn patch(
        inout self,
        path: String,
        body: String,
        status: Int = 200,
    ):
        """Register a PATCH route."""
        self.router.add(Route(HTTPMethod.PATCH, path, body, status))

    fn patch(inout self, path: String) -> RouteDecorator:
        """Decorator-style PATCH registration."""
        self.router.add(Route.dynamic(HTTPMethod.PATCH, path, "decorated"))
        return RouteDecorator(HTTPMethod.PATCH, path)

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

    fn route(inout self, method: String, path: String) -> RouteDecorator:
        """Decorator-style registration for any HTTP method."""
        self.router.add(Route.dynamic(method, path, "decorated"))
        return RouteDecorator(method, path)

    fn decorate_get[
        handler_fn: fn (Request) raises -> Response
    ](inout self, path: String) -> FunctionRouteAdapter[handler_fn]:
        """Explicit equivalent of `@server.get(path)` for plain handlers."""
        self.router.add(Route.dynamic(HTTPMethod.GET, path, "decorated"))
        return FunctionRouteAdapter[handler_fn]()

    fn decorate_post[
        handler_fn: fn (Request) raises -> Response
    ](inout self, path: String) -> FunctionRouteAdapter[handler_fn]:
        """Explicit equivalent of `@server.post(path)` for plain handlers."""
        self.router.add(Route.dynamic(HTTPMethod.POST, path, "decorated"))
        return FunctionRouteAdapter[handler_fn]()

    fn decorate_get_async[
        handler_fn: fn (Request, HandlerContext) raises -> Response
    ](inout self, path: String) -> AsyncFunctionRouteAdapter[handler_fn]:
        """Register a GET handler that receives HandlerContext."""
        self.router.add(Route.dynamic(HTTPMethod.GET, path, "decorated"))
        return AsyncFunctionRouteAdapter[handler_fn]()

    fn decorate_post_async[
        handler_fn: fn (Request, HandlerContext) raises -> Response
    ](inout self, path: String) -> AsyncFunctionRouteAdapter[handler_fn]:
        """Register a POST handler that receives HandlerContext."""
        self.router.add(Route.dynamic(HTTPMethod.POST, path, "decorated"))
        return AsyncFunctionRouteAdapter[handler_fn]()

    fn use_router(inout self, router: Router):
        """Replace the built-in router before the server starts."""
        if self._running:
            return
        self.router = router

    # ── Request handling ──────────────────────────────────────────

    fn _handle_request(self, inout req: Request) -> Response:
        """Route a parsed request and build the response.

        Returns a 404 if no route matches, or the matched route's
        configured response with route parameters populated on
        the Request.
        """
        var handler = BuiltInRouterHandler(self.router)
        var context = HandlerContext(self.config, -1)
        return handler.handle(req, context)

    # ── Connection handling ───────────────────────────────────────

    fn _handle_connection[
        H: RequestHandler,
    ](
        inout self,
        client_fd: Int32,
        fiber_id: Int,
        inout handler: H,
    ):
        """Read a request from a socket, route it, send the response, close.

        Uses the shared AsyncRequestHandler pipeline so parsing,
        middleware, handler/router, MAX context setup, response
        serialization, and close behavior stay in one place.

        TODO:
            - Keep-alive loop (read multiple requests per connection).
            - Read timeout enforcement.
            - Partial read buffering for large requests.
            - Sendfile() for static assets.
        """
        var middleware = MiddlewareStack[NoopMiddleware]()
        var async_handler = AsyncRequestHandler(self.config, fiber_id)
        try:
            async_handler.handle_connection[H, NoopMiddleware](
                client_fd,
                handler,
                middleware,
                self.observability,
            )
            self.observability.mark_connection_closed()
        except:
            self.observability.mark_connection_closed()
            _ = external_call["close", Int32, Int32](client_fd)

    fn _send_busy(self, client_fd: Int32):
        """Reject a connection when no Fiber slot is available."""
        var busy = Response.error("Server Busy", 503)
        var wire = busy.to_bytes_close()
        _ = external_call[
            "send", Int,
            Int32, UnsafePointer[UInt8], Int, Int32,
        ](client_fd, wire.unsafe_ptr(), len(wire), MSG_NOSIGNAL)
        _ = external_call["close", Int32, Int32](client_fd)

    fn _dispatch_connection[
        H: RequestHandler,
    ](
        inout self,
        client_fd: Int32,
        inout handler: H,
    ):
        """Assign a connection to a FiberPool slot and run its handler."""
        var fiber = self._fiber_pool.spawn(client_fd)
        if fiber.id < 0:
            if not self._pending_connections.push(client_fd):
                self._send_busy(client_fd)
                self.observability.mark_connection_closed()
            return

        var pool_slot = self._connection_pool.acquire(client_fd)
        self._fiber_pool.activate(fiber.id)
        try:
            self._handle_connection[H](client_fd, fiber.id, handler)
            self._connection_pool.release(pool_slot)
            self._fiber_pool.complete(fiber.id)
        except:
            self._connection_pool.release(pool_slot)
            self._fiber_pool.fail(fiber.id)
            _ = external_call["close", Int32, Int32](client_fd)

    fn _drain_pending[
        H: RequestHandler,
    ](
        inout self,
        inout handler: H,
    ):
        """Move queued sockets into newly available Fiber slots."""
        while not self._pending_connections.is_empty():
            if not self._fiber_pool.has_idle():
                break
            var fd = self._pending_connections.pop()
            if fd < 0:
                break
            self._dispatch_connection[H](fd, handler)

    fn _drain_accepts[
        H: RequestHandler,
    ](
        inout self,
        inout listener: AsyncListener,
        inout handler: H,
    ):
        """Drain all pending accepts from an edge-triggered listener."""
        var accepted = 0
        while self._accepting and accepted < self.config.accept_batch_size:
            if self.connection_pressure() >= self.config.max_connections:
                break
            var client_fd = listener.accept()
            if client_fd < 0:
                break
            accepted += 1
            self._connections_total += 1
            self.observability.mark_connection_open()
            self._dispatch_connection[H](client_fd, handler)
        self._drain_pending[H](handler)

    fn _drain_fibers(inout self):
        """Wait for active Fibers to finish after accepting stops."""
        while self._fiber_pool.active_count() > 0:
            self._fiber_pool.await_all()
            break

    fn shutdown(inout self):
        """Request graceful shutdown.

        The hot loop stops accepting new sockets, drains any active
        Fiber slots, then exits and lets AsyncListener close its fd.
        """
        self._shutdown_requested = True
        self._accepting = False
        self._running = False

    fn is_running(self) -> Bool:
        return self._running

    fn connections_total(self) -> Int:
        return self._connections_total

    fn active_fibers(self) -> Int:
        return self._fiber_pool.active_count()

    fn queued_connections(self) -> Int:
        return self._pending_connections.len()

    fn connection_pressure(self) -> Int:
        """Active pooled connections plus sockets waiting for a Fiber slot."""
        return self._connection_pool.active_count() + self._pending_connections.len()

    fn metrics_json(self) -> String:
        """Return a JSON snapshot of built-in server metrics."""
        return self.observability.metrics_json()

    fn openapi_json(self) -> String:
        """Return the generated OpenAPI document for the current router."""
        return self.router.openapi_json(self.config.server_name, "0.1.0")

    fn _register_observability_routes(inout self):
        """Install optional built-in observability routes once."""
        if self._observability_routes_registered:
            return
        if self.config.openapi_enabled:
            self.router.add(
                Route(
                    HTTPMethod.GET,
                    self.config.openapi_path,
                    self.openapi_json(),
                    200,
                    "application/json; charset=utf-8",
                )
            )
        self._observability_routes_registered = True

    # ── Main listen loop ──────────────────────────────────────────

    fn listen_and_serve(inout self) raises:
        """Serve using the built-in Router as the request handler."""
        var handler = BuiltInRouterHandler(self.router)
        self.listen_and_serve_with_handler[BuiltInRouterHandler](handler)

    fn listen_and_serve_decorated[
        F: RouteFunction,
    ](
        inout self,
        inout route_function: F,
    ) raises:
        """Serve using a decorator-registered route function.

        The built-in router still performs method/path matching.  The matched
        dynamic route delegates to `route_function`, so AI/UI code can expose
        endpoints by wrapping agents, LLM clients, UI compilers, or plain JSON
        builders in a RouteFunction.
        """
        var handler = DecoratedRouterHandler[F](self.router, route_function)
        self.listen_and_serve_with_handler[DecoratedRouterHandler[F]](handler)

    fn listen_and_serve_with_handler[
        H: RequestHandler,
    ](
        inout self,
        inout handler: H,
    ) raises:
        """Bind, listen, and serve with a user-provided handler.

        This is the primary server loop.  It binds via AsyncListener,
        polls via AsyncRuntime's EventLoop, accepts in a hot loop, and
        dispatches every connection to the FiberPool.
        """
        self.config.validate()
        self.observability = Observability(self.config)
        self._register_observability_routes()

        print("[MojoFlow] " + self.config.server_name)
        print("[MojoFlow] Binding to " + self.config.address())
        print(
            "[MojoFlow] Fibers: "
            + String(self.config.total_fiber_slots())
            + "  Stack: "
            + String(self.config.fiber_stack_size)
            + " B  Max connections: "
            + String(self.config.max_connections)
        )
        print(
            "[MojoFlow] Workers: "
            + String(self.config.worker_threads)
            + " OS threads  Pending queue: "
            + String(self.config.max_pending_connections)
        )
        if self.config.debug:
            print("[MojoFlow] DEBUG mode enabled")
        if self.config.observability_enabled:
            print(
                "[MojoFlow] Observability enabled"
                + "  logs="
                + self.config.log_level
                + "  metrics="
                + String(self.config.metrics_enabled)
            )
            if self.config.openapi_enabled:
                print("[MojoFlow] OpenAPI: " + self.config.openapi_path)
        if self.config.tls_enabled:
            print("[MojoFlow] TLS termination enabled (not yet implemented)")

        var listener = AsyncListener.start(self.config)
        var worker_model = WorkerModel(self.config)
        var runtime = AsyncRuntime.create(self.config)
        runtime.register_listener(listener.fd())
        self._fiber_pool = FiberPool(self.config.total_fiber_slots())
        self._pending_connections = PendingConnectionQueue(
            self.config.max_pending_connections
        )
        self._connection_pool = ConnectionPool(self.config.max_connections)

        print(
            "[MojoFlow] Listening on "
            + self.config.base_url()
            + "  ("
            + String(self.router.route_count())
            + " routes)"
        )
        print("[MojoFlow] " + String(worker_model))
        print("[MojoFlow] Ready. Press Ctrl+C to stop.")

        self._running = True
        self._accepting = True
        self._shutdown_requested = False

        while self._running:
            var events = runtime.event_loop.poll(
                timeout_ms=self.config.event_loop_poll_timeout_ms
            )
            for i in range(len(events)):
                var ev = events[i]
                if ev.fd == listener.fd() and ev.readable and self._accepting:
                    self._drain_accepts[H](listener, handler)
                elif ev.error or ev.hangup:
                    runtime.event_loop.deregister(ev.fd)
                    _ = external_call["close", Int32, Int32](ev.fd)

            if self._shutdown_requested:
                self._running = False

        self._accepting = False
        runtime.event_loop.deregister(listener.fd())
        self._drain_fibers()
        print("[MojoFlow] Server stopped.")
