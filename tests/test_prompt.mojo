"""
Tests for MojoFlow AI Prompt system.
"""

from mojoflow.ai.prompt import PromptTemplate, PromptRegistry
from mojoflow.core.types import KeyValue


fn test_basic_render() raises:
    """Test basic variable interpolation."""
    var tmpl = PromptTemplate(
        name="greet",
        template="Hello, {{name}}! Welcome to {{place}}.",
    )
    var vars = List[KeyValue]()
    vars.append(KeyValue("name", "Alice"))
    vars.append(KeyValue("place", "MojoFlow"))

    var result = tmpl.render(vars)
    if result != "Hello, Alice! Welcome to MojoFlow.":
        raise Error("Render failed: " + result)
    print("  ✓ test_basic_render")


fn test_render_no_vars() raises:
    """Test rendering with no variables (literal template)."""
    var tmpl = PromptTemplate(
        name="static",
        template="No variables here.",
    )
    var vars = List[KeyValue]()
    var result = tmpl.render(vars)
    if result != "No variables here.":
        raise Error("Static render failed: " + result)
    print("  ✓ test_render_no_vars")


fn test_render_missing_var() raises:
    """Test rendering with a missing variable keeps the placeholder."""
    var tmpl = PromptTemplate(
        name="missing",
        template="Hello, {{name}}!",
    )
    var vars = List[KeyValue]()
    var result = tmpl.render(vars)
    # Missing variables should remain as placeholders
    if "{{name}}" not in result and "name" not in result:
        raise Error("Missing var should keep placeholder or name: " + result)
    print("  ✓ test_render_missing_var")


fn test_registry() raises:
    """Test prompt registry add and get."""
    var registry = PromptRegistry()
    var tmpl = PromptTemplate(name="test", template="Hello {{who}}")
    registry.add(tmpl)

    if not registry.has("test"):
        raise Error("Registry should have 'test'")
    if registry.has("nonexistent"):
        raise Error("Registry should not have 'nonexistent'")

    var found = registry.get("test")
    if found.name != "test":
        raise Error("Got wrong template: " + found.name)

    if registry.count() != 1:
        raise Error("Expected count 1")
    print("  ✓ test_registry")


fn test_template_variables() raises:
    """Test extracting variable names from a template."""
    var tmpl = PromptTemplate(
        name="multi",
        template="{{greeting}}, {{name}}! Your ID is {{id}}.",
    )
    var vars = tmpl.variables()
    if len(vars) != 3:
        raise Error("Expected 3 variables, got " + String(len(vars)))
    print("  ✓ test_template_variables")


fn main() raises:
    print("Running Prompt tests...")
    test_basic_render()
    test_render_no_vars()
    test_render_missing_var()
    test_registry()
    test_template_variables()
    print("All Prompt tests passed!")
