# Contributing to MojoFlow

Thank you for your interest in contributing to MojoFlow! This document provides guidelines for contributing to the project.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/mojoflow.git`
3. Create a feature branch: `git checkout -b feature/your-feature`
4. Make your changes
5. Run tests: `mojo test tests/`
6. Commit: `git commit -m "feat: description of change"`
7. Push: `git push origin feature/your-feature`
8. Open a Pull Request

## Project Structure

- `mojoflow/core/` — Shared types, config, error handling
- `mojoflow/server/` — HTTP server, routing, middleware
- `mojoflow/ai/` — LLM abstraction, agents, orchestration
- `mojoflow/ui/` — Declarative UI DSL and compiler
- `mojoflow/cli/` — CLI tooling
- `examples/` — Example applications
- `tests/` — Test suite
- `docs/` — Documentation

## Commit Convention

We follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` — New feature
- `fix:` — Bug fix
- `docs:` — Documentation only
- `refactor:` — Code refactoring
- `test:` — Adding or updating tests
- `chore:` — Maintenance tasks

## Code Style

- Follow idiomatic Mojo conventions
- Use descriptive variable and function names
- Keep functions focused and small
- Add type annotations everywhere
- Document public APIs with docstrings

## Module Guidelines

- Each module should be independently usable where possible
- Core module must have zero external dependencies
- Use traits for abstraction boundaries
- Prefer composition over inheritance

## Reporting Issues

- Use GitHub Issues
- Include Mojo version, OS, and steps to reproduce
- Provide minimal reproduction examples

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.
