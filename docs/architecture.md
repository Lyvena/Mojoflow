# MojoFlow Architecture

## Layered Design

MojoFlow uses a strict layered architecture where each layer depends only on layers below it.

```
CLI → UI → AI → Server → Core
```

### Core Layer (`mojoflow/core/`)
- **Zero dependencies** — pure Mojo types and utilities
- Shared types: `Header`, `KeyValue`, `HttpMethod`, `StatusCode`
- Configuration: `Config` struct with sensible defaults
- Used by every other module

### Server Layer (`mojoflow/server/`)
- HTTP server with socket-level implementation
- Pattern-based routing with method matching
- Request/Response abstractions with JSON support
- Middleware pipeline (logging, CORS, auth hooks)
- Structured logging with levels

### AI Layer (`mojoflow/ai/`)
- `LLMClient` — Provider-agnostic LLM calls (OpenAI, Anthropic, local)
- `PromptTemplate` — Variable interpolation and prompt management
- `Agent` — Autonomous execution loop with tool support
- `Orchestrator` — Multi-task pipelines with dependencies

### UI Layer (`mojoflow/ui/`)
- Declarative DSL using Mojo structs
- Component library: Button, Text, Input, Container, Form, List
- Compiler targets: React JSX and static HTML
- Event binding to server API endpoints

### CLI Layer (`mojoflow/cli/`)
- `mojoflow create` — Project scaffolding
- `mojoflow dev` — Development server
- `mojoflow build` — Production build
- `mojoflow deploy` — Deployment (placeholder)

## Design Decisions

1. **Python interop for MVP** — AI layer uses Python libraries via Mojo's interop for LLM API calls. This will be replaced with native Mojo HTTP clients as the ecosystem matures.

2. **Struct-based components** — UI uses `@value` structs instead of classes, aligning with Mojo's value semantics and enabling compile-time optimizations.

3. **Middleware as functions** — Middleware is modeled as a chain of handler functions, keeping the pipeline simple and composable.

4. **Provider pattern for AI** — LLM integration uses a provider string, making it easy to swap between OpenAI, Anthropic, or local models.
