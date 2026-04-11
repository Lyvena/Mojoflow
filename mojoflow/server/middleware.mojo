"""
MojoFlow Server — Middleware system.

Supports both built-in named middleware and custom middleware via
a callback-based registration pattern.
"""

from .request import Request
from .response import Response


@value
struct Middleware:
    """Represents a named middleware unit.

    Built-in middleware (by name):
    - "logging"   → Logs request method and path
    - "cors"      → Adds CORS headers to response
    - "security"  → Adds security headers (X-Content-Type-Options, etc.)

    Custom middleware can be registered with custom_request_headers
    and custom_response_headers for simple header-based middleware.
    """

    var name: String
    var enabled: Bool
    var custom_request_headers: List[String]
    var custom_response_headers: List[String]

    fn __init__(out self, name: String, enabled: Bool = True):
        self.name = name
        self.enabled = enabled
        self.custom_request_headers = List[String]()
        self.custom_response_headers = List[String]()

    fn __init__(
        out self,
        name: String,
        response_headers: List[String],
        enabled: Bool = True,
    ):
        """Create middleware that adds custom response headers.

        Each string in response_headers should be "Header-Name: value".
        """
        self.name = name
        self.enabled = enabled
        self.custom_request_headers = List[String]()
        self.custom_response_headers = response_headers


struct MiddlewareChain:
    """Ordered chain of middleware to execute on each request.

    Middleware is executed in registration order for pre-processing
    and reverse order for post-processing.
    """

    var middlewares: List[Middleware]

    fn __init__(out self):
        self.middlewares = List[Middleware]()

    fn add(inout self, middleware: Middleware):
        """Add middleware to the chain."""
        self.middlewares.append(middleware)

    fn add_named(inout self, name: String):
        """Add a built-in middleware by name."""
        self.middlewares.append(Middleware(name))

    fn add_response_headers(inout self, name: String, headers: List[String]):
        """Add custom middleware that injects response headers."""
        self.middlewares.append(Middleware(name, headers))

    fn count(self) -> Int:
        """Number of middlewares in the chain."""
        return len(self.middlewares)

    fn get_names(self) -> List[String]:
        """Get names of all active middleware in execution order."""
        var names = List[String]()
        for i in range(len(self.middlewares)):
            if self.middlewares[i].enabled:
                names.append(self.middlewares[i].name)
        return names

    fn process_request(self, inout req: Request) raises:
        """Run pre-processing middleware on the request.

        Applies built-in middleware behaviors:
        - 'logging': logs the request method and path
        """
        for i in range(len(self.middlewares)):
            if not self.middlewares[i].enabled:
                continue
            var name = self.middlewares[i].name
            if name == "logging":
                print("[MojoFlow] --> " + req.method + " " + req.path)

    fn process_response(self, req: Request, inout resp: Response) raises:
        """Run post-processing middleware on the response.

        Applied in reverse order. Handles built-in behaviors and
        custom response header injection.
        """
        var i = len(self.middlewares) - 1
        while i >= 0:
            if self.middlewares[i].enabled:
                var mw = self.middlewares[i]
                var name = mw.name

                # Built-in: CORS
                if name == "cors":
                    resp.add_header("Access-Control-Allow-Origin", "*")
                    resp.add_header(
                        "Access-Control-Allow-Methods",
                        "GET, POST, PUT, DELETE, PATCH, OPTIONS",
                    )
                    resp.add_header(
                        "Access-Control-Allow-Headers",
                        "Content-Type, Authorization, X-Requested-With",
                    )
                    resp.add_header("Access-Control-Max-Age", "86400")

                # Built-in: Security headers
                elif name == "security":
                    resp.add_header("X-Content-Type-Options", "nosniff")
                    resp.add_header("X-Frame-Options", "DENY")
                    resp.add_header("X-XSS-Protection", "1; mode=block")
                    resp.add_header(
                        "Strict-Transport-Security",
                        "max-age=31536000; includeSubDomains",
                    )

                # Custom response headers
                for h in range(len(mw.custom_response_headers)):
                    var header_str = mw.custom_response_headers[h]
                    var colon = header_str.find(":")
                    if colon != -1:
                        var hdr_name = header_str[:colon].strip()
                        var hdr_val = header_str[colon + 1 :].strip()
                        resp.add_header(hdr_name, hdr_val)

            i -= 1
