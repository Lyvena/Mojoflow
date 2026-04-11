<p align="center">
  <h1 align="center">🔥 MojoFlow</h1>
  <p align="center"><strong>AI-Native Full-Stack Framework for Mojo</strong></p>
  <p align="center">
    <a href="#features">Features</a> •
    <a href="#architecture">Architecture</a> •
    <a href="#quickstart">Quickstart</a> •
    <a href="#examples">Examples</a> •
    <a href="docs/">Docs</a>
  </p>
</p>

---

MojoFlow is a production-grade, modular full-stack framework built for the [Mojo programming language](https://www.modular.com/mojo). It is designed from the ground up for **AI-native development** — LLM integration, agent workflows, and task orchestration are first-class citizens, not afterthoughts.

## Why MojoFlow?

- **AI-First** — Built-in primitives for LLM calls, prompt-to-function mapping, agent loops, and task orchestration.
- **Full-Stack in Mojo** — Backend APIs, AI pipelines, declarative UI, and CLI tooling all in one language.
- **Blazing Performance** — Leverages Mojo's systems-level speed with Python-level ergonomics.
- **Modular & Extensible** — Each layer (server, AI, UI, CLI) is independent and composable.
- **Open Source** — No proprietary dependencies. Usable standalone as a framework.

## Features

| Layer | Capabilities |
|-------|-------------|
| **Core** | Shared types, configuration, error handling |
| **Server** | HTTP server, routing, request/response, middleware, logging |
| **AI** | LLM abstraction, prompt mapping, agent execution, task orchestration |
| **UI** | Declarative DSL in Mojo → compiles to React/HTML |
| **CLI** | `mojoflow create`, `mojoflow dev`, `mojoflow build`, `mojoflow deploy` |

## Architecture

```
┌─────────────────────────────────────────────────┐
│                   CLI Layer                      │
│          mojoflow create / dev / build           │
├─────────────────────────────────────────────────┤
│                   UI Layer                       │
│        Declarative DSL → React / HTML            │
├─────────────────────────────────────────────────┤
│                  AI Layer                        │
│     LLM · Agents · Prompts · Orchestration       │
├─────────────────────────────────────────────────┤
│                Server Layer                      │
│     HTTP · Router · Middleware · Logging          │
├─────────────────────────────────────────────────┤
│                 Core Layer                       │
│       Types · Config · Errors · Utilities         │
└─────────────────────────────────────────────────┘
```

Each layer depends only on the layers below it. The Core layer has zero external dependencies.

## Project Structure

```
mojoflow/
├── mojoflow/                # Framework package
│   ├── core/                # Shared types, config, errors
│   ├── server/              # HTTP server & routing engine
│   ├── ai/                  # AI-native primitives
│   ├── ui/                  # Declarative UI DSL & compiler
│   └── cli/                 # Developer CLI tooling
├── examples/                # Example applications
│   ├── simple_api/          # Basic REST API
│   └── ai_app/              # AI-powered application
├── tests/                   # Test suite
├── docs/                    # Documentation
├── mojoproject.toml         # Mojo project configuration
├── LICENSE                  # Apache 2.0
└── README.md
```

## Quickstart

### Prerequisites

- [Mojo](https://www.modular.com/mojo) installed (latest stable)
- Python 3.10+ (for AI layer interop during MVP)

### Create a New App

```bash
# Clone the framework
git clone https://github.com/Lyvena/mojoflow.git
cd mojoflow

# Run the simple API example
mojo run examples/simple_api/main.mojo
```

### Minimal API Example

```mojo
from mojoflow.server import App, Request, Response

fn main() raises:
    var app = App()

    @app.get("/hello")
    fn hello(req: Request) -> Response:
        return Response.json('{"message": "Hello from MojoFlow!"}')

    app.listen(8080)
```

### AI-Powered Example

```mojo
from mojoflow.ai import LLMClient, Agent

fn main() raises:
    var client = LLMClient(provider="openai", model="gpt-4")
    var agent = Agent(name="assistant", llm=client)

    var result = agent.run("Summarize the benefits of Mojo")
    print(result)
```

## Design Principles

1. **AI-first, not AI-added** — AI primitives are core framework features.
2. **Developer experience matters** — Clean syntax, helpful errors, fast iteration.
3. **Modular architecture** — Use only the layers you need.
4. **Performance without compromise** — Mojo's speed with high-level ergonomics.
5. **Future-ready** — Designed for MAX Engine and hardware acceleration support.

## Roadmap

- [x] Phase 1: Project structure & architecture
- [x] Phase 2: Backend framework (HTTP, routing, middleware)
- [x] Phase 3: AI-native layer (LLM, agents, orchestration)
- [x] Phase 4: Declarative UI DSL & compiler
- [x] Phase 5: CLI tooling
- [x] Phase 6: Example applications
- [ ] Phase 7: Testing framework integration
- [ ] Phase 8: Plugin system
- [ ] Phase 9: MAX Engine integration
- [ ] Phase 10: Package registry publication

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

Apache License 2.0 — see [LICENSE](LICENSE) for details.

---

<p align="center">
  Built with 🔥 for the Mojo ecosystem
</p>