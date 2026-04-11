"""
Tests for MojoFlow Server Response.
"""

from mojoflow.server.response import Response


fn test_json_response() raises:
    """Test JSON response factory."""
    var resp = Response.json('{"ok": true}')
    if resp.status_code != 200:
        raise Error("Expected status 200")
    if resp.body != '{"ok": true}':
        raise Error("Body mismatch")
    print("  ✓ test_json_response")


fn test_error_response() raises:
    """Test error response factory."""
    var resp = Response.error("Not Found", 404)
    if resp.status_code != 404:
        raise Error("Expected status 404")
    if '"error"' not in resp.body:
        raise Error("Error response should contain 'error' key")
    print("  ✓ test_error_response")


fn test_html_response() raises:
    """Test HTML response factory."""
    var resp = Response.html("<h1>Hello</h1>")
    if resp.body != "<h1>Hello</h1>":
        raise Error("Body mismatch")
    print("  ✓ test_html_response")


fn test_to_http_format() raises:
    """Test HTTP response serialization."""
    var resp = Response('{"ok": true}', 200, "OK")
    resp.add_header("Content-Type", "application/json")
    var http = resp.to_http()

    if "HTTP/1.1 200 OK" not in http:
        raise Error("Missing status line in: " + http)
    if "Content-Type: application/json" not in http:
        raise Error("Missing content-type header")
    if '{"ok": true}' not in http:
        raise Error("Missing body")
    print("  ✓ test_to_http_format")


fn test_redirect_response() raises:
    """Test redirect response factory."""
    var resp = Response.redirect("/new-location")
    if resp.status_code != 302:
        raise Error("Expected 302 status")
    print("  ✓ test_redirect_response")


fn test_add_multiple_headers() raises:
    """Test adding multiple headers."""
    var resp = Response("body", 200)
    resp.add_header("X-First", "1")
    resp.add_header("X-Second", "2")
    var http = resp.to_http()

    if "X-First: 1" not in http:
        raise Error("Missing first header")
    if "X-Second: 2" not in http:
        raise Error("Missing second header")
    print("  ✓ test_add_multiple_headers")


fn main() raises:
    print("Running Response tests...")
    test_json_response()
    test_error_response()
    test_html_response()
    test_to_http_format()
    test_redirect_response()
    test_add_multiple_headers()
    print("All Response tests passed!")
