# MojoFlow Native Async Server

MojoFlow's native server is a pure-Mojo HTTP backend built for AI-native applications: low-latency APIs, high-throughput inference endpoints, streaming agents, realtime workflows, and compute-heavy request handlers that should not be trapped behind a Python or JavaScript runtime.

```mojo
from mojoflow import Server, ServerConfig


fn main() raises:
    var config = ServerConfig(
        host="127.0.0.1",
        port=8080,
        server_name="MojoFlow API",
        worker_threads=2,
        worker_fibers=64,
        max_connections=100_000,
        metrics_enabled=True,
        openapi_enabled=True,
    )

    var app = Server(config)

    app.get("/", '{"status":"ok","runtime":"native-mojo"}')
    app.get("/health", '{"ok":true}')
    app.post("/v1/jobs", '{"job":{"status":"queued"}}', status=202)

    app.listen_and_serve()
```

Run it:

```bash
mojo run examples/async_server.mojo
# or from a generated MojoFlow app
mojoflow dev
```

## Why It Is Fast

Python and JavaScript web servers are excellent developer tools, but their hot paths still move through interpreter or VM layers, object-heavy request models, garbage-collected allocation patterns, and framework abstractions designed around dynamic languages. MojoFlow is built around a different idea: the web server, parser, router, scheduler, and AI compute path should all live in native Mojo.

The server stack is designed around:

- Direct socket I/O through Mojo FFI, avoiding Python/JS runtime overhead.
- Async listener and event-loop primitives for readiness-driven networking.
- Zero-copy-oriented HTTP parsing with `ByteView` slices over raw bytes.
- SIMD scans for request-line and header delimiters.
- Fiber-based concurrency so many connections can share a small worker footprint.
- Backpressure controls for max connections, pending queues, keep-alive limits, and accept batching.
- MAX parallelism exposed through `HandlerContext.parallel_for()` for CPU-heavy handlers.

That combination lets MojoFlow target the shape AI backends actually need: cheap concurrent I/O for clients and agents, plus native parallel compute for token post-processing, embeddings, JSON transforms, retrieval scoring, routing decisions, and model-adjacent workloads.

## Async + Fibers + MAX

Traditional async frameworks are usually great at I/O and weaker at CPU-heavy work. Traditional parallel systems are usually great at compute and awkward for request handling. MojoFlow combines both:

- **Async I/O** keeps sockets responsive and avoids one-thread-per-client scaling.
- **Fibers** give request handlers lightweight execution contexts without forcing application code into callback-heavy shapes.
- **MAX parallelism** lets a handler fan out compute across workers when the request becomes CPU-bound.

Inside a custom handler, use the request context to parallelize work:

```mojo
fn handle(inout self, inout req: Request, inout ctx: HandlerContext) raises -> Response:
    @parameter
    fn score_chunk(i: Int):
        # rank, transform, embed, or post-process chunk i
        pass

    ctx.parallel_for[score_chunk](1024)
    return Response.json('{"ok":true}')
```

The result is a backend architecture built for AI systems from the first line: native networking, native scheduling, native compute, and one language from HTTP request to high-performance model-adjacent logic.

## Built-In API Surface

The public API is intentionally small:

- `ServerConfig(...)` controls host, port, Fibers, worker threads, timeouts, buffers, backpressure, metrics, and OpenAPI.
- `Server(config)` creates the app.
- `server.get/post/put/delete/patch(...)` registers static JSON routes.
- `Request`, `Response`, `HandlerContext`, and `RequestHandler` power custom handlers.
- `server.listen_and_serve()` starts the native async server.

For benchmarks:

```bash
pixi run bench-server
```

Configure comparison targets with:

```bash
MOJOFLOW_PREVIOUS_CMD="mojo run /path/to/previous_server.mojo"
LIGHTBUG_BENCH_CMD="lightbug /path/to/app"
MOJOFLOW_BENCH_TOOL=wrk
pixi run bench-server
```

MojoFlow's goal is simple: make the fastest path the cleanest path, so AI-native backends can be written like modern web apps while running like systems software.
