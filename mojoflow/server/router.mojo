"""
MojoFlow Server — Routing system.

Maps HTTP methods and URL paths to handler functions.
"""

from .request import Request
from .response import Response


@value
struct Route:
    """A single route mapping a method + path to a handler identifier."""

    var method: String
    var path: String
    var handler_name: String

    fn __init__(out self, method: String, path: String, handler_name: String = ""):
        self.method = method
        self.path = path
        self.handler_name = handler_name

    fn matches(self, method: String, path: String) -> Bool:
        """Check if this route matches the given method and path."""
        if self.method != method:
            return False
        return self._match_path(path)

    fn _match_path(self, path: String) -> Bool:
        """Match path with support for simple patterns.

        Supports:
        - Exact match: /hello == /hello
        - Wildcard segments: /users/:id matches /users/123
        """
        if self.path == path:
            return True

        # Check for parameterized routes
        var route_parts = self.path.split("/")
        var path_parts = path.split("/")

        if len(route_parts) != len(path_parts):
            return False

        for i in range(len(route_parts)):
            var rp = route_parts[i]
            if len(rp) > 0 and rp[0] == ":":
                continue  # Wildcard segment, matches anything
            if rp != path_parts[i]:
                return False
        return True

    fn extract_params(self, path: String) -> List[String]:
        """Extract parameter values from a matched path.

        Returns parameter values in order of appearance in the route pattern.
        E.g., for route /users/:id and path /users/42, returns ["42"].
        """
        var params = List[String]()
        var route_parts = self.path.split("/")
        var path_parts = path.split("/")

        if len(route_parts) != len(path_parts):
            return params

        for i in range(len(route_parts)):
            var rp = route_parts[i]
            if len(rp) > 0 and rp[0] == ":":
                params.append(path_parts[i])
        return params


struct Router:
    """HTTP router that maps requests to route definitions.

    The router stores routes and provides lookup by method + path.
    Handler dispatch is managed by the App layer.
    """

    var routes: List[Route]

    fn __init__(out self):
        self.routes = List[Route]()

    fn add(inout self, method: String, path: String, handler_name: String = ""):
        """Register a new route."""
        self.routes.append(Route(method, path, handler_name))

    fn get(inout self, path: String, handler_name: String = ""):
        """Register a GET route."""
        self.add("GET", path, handler_name)

    fn post(inout self, path: String, handler_name: String = ""):
        """Register a POST route."""
        self.add("POST", path, handler_name)

    fn put(inout self, path: String, handler_name: String = ""):
        """Register a PUT route."""
        self.add("PUT", path, handler_name)

    fn delete(inout self, path: String, handler_name: String = ""):
        """Register a DELETE route."""
        self.add("DELETE", path, handler_name)

    fn find(self, method: String, path: String) -> Route:
        """Find the first matching route for a method + path.

        Returns a default empty Route if no match is found.
        """
        for i in range(len(self.routes)):
            if self.routes[i].matches(method, path):
                return self.routes[i]
        return Route("", "", "")

    fn has_route(self, method: String, path: String) -> Bool:
        """Check if a matching route exists."""
        for i in range(len(self.routes)):
            if self.routes[i].matches(method, path):
                return True
        return False

    fn route_count(self) -> Int:
        """Return the number of registered routes."""
        return len(self.routes)
