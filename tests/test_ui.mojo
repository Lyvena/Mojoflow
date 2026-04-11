"""
Tests for MojoFlow UI DSL and Compiler.
"""

from mojoflow.ui.dsl import UINode, Prop
from mojoflow.ui.compiler import UICompiler


fn test_prop_html_attr() raises:
    """Test Prop HTML attribute rendering."""
    var prop = Prop("className", "btn-primary")
    var result = prop.to_html_attr()
    if result != 'className="btn-primary"':
        raise Error("HTML attr failed: " + result)
    print("  ✓ test_prop_html_attr")


fn test_prop_jsx_attr_normal() raises:
    """Test Prop JSX attribute for normal props."""
    var prop = Prop("className", "container")
    var result = prop.to_jsx_attr()
    if result != 'className="container"':
        raise Error("JSX attr failed: " + result)
    print("  ✓ test_prop_jsx_attr_normal")


fn test_prop_jsx_attr_event() raises:
    """Test Prop JSX attribute for event handlers."""
    var prop = Prop("onClick", "handleClick()")
    var result = prop.to_jsx_attr()
    if "onClick" not in result:
        raise Error("Event handler should contain onClick: " + result)
    if "() =>" not in result:
        raise Error("Event handler should be wrapped in arrow fn: " + result)
    print("  ✓ test_prop_jsx_attr_event")


fn test_prop_api_call_detection() raises:
    """Test Prop API call detection."""
    var p1 = Prop("onClick", 'call_api("/predict")')
    if not p1.is_api_call():
        raise Error("Should detect call_api")
    if not p1.is_event_handler():
        raise Error("onClick should be event handler")

    var p2 = Prop("className", "btn")
    if p2.is_api_call():
        raise Error("className should not be API call")
    if p2.is_event_handler():
        raise Error("className should not be event handler")
    print("  ✓ test_prop_api_call_detection")


fn test_prop_jsx_api_call() raises:
    """Test Prop JSX rendering with call_api pattern."""
    var prop = Prop("onClick", 'call_api("/predict")')
    var result = prop.to_jsx_attr()
    if "fetch('/predict')" not in result:
        raise Error("API call should be converted to fetch: " + result)
    print("  ✓ test_prop_jsx_api_call")


fn test_ui_node_basic() raises:
    """Test basic UINode construction."""
    var node = UINode("div")
    node.add_prop("className", "container")
    node.set_text("Hello")

    if node.tag != "div":
        raise Error("Tag mismatch")
    if node.prop_count() != 1:
        raise Error("Expected 1 prop")
    if node.text_content != "Hello":
        raise Error("Text mismatch")
    if node.get_prop("className") != "container":
        raise Error("get_prop failed")
    print("  ✓ test_ui_node_basic")


fn test_ui_node_children() raises:
    """Test UINode with children."""
    var parent = UINode("div")
    var child1 = UINode("span", "Hello")
    var child2 = UINode("span", "World")
    parent.add_child(child1)
    parent.add_child(child2)

    if parent.child_count() != 2:
        raise Error("Expected 2 children")
    print("  ✓ test_ui_node_children")


fn test_compile_html_simple() raises:
    """Test HTML compilation of a simple node."""
    var compiler = UICompiler()
    var node = UINode("div", "Hello")
    node.add_prop("className", "greeting")

    var html = compiler.compile_to_html(node)
    if "<!DOCTYPE html>" not in html:
        raise Error("Missing DOCTYPE")
    if '<div class="greeting">' not in html:
        raise Error("className should be converted to class in HTML: " + html)
    if "Hello" not in html:
        raise Error("Missing text content")
    print("  ✓ test_compile_html_simple")


fn test_compile_react_simple() raises:
    """Test React JSX compilation."""
    var compiler = UICompiler(component_name="MyComponent")
    var node = UINode("div", "Hello")

    var jsx = compiler.compile_to_react(node)
    if "import React from 'react'" not in jsx:
        raise Error("Missing React import")
    if "export default function MyComponent()" not in jsx:
        raise Error("Missing component function")
    if "<div>" not in jsx:
        raise Error("Missing div tag")
    print("  ✓ test_compile_react_simple")


fn test_compile_react_with_api() raises:
    """Test React compilation with API call detection."""
    var compiler = UICompiler()
    var node = UINode("button", "Click")
    node.add_prop("onClick", 'call_api("/predict")')

    var jsx = compiler.compile_to_react(node)
    if "useState" not in jsx:
        raise Error("API calls should trigger useState import: " + jsx)
    if "callApi" not in jsx:
        raise Error("Should generate callApi helper: " + jsx)
    print("  ✓ test_compile_react_with_api")


fn test_compile_html_event_scripts() raises:
    """Test HTML compilation generates event scripts."""
    var compiler = UICompiler()
    var node = UINode("button", "Click")
    node.add_prop("onClick", 'call_api("/api/predict")')

    var html = compiler.compile_to_html(node)
    if "<script>" not in html:
        raise Error("Should contain script tag for event handlers")
    if "fetch('/api/predict')" not in html:
        raise Error("Should generate fetch call in script: " + html)
    print("  ✓ test_compile_html_event_scripts")


fn test_self_closing_tag() raises:
    """Test self-closing tag compilation."""
    var compiler = UICompiler()
    var node = UINode("input")
    node.is_self_closing = True
    node.add_prop("type", "text")

    var fragment = compiler.compile_to_html_fragment(node)
    if "/>" not in fragment:
        raise Error("Self-closing tag missing />: " + fragment)
    print("  ✓ test_self_closing_tag")


fn main() raises:
    print("Running UI tests...")
    test_prop_html_attr()
    test_prop_jsx_attr_normal()
    test_prop_jsx_attr_event()
    test_prop_api_call_detection()
    test_prop_jsx_api_call()
    test_ui_node_basic()
    test_ui_node_children()
    test_compile_html_simple()
    test_compile_react_simple()
    test_compile_react_with_api()
    test_compile_html_event_scripts()
    test_self_closing_tag()
    print("All UI tests passed!")
