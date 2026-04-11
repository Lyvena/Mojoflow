"""
MojoFlow Core JSON — Safe JSON construction and escaping.

Provides a builder pattern for constructing JSON objects and arrays
without manual string concatenation or escaping bugs.
"""


fn _escape_json_string(s: String) -> String:
    """Escape special characters in a string for safe JSON embedding."""
    var result = String("")
    for i in range(len(s)):
        var c = s[i]
        if c == '"':
            result += '\\"'
        elif c == "\\":
            result += "\\\\"
        elif c == "\n":
            result += "\\n"
        elif c == "\r":
            result += "\\r"
        elif c == "\t":
            result += "\\t"
        else:
            result += String(c)
    return result


@value
struct JsonValue:
    """Represents a JSON value that can be a string, number, bool, null,
    object, or array. Stored as a pre-serialized string internally.
    """

    var _raw: String
    var _is_string: Bool

    fn __init__(out self):
        self._raw = "null"
        self._is_string = False

    @staticmethod
    fn null() -> JsonValue:
        return JsonValue("null", False)

    @staticmethod
    fn from_bool(val: Bool) -> JsonValue:
        if val:
            return JsonValue("true", False)
        return JsonValue("false", False)

    @staticmethod
    fn from_int(val: Int) -> JsonValue:
        return JsonValue(String(val), False)

    @staticmethod
    fn from_float(val: Float64) -> JsonValue:
        return JsonValue(String(val), False)

    @staticmethod
    fn from_string(val: String) -> JsonValue:
        return JsonValue(val, True)

    @staticmethod
    fn raw(val: String) -> JsonValue:
        """Create a JsonValue from a pre-serialized JSON string (object/array)."""
        return JsonValue(val, False)

    fn to_json(self) -> String:
        """Serialize this value to a JSON string."""
        if self._is_string:
            return '"' + _escape_json_string(self._raw) + '"'
        return self._raw

    fn __str__(self) -> String:
        return self.to_json()


struct JsonBuilder:
    """Builder for constructing JSON objects with a fluent API.

    Example:
        var json = JsonBuilder()
        json.add_string("name", "Alice")
        json.add_int("age", 30)
        json.add_bool("active", True)
        var result = json.build()
        # -> {"name": "Alice", "age": 30, "active": true}
    """

    var _entries: List[String]

    fn __init__(out self):
        self._entries = List[String]()

    fn add_string(inout self, key: String, value: String):
        """Add a string field."""
        var entry = '"' + _escape_json_string(key) + '": "' + _escape_json_string(value) + '"'
        self._entries.append(entry)

    fn add_int(inout self, key: String, value: Int):
        """Add an integer field."""
        var entry = '"' + _escape_json_string(key) + '": ' + String(value)
        self._entries.append(entry)

    fn add_float(inout self, key: String, value: Float64):
        """Add a float field."""
        var entry = '"' + _escape_json_string(key) + '": ' + String(value)
        self._entries.append(entry)

    fn add_bool(inout self, key: String, value: Bool):
        """Add a boolean field."""
        var val = "true" if value else "false"
        var entry = '"' + _escape_json_string(key) + '": ' + val
        self._entries.append(entry)

    fn add_null(inout self, key: String):
        """Add a null field."""
        var entry = '"' + _escape_json_string(key) + '": null'
        self._entries.append(entry)

    fn add_raw(inout self, key: String, raw_json: String):
        """Add a pre-serialized JSON value (object, array, etc.)."""
        var entry = '"' + _escape_json_string(key) + '": ' + raw_json
        self._entries.append(entry)

    fn add_object(inout self, key: String, obj: JsonBuilder):
        """Add a nested JSON object."""
        var entry = '"' + _escape_json_string(key) + '": ' + obj.build()
        self._entries.append(entry)

    fn add_value(inout self, key: String, value: JsonValue):
        """Add a JsonValue field."""
        var entry = '"' + _escape_json_string(key) + '": ' + value.to_json()
        self._entries.append(entry)

    fn build(self) -> String:
        """Build the final JSON object string."""
        if len(self._entries) == 0:
            return "{}"
        var result = String("{")
        for i in range(len(self._entries)):
            if i > 0:
                result += ", "
            result += self._entries[i]
        result += "}"
        return result

    fn __str__(self) -> String:
        return self.build()


struct JsonArrayBuilder:
    """Builder for constructing JSON arrays.

    Example:
        var arr = JsonArrayBuilder()
        arr.add_string("Alice")
        arr.add_string("Bob")
        var result = arr.build()
        # -> ["Alice", "Bob"]
    """

    var _items: List[String]

    fn __init__(out self):
        self._items = List[String]()

    fn add_string(inout self, value: String):
        """Add a string element."""
        self._items.append('"' + _escape_json_string(value) + '"')

    fn add_int(inout self, value: Int):
        """Add an integer element."""
        self._items.append(String(value))

    fn add_float(inout self, value: Float64):
        """Add a float element."""
        self._items.append(String(value))

    fn add_bool(inout self, value: Bool):
        """Add a boolean element."""
        self._items.append("true" if value else "false")

    fn add_null(inout self):
        """Add a null element."""
        self._items.append("null")

    fn add_raw(inout self, raw_json: String):
        """Add a pre-serialized JSON element."""
        self._items.append(raw_json)

    fn add_object(inout self, obj: JsonBuilder):
        """Add a nested object."""
        self._items.append(obj.build())

    fn build(self) -> String:
        """Build the final JSON array string."""
        if len(self._items) == 0:
            return "[]"
        var result = String("[")
        for i in range(len(self._items)):
            if i > 0:
                result += ", "
            result += self._items[i]
        result += "]"
        return result

    fn __str__(self) -> String:
        return self.build()
