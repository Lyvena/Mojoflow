"""
MojoFlow UI — DSL primitives for declarative UI definition.

Provides the foundational node and property types that all
UI components are built upon.
"""


@value
struct Prop:
    """A UI component property (key-value attribute)."""

    var key: String
    var value: String

    fn __init__(out self, key: String, value: String):
        self.key = key
        self.value = value

    fn to_html_attr(self) -> String:
        """Render as an HTML attribute."""
        return self.key + '="' + self.value + '"'

    fn is_event_handler(self) -> Bool:
        """Check if this prop is an event handler (starts with 'on')."""
        return len(self.key) > 2 and self.key[:2] == "on"

    fn is_api_call(self) -> Bool:
        """Check if the value is an API call pattern like 'call_api("/path")'."""
        return "call_api(" in self.value or "fetch(" in self.value

    fn to_jsx_attr(self) -> String:
        """Render as a JSX attribute.

        Event handlers (onClick, onChange, etc.) are rendered as
        function expressions. API call patterns are converted to fetch().
        """
        if len(self.key) < 2:
            return self.key + '="' + self.value + '"'
        if self.key[:2] == "on":
            # Check for call_api() pattern and convert to fetch
            if "call_api(" in self.value:
                var api_path = self._extract_api_path()
                return (
                    self.key
                    + "={() => fetch('"
                    + api_path
                    + "').then(r => r.json()).then(data => console.log(data))}"
                )
            return self.key + "={() => " + self.value + "}"
        return self.key + '="' + self.value + '"'

    fn _extract_api_path(self) -> String:
        """Extract the API path from a call_api("/path") pattern."""
        var start = self.value.find('("')
        var end = self.value.find('")')
        if start != -1 and end != -1:
            return self.value[start + 2 : end]
        start = self.value.find("('")
        end = self.value.find("')")
        if start != -1 and end != -1:
            return self.value[start + 2 : end]
        return "/"


@value
struct UINode:
    """A generic node in the UI tree.

    Every UI element (component, text, container) is represented
    as a UINode with a tag, properties, children, and optional
    text content.
    """

    var tag: String
    var props: List[Prop]
    var children: List[UINode]
    var text_content: String
    var is_self_closing: Bool

    fn __init__(out self, tag: String):
        self.tag = tag
        self.props = List[Prop]()
        self.children = List[UINode]()
        self.text_content = ""
        self.is_self_closing = False

    fn __init__(out self, tag: String, text: String):
        self.tag = tag
        self.props = List[Prop]()
        self.children = List[UINode]()
        self.text_content = text
        self.is_self_closing = False

    fn add_prop(inout self, key: String, value: String):
        """Add a property to this node."""
        self.props.append(Prop(key, value))

    fn add_child(inout self, child: UINode):
        """Add a child node."""
        self.children.append(child)

    fn set_text(inout self, text: String):
        """Set the text content of this node."""
        self.text_content = text

    fn prop_count(self) -> Int:
        return len(self.props)

    fn child_count(self) -> Int:
        return len(self.children)

    fn get_prop(self, key: String) -> String:
        """Get property value by key. Returns empty string if not found."""
        for i in range(len(self.props)):
            if self.props[i].key == key:
                return self.props[i].value
        return ""
