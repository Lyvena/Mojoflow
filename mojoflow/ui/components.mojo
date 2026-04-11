"""
MojoFlow UI — Built-in component library.

Provides pre-built UI components that map to common HTML/React elements.
Each component is a factory that returns a configured UINode.
"""

from .dsl import UINode, Prop


@value
struct Component:
    """Base component wrapper around a UINode.

    Provides a fluent interface for building UI trees.
    """

    var node: UINode

    fn __init__(out self, tag: String):
        self.node = UINode(tag)

    fn __init__(out self, tag: String, text: String):
        self.node = UINode(tag, text)

    fn set_prop(inout self, key: String, value: String) -> ref [self] Self:
        """Set a property on this component."""
        self.node.add_prop(key, value)
        return self

    fn add_child(inout self, child: Component):
        """Add a child component."""
        self.node.add_child(child.node)

    fn add_child_node(inout self, child: UINode):
        """Add a raw UINode as child."""
        self.node.add_child(child)

    fn get_node(self) -> UINode:
        """Get the underlying UINode."""
        return self.node


struct Button:
    """Button component factory."""

    @staticmethod
    fn create(text: String, on_click: String = "") -> Component:
        """Create a button component.

        Args:
            text: Button label text.
            on_click: Click handler — can be a JS expression or API call.
        """
        var comp = Component("button", text)
        comp.node.add_prop("type", "button")
        if on_click != "":
            comp.node.add_prop("onClick", on_click)
        return comp

    @staticmethod
    fn submit(text: String = "Submit") -> Component:
        """Create a submit button."""
        var comp = Component("button", text)
        comp.node.add_prop("type", "submit")
        return comp


struct Text:
    """Text display component factory."""

    @staticmethod
    fn heading(content: String, level: Int = 1) -> Component:
        """Create a heading (h1-h6)."""
        var tag = "h" + String(level)
        return Component(tag, content)

    @staticmethod
    fn paragraph(content: String) -> Component:
        """Create a paragraph."""
        return Component("p", content)

    @staticmethod
    fn span(content: String) -> Component:
        """Create an inline text span."""
        return Component("span", content)

    @staticmethod
    fn label(content: String, for_id: String = "") -> Component:
        """Create a label element."""
        var comp = Component("label", content)
        if for_id != "":
            comp.node.add_prop("htmlFor", for_id)
        return comp


struct Input:
    """Input component factory."""

    @staticmethod
    fn text(name: String, placeholder: String = "", value: String = "") -> Component:
        """Create a text input."""
        var comp = Component("input")
        comp.node.is_self_closing = True
        comp.node.add_prop("type", "text")
        comp.node.add_prop("name", name)
        if placeholder != "":
            comp.node.add_prop("placeholder", placeholder)
        if value != "":
            comp.node.add_prop("value", value)
        return comp

    @staticmethod
    fn password(name: String, placeholder: String = "") -> Component:
        """Create a password input."""
        var comp = Component("input")
        comp.node.is_self_closing = True
        comp.node.add_prop("type", "password")
        comp.node.add_prop("name", name)
        if placeholder != "":
            comp.node.add_prop("placeholder", placeholder)
        return comp

    @staticmethod
    fn textarea(name: String, placeholder: String = "", rows: Int = 4) -> Component:
        """Create a textarea."""
        var comp = Component("textarea")
        comp.node.add_prop("name", name)
        comp.node.add_prop("rows", String(rows))
        if placeholder != "":
            comp.node.add_prop("placeholder", placeholder)
        return comp


struct Container:
    """Container/layout component factory."""

    @staticmethod
    fn div(class_name: String = "") -> Component:
        """Create a div container."""
        var comp = Component("div")
        if class_name != "":
            comp.node.add_prop("className", class_name)
        return comp

    @staticmethod
    fn section(class_name: String = "") -> Component:
        """Create a section container."""
        var comp = Component("section")
        if class_name != "":
            comp.node.add_prop("className", class_name)
        return comp

    @staticmethod
    fn main(class_name: String = "") -> Component:
        """Create a main container."""
        var comp = Component("main")
        if class_name != "":
            comp.node.add_prop("className", class_name)
        return comp


struct Form:
    """Form component factory."""

    @staticmethod
    fn create(action: String = "", method: String = "POST") -> Component:
        """Create a form element."""
        var comp = Component("form")
        if action != "":
            comp.node.add_prop("action", action)
        comp.node.add_prop("method", method)
        return comp


struct List:
    """List component factory."""

    @staticmethod
    fn unordered(class_name: String = "") -> Component:
        """Create an unordered list."""
        var comp = Component("ul")
        if class_name != "":
            comp.node.add_prop("className", class_name)
        return comp

    @staticmethod
    fn ordered(class_name: String = "") -> Component:
        """Create an ordered list."""
        var comp = Component("ol")
        if class_name != "":
            comp.node.add_prop("className", class_name)
        return comp

    @staticmethod
    fn item(content: String) -> Component:
        """Create a list item."""
        return Component("li", content)
