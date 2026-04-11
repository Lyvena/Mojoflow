"""
Tests for MojoFlow Server Router.
"""

from mojoflow.server.router import Route, RouteMatch, Router
from mojoflow.core.types import KeyValue


fn test_exact_match() raises:
    """Test exact path matching."""
    var route = Route("GET", "/hello")
    if not route.matches("GET", "/hello"):
        raise Error("Exact match should succeed")
    if route.matches("GET", "/world"):
        raise Error("Should not match different path")
    if route.matches("POST", "/hello"):
        raise Error("Should not match different method")
    print("  ✓ test_exact_match")


fn test_parameterized_match() raises:
    """Test parameterized path matching."""
    var route = Route("GET", "/users/:id")
    if not route.matches("GET", "/users/42"):
        raise Error("Param match should succeed")
    if not route.matches("GET", "/users/abc"):
        raise Error("Param match with string should succeed")
    if route.matches("GET", "/users/42/extra"):
        raise Error("Should not match extra segments")
    if route.matches("GET", "/users"):
        raise Error("Should not match missing segment")
    print("  ✓ test_parameterized_match")


fn test_multi_param() raises:
    """Test multiple parameters in a path."""
    var route = Route("GET", "/users/:id/posts/:postId")
    if not route.matches("GET", "/users/1/posts/99"):
        raise Error("Multi-param match should succeed")

    var params = route.extract_params("/users/1/posts/99")
    if len(params) != 2:
        raise Error("Expected 2 params, got " + String(len(params)))
    if params[0].key != "id" or params[0].value != "1":
        raise Error("First param wrong: " + params[0].key + "=" + params[0].value)
    if params[1].key != "postId" or params[1].value != "99":
        raise Error("Second param wrong: " + params[1].key + "=" + params[1].value)
    print("  ✓ test_multi_param")


fn test_is_parameterized() raises:
    """Test is_parameterized detection."""
    var r1 = Route("GET", "/hello")
    var r2 = Route("GET", "/users/:id")
    if r1.is_parameterized():
        raise Error("/hello should not be parameterized")
    if not r2.is_parameterized():
        raise Error("/users/:id should be parameterized")
    print("  ✓ test_is_parameterized")


fn test_router_method_grouping() raises:
    """Test that router groups by method correctly."""
    var router = Router()
    router.get("/a")
    router.get("/b")
    router.post("/a")
    router.delete("/c")

    if router.route_count() != 4:
        raise Error("Expected 4 routes, got " + String(router.route_count()))

    if not router.has_route("GET", "/a"):
        raise Error("GET /a should exist")
    if not router.has_route("GET", "/b"):
        raise Error("GET /b should exist")
    if not router.has_route("POST", "/a"):
        raise Error("POST /a should exist")
    if not router.has_route("DELETE", "/c"):
        raise Error("DELETE /c should exist")
    if router.has_route("PUT", "/a"):
        raise Error("PUT /a should not exist")
    print("  ✓ test_router_method_grouping")


fn test_router_resolve() raises:
    """Test router resolve with parameter extraction."""
    var router = Router()
    router.get("/")
    router.get("/users/:id")

    var match1 = router.resolve("GET", "/")
    if not match1.found:
        raise Error("Should find /")
    if len(match1.params) != 0:
        raise Error("/ should have no params")

    var match2 = router.resolve("GET", "/users/42")
    if not match2.found:
        raise Error("Should find /users/42")
    if len(match2.params) != 1:
        raise Error("Expected 1 param")
    if match2.params[0].key != "id" or match2.params[0].value != "42":
        raise Error("Param should be id=42")

    var match3 = router.resolve("GET", "/nonexistent")
    if match3.found:
        raise Error("Should not find /nonexistent")
    print("  ✓ test_router_resolve")


fn test_exact_match_priority() raises:
    """Test that exact matches are preferred over parameterized."""
    var router = Router()
    router.get("/users/me")
    router.get("/users/:id")

    var match = router.resolve("GET", "/users/me")
    if not match.found:
        raise Error("Should find /users/me")
    if match.route.path != "/users/me":
        raise Error("Should match exact /users/me, not parameterized")
    print("  ✓ test_exact_match_priority")


fn main() raises:
    print("Running Router tests...")
    test_exact_match()
    test_parameterized_match()
    test_multi_param()
    test_is_parameterized()
    test_router_method_grouping()
    test_router_resolve()
    test_exact_match_priority()
    print("All Router tests passed!")
