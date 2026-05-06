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
    fn get(inout self, path: String, body: String, status: Int = 200)
    fn post(inout self, path: String, body: String, status: Int = 200)
    fn get(inout self, path: String) -> RouteDecorator
    fn post(inout self, path: String) -> RouteDecorator
    fn decorate_get[handler_fn](inout self, path: String)
    fn decorate_post[handler_fn](inout self, path: String)
    fn use_middleware(inout self, middleware: Middleware)
    fn listen(self, port: Int) raises
```

### `ServerConfig` Observability
```mojo
var observability_enabled: Bool      # default: True
var log_level: String                # "off" | "error" | "warn" | "info" | "debug" | "trace"
var request_logging_enabled: Bool    # default: True
var metrics_enabled: Bool            # default: True
var openapi_enabled: Bool            # default: False
var openapi_path: String             # default: "/openapi.json"
```

### `ServerConfig` Scaling
```mojo
var worker_threads: Int              # OS workers, default: 1
var worker_fibers: Int               # Fiber slots per worker
var max_pending_connections: Int     # bounded backpressure queue
var accept_batch_size: Int           # accepts drained per readiness event
var event_loop_poll_timeout_ms: Int  # hot-loop poll timeout
var max_keep_alive_requests: Int     # requests per keep-alive socket
var keep_alive_timeout_ms: Int       # idle keep-alive timeout
fn total_fiber_slots(self) -> Int
```

### `Server` Observability
```mojo
fn metrics_json(self) -> String
fn openapi_json(self) -> String
fn queued_connections(self) -> Int
fn connection_pressure(self) -> Int
```

### Runtime Scaling
```mojo
struct WorkerModel:
    var worker_threads: Int
    var fibers_per_worker: Int
    var max_parallel_workers: Int
    fn total_fibers(self) -> Int
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
