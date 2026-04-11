"""
MojoFlow Server — HTTP Response handling.
"""

from ..core.types import Header, StatusCode


@value
struct Response:
    """Represents an HTTP response to send back to the client."""

    var status_code: Int
    var status_message: String
    var body: String
    var headers: List[Header]

    fn __init__(out self):
        self.status_code = 200
        self.status_message = "OK"
        self.body = ""
        self.headers = List[Header]()

    fn __init__(out self, body: String, status_code: Int = 200, status_message: String = "OK"):
        self.status_code = status_code
        self.status_message = status_message
        self.body = body
        self.headers = List[Header]()

    fn add_header(inout self, name: String, value: String):
        """Add a header to the response."""
        self.headers.append(Header(name, value))

    fn set_content_type(inout self, content_type: String):
        """Set the Content-Type header."""
        self.headers.append(Header("Content-Type", content_type))

    @staticmethod
    fn json(body: String, status: Int = 200) -> Response:
        """Create a JSON response."""
        var resp = Response(body, status)
        resp.add_header("Content-Type", "application/json")
        resp.add_header("Content-Length", String(len(body)))
        return resp

    @staticmethod
    fn html(body: String, status: Int = 200) -> Response:
        """Create an HTML response."""
        var resp = Response(body, status)
        resp.add_header("Content-Type", "text/html; charset=utf-8")
        resp.add_header("Content-Length", String(len(body)))
        return resp

    @staticmethod
    fn text(body: String, status: Int = 200) -> Response:
        """Create a plain text response."""
        var resp = Response(body, status)
        resp.add_header("Content-Type", "text/plain; charset=utf-8")
        resp.add_header("Content-Length", String(len(body)))
        return resp

    @staticmethod
    fn error(message: String, status: Int = 500) -> Response:
        """Create an error response as JSON."""
        var body = '{"error": "' + message + '"}'
        var resp = Response(body, status)
        if status == 404:
            resp.status_message = "Not Found"
        elif status == 400:
            resp.status_message = "Bad Request"
        elif status == 401:
            resp.status_message = "Unauthorized"
        elif status == 403:
            resp.status_message = "Forbidden"
        elif status == 405:
            resp.status_message = "Method Not Allowed"
        else:
            resp.status_message = "Internal Server Error"
        resp.add_header("Content-Type", "application/json")
        resp.add_header("Content-Length", String(len(body)))
        return resp

    @staticmethod
    fn redirect(location: String, status: Int = 302) -> Response:
        """Create a redirect response."""
        var resp = Response("", status, "Found")
        resp.add_header("Location", location)
        return resp

    fn to_http(self) -> String:
        """Serialize the response into a raw HTTP/1.1 response string."""
        var result = "HTTP/1.1 " + String(self.status_code) + " " + self.status_message + "\r\n"

        # Add headers
        for i in range(len(self.headers)):
            result += self.headers[i].name + ": " + self.headers[i].value + "\r\n"

        # Add server header
        result += "Server: MojoFlow/0.1.0\r\n"
        result += "Connection: close\r\n"
        result += "\r\n"
        result += self.body
        return result
