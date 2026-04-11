"""
MojoFlow Core Types — Foundational data structures for the framework.
"""


@value
struct Header:
    """Represents an HTTP header as a key-value pair."""

    var name: String
    var value: String

    fn __init__(out self, name: String, value: String):
        self.name = name
        self.value = value

    fn to_string(self) -> String:
        return self.name + ": " + self.value


@value
struct KeyValue:
    """Generic key-value pair used across the framework."""

    var key: String
    var value: String

    fn __init__(out self, key: String, value: String):
        self.key = key
        self.value = value


@value
struct HttpMethod:
    """HTTP method constants."""

    alias GET = "GET"
    alias POST = "POST"
    alias PUT = "PUT"
    alias DELETE = "DELETE"
    alias PATCH = "PATCH"
    alias OPTIONS = "OPTIONS"
    alias HEAD = "HEAD"

    var value: String

    fn __init__(out self, value: String):
        self.value = value

    fn __eq__(self, other: HttpMethod) -> Bool:
        return self.value == other.value

    fn __ne__(self, other: HttpMethod) -> Bool:
        return self.value != other.value

    fn __str__(self) -> String:
        return self.value


@value
struct StatusCode:
    """HTTP status code constants and utilities."""

    alias OK = 200
    alias CREATED = 201
    alias NO_CONTENT = 204
    alias BAD_REQUEST = 400
    alias UNAUTHORIZED = 401
    alias FORBIDDEN = 403
    alias NOT_FOUND = 404
    alias METHOD_NOT_ALLOWED = 405
    alias INTERNAL_SERVER_ERROR = 500
    alias NOT_IMPLEMENTED = 501

    var code: Int
    var message: String

    fn __init__(out self, code: Int, message: String):
        self.code = code
        self.message = message

    @staticmethod
    fn ok() -> StatusCode:
        return StatusCode(200, "OK")

    @staticmethod
    fn not_found() -> StatusCode:
        return StatusCode(404, "Not Found")

    @staticmethod
    fn internal_error() -> StatusCode:
        return StatusCode(500, "Internal Server Error")

    @staticmethod
    fn bad_request() -> StatusCode:
        return StatusCode(400, "Bad Request")

    fn __str__(self) -> String:
        return String(self.code) + " " + self.message
