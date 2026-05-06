"""
MojoFlow Server — request handling core.

This module owns the per-connection pipeline:

    socket fd -> Fiber slot -> async parse -> middleware before hooks
              -> user RequestHandler -> middleware after hooks
              -> serialize response -> send -> close/recycle

The implementation is deliberately trait-based.  Applications can provide
their own RequestHandler and middleware types, while the Server struct keeps
using the same core through its route-backed handler implementation.

MAX integration:
    HandlerContext exposes `parallel_for()` / `run_heavy_compute()` so CPU-heavy
    work inside handlers fans out through MAX Engine's `algorithm.parallelize`
    via the runtime's `parallelize_work` helper.  The default
    AsyncRequestHandler creates this context for every request and enables MAX
    parallelism automatically from ServerConfig.worker_fibers.
"""

from sys.ffi import external_call
from memory import UnsafePointer, memset_zero

from .config import ServerConfig
from .http_parser import parse_request, serialize_response
from .runtime import parallelize_work
from .types import Request, Response


alias MSG_NOSIGNAL: Int32 = 16384


# ══════════════════════════════════════════════════════════════════
#  HandlerContext — per-request execution context
# ══════════════════════════════════════════════════════════════════


struct HandlerContext:
    """Execution context passed to user handlers and middleware.

    The context is created once per request.  It carries Fiber identity,
    server configuration, and MAX worker settings so handlers can offload
    expensive loops without having to know about the runtime internals.
    """

    var config: ServerConfig
    var fiber_id: Int
    var max_workers: Int
    var max_parallelism_enabled: Bool

    fn __init__(out self, config: ServerConfig, fiber_id: Int = -1):
        self.config = config
        self.fiber_id = fiber_id
        self.max_workers = config.worker_fibers
        self.max_parallelism_enabled = config.worker_fibers > 1

    fn enable_max_parallelism(inout self):
        """Enable MAX Engine fan-out for heavy handler work."""
        self.max_parallelism_enabled = True
        if self.max_workers < 1:
            self.max_workers = 1

    fn disable_max_parallelism(inout self):
        """Disable MAX fan-out for code that must run serially."""
        self.max_parallelism_enabled = False

    fn parallel_for[
        work_fn: fn (Int) capturing -> None
    ](self, num_items: Int):
        """Run a CPU-heavy loop through MAX Engine.

        Handlers should use this for AI inference batches, embedding
        post-processing, large JSON/data transformations, and other
        compute-heavy loops.
        """
        if num_items <= 0:
            return
        if self.max_parallelism_enabled:
            parallelize_work[work_fn](num_items, self.max_workers)
        else:
            for i in range(num_items):
                work_fn(i)

    fn run_heavy_compute[
        work_fn: fn (Int) capturing -> None
    ](self, num_items: Int):
        """Alias for `parallel_for()` with a domain-specific name."""
        self.parallel_for[work_fn](num_items)


# ══════════════════════════════════════════════════════════════════
#  RequestHandler — user-defined handler trait
# ══════════════════════════════════════════════════════════════════


trait RequestHandler:
    """Trait implemented by application request handlers.

    A handler receives a fully parsed Request and the HandlerContext
    prepared by AsyncRequestHandler.  It returns a Response ready for
    middleware post-processing and serialization.
    """

    fn handle(
        inout self,
        inout request: Request,
        inout context: HandlerContext,
    ) raises -> Response:
        ...


# ══════════════════════════════════════════════════════════════════
#  Async middleware
# ══════════════════════════════════════════════════════════════════


struct MiddlewareDecision:
    """Result of a middleware before hook."""

    var should_continue: Bool
    var response: Response

    fn __init__(out self):
        self.should_continue = True
        self.response = Response()

    fn __init__(out self, response: Response):
        self.should_continue = False
        self.response = response

    @staticmethod
    fn next() -> MiddlewareDecision:
        return MiddlewareDecision()

    @staticmethod
    fn stop(response: Response) -> MiddlewareDecision:
        return MiddlewareDecision(response)


trait AsyncMiddleware:
    """Async middleware trait with before/after hooks.

    Middleware can short-circuit a request in `before()` or mutate the
    response in `after()`.  Hooks run in stack order before the handler
    and reverse stack order after the handler.
    """

    fn before(
        inout self,
        inout request: Request,
        inout context: HandlerContext,
    ) raises -> MiddlewareDecision:
        ...

    fn after(
        inout self,
        inout request: Request,
        inout response: Response,
        inout context: HandlerContext,
    ) raises:
        ...


struct NoopMiddleware(AsyncMiddleware):
    """Default middleware used when an app has no middleware."""

    fn __init__(out self):
        pass

    fn before(
        inout self,
        inout request: Request,
        inout context: HandlerContext,
    ) raises -> MiddlewareDecision:
        return MiddlewareDecision.next()

    fn after(
        inout self,
        inout request: Request,
        inout response: Response,
        inout context: HandlerContext,
    ) raises:
        pass


struct MiddlewareStack[M: AsyncMiddleware]:
    """Homogeneous async middleware stack.

    Mojo does not yet have stable boxed trait objects, so the stack is
    generic over a middleware type.  Multiple instances of that type can
    be pushed and will be run in normal before / reverse after order.
    """

    var _items: List[M]

    fn __init__(out self):
        self._items = List[M]()

    fn push(inout self, middleware: M):
        self._items.append(middleware)

    fn len(self) -> Int:
        return len(self._items)

    fn run_before(
        inout self,
        inout request: Request,
        inout context: HandlerContext,
    ) raises -> MiddlewareDecision:
        for i in range(len(self._items)):
            var decision = self._items[i].before(request, context)
            if not decision.should_continue:
                return decision
        return MiddlewareDecision.next()

    fn run_after(
        inout self,
        inout request: Request,
        inout response: Response,
        inout context: HandlerContext,
    ) raises:
        var i = len(self._items) - 1
        while i >= 0:
            self._items[i].after(request, response, context)
            i -= 1


# ══════════════════════════════════════════════════════════════════
#  AsyncRequestHandler — default per-connection pipeline
# ══════════════════════════════════════════════════════════════════


struct AsyncRequestHandler:
    """Default async connection handler.

    The server creates one of these around each accepted connection/Fiber
    slot.  It parses the request, runs middleware, invokes the user
    RequestHandler, serializes the response, and closes the connection.
    """

    var config: ServerConfig
    var fiber_id: Int

    fn __init__(out self, config: ServerConfig, fiber_id: Int = -1):
        self.config = config
        self.fiber_id = fiber_id

    fn handle_connection[
        H: RequestHandler,
        M: AsyncMiddleware,
    ](
        self,
        client_fd: Int32,
        inout handler: H,
        inout middleware: MiddlewareStack[M],
    ) raises:
        """Process one connection inside its assigned Fiber slot."""
        var raw = self.read_request_bytes(client_fd)
        if len(raw) == 0:
            _ = external_call["close", Int32, Int32](client_fd)
            return

        var response = self.handle_raw_request[H, M](raw, handler, middleware)
        var keep_alive = False
        var wire = serialize_response(response, keep_alive)
        _ = external_call[
            "send", Int,
            Int32, UnsafePointer[UInt8], Int, Int32,
        ](client_fd, wire.unsafe_ptr(), len(wire), MSG_NOSIGNAL)
        _ = external_call["close", Int32, Int32](client_fd)

    fn handle_raw_request[
        H: RequestHandler,
        M: AsyncMiddleware,
    ](
        self,
        raw: String,
        inout handler: H,
        inout middleware: MiddlewareStack[M],
    ) raises -> Response:
        """Parse and dispatch a raw HTTP request string.

        This is also useful for tests that want to exercise the handler
        pipeline without opening a socket.
        """
        var context = HandlerContext(self.config, self.fiber_id)
        context.enable_max_parallelism()

        var request: Request
        try:
            request = parse_request(raw)
        except e:
            return Response.error("Bad Request: " + String(e), 400)

        var decision = middleware.run_before(request, context)
        if not decision.should_continue:
            var short_response = decision.response
            middleware.run_after(request, short_response, context)
            return short_response

        var response: Response
        try:
            response = handler.handle(request, context)
        except e:
            response = Response.error("Internal Server Error: " + String(e), 500)

        middleware.run_after(request, response, context)
        return response

    fn read_request_bytes(self, client_fd: Int32) -> String:
        """Read one HTTP request from the connection.

        The current listener accepts blocking sockets, so this uses a
        blocking first read inside the Fiber slot.  The parser and handler
        pipeline stay the same when the event-loop path switches this to
        `AsyncConnection` readiness-driven reads.
        """
        var buf_size = self.config.read_buffer_size
        var buf = UnsafePointer[UInt8].alloc(buf_size)
        memset_zero(buf, buf_size)

        var n = external_call[
            "recv", Int,
            Int32, UnsafePointer[UInt8], Int, Int32,
        ](client_fd, buf, buf_size - 1, 0)

        if n <= 0:
            buf.free()
            return String("")

        var raw = String("")
        for i in range(n):
            raw += chr(Int(buf[i]))
        buf.free()
        return raw


fn handle_connection_async[
    H: RequestHandler,
    M: AsyncMiddleware,
](
    client_fd: Int32,
    inout handler: H,
    inout middleware: MiddlewareStack[M],
    config: ServerConfig,
    fiber_id: Int = -1,
) raises:
    """Convenience wrapper for the default AsyncRequestHandler."""
    var async_handler = AsyncRequestHandler(config, fiber_id)
    async_handler.handle_connection[H, M](client_fd, handler, middleware)
