"""
MojoFlow Server — Error types for the async HTTP server.

Provides structured, categorized error handling for every failure
mode in the server lifecycle: socket operations, HTTP parsing,
connection management, routing, and TLS.

Design goals:
    - Every error carries a machine-readable kind + human-readable message.
    - Static constructors make common errors one-liners at call sites.
    - Zero Python interop — pure Mojo value types.
"""


# ──────────────────────────────────────────────────────────────────
# Error Kind — machine-readable category
# ──────────────────────────────────────────────────────────────────


@value
struct ErrorKind:
    """Enumeration of server error categories.

    Each constant maps to a distinct failure mode so callers can
    branch on `kind.value` without string matching.
    """

    alias BIND: Int = 1
    alias ACCEPT: Int = 2
    alias PARSE: Int = 3
    alias TIMEOUT: Int = 4
    alias CONNECTION_RESET: Int = 5
    alias HEADER_TOO_LARGE: Int = 6
    alias BODY_TOO_LARGE: Int = 7
    alias METHOD_NOT_ALLOWED: Int = 8
    alias NOT_FOUND: Int = 9
    alias INTERNAL: Int = 10
    alias TLS: Int = 11
    alias IO: Int = 12
    alias SHUTDOWN: Int = 13
    alias CONFIGURATION: Int = 14
    alias EPOLL: Int = 15

    var value: Int

    fn __init__(out self, value: Int):
        self.value = value

    fn name(self) -> String:
        """Return a human-readable label for this error kind."""
        if self.value == Self.BIND:
            return "BIND"
        if self.value == Self.ACCEPT:
            return "ACCEPT"
        if self.value == Self.PARSE:
            return "PARSE"
        if self.value == Self.TIMEOUT:
            return "TIMEOUT"
        if self.value == Self.CONNECTION_RESET:
            return "CONNECTION_RESET"
        if self.value == Self.HEADER_TOO_LARGE:
            return "HEADER_TOO_LARGE"
        if self.value == Self.BODY_TOO_LARGE:
            return "BODY_TOO_LARGE"
        if self.value == Self.METHOD_NOT_ALLOWED:
            return "METHOD_NOT_ALLOWED"
        if self.value == Self.NOT_FOUND:
            return "NOT_FOUND"
        if self.value == Self.INTERNAL:
            return "INTERNAL"
        if self.value == Self.TLS:
            return "TLS"
        if self.value == Self.IO:
            return "IO"
        if self.value == Self.SHUTDOWN:
            return "SHUTDOWN"
        if self.value == Self.CONFIGURATION:
            return "CONFIGURATION"
        if self.value == Self.EPOLL:
            return "EPOLL"
        return "UNKNOWN"

    fn __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    fn __ne__(self, other: Self) -> Bool:
        return self.value != other.value

    fn __str__(self) -> String:
        return self.name()


# ──────────────────────────────────────────────────────────────────
# ServerError — rich error with kind + message + detail
# ──────────────────────────────────────────────────────────────────


@value
struct ServerError:
    """Structured error carrying a category, summary, and optional detail.

    Example:
        var err = ServerError.parse("Malformed request line", raw_line)
        if err.kind == ErrorKind(ErrorKind.PARSE):
            log_parse_failure(err)
    """

    var kind: ErrorKind
    var message: String
    var detail: String

    fn __init__(out self, kind: ErrorKind, message: String, detail: String = ""):
        self.kind = kind
        self.message = message
        self.detail = detail

    fn __str__(self) -> String:
        var s = "[" + self.kind.name() + "] " + self.message
        if self.detail != "":
            s += " — " + self.detail
        return s

    fn to_error(self) -> Error:
        """Convert to a stdlib Error for use with `raise`."""
        return Error(self.__str__())

    # ── Static constructors for common errors ─────────────────────

    @staticmethod
    fn bind(message: String, detail: String = "") -> ServerError:
        return ServerError(ErrorKind(ErrorKind.BIND), message, detail)

    @staticmethod
    fn accept(message: String, detail: String = "") -> ServerError:
        return ServerError(ErrorKind(ErrorKind.ACCEPT), message, detail)

    @staticmethod
    fn parse(message: String, detail: String = "") -> ServerError:
        return ServerError(ErrorKind(ErrorKind.PARSE), message, detail)

    @staticmethod
    fn timeout(message: String, detail: String = "") -> ServerError:
        return ServerError(ErrorKind(ErrorKind.TIMEOUT), message, detail)

    @staticmethod
    fn connection_reset(detail: String = "") -> ServerError:
        return ServerError(
            ErrorKind(ErrorKind.CONNECTION_RESET),
            "Connection reset by peer",
            detail,
        )

    @staticmethod
    fn header_too_large(size: Int, limit: Int) -> ServerError:
        return ServerError(
            ErrorKind(ErrorKind.HEADER_TOO_LARGE),
            "Header section exceeds limit",
            "size=" + String(size) + " limit=" + String(limit),
        )

    @staticmethod
    fn body_too_large(size: Int, limit: Int) -> ServerError:
        return ServerError(
            ErrorKind(ErrorKind.BODY_TOO_LARGE),
            "Request body exceeds limit",
            "size=" + String(size) + " limit=" + String(limit),
        )

    @staticmethod
    fn not_found(path: String) -> ServerError:
        return ServerError(
            ErrorKind(ErrorKind.NOT_FOUND),
            "No route matched",
            "path=" + path,
        )

    @staticmethod
    fn method_not_allowed(method: String, path: String) -> ServerError:
        return ServerError(
            ErrorKind(ErrorKind.METHOD_NOT_ALLOWED),
            "Method not allowed",
            method + " " + path,
        )

    @staticmethod
    fn internal(message: String, detail: String = "") -> ServerError:
        return ServerError(ErrorKind(ErrorKind.INTERNAL), message, detail)

    @staticmethod
    fn io(message: String, detail: String = "") -> ServerError:
        return ServerError(ErrorKind(ErrorKind.IO), message, detail)

    @staticmethod
    fn epoll(message: String, detail: String = "") -> ServerError:
        return ServerError(ErrorKind(ErrorKind.EPOLL), message, detail)

    @staticmethod
    fn configuration(message: String, detail: String = "") -> ServerError:
        return ServerError(ErrorKind(ErrorKind.CONFIGURATION), message, detail)
