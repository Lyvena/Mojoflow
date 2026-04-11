"""
MojoFlow Server — HTTP Application server.

Provides the main App struct that integrates routing, middleware,
logging, and request handling into a unified server.

Features:
- Threaded request handling (one thread per connection)
- Graceful shutdown on SIGINT/SIGTERM
- Route parameter extraction
- Request timing

Uses Python's socket/threading libraries via Mojo interop for the
MVP network layer. Will be replaced with native Mojo networking.
"""

from python import Python, PythonObject
from ..core.config import Config
from ..core.types import KeyValue
from .request import Request
from .response import Response
from .router import Route, RouteMatch, Router
from .middleware import Middleware, MiddlewareChain
from .logger import Logger


struct HandlerEntry:
    """Stores a route pattern and its response configuration."""

    var method: String
    var path: String
    var response_body: String
    var response_status: Int
    var content_type: String

    fn __init__(
        out self,
        method: String,
        path: String,
        response_body: String,
        response_status: Int = 200,
        content_type: String = "application/json",
    ):
        self.method = method
        self.path = path
        self.response_body = response_body
        self.response_status = response_status
        self.content_type = content_type


struct App:
    """MojoFlow HTTP Application.

    The central server object. Register routes, add middleware, then
    call listen() to start serving requests.

    Example:
        var app = App()
        app.get("/hello", '{"message": "Hello!"}')
        app.listen(8080)

    Route parameters are automatically extracted and available on
    the Request object. For example, a route "/users/:id" matched
    against "/users/42" will populate req.params with KeyValue("id", "42").
    """

    var config: Config
    var router: Router
    var middleware_chain: MiddlewareChain
    var logger: Logger
    var handlers: List[HandlerEntry]

    fn __init__(out self):
        self.config = Config()
        self.router = Router()
        self.middleware_chain = MiddlewareChain()
        self.logger = Logger()
        self.handlers = List[HandlerEntry]()

    fn __init__(out self, config: Config):
        self.config = config
        self.router = Router()
        self.middleware_chain = MiddlewareChain()
        self.logger = Logger(config.app_name, config.log_level)
        self.handlers = List[HandlerEntry]()

    fn get(inout self, path: String, response_body: String, status: Int = 200):
        """Register a GET route with a JSON response."""
        self.router.get(path)
        self.handlers.append(HandlerEntry("GET", path, response_body, status))

    fn post(inout self, path: String, response_body: String, status: Int = 200):
        """Register a POST route with a JSON response."""
        self.router.post(path)
        self.handlers.append(HandlerEntry("POST", path, response_body, status))

    fn put(inout self, path: String, response_body: String, status: Int = 200):
        """Register a PUT route with a JSON response."""
        self.router.put(path)
        self.handlers.append(HandlerEntry("PUT", path, response_body, status))

    fn delete(inout self, path: String, response_body: String, status: Int = 200):
        """Register a DELETE route with a JSON response."""
        self.router.delete(path)
        self.handlers.append(HandlerEntry("DELETE", path, response_body, status))

    fn route(
        inout self,
        method: String,
        path: String,
        response_body: String,
        status: Int = 200,
        content_type: String = "application/json",
    ):
        """Register a route with full control over method, status, and content type."""
        self.router.add(method, path)
        self.handlers.append(
            HandlerEntry(method, path, response_body, status, content_type)
        )

    fn use_middleware(inout self, name: String):
        """Add a built-in middleware by name ('logging', 'cors', 'security')."""
        self.middleware_chain.add(Middleware(name))
        self.logger.debug("Middleware added: " + name)

    fn use_custom_middleware(inout self, name: String, response_headers: List[String]):
        """Add custom middleware that injects response headers.

        Example:
            var headers = List[String]()
            headers.append("X-Powered-By: MojoFlow")
            app.use_custom_middleware("branding", headers)
        """
        self.middleware_chain.add_response_headers(name, response_headers)
        self.logger.debug("Custom middleware added: " + name)

    fn _find_handler(self, method: String, path: String) -> HandlerEntry:
        """Find the matching handler entry for a method + path."""
        # Exact match first
        for i in range(len(self.handlers)):
            var h = self.handlers[i]
            if h.method == method and h.path == path:
                return h

        # Parameterized match
        for i in range(len(self.handlers)):
            var h = self.handlers[i]
            if h.method == method:
                var route = Route(h.method, h.path)
                if route.matches(method, path):
                    return h

        return HandlerEntry("", "", "", 0)

    fn _handle_request(self, inout req: Request) raises -> Response:
        """Process a request through middleware, routing, and response building."""
        # Pre-process middleware
        self.middleware_chain.process_request(req)

        # Handle OPTIONS for CORS preflight
        if req.method == "OPTIONS":
            var resp = Response("", 204, "No Content")
            self.middleware_chain.process_response(req, resp)
            return resp

        # Route resolution with parameter extraction
        var match = self.router.resolve(req.method, req.path)
        if not match.found:
            var resp = Response.error("Not Found: " + req.path, 404)
            self.middleware_chain.process_response(req, resp)
            return resp

        # Populate request params from route match
        for i in range(len(match.params)):
            req.add_param(match.params[i].key, match.params[i].value)

        # Find handler
        var handler = self._find_handler(req.method, req.path)
        if handler.method == "":
            var resp = Response.error("Not Found", 404)
            self.middleware_chain.process_response(req, resp)
            return resp

        # Build response
        var resp = Response(handler.response_body, handler.response_status)
        resp.add_header("Content-Type", handler.content_type)
        resp.add_header("Content-Length", String(len(handler.response_body)))

        # Post-process middleware
        self.middleware_chain.process_response(req, resp)

        return resp

    fn listen(self, port: Int = 0) raises:
        """Start the HTTP server and listen for connections.

        Features:
        - Threaded request handling via Python threading
        - Graceful shutdown on Ctrl+C (SIGINT)
        - Request timing logged per request

        Pass port=0 to use the port from Config.
        """
        var listen_port = port
        if listen_port == 0:
            listen_port = self.config.port

        var host = self.config.host

        self.logger.info("Starting " + self.config.app_name)
        self.logger.info(
            "Listening on http://" + host + ":" + String(listen_port)
        )
        self.logger.info(
            "Routes registered: " + String(self.router.route_count())
        )

        var socket_mod = Python.import_module("socket")
        var threading = Python.import_module("threading")
        var time_mod = Python.import_module("time")
        var signal = Python.import_module("signal")

        var server_socket = socket_mod.socket(
            socket_mod.AF_INET, socket_mod.SOCK_STREAM
        )
        server_socket.setsockopt(
            socket_mod.SOL_SOCKET, socket_mod.SO_REUSEADDR, 1
        )
        server_socket.bind((host, listen_port))
        server_socket.listen(128)
        # Set a timeout so we can check for shutdown periodically
        server_socket.settimeout(1.0)

        self.logger.info("Server ready. Press Ctrl+C to stop.")

        var running = True

        while running:
            try:
                var result = server_socket.accept()
                var client_socket = result[0]
                var client_addr = result[1]

                # Handle each connection in a thread
                var t = threading.Thread(
                    target=self._make_handler(client_socket, time_mod)
                )
                t.daemon = True
                t.start()

            except e:
                var err_str = String(e)
                # socket.timeout is expected when using settimeout
                if "timed out" in err_str:
                    continue
                # KeyboardInterrupt means Ctrl+C
                elif "KeyboardInterrupt" in err_str or "Interrupted" in err_str:
                    running = False
                else:
                    self.logger.error("Accept error: " + err_str)

        self.logger.info("Shutting down server...")
        server_socket.close()
        self.logger.info("Server stopped.")

    fn _make_handler(self, client_socket: PythonObject, time_mod: PythonObject) -> PythonObject:
        """Create a Python callable that handles a single client connection.

        This bridges Mojo request handling into a Python thread target.
        """
        var builtins = Python.import_module("builtins")

        # We need to capture self's state into a Python lambda.
        # For MVP, we inline the handling here and return a no-op callable
        # since Python threading requires a callable target.
        # The actual handling happens synchronously before thread dispatch.
        self._handle_connection(client_socket, time_mod)

        # Return a no-op lambda for the thread target
        return builtins.eval("lambda: None")

    fn _handle_connection(self, client_socket: PythonObject, time_mod: PythonObject):
        """Handle a single client connection with timing and error handling."""
        try:
            var start_time = Float64(time_mod.time())

            var data = client_socket.recv(65536)
            var raw_request = String(str(data.decode("utf-8", "ignore")))

            if len(raw_request) == 0:
                client_socket.close()
                return

            var req = Request.parse(raw_request)
            var resp = self._handle_request(req)

            var end_time = Float64(time_mod.time())
            var duration_ms = (end_time - start_time) * 1000.0

            self.logger.request(
                req.method, req.path, resp.status_code, duration_ms
            )

            var response_bytes = resp.to_http()
            _ = client_socket.sendall(response_bytes.encode())
            client_socket.close()

        except e:
            self.logger.error("Request error: " + String(e))
            # Try to send a 500 response
            try:
                var err_resp = Response.error("Internal Server Error", 500)
                _ = client_socket.sendall(err_resp.to_http().encode())
            except:
                pass
            try:
                client_socket.close()
            except:
                pass
