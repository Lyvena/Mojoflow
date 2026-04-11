"""
Tests for MojoFlow Core JSON builder.
"""

from mojoflow.core.json import JsonBuilder, JsonArrayBuilder, JsonValue, _escape_json_string


fn test_escape_json_string() raises:
    """Test JSON string escaping."""
    # Basic string — no escaping needed
    var result = _escape_json_string("hello")
    if result != "hello":
        raise Error("Expected 'hello', got: " + result)

    # Double quotes
    result = _escape_json_string('say "hi"')
    if result != 'say \\"hi\\"':
        raise Error("Quote escaping failed: " + result)

    # Newlines and tabs
    result = _escape_json_string("line1\nline2")
    if result != "line1\\nline2":
        raise Error("Newline escaping failed: " + result)

    result = _escape_json_string("col1\tcol2")
    if result != "col1\\tcol2":
        raise Error("Tab escaping failed: " + result)

    print("  ✓ test_escape_json_string")


fn test_json_builder_empty() raises:
    """Test empty JSON object."""
    var builder = JsonBuilder()
    var result = builder.build()
    if result != "{}":
        raise Error("Expected '{}', got: " + result)
    print("  ✓ test_json_builder_empty")


fn test_json_builder_strings() raises:
    """Test JSON builder with string fields."""
    var builder = JsonBuilder()
    builder.add_string("name", "Alice")
    builder.add_string("city", "Berlin")
    var result = builder.build()

    if '"name": "Alice"' not in result:
        raise Error("Missing name field in: " + result)
    if '"city": "Berlin"' not in result:
        raise Error("Missing city field in: " + result)
    print("  ✓ test_json_builder_strings")


fn test_json_builder_mixed() raises:
    """Test JSON builder with mixed types."""
    var builder = JsonBuilder()
    builder.add_string("name", "Bob")
    builder.add_int("age", 30)
    builder.add_bool("active", True)
    builder.add_null("deleted_at")
    var result = builder.build()

    if '"name": "Bob"' not in result:
        raise Error("Missing name in: " + result)
    if '"age": 30' not in result:
        raise Error("Missing age in: " + result)
    if '"active": true' not in result:
        raise Error("Missing active in: " + result)
    if '"deleted_at": null' not in result:
        raise Error("Missing deleted_at in: " + result)
    print("  ✓ test_json_builder_mixed")


fn test_json_array_builder() raises:
    """Test JSON array builder."""
    var arr = JsonArrayBuilder()
    arr.add_string("Alice")
    arr.add_string("Bob")
    arr.add_int(42)
    var result = arr.build()

    if result != '["Alice", "Bob", 42]':
        raise Error("Unexpected array: " + result)
    print("  ✓ test_json_array_builder")


fn test_json_array_empty() raises:
    """Test empty JSON array."""
    var arr = JsonArrayBuilder()
    if arr.build() != "[]":
        raise Error("Expected '[]'")
    print("  ✓ test_json_array_empty")


fn test_nested_object() raises:
    """Test nested JSON objects."""
    var inner = JsonBuilder()
    inner.add_string("street", "123 Main St")
    inner.add_string("city", "Springfield")

    var outer = JsonBuilder()
    outer.add_string("name", "Alice")
    outer.add_object("address", inner)
    var result = outer.build()

    if '"address": {' not in result:
        raise Error("Missing nested object in: " + result)
    if '"street": "123 Main St"' not in result:
        raise Error("Missing street in: " + result)
    print("  ✓ test_nested_object")


fn test_json_value() raises:
    """Test JsonValue construction."""
    var s = JsonValue.from_string("hello")
    if s.to_json() != '"hello"':
        raise Error("String value failed: " + s.to_json())

    var n = JsonValue.from_int(42)
    if n.to_json() != "42":
        raise Error("Int value failed: " + n.to_json())

    var b = JsonValue.from_bool(True)
    if b.to_json() != "true":
        raise Error("Bool value failed: " + b.to_json())

    var null = JsonValue.null()
    if null.to_json() != "null":
        raise Error("Null value failed: " + null.to_json())
    print("  ✓ test_json_value")


fn main() raises:
    print("Running JSON tests...")
    test_escape_json_string()
    test_json_builder_empty()
    test_json_builder_strings()
    test_json_builder_mixed()
    test_json_array_builder()
    test_json_array_empty()
    test_nested_object()
    test_json_value()
    print("All JSON tests passed!")
