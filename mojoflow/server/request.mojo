"""
MojoFlow Server — HTTP Request handling.
"""

from ..core.types import Header, HttpMethod


@value
struct Request:
    """Represents an incoming HTTP request."""

    var method: String
    var path: String
    var body: String
    var query_string: String
    var http_version: String
    var headers: List[Header]

    fn __init__(out self):
        self.method = HttpMethod.GET
        self.path = "/"
        self.body = ""
        self.query_string = ""
        self.http_version = "HTTP/1.1"
        self.headers = List[Header]()

    fn __init__(
        out self,
        method: String,
        path: String,
        body: String = "",
        query_string: String = "",
        http_version: String = "HTTP/1.1",
    ):
        self.method = method
        self.path = path
        self.body = body
        self.query_string = query_string
        self.http_version = http_version
        self.headers = List[Header]()

    fn add_header(inout self, name: String, value: String):
        """Add a header to the request."""
        self.headers.append(Header(name, value))

    fn get_header(self, name: String) -> String:
        """Get a header value by name (case-insensitive). Returns empty string if not found."""
        var lower_name = name.lower()
        for i in range(len(self.headers)):
            if self.headers[i].name.lower() == lower_name:
                return self.headers[i].value
        return ""

    fn has_header(self, name: String) -> Bool:
        """Check if a header exists."""
        var lower_name = name.lower()
        for i in range(len(self.headers)):
            if self.headers[i].name.lower() == lower_name:
                return True
        return False

    fn is_json(self) -> Bool:
        """Check if the request content type is JSON."""
        var ct = self.get_header("Content-Type")
        return "application/json" in ct

    fn content_length(self) -> Int:
        """Get the content length, or 0 if not present."""
        var val = self.get_header("Content-Length")
        if val == "":
            return 0
        try:
            return Int(val)
        except:
            return 0

    @staticmethod
    fn parse(raw: String) raises -> Request:
        """Parse a raw HTTP request string into a Request struct.

        Parses the request line, headers, and body from a raw HTTP/1.1 request.
        """
        var req = Request()

        var header_end = raw.find("\r\n\r\n")
        var header_section: String
        var body_section: String = ""

        if header_end != -1:
            header_section = raw[:header_end]
            body_section = raw[header_end + 4 :]
        else:
            header_section = raw

        var lines = header_section.split("\r\n")
        if len(lines) == 0:
            raise Error("Empty HTTP request")

        # Parse request line: METHOD /path HTTP/1.1
        var request_line = lines[0]
        var parts = request_line.split(" ")
        if len(parts) < 3:
            raise Error("Malformed request line: " + request_line)

        req.method = parts[0]
        var full_path = parts[1]
        req.http_version = parts[2]

        # Split path and query string
        var q_index = full_path.find("?")
        if q_index != -1:
            req.path = full_path[:q_index]
            req.query_string = full_path[q_index + 1 :]
        else:
            req.path = full_path

        # Parse headers
        for i in range(1, len(lines)):
            var line = lines[i]
            var colon = line.find(":")
            if colon != -1:
                var name = line[:colon]
                var value = line[colon + 1 :]
                # Strip leading whitespace from value
                if len(value) > 0 and value[0] == " ":
                    value = value[1:]
                req.add_header(name, value)

        req.body = body_section
        return req
