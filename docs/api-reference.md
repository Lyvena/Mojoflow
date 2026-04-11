# MojoFlow API Reference

## Core

### `Config`
```mojo
struct Config:
    var app_name: String
    var host: String       # default: "127.0.0.1"
    var port: Int          # default: 8080
    var debug: Bool        # default: False
    var log_level: String  # default: "info"
```

### `StatusCode`
Static methods: `ok()`, `not_found()`, `internal_error()`, `bad_request()`

---

## Server

### `App`
```mojo
struct App:
    fn get(inout self, path: String, handler: fn(Request) raises -> Response)
    fn post(inout self, path: String, handler: fn(Request) raises -> Response)
    fn use_middleware(inout self, middleware: Middleware)
    fn listen(self, port: Int) raises
```

### `Request`
```mojo
struct Request:
    var method: String
    var path: String
    var body: String
    var headers: List[Header]
    fn get_header(self, name: String) -> String
```

### `Response`
```mojo
struct Response:
    fn json(body: String, status: Int = 200) -> Response
    fn html(body: String, status: Int = 200) -> Response
    fn text(body: String, status: Int = 200) -> Response
    fn error(message: String, status: Int = 500) -> Response
```

---

## AI

### `LLMClient`
```mojo
struct LLMClient:
    fn complete(self, prompt: String) raises -> LLMResponse
    fn complete_with_template(self, template: PromptTemplate, variables: List[KeyValue]) raises -> LLMResponse
```

### `Agent`
```mojo
struct Agent:
    fn run(self, task: String) raises -> String
    fn run_with_context(self, task: String, context: String) raises -> String
```

### `Orchestrator`
```mojo
struct Orchestrator:
    fn add_task(inout self, task: Task)
    fn execute(self) raises -> List[String]
```

---

## UI

### `Component`
```mojo
struct Component:
    fn add_child(inout self, child: Component)
    fn set_prop(inout self, key: String, value: String)
```

### `UICompiler`
```mojo
struct UICompiler:
    fn compile_to_html(self, root: Component) -> String
    fn compile_to_react(self, root: Component) -> String
```

---

## CLI

### Commands
| Command | Description |
|---------|-------------|
| `mojoflow create <name>` | Scaffold new project |
| `mojoflow dev` | Start dev server |
| `mojoflow build` | Production build |
| `mojoflow deploy` | Deploy (placeholder) |
