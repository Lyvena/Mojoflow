"""
MojoFlow CLI — Developer tooling for project scaffolding, development, and deployment.

Commands:
    create  — Scaffold a new MojoFlow project
    dev     — Start development server with hot reload
    build   — Build the project for production
    deploy  — Deploy to a target platform (placeholder)
"""

from .commands import CLICommand, CreateCommand, DevCommand, BuildCommand, DeployCommand
from .main import CLI
