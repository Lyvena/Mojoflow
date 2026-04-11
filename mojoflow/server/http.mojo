"""
MojoFlow Server — HTTP Application server.

Provides the main App struct that integrates routing, middleware,
logging, and request handling into a unified server.

Uses Python's socket library via Mojo interop for the MVP network layer.
This will be replaced with native Mojo networking when available.
"""

from python import Python, PythonObject
from ..core.config import Config
from .request import Request
from .response import Response
from .router import Route, Router
from .middleware import Middleware, MiddlewareChain
from .logger import Logger


# Handler registry using parallel lists (method+path -> response body generators)
# In MVP, we use a callback-table pattern since Mojo's fn pointer support is evolving.

struct HandlerEntry:
    """Stores a route pattern and its static or dynamic response info."""

    var method: String
    var path: String
    var response_body: String
    var response_status: Int
    var content_type: String
    var is_static: Bool

    fn __init__(
        out self,
        method: String,
        path: String,
        response_body: String,
        response_status: Int = 200,
        content_type: String = "application/json",
        is_static: Bool = True,
    ):
        self.method = method
        self.path = path
        self.response_body = response_body
        self.response_status = response_status
        self.content_type = content_type
        self.is_static = is_static


struct App:
    """MojoFlow HTTP Application.

    The central server object. Register routes, add middleware, then
    call listen() to start serving requests.

    Example:
        var app = App()
        app.get("/hello", '{"message": "Hello!"}')
        app.listen(8080)
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

    fn get(inout self, path: String, response_body: String):
        """Register a GET route with a static JSON response."""
        self.router.get(path)
        self.handlers.append(HandlerEntry("GET", path, response_body))

    fn post(inout self, path: String, response_body: String):
        """Register a POST route with a static JSON response."""
        self.router.post(path)
        self.handlers.append(HandlerEntry("POST", path, response_body))

    fn put(inout self, path: String, response_body: String):
        """Register a PUT route with a static JSON response."""
        self.router.put(path)
        self.handlers.append(HandlerEntry("PUT", path, response_body))

    fn delete(inout self, path: String, response_body: String):
        """Register a DELETE route with a static JSON response."""
        self.router.delete(path)
        self.handlers.append(HandlerEntry("DELETE", path, response_body))

    fn use_middleware(inout self, name: String):
        """Add a named middleware to the processing chain."""
        self.middleware_chain.add(Middleware(name))
        self.logger.debug("Middleware added: " + name)

    fn _find_handler(self, method: String, path: String) -> HandlerEntry:
        """Find the matching handler entry for a method + path."""
        for i in range(len(self.handlers)):
            var h = self.handlers[i]
            if h.method == method:
                # Check exact match first
                if h.path == path:
                    return h
                # Check parameterized match
                var route = Route(h.method, h.path)
                if route.matches(method, path):
                    return h
        return HandlerEntry("", "", "", 0)

    fn _handle_request(self, inout req: Request) raises -> Response:
        """Process a request through middleware and routing."""
        # Pre-process middleware
        self.middleware_chain.process_request(req)

        # Route lookup
        if not self.router.has_route(req.method, req.path):
            # Handle OPTIONS for CORS preflight
            if req.method == "OPTIONS":
                var resp = Response("", 204, "No Content")
                return resp
            return Response.error("Not Found", 404)

        # Find handler
        var handler = self._find_handler(req.method, req.path)
        if handler.method == "":
            return Response.error("Not Found", 404)

        # Build response
        var resp = Response(handler.response_body, handler.response_status)
        resp.add_header("Content-Type", handler.content_type)
        resp.add_header("Content-Length", String(len(handler.response_body)))

        # Post-process middleware
        self.middleware_chain.process_response(req, resp)

        return resp

    fn listen(self, port: Int = 0) raises:
        """Start the HTTP server and listen for connections.

        Uses Python socket library via Mojo interop for MVP networking.
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

        # Use Python socket for network I/O (MVP approach)
        var socket = Python.import_module("socket")
        var server_socket = socket.socket(
            socket.AF_INET, socket.SOCK_STREAM
        )
        server_socket.setsockopt(
            socket.SOL_SOCKET, socket.SO_REUSEADDR, 1
        )
        server_socket.bind((host, listen_port))
        server_socket.listen(128)

        self.logger.info("Server ready. Press Ctrl+C to stop.")

        # Accept loop
        while True:
            try:
                var result = server_socket.accept()
                var client_socket = result[0]
                var client_addr = result[1]

                # Read request data
                var data = client_socket.recv(65536)
                var raw_request = String(str(data.decode("utf-8", "ignore")))

                if len(raw_request) == 0:
                    client_socket.close()
                    continue

                # Parse and handle
                var req = Request.parse(raw_request)
                var resp = self._handle_request(req)

                # Log
                self.logger.request(req.method, req.path, resp.status_code)

                # Send response
                var response_bytes = resp.to_http()
                _ = client_socket.sendall(response_bytes.encode())
                client_socket.close()

            except e:
                self.logger.error("Request error: " + String(e))
                try:
                    client_socket.close()
                except:
                    pass
