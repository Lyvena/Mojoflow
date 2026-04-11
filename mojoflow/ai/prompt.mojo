"""
MojoFlow AI — Prompt template system.

Provides reusable prompt templates with variable interpolation
and a registry for managing prompt collections.
"""

from ..core.types import KeyValue


@value
struct PromptTemplate:
    """A reusable prompt template with variable placeholders.

    Placeholders use {{variable_name}} syntax.

    Example:
        var tpl = PromptTemplate(
            name="summarize",
            template="Summarize the following text in {{style}}: {{text}}"
        )
        var result = tpl.render(variables)
    """

    var name: String
    var template: String
    var description: String

    fn __init__(out self, name: String, template: String, description: String = ""):
        self.name = name
        self.template = template
        self.description = description

    fn render(self, variables: List[KeyValue]) raises -> String:
        """Render the template by replacing {{key}} placeholders with values.

        Raises if a placeholder has no matching variable.
        """
        var result = self.template

        for i in range(len(variables)):
            var placeholder = "{{" + variables[i].key + "}}"
            # Replace all occurrences
            while placeholder in result:
                var idx = result.find(placeholder)
                if idx == -1:
                    break
                result = result[:idx] + variables[i].value + result[idx + len(placeholder) :]

        # Check for unreplaced placeholders
        if "{{" in result and "}}" in result:
            raise Error("Unresolved placeholders in template '" + self.name + "': " + result)

        return result

    fn variables(self) -> List[String]:
        """Extract placeholder variable names from the template."""
        var vars = List[String]()
        var text = self.template
        var start = 0

        while start < len(text):
            var open_idx = text.find("{{", start)
            if open_idx == -1:
                break
            var close_idx = text.find("}}", open_idx)
            if close_idx == -1:
                break
            var var_name = text[open_idx + 2 : close_idx]
            vars.append(var_name)
            start = close_idx + 2

        return vars


struct PromptRegistry:
    """Registry for managing named prompt templates.

    Allows registering, retrieving, and listing prompt templates
    by name for organized prompt management.
    """

    var templates: List[PromptTemplate]

    fn __init__(out self):
        self.templates = List[PromptTemplate]()

    fn register(inout self, template: PromptTemplate):
        """Register a prompt template."""
        self.templates.append(template)

    fn get(self, name: String) raises -> PromptTemplate:
        """Get a template by name."""
        for i in range(len(self.templates)):
            if self.templates[i].name == name:
                return self.templates[i]
        raise Error("Prompt template not found: " + name)

    fn has(self, name: String) -> Bool:
        """Check if a template exists."""
        for i in range(len(self.templates)):
            if self.templates[i].name == name:
                return True
        return False

    fn list_names(self) -> List[String]:
        """List all registered template names."""
        var names = List[String]()
        for i in range(len(self.templates)):
            names.append(self.templates[i].name)
        return names

    fn count(self) -> Int:
        return len(self.templates)
