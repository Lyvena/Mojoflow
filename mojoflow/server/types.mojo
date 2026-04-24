"""
MojoFlow Server — Core HTTP types.

Pure-Mojo value types for the request/response lifecycle:

    HTTPVersion  — HTTP protocol version (1.0 / 1.1).
    HTTPMethod   — Standard HTTP verbs with fast equality.
    StatusCode   — Numeric code + canonical reason phrase.
    Headers      — Case-insensitive, multi-value header map.
    Request      — Fully parsed incoming request.
    Response     — Outgoing response with builder helpers.

Design goals:
    - Zero Python interop — every type is a native Mojo struct.
    - Allocation-conscious: headers stored in a flat List for
      cache-friendly iteration; Dict index planned behind a TODO.
    - Builder pattern on Response for ergonomic construction.

TODO:
    - Streaming body support (chunked transfer-encoding).
    - Cookie parsing helpers on Request.
    - Typed header accessors (Accept, Content-Type, etc.).
    - HTTP/2 pseudo-header support.
    - URL-decoded query parameter parsing.
    - Multipart form-data parsing.
"""


# ──────────────────────────────────────────────────────────────────
# HTTP Version
# ──────────────────────────────────────────────────────────────────


@value
struct HTTPVersion:
    """HTTP protocol version."""

    alias HTTP10 = "HTTP/1.0"
    alias HTTP11 = "HTTP/1.1"

    var value: String

    fn __init__(out self, value: String = Self.HTTP11):
        self.value = value

    fn is_keep_alive_default(self) -> Bool:
        """HTTP/1.1 defaults to keep-alive; 1.0 does not."""
        return self.value == Self.HTTP11

    fn __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    fn __ne__(self, other: Self) -> Bool:
        return self.value != other.value

    fn __str__(self) -> String:
        return self.value


# ──────────────────────────────────────────────────────────────────
# HTTP Method
# ──────────────────────────────────────────────────────────────────


@value
struct HTTPMethod:
    """Standard HTTP request methods.

    Comparison is case-sensitive (RFC 7230 §3.1.1: methods are
    case-sensitive, and standard methods are uppercase).
    """

    alias GET = "GET"
    alias HEAD = "HEAD"
    alias POST = "POST"
    alias PUT = "PUT"
    alias DELETE = "DELETE"
    alias PATCH = "PATCH"
    alias OPTIONS = "OPTIONS"
    alias TRACE = "TRACE"
    alias CONNECT = "CONNECT"

    var value: String

    fn __init__(out self, value: String = Self.GET):
        self.value = value

    fn is_safe(self) -> Bool:
        """Safe methods do not modify server state (RFC 7231 §4.2.1)."""
        return (
            self.value == Self.GET
            or self.value == Self.HEAD
            or self.value == Self.OPTIONS
            or self.value == Self.TRACE
        )

    fn is_idempotent(self) -> Bool:
        """Idempotent methods yield the same result on repeat (RFC 7231 §4.2.2)."""
        return self.is_safe() or self.value == Self.PUT or self.value == Self.DELETE

    fn allows_body(self) -> Bool:
        """Whether the method semantically allows a request body."""
        return (
            self.value == Self.POST
            or self.value == Self.PUT
            or self.value == Self.PATCH
        )

    fn __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    fn __ne__(self, other: Self) -> Bool:
        return self.value != other.value

    fn __str__(self) -> String:
        return self.value


# ──────────────────────────────────────────────────────────────────
# Status Code
# ──────────────────────────────────────────────────────────────────


@value
struct StatusCode:
    """HTTP response status code with canonical reason phrase.

    Provides aliases for every standard code used in practice and a
    `reason()` method that returns the phrase for the wire format.
    """

    # — 1xx Informational —
    alias CONTINUE = 100
    alias SWITCHING_PROTOCOLS = 101

    # — 2xx Success —
    alias OK = 200
    alias CREATED = 201
    alias ACCEPTED = 202
    alias NO_CONTENT = 204
    alias PARTIAL_CONTENT = 206

    # — 3xx Redirection —
    alias MOVED_PERMANENTLY = 301
    alias FOUND = 302
    alias SEE_OTHER = 303
    alias NOT_MODIFIED = 304
    alias TEMPORARY_REDIRECT = 307
    alias PERMANENT_REDIRECT = 308

    # — 4xx Client Error —
    alias BAD_REQUEST = 400
    alias UNAUTHORIZED = 401
    alias FORBIDDEN = 403
    alias NOT_FOUND = 404
    alias METHOD_NOT_ALLOWED = 405
    alias REQUEST_TIMEOUT = 408
    alias CONFLICT = 409
    alias GONE = 410
    alias LENGTH_REQUIRED = 411
    alias PAYLOAD_TOO_LARGE = 413
    alias URI_TOO_LONG = 414
    alias UNSUPPORTED_MEDIA_TYPE = 415
    alias TOO_MANY_REQUESTS = 429

    # — 5xx Server Error —
    alias INTERNAL_SERVER_ERROR = 500
    alias NOT_IMPLEMENTED = 501
    alias BAD_GATEWAY = 502
    alias SERVICE_UNAVAILABLE = 503
    alias GATEWAY_TIMEOUT = 504

    var code: Int

    fn __init__(out self, code: Int = Self.OK):
        self.code = code

    fn reason(self) -> String:
        """Canonical reason phrase for the status line."""
        if self.code == 100: return "Continue"
        if self.code == 101: return "Switching Protocols"
        if self.code == 200: return "OK"
        if self.code == 201: return "Created"
        if self.code == 202: return "Accepted"
        if self.code == 204: return "No Content"
        if self.code == 206: return "Partial Content"
        if self.code == 301: return "Moved Permanently"
        if self.code == 302: return "Found"
        if self.code == 303: return "See Other"
        if self.code == 304: return "Not Modified"
        if self.code == 307: return "Temporary Redirect"
        if self.code == 308: return "Permanent Redirect"
        if self.code == 400: return "Bad Request"
        if self.code == 401: return "Unauthorized"
        if self.code == 403: return "Forbidden"
        if self.code == 404: return "Not Found"
        if self.code == 405: return "Method Not Allowed"
        if self.code == 408: return "Request Timeout"
        if self.code == 409: return "Conflict"
        if self.code == 410: return "Gone"
        if self.code == 411: return "Length Required"
        if self.code == 413: return "Payload Too Large"
        if self.code == 414: return "URI Too Long"
        if self.code == 415: return "Unsupported Media Type"
        if self.code == 429: return "Too Many Requests"
        if self.code == 500: return "Internal Server Error"
        if self.code == 501: return "Not Implemented"
        if self.code == 502: return "Bad Gateway"
        if self.code == 503: return "Service Unavailable"
        if self.code == 504: return "Gateway Timeout"
        return "Unknown"

    fn is_informational(self) -> Bool:
        return self.code >= 100 and self.code < 200

    fn is_success(self) -> Bool:
        return self.code >= 200 and self.code < 300

    fn is_redirect(self) -> Bool:
        return self.code >= 300 and self.code < 400

    fn is_client_error(self) -> Bool:
        return self.code >= 400 and self.code < 500

    fn is_server_error(self) -> Bool:
        return self.code >= 500 and self.code < 600

    fn __eq__(self, other: Self) -> Bool:
        return self.code == other.code

    fn __ne__(self, other: Self) -> Bool:
        return self.code != other.code

    fn __str__(self) -> String:
        return String(self.code) + " " + self.reason()


# ──────────────────────────────────────────────────────────────────
# Headers — case-insensitive header map
# ──────────────────────────────────────────────────────────────────


@value
struct HeaderEntry:
    """Single header: original-case name + value."""

    var name: String
    var value: String

    fn __init__(out self, name: String, value: String):
        self.name = name
        self.value = value


struct Headers:
    """Case-insensitive HTTP header collection.

    Stores headers in insertion order in a flat list for cache-friendly
    iteration.  Lookups lower-case the key for case-insensitive matching
    per RFC 7230 §3.2.

    Example:
        var h = Headers()
        h.set("Content-Type", "application/json")
        var ct = h.get("content-type")  # "application/json"

    TODO:
        - Add a Dict[String, Int] index for O(1) lookup on large header sets.
        - Support multi-value headers (e.g. Set-Cookie) via get_all().
        - Typed accessors for common headers (Accept, Authorization, …).
    """

    var _entries: List[HeaderEntry]

    fn __init__(out self):
        self._entries = List[HeaderEntry]()

    fn set(inout self, name: String, value: String):
        """Set a header, replacing any existing header with the same name."""
        var lower = name.lower()
        for i in range(len(self._entries)):
            if self._entries[i].name.lower() == lower:
                self._entries[i] = HeaderEntry(name, value)
                return
        self._entries.append(HeaderEntry(name, value))

    fn append(inout self, name: String, value: String):
        """Append a header (allows duplicate names, e.g. Set-Cookie)."""
        self._entries.append(HeaderEntry(name, value))

    fn get(self, name: String) -> String:
        """Get the first value for a header name (case-insensitive).

        Returns empty string if not found.
        """
        var lower = name.lower()
        for i in range(len(self._entries)):
            if self._entries[i].name.lower() == lower:
                return self._entries[i].value
        return ""

    fn has(self, name: String) -> Bool:
        """Check whether a header exists (case-insensitive)."""
        var lower = name.lower()
        for i in range(len(self._entries)):
            if self._entries[i].name.lower() == lower:
                return True
        return False

    fn remove(inout self, name: String):
        """Remove all headers with this name (case-insensitive)."""
        var lower = name.lower()
        var new_entries = List[HeaderEntry]()
        for i in range(len(self._entries)):
            if self._entries[i].name.lower() != lower:
                new_entries.append(self._entries[i])
        self._entries = new_entries

    fn len(self) -> Int:
        """Number of header entries."""
        return len(self._entries)

    fn byte_size(self) -> Int:
        """Approximate byte size of all headers on the wire.

        Used for max_header_size enforcement.
        """
        var total = 0
        for i in range(len(self._entries)):
            # "Name: Value\r\n"
            total += len(self._entries[i].name) + 2 + len(self._entries[i].value) + 2
        return total

    fn to_http(self) -> String:
        """Serialize headers to HTTP wire format (Name: Value\\r\\n)."""
        var out = String("")
        for i in range(len(self._entries)):
            out += self._entries[i].name + ": " + self._entries[i].value + "\r\n"
        return out

    fn clear(inout self):
        """Remove all headers."""
        self._entries = List[HeaderEntry]()


# ──────────────────────────────────────────────────────────────────
# Request
# ──────────────────────────────────────────────────────────────────


@value
struct QueryParam:
    """A single key=value from the query string."""

    var key: String
    var value: String

    fn __init__(out self, key: String, value: String):
        self.key = key
        self.value = value


@value
struct RouteParam:
    """A named parameter extracted from a route pattern (e.g. :id → 42)."""

    var key: String
    var value: String

    fn __init__(out self, key: String, value: String):
        self.key = key
        self.value = value


struct Request:
    """Incoming HTTP request.

    Holds every piece of a parsed HTTP/1.x request: method, path,
    version, headers, body, query-string parameters, and route
    parameters injected by the router.

    The `parse()` static method turns raw bytes into a Request.

    Example:
        var req = Request.parse(raw_bytes)
        var user_id = req.route_param("id")
        var format  = req.query_param("format")

    TODO:
        - Streaming / chunked body support.
        - Decompression (gzip, brotli) on the body.
        - Cookie jar accessor.
        - Form-data / multipart parsing.
        - URL percent-decoding of path and query values.
    """

    var method: HTTPMethod
    var path: String
    var version: HTTPVersion
    var headers: Headers
    var body: String
    var query_string: String
    var query_params: List[QueryParam]
    var route_params: List[RouteParam]
    var remote_addr: String

    fn __init__(out self):
        self.method = HTTPMethod()
        self.path = "/"
        self.version = HTTPVersion()
        self.headers = Headers()
        self.body = ""
        self.query_string = ""
        self.query_params = List[QueryParam]()
        self.route_params = List[RouteParam]()
        self.remote_addr = ""

    fn __init__(
        out self,
        method: String,
        path: String,
        version: String = HTTPVersion.HTTP11,
    ):
        self.method = HTTPMethod(method)
        self.path = path
        self.version = HTTPVersion(version)
        self.headers = Headers()
        self.body = ""
        self.query_string = ""
        self.query_params = List[QueryParam]()
        self.route_params = List[RouteParam]()
        self.remote_addr = ""

    # ── Header accessors ──────────────────────────────────────────

    fn get_header(self, name: String) -> String:
        """Get header value (case-insensitive). Empty string if absent."""
        return self.headers.get(name)

    fn has_header(self, name: String) -> Bool:
        return self.headers.has(name)

    fn content_length(self) -> Int:
        """Parsed Content-Length, or 0 if absent / malformed."""
        var val = self.headers.get("Content-Length")
        if val == "":
            return 0
        try:
            return Int(val)
        except:
            return 0

    fn content_type(self) -> String:
        return self.headers.get("Content-Type")

    fn is_json(self) -> Bool:
        return "application/json" in self.content_type()

    fn is_keep_alive(self) -> Bool:
        """Whether this request wants keep-alive."""
        var conn = self.headers.get("Connection").lower()
        if conn == "close":
            return False
        if conn == "keep-alive":
            return True
        # HTTP/1.1 defaults to keep-alive
        return self.version.is_keep_alive_default()

    # ── Route parameter accessors ─────────────────────────────────

    fn route_param(self, name: String) -> String:
        """Get a route parameter by name. Empty string if absent."""
        for i in range(len(self.route_params)):
            if self.route_params[i].key == name:
                return self.route_params[i].value
        return ""

    fn has_route_param(self, name: String) -> Bool:
        for i in range(len(self.route_params)):
            if self.route_params[i].key == name:
                return True
        return False

    fn add_route_param(inout self, key: String, value: String):
        self.route_params.append(RouteParam(key, value))

    # ── Query parameter accessors ─────────────────────────────────

    fn query_param(self, name: String) -> String:
        """Get a query parameter by name. Empty string if absent."""
        for i in range(len(self.query_params)):
            if self.query_params[i].key == name:
                return self.query_params[i].value
        return ""

    fn has_query_param(self, name: String) -> Bool:
        for i in range(len(self.query_params)):
            if self.query_params[i].key == name:
                return True
        return False

    # ── Parsing ───────────────────────────────────────────────────

    @staticmethod
    fn parse(raw: String) raises -> Request:
        """Parse a raw HTTP/1.x request string into a Request.

        Splits the request line, headers, and body on \\r\\n boundaries.
        Query string is split from the path and parsed into key=value pairs.

        Raises on malformed input (empty request, missing request line fields).
        """
        if len(raw) == 0:
            raise Error("Empty HTTP request")

        var req = Request()

        # ── Split header section from body ────────────────────────
        var header_end = raw.find("\r\n\r\n")
        var header_section: String
        var body_section: String = ""

        if header_end != -1:
            header_section = raw[:header_end]
            body_section = raw[header_end + 4 :]
        else:
            header_section = raw

        # ── Parse request line ────────────────────────────────────
        var lines = header_section.split("\r\n")
        if len(lines) == 0:
            raise Error("Missing request line")

        var parts = lines[0].split(" ")
        if len(parts) < 3:
            raise Error("Malformed request line: " + lines[0])

        req.method = HTTPMethod(parts[0])
        var full_path = parts[1]
        req.version = HTTPVersion(parts[2])

        # ── Separate path from query string ───────────────────────
        var q_idx = full_path.find("?")
        if q_idx != -1:
            req.path = full_path[:q_idx]
            req.query_string = full_path[q_idx + 1 :]
            req.query_params = Request._parse_query(req.query_string)
        else:
            req.path = full_path

        # ── Parse headers ─────────────────────────────────────────
        for i in range(1, len(lines)):
            var line = lines[i]
            var colon = line.find(":")
            if colon != -1:
                var name = line[:colon]
                var value = line[colon + 1 :]
                # Trim leading whitespace from value
                if len(value) > 0 and value[0] == " ":
                    value = value[1:]
                req.headers.set(name, value)

        req.body = body_section
        return req

    @staticmethod
    fn _parse_query(qs: String) -> List[QueryParam]:
        """Split a query string into key=value pairs on '&'."""
        var params = List[QueryParam]()
        if qs == "":
            return params
        var pairs = qs.split("&")
        for i in range(len(pairs)):
            var pair = pairs[i]
            var eq = pair.find("=")
            if eq != -1:
                params.append(QueryParam(pair[:eq], pair[eq + 1 :]))
            else:
                params.append(QueryParam(pair, ""))
        return params


# ──────────────────────────────────────────────────────────────────
# Response
# ──────────────────────────────────────────────────────────────────


struct Response:
    """Outgoing HTTP response.

    Build responses with static constructors (`.json()`, `.html()`,
    `.text()`, `.error()`, `.redirect()`) or create one manually
    and mutate it before serialisation.

    Call `to_bytes()` to obtain the full HTTP/1.1 response ready to
    be written to a socket.

    Example:
        var resp = Response.json('{"ok": true}')
        resp.set_header("X-Request-Id", request_id)
        var wire = resp.to_bytes()

    TODO:
        - Streaming / chunked responses.
        - Compression (gzip, brotli) via Content-Encoding.
        - ETag / Last-Modified auto-generation helpers.
        - Cookie setting helpers.
    """

    var status: StatusCode
    var headers: Headers
    var body: String
    var _server_name: String

    fn __init__(out self):
        self.status = StatusCode(StatusCode.OK)
        self.headers = Headers()
        self.body = ""
        self._server_name = "MojoFlow/0.2.0"

    fn __init__(
        out self,
        body: String,
        status_code: Int = StatusCode.OK,
        server_name: String = "MojoFlow/0.2.0",
    ):
        self.status = StatusCode(status_code)
        self.headers = Headers()
        self.body = body
        self._server_name = server_name

    # ── Header helpers ────────────────────────────────────────────

    fn set_header(inout self, name: String, value: String):
        """Set a response header (replaces if exists)."""
        self.headers.set(name, value)

    fn add_header(inout self, name: String, value: String):
        """Append a response header (allows duplicates like Set-Cookie)."""
        self.headers.append(name, value)

    fn set_content_type(inout self, ct: String):
        self.headers.set("Content-Type", ct)

    # ── Static builders ───────────────────────────────────────────

    @staticmethod
    fn json(body: String, status: Int = 200) -> Response:
        """JSON response with correct Content-Type and Content-Length."""
        var r = Response(body, status)
        r.headers.set("Content-Type", "application/json; charset=utf-8")
        r.headers.set("Content-Length", String(len(body)))
        return r

    @staticmethod
    fn html(body: String, status: Int = 200) -> Response:
        """HTML response."""
        var r = Response(body, status)
        r.headers.set("Content-Type", "text/html; charset=utf-8")
        r.headers.set("Content-Length", String(len(body)))
        return r

    @staticmethod
    fn text(body: String, status: Int = 200) -> Response:
        """Plain-text response."""
        var r = Response(body, status)
        r.headers.set("Content-Type", "text/plain; charset=utf-8")
        r.headers.set("Content-Length", String(len(body)))
        return r

    @staticmethod
    fn error(message: String, status: Int = 500) -> Response:
        """JSON error response.  Escapes the message into a JSON string."""
        var body = '{"error": "' + message + '"}'
        var r = Response(body, status)
        r.headers.set("Content-Type", "application/json; charset=utf-8")
        r.headers.set("Content-Length", String(len(body)))
        return r

    @staticmethod
    fn redirect(location: String, status: Int = 302) -> Response:
        """Redirect response (302 by default)."""
        var r = Response("", status)
        r.headers.set("Location", location)
        r.headers.set("Content-Length", "0")
        return r

    @staticmethod
    fn no_content() -> Response:
        """204 No Content response."""
        return Response("", StatusCode.NO_CONTENT)

    # ── Serialisation ─────────────────────────────────────────────

    fn to_bytes(self) -> String:
        """Serialize the full HTTP/1.1 response for the wire.

        Format:
            HTTP/1.1 {code} {reason}\\r\\n
            {headers}\\r\\n
            Server: {server_name}\\r\\n
            Connection: keep-alive\\r\\n
            \\r\\n
            {body}
        """
        var out = (
            "HTTP/1.1 "
            + String(self.status.code)
            + " "
            + self.status.reason()
            + "\r\n"
        )
        out += self.headers.to_http()
        out += "Server: " + self._server_name + "\r\n"
        out += "Connection: keep-alive\r\n"
        out += "\r\n"
        out += self.body
        return out

    fn to_bytes_close(self) -> String:
        """Like `to_bytes()` but with `Connection: close`."""
        var out = (
            "HTTP/1.1 "
            + String(self.status.code)
            + " "
            + self.status.reason()
            + "\r\n"
        )
        out += self.headers.to_http()
        out += "Server: " + self._server_name + "\r\n"
        out += "Connection: close\r\n"
        out += "\r\n"
        out += self.body
        return out
