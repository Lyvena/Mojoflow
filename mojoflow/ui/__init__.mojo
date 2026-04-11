"""
MojoFlow UI — Declarative UI DSL and compiler.

Define UI components in Mojo using a clean declarative syntax,
then compile them to React components or static HTML.
"""

from .dsl import UINode, Prop
from .components import Component, Button, Text, Input, Container, Form, List
from .compiler import UICompiler, CompileTarget
