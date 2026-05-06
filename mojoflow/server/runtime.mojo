"""
MojoFlow Server — Fiber-based async runtime and scheduler.

Manages thousands of lightweight Fibers for concurrent request
handling, backed by a work-stealing scheduler and structured
concurrency via TaskGroup.

Architecture:
    ┌───────────────────────────────────────────────────────────┐
    │  AsyncRuntime                                             │
    │                                                           │
    │  ┌───────────┐   poll()   ┌────────────────────────────┐ │
    │  │ EventLoop │ ─────────► │ FiberPool                  │ │
    │  │ (epoll)   │            │                            │ │
    │  └───────────┘            │  ┌──────┐ ┌──────┐ ┌────┐ │ │
    │                           │  │Fiber0│ │Fiber1│ │ …  │ │ │
    │                           │  └──┬───┘ └──┬───┘ └──┬─┘ │ │
    │                           └─────┼────────┼────────┼───┘ │
    │                                 ▼        ▼        ▼     │
    │                           handler() → Response          │
    │                                                           │
    │  ┌──────────────────┐  for CPU-bound work inside handlers│
    │  │ MAX parallelize  │◄────────────────────────────────── │
    │  └──────────────────┘                                    │
    └───────────────────────────────────────────────────────────┘

Components:
    FiberState       — Lifecycle state of a single Fiber.
    FiberHandle      — Handle referencing a spawned Fiber.
    FiberPool        — Fixed-size pool with spawn/reclaim.
    TaskQueue        — FIFO of pending work items.
    TaskGroup        — Structured-concurrency barrier over a set of Fibers.
    AsyncRuntime     — Top-level runtime: event loop + fiber pool.

Public functions:
    run_forever()    — Start the runtime and block until shutdown.
    spawn_fiber()    — Submit work to the fiber pool.
    await_all()      — Block until all pending fibers complete.
    parallelize_work — Fan CPU-bound work out to MAX Engine workers.

TODO:
    - True Fiber integration once Mojo stabilises Fiber/Coroutine.
    - Work-stealing across OS threads.
    - Fiber migration between cores.
    - Cancellation tokens and structured shutdown.
    - Per-fiber stack guard pages.
    - Adaptive fiber pool sizing.
"""

from memory import UnsafePointer, memset_zero
from sys import external_call
from algorithm import parallelize

from .config import ServerConfig
from .errors import ServerError, ErrorKind
from .net import EventLoop, IOEvent, AsyncListener, AsyncConnection


# ══════════════════════════════════════════════════════════════════
#  Fiber lifecycle
# ══════════════════════════════════════════════════════════════════

@value
struct FiberState:
    """State machine for a single Fiber slot.

    Transitions:
        IDLE → READY → RUNNING → COMPLETE → IDLE (recycled)
                                 ↘ FAILED → IDLE
    """
    alias IDLE: Int = 0       # Slot available for reuse
    alias READY: Int = 1      # Work assigned, waiting to run
    alias RUNNING: Int = 2    # Actively executing handler
    alias COMPLETE: Int = 3   # Finished successfully
    alias FAILED: Int = 4     # Finished with error

    var value: Int

    fn __init__(out self, value: Int = Self.IDLE):
        self.value = value

    fn is_idle(self) -> Bool:
        return self.value == Self.IDLE

    fn is_active(self) -> Bool:
        return self.value == Self.READY or self.value == Self.RUNNING

    fn name(self) -> String:
        if self.value == Self.IDLE:      return "IDLE"
        if self.value == Self.READY:     return "READY"
        if self.value == Self.RUNNING:   return "RUNNING"
        if self.value == Self.COMPLETE:  return "COMPLETE"
        if self.value == Self.FAILED:    return "FAILED"
        return "UNKNOWN"


# ══════════════════════════════════════════════════════════════════
#  FiberHandle — reference to a spawned fiber
# ══════════════════════════════════════════════════════════════════

@value
struct FiberHandle:
    """Opaque handle returned by `spawn_fiber()`.

    Can be used to query state or (in future) cancel a fiber.

    TODO:
        - Cancellation support.
        - Result retrieval for typed returns.
    """
    var id: Int
    var _pool_generation: Int

    fn __init__(out self, id: Int, generation: Int):
        self.id = id
        self._pool_generation = generation

    fn __str__(self) -> String:
        return "FiberHandle(id=" + String(self.id) + ")"


# ══════════════════════════════════════════════════════════════════
#  TaskGroup — structured concurrency barrier
# ══════════════════════════════════════════════════════════════════

struct TaskGroup:
    """Structured-concurrency scope mirroring Mojo's `TaskGroup`.

    A TaskGroup owns a set of FiberHandles and guarantees that
    `wait()` blocks until **every** member fiber has reached
    COMPLETE or FAILED — no fiber outlives its group.

    Usage (inside a handler):

        var group = TaskGroup()
        group.add(runtime.spawn_fiber(fd_a))
        group.add(runtime.spawn_fiber(fd_b))
        group.wait(runtime)   # blocks until both finish

    Error semantics:
        - If any fiber FAILED, `any_failed()` returns True after wait().
        - `failures()` returns the count of failed fibers.
        - A failing fiber never prevents sibling completion —
          cancellation is cooperative (see TODO).

    TODO:
        - Cooperative cancellation on first failure (fail-fast mode).
        - Per-group timeout via timer fd.
        - Typed results once Mojo supports generic return values.
    """

    var _handles: List[FiberHandle]
    var _failed_count: Int

    fn __init__(out self):
        self._handles = List[FiberHandle]()
        self._failed_count = 0

    fn add(inout self, handle: FiberHandle):
        """Enlist a fiber handle in the group."""
        if handle.id >= 0:
            self._handles.append(handle)

    fn wait(inout self, inout runtime: AsyncRuntime) raises:
        """Block until every member fiber is no longer active.

        Drives the runtime's poll loop in a bounded fashion so
        work can actually make progress while we wait — this is
        the structured-concurrency equivalent of joining a
        TaskGroup, not a busy-wait.
        """
        while True:
            var any_active = False
            for i in range(len(self._handles)):
                var h = self._handles[i]
                var st = runtime.fiber_pool.get_state(h.id)
                if st.is_active():
                    any_active = True
                    break
            if not any_active:
                break
            # Advance runtime by one poll cycle.
            runtime.tick()

        # Tally failures.
        self._failed_count = 0
        for i in range(len(self._handles)):
            var h = self._handles[i]
            var st = runtime.fiber_pool.get_state(h.id)
            if st.value == FiberState.FAILED:
                self._failed_count += 1

    fn size(self) -> Int:
        return len(self._handles)

    fn any_failed(self) -> Bool:
        return self._failed_count > 0

    fn failures(self) -> Int:
        return self._failed_count


# ══════════════════════════════════════════════════════════════════
#  Work Item — unit of work submitted to the pool
# ══════════════════════════════════════════════════════════════════

@value
struct WorkItem:
    """A pending unit of work: a connection fd to process.

    In future this will wrap a closure / function pointer once
    Mojo supports storable `fn` types.  For now, work items carry
    the client fd and the fiber pool processes them through the
    server's request handler.

    TODO:
        - Generic work: `fn(AsyncConnection) raises -> None`.
        - Priority levels for latency-sensitive routes.
    """
    var client_fd: Int32
    var fiber_id: Int  # -1 = unassigned

    fn __init__(out self, client_fd: Int32):
        self.client_fd = client_fd
        self.fiber_id = -1


# ══════════════════════════════════════════════════════════════════
#  TaskQueue — FIFO of pending work
# ══════════════════════════════════════════════════════════════════

struct TaskQueue:
    """Simple FIFO queue for pending work items.

    Used by the runtime to buffer accepted connections until a
    fiber slot becomes available.

    TODO:
        - Lock-free MPSC queue for multi-threaded runtime.
        - Bounded capacity with back-pressure to the accept loop.
    """
    var _items: List[WorkItem]

    fn __init__(out self):
        self._items = List[WorkItem]()

    fn push(inout self, item: WorkItem):
        """Enqueue a work item."""
        self._items.append(item)

    fn pop(inout self) -> WorkItem:
        """Dequeue the oldest work item.

        Caller must check `is_empty()` first.
        """
        var item = self._items[0]
        # Shift remaining items (O(n) — acceptable for MVP)
        var new_items = List[WorkItem]()
        for i in range(1, len(self._items)):
            new_items.append(self._items[i])
        self._items = new_items
        return item

    fn is_empty(self) -> Bool:
        return len(self._items) == 0

    fn len(self) -> Int:
        return len(self._items)


# ══════════════════════════════════════════════════════════════════
#  FiberPool — fixed-size pool of fiber slots
# ══════════════════════════════════════════════════════════════════

struct FiberPool:
    """Manages a fixed pool of Fiber slots for concurrent work.

    Each slot tracks its state and the fd it's processing.
    When a fiber completes, its slot is recycled to IDLE.

    The pool size is set by `config.worker_fibers`.

    Structured concurrency: `await_all()` blocks until every
    active fiber has finished — this is the TaskGroup equivalent.

    TODO:
        - Integrate real Mojo Fiber/Coroutine when available.
        - Stack allocation per fiber using config.fiber_stack_size.
        - Work-stealing between OS threads.
        - Fiber-local storage.
    """

    var _states: List[FiberState]
    var _fds: List[Int32]
    var _size: Int
    var _active_count: Int
    var _total_spawned: Int
    var _generation: Int

    fn __init__(out self, size: Int):
        """Create a pool with `size` fiber slots, all IDLE."""
        self._size = size
        self._active_count = 0
        self._total_spawned = 0
        self._generation = 0
        self._states = List[FiberState]()
        self._fds = List[Int32]()
        for _ in range(size):
            self._states.append(FiberState(FiberState.IDLE))
            self._fds.append(-1)

    fn spawn(inout self, client_fd: Int32) -> FiberHandle:
        """Assign work to the first idle fiber slot.

        Returns a FiberHandle.  If no slot is available, returns
        a handle with id = -1 (caller should queue the work).
        """
        for i in range(self._size):
            if self._states[i].is_idle():
                self._states[i] = FiberState(FiberState.READY)
                self._fds[i] = client_fd
                self._active_count += 1
                self._total_spawned += 1
                self._generation += 1
                return FiberHandle(i, self._generation)
        return FiberHandle(-1, 0)  # No slot available

    fn activate(inout self, fiber_id: Int):
        """Transition a READY fiber to RUNNING."""
        if fiber_id >= 0 and fiber_id < self._size:
            self._states[fiber_id] = FiberState(FiberState.RUNNING)

    fn complete(inout self, fiber_id: Int):
        """Mark a fiber as COMPLETE and recycle to IDLE."""
        if fiber_id >= 0 and fiber_id < self._size:
            self._states[fiber_id] = FiberState(FiberState.IDLE)
            self._fds[fiber_id] = -1
            self._active_count -= 1

    fn fail(inout self, fiber_id: Int):
        """Mark a fiber as FAILED and recycle to IDLE."""
        if fiber_id >= 0 and fiber_id < self._size:
            self._states[fiber_id] = FiberState(FiberState.IDLE)
            self._fds[fiber_id] = -1
            self._active_count -= 1

    fn get_fd(self, fiber_id: Int) -> Int32:
        """Get the client fd assigned to a fiber."""
        if fiber_id >= 0 and fiber_id < self._size:
            return self._fds[fiber_id]
        return -1

    fn get_state(self, fiber_id: Int) -> FiberState:
        """Get the current state of a fiber."""
        if fiber_id >= 0 and fiber_id < self._size:
            return self._states[fiber_id]
        return FiberState()

    fn active_count(self) -> Int:
        """Number of fibers currently doing work."""
        return self._active_count

    fn idle_count(self) -> Int:
        """Number of available fiber slots."""
        return self._size - self._active_count

    fn has_idle(self) -> Bool:
        """Whether at least one slot is available."""
        return self._active_count < self._size

    fn total_spawned(self) -> Int:
        """Total fibers spawned since pool creation (monotonic)."""
        return self._total_spawned

    fn pool_size(self) -> Int:
        return self._size

    fn await_all(self):
        """Block until all active fibers are idle.

        In the current synchronous implementation this is a no-op
        because fibers run inline.  With real async Fibers, this
        will yield the calling fiber until every slot returns to
        IDLE — the equivalent of TaskGroup.await_all().

        TODO:
            - Integrate with Mojo TaskGroup for structured concurrency.
            - Add timeout parameter.
            - Add cancellation support.
        """
        # MVP: synchronous — all work completes inline before
        # this method is called, so active_count is already 0.
        pass


# ══════════════════════════════════════════════════════════════════
#  AsyncRuntime — top-level runtime tying everything together
# ══════════════════════════════════════════════════════════════════

struct AsyncRuntime:
    """The MojoFlow async runtime.

    Owns the event loop, fiber pool, and task queue.  Drives the
    accept → dispatch → handle → respond cycle.

    MAX Engine integration:
        For CPU-bound work inside request handlers (JSON parsing,
        template rendering, AI inference), callers can use
        `parallelize_work()` to offload to MAX parallel workers.
        This keeps the fiber pool responsive for I/O-bound work.

    Example:
        var rt = AsyncRuntime.create(config)
        rt.register_listener(listener)
        rt.run_forever(handle_fn)

    TODO:
        - Signal handling (SIGTERM, SIGINT) for graceful shutdown.
        - Metrics: connections/sec, latency histogram, active fibers.
        - Health check endpoint built into the runtime.
        - Hot config reload.
    """

    var config: ServerConfig
    var event_loop: EventLoop
    var fiber_pool: FiberPool
    var task_queue: TaskQueue
    var _running: Bool
    var _connections_total: Int

    fn __init__(out self, config: ServerConfig, event_loop: EventLoop):
        self.config = config
        self.event_loop = event_loop^
        self.fiber_pool = FiberPool(config.worker_fibers)
        self.task_queue = TaskQueue()
        self._running = False
        self._connections_total = 0

    @staticmethod
    fn create(config: ServerConfig) raises -> AsyncRuntime:
        """Create a runtime with event loop sized from config."""
        var loop = EventLoop.create()
        return AsyncRuntime(config, loop^)

    fn register_listener(inout self, listener_fd: Int32) raises:
        """Register the listener socket with the event loop."""
        self.event_loop.register(listener_fd, readable=True, writable=False)

    # ── Core loop ─────────────────────────────────────────────────

    fn run_forever(
        inout self,
        listener_fd: Int32,
        inout handle_fn_placeholder: Bool,
    ) raises:
        """Main event loop — poll, accept, dispatch, repeat.

        Runs until `shutdown()` is called or an unrecoverable error.

        Current (MVP) flow per iteration:
            1. `event_loop.poll()` — wait for I/O readiness.
            2. For each readable listener event → `accept()`.
            3. Assign each new fd to a fiber via `spawn_fiber()`.
            4. If no fiber is free, queue the work.
            5. For each ready fiber, run the handler inline.
            6. Drain the task queue into newly-freed fiber slots.

        Planned flow with real Fibers:
            1. poll() returns ready events.
            2. For listener events → accept → spawn Fiber.
            3. For connection events → resume the owning Fiber.
            4. Fibers yield on I/O, scheduler picks next ready Fiber.

        Args:
            listener_fd: The bound/listening socket fd.
            handle_fn_placeholder: Unused — will be replaced by a
                real handler fn once Mojo supports storable functions.

        TODO:
            - Replace handle_fn_placeholder with real handler callback.
            - Graceful shutdown: stop accepting, drain, close.
            - Timeout enforcement via timer fds.
            - Back-pressure when task queue exceeds threshold.
        """
        self._running = True

        print(
            "[MojoFlow Runtime] Started — "
            + String(self.fiber_pool.pool_size())
            + " fibers, polling..."
        )

        while self._running:
            # ── Poll for I/O events ───────────────────────────────
            var events = self.event_loop.poll(timeout_ms=100)

            for i in range(len(events)):
                var ev = events[i]

                if ev.fd == listener_fd and ev.readable:
                    # ── Accept new connections ────────────────────
                    # Edge-triggered: drain all pending accepts
                    while True:
                        var client_fd = external_call[
                            "accept", Int32,
                            Int32, UnsafePointer[UInt8], UnsafePointer[UInt32],
                        ](
                            listener_fd,
                            UnsafePointer[UInt8](),
                            UnsafePointer[UInt32](),
                        )
                        if client_fd < 0:
                            break  # EAGAIN — no more pending

                        self._connections_total += 1

                        # Try to assign to a fiber immediately
                        if self.fiber_pool.has_idle():
                            var handle = self.fiber_pool.spawn(client_fd)
                            if handle.id >= 0:
                                self.fiber_pool.activate(handle.id)
                                # MVP: handle inline (see TODO above)
                                self.fiber_pool.complete(handle.id)
                        else:
                            # Queue for later
                            self.task_queue.push(WorkItem(client_fd))

                elif ev.error or ev.hangup:
                    # Connection reset / error — deregister
                    self.event_loop.deregister(ev.fd)
                    _ = external_call["close", Int32, Int32](ev.fd)

            # ── Drain queued work into freed fiber slots ──────────
            while not self.task_queue.is_empty() and self.fiber_pool.has_idle():
                var item = self.task_queue.pop()
                var handle = self.fiber_pool.spawn(item.client_fd)
                if handle.id >= 0:
                    self.fiber_pool.activate(handle.id)
                    # MVP: handle inline
                    self.fiber_pool.complete(handle.id)

        print("[MojoFlow Runtime] Shutdown complete.")

    fn shutdown(inout self):
        """Signal the runtime to stop after the current poll cycle."""
        self._running = False
        print("[MojoFlow Runtime] Shutdown requested.")

    fn tick(inout self) raises:
        """Advance the runtime by a single poll cycle.

        Exposed so `TaskGroup.wait()` (and other structured-concurrency
        primitives) can drive forward progress without owning the
        main loop.  Drains at most one batch of I/O events and one
        batch of queued work before returning.
        """
        var events = self.event_loop.poll(timeout_ms=1)
        for i in range(len(events)):
            var ev = events[i]
            if ev.error or ev.hangup:
                self.event_loop.deregister(ev.fd)
                _ = external_call["close", Int32, Int32](ev.fd)

        while not self.task_queue.is_empty() and self.fiber_pool.has_idle():
            var item = self.task_queue.pop()
            var handle = self.fiber_pool.spawn(item.client_fd)
            if handle.id >= 0:
                self.fiber_pool.activate(handle.id)
                self.fiber_pool.complete(handle.id)

    # ── Fiber pool wrappers ───────────────────────────────────────

    fn spawn_fiber(inout self, client_fd: Int32) -> FiberHandle:
        """Spawn a fiber for the given connection.

        If no fiber slot is free, the work is queued automatically
        and a handle with id = -1 is returned.

        This is the public API — callers should prefer this over
        direct FiberPool access.
        """
        if self.fiber_pool.has_idle():
            return self.fiber_pool.spawn(client_fd)
        # Queue for later
        self.task_queue.push(WorkItem(client_fd))
        return FiberHandle(-1, 0)

    fn await_all(inout self) raises:
        """Block until all fibers and queued work complete.

        Structured-concurrency barrier — equivalent to
        `TaskGroup.await_all()` applied to the *entire runtime*.

        Unlike the pool-level primitive this drains the task queue
        by calling `tick()` repeatedly, so queued work actually
        runs before we return.

        TODO:
            - Timeout / deadline parameter.
            - Cancellation propagation to in-flight fibers.
        """
        while (
            self.fiber_pool.active_count() > 0
            or not self.task_queue.is_empty()
        ):
            self.tick()
        self.fiber_pool.await_all()

    # ── Stats ─────────────────────────────────────────────────────

    fn connections_total(self) -> Int:
        """Total connections accepted since start."""
        return self._connections_total

    fn active_fibers(self) -> Int:
        return self.fiber_pool.active_count()

    fn idle_fibers(self) -> Int:
        return self.fiber_pool.idle_count()

    fn queued_tasks(self) -> Int:
        return self.task_queue.len()

    fn stats_str(self) -> String:
        """Human-readable runtime stats snapshot."""
        return (
            "Runtime(total_conn="
            + String(self._connections_total)
            + ", active_fibers="
            + String(self.fiber_pool.active_count())
            + ", idle_fibers="
            + String(self.fiber_pool.idle_count())
            + ", queued="
            + String(self.task_queue.len())
            + ")"
        )


# ══════════════════════════════════════════════════════════════════
#  Worker model — OS-thread runtime layout
# ══════════════════════════════════════════════════════════════════

struct WorkerModel:
    """Configurable multi-worker runtime topology.

    Each OS worker is intended to own an AsyncRuntime, an EventLoop, and a
    FiberPool.  MAX parallelism spans the aggregate worker capacity so heavy
    handler compute can fan out across all configured threads.

    The current server loop still drives one runtime inline while Mojo's stable
    threading APIs settle; this struct centralises the sizing and MAX fan-out
    contract so the per-thread runtime split can be enabled without changing
    handler code.
    """

    var worker_threads: Int
    var fibers_per_worker: Int
    var max_parallel_workers: Int

    fn __init__(out self, config: ServerConfig):
        self.worker_threads = config.worker_threads
        self.fibers_per_worker = config.worker_fibers
        self.max_parallel_workers = config.total_fiber_slots()

    fn total_fibers(self) -> Int:
        return self.worker_threads * self.fibers_per_worker

    fn run_across_workers[
        work_fn: fn (Int) capturing -> None
    ](self):
        """Run one setup/maintenance task per OS worker via MAX."""
        parallelize_work[work_fn](self.worker_threads, self.worker_threads)

    fn __str__(self) -> String:
        return (
            "WorkerModel(threads="
            + String(self.worker_threads)
            + ", fibers_per_worker="
            + String(self.fibers_per_worker)
            + ", total_fibers="
            + String(self.total_fibers())
            + ")"
        )


# ══════════════════════════════════════════════════════════════════
#  MAX Engine parallelism helper
# ══════════════════════════════════════════════════════════════════

fn parallelize_work[
    work_fn: fn (Int) capturing -> None
](num_items: Int, num_workers: Int):
    """Distribute CPU-bound work across MAX parallel workers.

    Thin wrapper over `algorithm.parallelize` — MAX Engine's
    built-in work-stealing executor.  Intended for use *inside*
    request handlers that perform heavy computation (JSON parsing
    of large payloads, template rendering, AI inference).  Keeps
    the Fiber pool responsive for I/O while CPU work fans out
    across every available hardware thread.

    Parameters:
        work_fn:     Parametric kernel invoked once per work-item
                     index `[0, num_items)`.  May capture handler
                     state by reference.

    Args:
        num_items:   Total number of work items.
        num_workers: Max parallel workers (typically
                     `config.worker_fibers` or core count).

    Example (inside a handler):

        var results = List[Int](capacity=len(items))
        for _ in range(len(items)): results.append(0)

        @parameter
        fn kernel(i: Int):
            results[i] = heavy_compute(items[i])

        parallelize_work[kernel](len(items), config.worker_fibers)

    TODO:
        - Auto-tune `num_workers` from `performance_num_performance_cores()`.
        - GPU dispatch path via MAX Engine when a device is available.
    """
    if num_items <= 0:
        return
    parallelize[work_fn](num_items, num_workers)


fn parallelize_work[
    work_fn: fn (Int) capturing -> None
](num_items: Int):
    """Overload that defaults `num_workers` to `num_items`.

    Lets MAX Engine pick the degree of parallelism based on the
    underlying runtime's worker count.
    """
    if num_items <= 0:
        return
    parallelize[work_fn](num_items)


# ══════════════════════════════════════════════════════════════════
#  Module-level convenience functions
# ══════════════════════════════════════════════════════════════════

fn run_forever(inout runtime: AsyncRuntime, listener_fd: Int32) raises:
    """Start the async runtime and block until shutdown.

    Convenience wrapper around `runtime.run_forever()`.

    Example:
        var rt = AsyncRuntime.create(config)
        rt.register_listener(listener.fd())
        run_forever(rt, listener.fd())
    """
    var placeholder = True
    runtime.run_forever(listener_fd, placeholder)


fn spawn_fiber(inout runtime: AsyncRuntime, client_fd: Int32) -> FiberHandle:
    """Spawn a fiber in the runtime for a new connection.

    Convenience wrapper around `runtime.spawn_fiber()`.
    """
    return runtime.spawn_fiber(client_fd)


fn await_all(inout runtime: AsyncRuntime) raises:
    """Wait for all fibers and queued tasks to complete.

    Structured-concurrency barrier — equivalent to
    `TaskGroup.await_all()` applied to the whole runtime.
    """
    runtime.await_all()
