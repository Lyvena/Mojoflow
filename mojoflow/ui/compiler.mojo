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
        """Compile a UINode tree into a complete HTML document."""
        var body = self._render_html_node(root, 2)
        var html = "<!DOCTYPE html>\n"
        html += "<html lang=\"en\">\n"
        html += "<head>\n"
        html += "  <meta charset=\"UTF-8\">\n"
        html += "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n"
        html += "  <title>MojoFlow App</title>\n"
        html += "</head>\n"
        html += "<body>\n"
        html += body
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
        """Compile a UINode tree into a React functional component."""
        var jsx_body = self._render_jsx_node(root, 2)

        var output = "import React from 'react';\n\n"
        output += "export default function " + self.component_name + "() {\n"
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

    fn compile(self, root: UINode, target: String) -> String:
        """Compile to the specified target format."""
        if target == CompileTarget.REACT:
            return self.compile_to_react(root)
        else:
            return self.compile_to_html(root)
