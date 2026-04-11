"""
Tests for MojoFlow Server Request parsing.
"""

from mojoflow.server.request import Request


fn test_parse_simple_get() raises:
    """Test parsing a simple GET request."""
    var raw = "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n"
    var req = Request.parse(raw)

    if req.method != "GET":
        raise Error("Expected GET, got: " + req.method)
    if req.path != "/hello":
        raise Error("Expected /hello, got: " + req.path)
    if req.http_version != "HTTP/1.1":
        raise Error("Expected HTTP/1.1, got: " + req.http_version)
    if req.get_header("Host") != "localhost":
        raise Error("Host header missing")
    print("  ✓ test_parse_simple_get")


fn test_parse_with_query_string() raises:
    """Test parsing a request with query parameters."""
    var raw = "GET /search?q=mojo&limit=10 HTTP/1.1\r\nHost: localhost\r\n\r\n"
    var req = Request.parse(raw)

    if req.path != "/search":
        raise Error("Expected /search, got: " + req.path)
    if req.query_string != "q=mojo&limit=10":
        raise Error("Expected query string, got: " + req.query_string)
    if req.get_query_param("q") != "mojo":
        raise Error("Expected q=mojo")
    if req.get_query_param("limit") != "10":
        raise Error("Expected limit=10")
    if req.get_query_param("nonexistent") != "":
        raise Error("Missing param should return empty string")
    print("  ✓ test_parse_with_query_string")


fn test_parse_post_with_body() raises:
    """Test parsing a POST request with a body."""
    var raw = "POST /api/data HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"key\":\"val\"}"
    var req = Request.parse(raw)

    if req.method != "POST":
        raise Error("Expected POST")
    if req.path != "/api/data":
        raise Error("Expected /api/data")
    if not req.is_json():
        raise Error("Should be JSON content type")
    if req.body != '{"key":"val"}':
        raise Error("Body mismatch: " + req.body)
    if req.content_length() != 13:
        raise Error("Content length should be 13")
    print("  ✓ test_parse_post_with_body")


fn test_parse_empty_request() raises:
    """Test that empty request raises an error."""
    var raised = False
    try:
        _ = Request.parse("")
    except:
        raised = True
    if not raised:
        raise Error("Should raise on empty request")
    print("  ✓ test_parse_empty_request")


fn test_headers_case_insensitive() raises:
    """Test case-insensitive header lookup."""
    var raw = "GET / HTTP/1.1\r\nContent-Type: text/html\r\nX-Custom: value123\r\n\r\n"
    var req = Request.parse(raw)

    if req.get_header("content-type") != "text/html":
        raise Error("Case-insensitive lookup failed")
    if req.get_header("CONTENT-TYPE") != "text/html":
        raise Error("Uppercase lookup failed")
    if not req.has_header("x-custom"):
        raise Error("has_header case-insensitive failed")
    print("  ✓ test_headers_case_insensitive")


fn test_route_params() raises:
    """Test route parameter accessors."""
    var req = Request("GET", "/users/42")
    req.add_param("id", "42")

    if req.get_param("id") != "42":
        raise Error("get_param failed")
    if not req.has_param("id"):
        raise Error("has_param failed")
    if req.get_param("nonexistent") != "":
        raise Error("Missing param should return empty")
    print("  ✓ test_route_params")


fn main() raises:
    print("Running Request tests...")
    test_parse_simple_get()
    test_parse_with_query_string()
    test_parse_post_with_body()
    test_parse_empty_request()
    test_headers_case_insensitive()
    test_route_params()
    print("All Request tests passed!")
