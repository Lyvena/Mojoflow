"""
MojoFlow Server — Routing system.

Maps HTTP methods and URL paths to handler functions.
Uses method-keyed grouping for O(1) method lookup before path matching.
"""

from .request import Request
from .response import Response
from ..core.types import KeyValue


@value
struct RouteMatch:
    """Result of a route lookup — includes the matched route and extracted params."""

    var found: Bool
    var route: Route
    var params: List[KeyValue]

    fn __init__(out self):
        self.found = False
        self.route = Route("", "")
        self.params = List[KeyValue]()

    fn __init__(out self, route: Route, params: List[KeyValue]):
        self.found = True
        self.route = route
        self.params = params


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

    fn extract_params(self, path: String) -> List[KeyValue]:
        """Extract named parameter key-value pairs from a matched path.

        E.g., for route /users/:id/posts/:postId and path /users/42/posts/7,
        returns [KeyValue("id", "42"), KeyValue("postId", "7")].
        """
        var params = List[KeyValue]()
        var route_parts = self.path.split("/")
        var path_parts = path.split("/")

        if len(route_parts) != len(path_parts):
            return params

        for i in range(len(route_parts)):
            var rp = route_parts[i]
            if len(rp) > 0 and rp[0] == ":":
                var param_name = rp[1:]
                params.append(KeyValue(param_name, path_parts[i]))
        return params

    fn is_parameterized(self) -> Bool:
        """Check if this route has any :param segments."""
        return ":" in self.path


struct Router:
    """HTTP router that maps requests to route definitions.

    Routes are grouped by HTTP method for O(1) method lookup.
    Within each method group, routes are checked in registration order
    with exact matches prioritized over parameterized matches.
    """

    var _get_routes: List[Route]
    var _post_routes: List[Route]
    var _put_routes: List[Route]
    var _delete_routes: List[Route]
    var _other_routes: List[Route]
    var _total_count: Int

    fn __init__(out self):
        self._get_routes = List[Route]()
        self._post_routes = List[Route]()
        self._put_routes = List[Route]()
        self._delete_routes = List[Route]()
        self._other_routes = List[Route]()
        self._total_count = 0

    fn _routes_for_method(inout self, method: String) -> ref [self] List[Route]:
        """Get the route list for a given HTTP method."""
        if method == "GET":
            return self._get_routes
        elif method == "POST":
            return self._post_routes
        elif method == "PUT":
            return self._put_routes
        elif method == "DELETE":
            return self._delete_routes
        return self._other_routes

    fn add(inout self, method: String, path: String, handler_name: String = ""):
        """Register a new route."""
        var route = Route(method, path, handler_name)
        if method == "GET":
            self._get_routes.append(route)
        elif method == "POST":
            self._post_routes.append(route)
        elif method == "PUT":
            self._put_routes.append(route)
        elif method == "DELETE":
            self._delete_routes.append(route)
        else:
            self._other_routes.append(route)
        self._total_count += 1

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

    fn _get_routes_readonly(self, method: String) -> List[Route]:
        """Get a copy of routes for a method (for read-only lookup)."""
        if method == "GET":
            return self._get_routes
        elif method == "POST":
            return self._post_routes
        elif method == "PUT":
            return self._put_routes
        elif method == "DELETE":
            return self._delete_routes
        return self._other_routes

    fn resolve(self, method: String, path: String) -> RouteMatch:
        """Find the best matching route and extract parameters.

        Prioritizes exact matches over parameterized matches.
        Returns a RouteMatch with found=False if no match.
        """
        var routes = self._get_routes_readonly(method)

        # First pass: exact matches
        for i in range(len(routes)):
            if routes[i].path == path:
                return RouteMatch(routes[i], List[KeyValue]())

        # Second pass: parameterized matches
        for i in range(len(routes)):
            if routes[i].is_parameterized() and routes[i]._match_path(path):
                var params = routes[i].extract_params(path)
                return RouteMatch(routes[i], params)

        return RouteMatch()

    fn find(self, method: String, path: String) -> Route:
        """Find the first matching route for a method + path.

        Returns a default empty Route if no match is found.
        """
        var match = self.resolve(method, path)
        if match.found:
            return match.route
        return Route("", "", "")

    fn has_route(self, method: String, path: String) -> Bool:
        """Check if a matching route exists."""
        return self.resolve(method, path).found

    fn route_count(self) -> Int:
        """Return the number of registered routes."""
        return self._total_count
