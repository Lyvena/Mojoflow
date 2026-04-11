"""
MojoFlow Server — Middleware system.

Middleware functions can inspect/modify requests before handlers
and responses after handlers.
"""

from .request import Request
from .response import Response


@value
struct Middleware:
    """Represents a named middleware unit.

    In the MVP, middleware is tracked by name and applied by the App
    layer during request processing. Each middleware can define
    pre-processing (before handler) and post-processing (after handler) logic.
    """

    var name: String
    var enabled: Bool

    fn __init__(out self, name: String, enabled: Bool = True):
        self.name = name
        self.enabled = enabled


struct MiddlewareChain:
    """Ordered chain of middleware to execute on each request.

    Middleware is executed in order for pre-processing and reverse
    order for post-processing.
    """

    var middlewares: List[Middleware]

    fn __init__(out self):
        self.middlewares = List[Middleware]()

    fn add(inout self, middleware: Middleware):
        """Add middleware to the chain."""
        self.middlewares.append(middleware)

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
        - 'cors': adds CORS headers (handled in response)
        """
        for i in range(len(self.middlewares)):
            if not self.middlewares[i].enabled:
                continue
            var name = self.middlewares[i].name
            if name == "logging":
                print("[MojoFlow] " + req.method + " " + req.path)

    fn process_response(self, req: Request, inout resp: Response) raises:
        """Run post-processing middleware on the response.

        Applied in reverse order.
        """
        var i = len(self.middlewares) - 1
        while i >= 0:
            if self.middlewares[i].enabled:
                var name = self.middlewares[i].name
                if name == "cors":
                    resp.add_header("Access-Control-Allow-Origin", "*")
                    resp.add_header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
                    resp.add_header("Access-Control-Allow-Headers", "Content-Type, Authorization")
            i -= 1
