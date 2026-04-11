"""
MojoFlow UI — Compiler that converts the DSL tree into React or HTML output.
"""

from .dsl import UINode, Prop
from .components import Component


@value
struct CompileTarget:
    """Compilation target constants."""

    alias HTML = "html"
    alias REACT = "react"

    var value: String

    fn __init__(out self, value: String):
        self.value = value


struct UICompiler:
    """Compiles a UINode tree into HTML or React JSX source code.

    Example:
        var compiler = UICompiler()
        var html = compiler.compile_to_html(root_component.get_node())
        var jsx = compiler.compile_to_react(root_component.get_node())
    """

    var indent_size: Int
    var component_name: String

    fn __init__(out self, indent_size: Int = 2, component_name: String = "App"):
        self.indent_size = indent_size
        self.component_name = component_name

    # ── HTML Compilation ──────────────────────────────────────────

    fn compile_to_html(self, root: UINode) -> String:
        """Compile a UINode tree into a complete HTML document.

        Event handlers are compiled into inline JavaScript.
        API call patterns (call_api) are converted to fetch() calls.
        """
        var body = self._render_html_node(root, 2)
        var scripts = self._collect_event_scripts(root)
        var html = "<!DOCTYPE html>\n"
        html += "<html lang=\"en\">\n"
        html += "<head>\n"
        html += "  <meta charset=\"UTF-8\">\n"
        html += "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n"
        html += "  <title>MojoFlow App</title>\n"
        html += "</head>\n"
        html += "<body>\n"
        html += body
        if scripts != "":
            html += "  <script>\n" + scripts + "  </script>\n"
        html += "</body>\n"
        html += "</html>\n"
        return html

    fn compile_to_html_fragment(self, root: UINode) -> String:
        """Compile a UINode tree into an HTML fragment (no document wrapper)."""
        return self._render_html_node(root, 0)

    fn _render_html_node(self, node: UINode, depth: Int) -> String:
        """Recursively render a UINode into HTML."""
        var indent = self._indent(depth)
        var result = indent + "<" + node.tag

        # Render attributes
        for i in range(len(node.props)):
            var prop = node.props[i]
            # Convert React-style attributes to HTML
            var attr_name = prop.key
            if attr_name == "className":
                attr_name = "class"
            elif attr_name == "htmlFor":
                attr_name = "for"
            # Skip event handlers in HTML (they need JS)
            if len(attr_name) > 2 and attr_name[:2] == "on":
                continue
            result += " " + attr_name + '="' + prop.value + '"'

        # Self-closing tags
        if node.is_self_closing:
            result += " />\n"
            return result

        result += ">"

        # Text content
        if node.text_content != "":
            if len(node.children) == 0:
                result += node.text_content + "</" + node.tag + ">\n"
                return result
            else:
                result += "\n" + indent + "  " + node.text_content + "\n"

        # Children
        if len(node.children) > 0:
            if node.text_content == "":
                result += "\n"
            for i in range(len(node.children)):
                result += self._render_html_node(node.children[i], depth + 1)
            result += indent + "</" + node.tag + ">\n"
        else:
            if node.text_content == "":
                result += "</" + node.tag + ">\n"

        return result

    # ── React/JSX Compilation ─────────────────────────────────────

    fn compile_to_react(self, root: UINode) -> String:
        """Compile a UINode tree into a React functional component.

        Automatically adds useState import if any event handlers with
        API calls are detected, and generates state + handler functions.
        """
        var jsx_body = self._render_jsx_node(root, 2)
        var has_api_calls = self._has_api_calls(root)

        var output = String("")
        if has_api_calls:
            output += "import React, { useState } from 'react';\n\n"
        else:
            output += "import React from 'react';\n\n"

        output += "export default function " + self.component_name + "() {\n"

        if has_api_calls:
            output += "  const [data, setData] = useState(null);\n"
            output += "  const [loading, setLoading] = useState(false);\n\n"
            output += "  const callApi = async (path) => {\n"
            output += "    setLoading(true);\n"
            output += "    try {\n"
            output += "      const res = await fetch(path);\n"
            output += "      const json = await res.json();\n"
            output += "      setData(json);\n"
            output += "    } catch (err) {\n"
            output += "      console.error('API error:', err);\n"
            output += "    } finally {\n"
            output += "      setLoading(false);\n"
            output += "    }\n"
            output += "  };\n\n"

        output += "  return (\n"
        output += jsx_body
        output += "  );\n"
        output += "}\n"
        return output

    fn compile_to_jsx_fragment(self, root: UINode) -> String:
        """Compile a UINode tree into a JSX fragment (no component wrapper)."""
        return self._render_jsx_node(root, 0)

    fn _render_jsx_node(self, node: UINode, depth: Int) -> String:
        """Recursively render a UINode into JSX."""
        var indent = self._indent(depth)
        var result = indent + "<" + node.tag

        # Render attributes (JSX-style)
        for i in range(len(node.props)):
            var prop = node.props[i]
            result += " " + prop.to_jsx_attr()

        # Self-closing tags
        if node.is_self_closing:
            result += " />\n"
            return result

        result += ">"

        # Text content
        if node.text_content != "":
            if len(node.children) == 0:
                result += node.text_content + "</" + node.tag + ">\n"
                return result
            else:
                result += "\n" + indent + "  " + node.text_content + "\n"

        # Children
        if len(node.children) > 0:
            if node.text_content == "":
                result += "\n"
            for i in range(len(node.children)):
                result += self._render_jsx_node(node.children[i], depth + 1)
            result += indent + "</" + node.tag + ">\n"
        else:
            if node.text_content == "":
                result += "</" + node.tag + ">\n"

        return result

    # ── Utilities ─────────────────────────────────────────────────

    fn _indent(self, depth: Int) -> String:
        """Generate indentation string for the given depth."""
        var result = String("")
        for _ in range(depth * self.indent_size):
            result += " "
        return result

    fn _collect_event_scripts(self, node: UINode) -> String:
        """Collect event handlers from the tree and generate JavaScript."""
        var scripts = String("")
        var counter = 0
        scripts += self._collect_events_recursive(node, counter)
        return scripts

    fn _collect_events_recursive(self, node: UINode, inout counter: Int) -> String:
        """Recursively collect event handler scripts from the node tree."""
        var scripts = String("")
        for i in range(len(node.props)):
            var prop = node.props[i]
            if prop.is_event_handler():
                if prop.is_api_call():
                    var path = prop._extract_api_path()
                    scripts += (
                        "    function handleEvent"
                        + String(counter)
                        + "() {\n"
                    )
                    scripts += "      fetch('" + path + "')\n"
                    scripts += "        .then(r => r.json())\n"
                    scripts += "        .then(data => console.log(data))\n"
                    scripts += "        .catch(err => console.error(err));\n"
                    scripts += "    }\n"
                    counter += 1
        for i in range(len(node.children)):
            scripts += self._collect_events_recursive(node.children[i], counter)
        return scripts

    fn _has_api_calls(self, node: UINode) -> Bool:
        """Check if any node in the tree has API call event handlers."""
        for i in range(len(node.props)):
            if node.props[i].is_api_call():
                return True
        for i in range(len(node.children)):
            if self._has_api_calls(node.children[i]):
                return True
        return False

    fn compile(self, root: UINode, target: String) -> String:
        """Compile to the specified target format."""
        if target == CompileTarget.REACT:
            return self.compile_to_react(root)
        else:
            return self.compile_to_html(root)
