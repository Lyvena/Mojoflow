"""
MojoFlow CLI — Executable entry point.

This file serves as the main() entry for the CLI tool.

Run:
    mojo run mojoflow/cli/entry.mojo create myapp
    mojo run mojoflow/cli/entry.mojo dev
    mojo run mojoflow/cli/entry.mojo build
    mojo run mojoflow/cli/entry.mojo --help
"""

from .main import CLI


fn main() raises:
    var cli = CLI()
    cli.run()
