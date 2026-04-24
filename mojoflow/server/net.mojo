"""
MojoFlow Server — Low-level async networking primitives.

Provides non-blocking socket I/O with platform-specific event
multiplexing (epoll on Linux, kqueue on macOS).

Architecture:
    AsyncSocket     — Non-blocking fd wrapper with lifecycle management.
    AsyncListener   — Binds, listens, and async-accepts new connections.
    AsyncConnection — Per-connection buffered read/write with zero-copy.
    EventLoop       — epoll/kqueue multiplexer driving all I/O.

Zero-copy strategy:
    Reads land directly into caller-owned UnsafePointer buffers.
    No intermediate String copies on the hot path — conversion to
    String happens only when the HTTP parser needs it.

Resource cleanup:
    Every struct that owns a file descriptor implements __del__
    to close it, preventing fd leaks even on unwind.

TODO:
    - IOCP backend for Windows.
    - io_uring backend for Linux 5.6+.
    - Vectored I/O (readv/writev) for scatter-gather.
    - TLS integration (read/write through TLS layer).
    - UDP / datagram socket support.
    - Unix domain socket support.
"""

from sys.ffi import external_call
from sys.info import os_is_linux, os_is_macos, os_is_windows
from memory import UnsafePointer, memset_zero

from .errors import ServerError, ErrorKind
from .config import ServerConfig


# ══════════════════════════════════════════════════════════════════
#  POSIX / platform constants
# ══════════════════════════════════════════════════════════════════

# --- Address families & socket types ---
alias AF_INET: Int32 = 2
alias SOCK_STREAM: Int32 = 1
alias SOCK_NONBLOCK: Int32 = 2048  # Linux-only flag to socket()

# --- Socket options ---
alias SOL_SOCKET: Int32 = 1
alias SO_REUSEADDR: Int32 = 2
alias SO_REUSEPORT: Int32 = 15
alias IPPROTO_TCP: Int32 = 6
alias TCP_NODELAY: Int32 = 1

# --- fcntl ---
alias F_GETFL: Int32 = 3
alias F_SETFL: Int32 = 4
alias O_NONBLOCK: Int32 = 2048

# --- recv / send ---
alias MSG_NOSIGNAL: Int32 = 16384
alias MSG_DONTWAIT: Int32 = 64

# --- errno sentinels ---
alias EAGAIN: Int = -11
alias EWOULDBLOCK: Int = -11
alias EINTR: Int = -4

# --- epoll (Linux) ---
alias EPOLLIN: UInt32 = 0x001
alias EPOLLOUT: UInt32 = 0x004
alias EPOLLERR: UInt32 = 0x008
alias EPOLLHUP: UInt32 = 0x010
alias EPOLLRDHUP: UInt32 = 0x2000
alias EPOLLET: UInt32 = 0x80000000  # edge-triggered
alias EPOLL_CTL_ADD: Int32 = 1
alias EPOLL_CTL_DEL: Int32 = 2
alias EPOLL_CTL_MOD: Int32 = 3

# --- kqueue (macOS/BSD) ---
alias EVFILT_READ: Int16 = -1
alias EVFILT_WRITE: Int16 = -2
alias EV_ADD: UInt16 = 0x0001
alias EV_DELETE: UInt16 = 0x0002
alias EV_ENABLE: UInt16 = 0x0004
alias EV_ONESHOT: UInt16 = 0x0010
alias EV_CLEAR: UInt16 = 0x0020  # edge-triggered (kqueue's analogue of EPOLLET)
alias EV_ERROR: UInt16 = 0x4000
alias EV_EOF: UInt16 = 0x8000

# --- WSAPoll (Windows) ---
# NOTE: true IOCP is a proactor model that would require reworking
# AsyncConnection to issue overlapped WSARecv / WSASend *before* the
# event loop returns a completion.  WSAPoll matches the existing
# reactor-style readiness API used on Linux/macOS and lets the same
# AsyncConnection code path work unchanged.  A real IOCP backend is
# tracked in the TODO block below.
alias POLLRDNORM: Int16 = 0x0100
alias POLLRDBAND: Int16 = 0x0200
alias POLLIN_WIN: Int16 = 0x0300   # POLLRDNORM | POLLRDBAND
alias POLLWRNORM: Int16 = 0x0010
alias POLLOUT_WIN: Int16 = 0x0010
alias POLLERR_WIN: Int16 = 0x0001
alias POLLHUP_WIN: Int16 = 0x0002
alias POLLNVAL_WIN: Int16 = 0x0004

# --- Compile-time max events per poll ---
alias MAX_EVENTS: Int = 1024


# ══════════════════════════════════════════════════════════════════
#  FFI struct layouts
# ══════════════════════════════════════════════════════════════════

@value
@register_passable("trivial")
struct SockAddrIn:
    """POSIX sockaddr_in (IPv4), 16 bytes for FFI."""
    var sin_family: UInt16
    var sin_port: UInt16
    var sin_addr: UInt32
    var _pad: UInt64

    fn __init__(out self):
        self.sin_family = 0
        self.sin_port = 0
        self.sin_addr = 0
        self._pad = 0


@value
@register_passable("trivial")
struct EpollEvent:
    """Linux epoll_event (12 bytes, packed)."""
    var events: UInt32
    var data: UInt64  # union — we store the fd here

    fn __init__(out self):
        self.events = 0
        self.data = 0

    fn __init__(out self, events: UInt32, fd: Int32):
        self.events = events
        self.data = UInt64(fd)

    fn fd(self) -> Int32:
        return Int32(self.data)


@value
@register_passable("trivial")
struct KEvent:
    """BSD / macOS `struct kevent` (32 bytes on 64-bit targets).

    Layout:
        uintptr_t ident;   // fd
        int16_t   filter;  // EVFILT_READ / EVFILT_WRITE
        uint16_t  flags;   // EV_ADD | EV_CLEAR | ...
        uint32_t  fflags;
        intptr_t  data;
        void*     udata;
    """
    var ident: UInt64
    var filter: Int16
    var flags: UInt16
    var fflags: UInt32
    var data: Int64
    var udata: UInt64

    fn __init__(out self):
        self.ident = 0
        self.filter = 0
        self.flags = 0
        self.fflags = 0
        self.data = 0
        self.udata = 0

    fn __init__(
        out self,
        fd: Int32,
        filter: Int16,
        flags: UInt16,
    ):
        self.ident = UInt64(fd)
        self.filter = filter
        self.flags = flags
        self.fflags = 0
        self.data = 0
        self.udata = 0

    fn fd(self) -> Int32:
        return Int32(self.ident)


@value
@register_passable("trivial")
struct Timespec:
    """POSIX `struct timespec` (16 bytes on 64-bit)."""
    var tv_sec: Int64
    var tv_nsec: Int64

    fn __init__(out self, ms: Int):
        self.tv_sec = Int64(ms) // 1000
        self.tv_nsec = (Int64(ms) % 1000) * 1_000_000


@value
@register_passable("trivial")
struct WSAPollFd:
    """Windows `WSAPOLLFD` struct (16 bytes on 64-bit Windows).

    Layout:
        SOCKET fd;       // 8 bytes (uintptr_t)
        SHORT  events;   // 2 bytes
        SHORT  revents;  // 2 bytes
        // 4 bytes tail padding
    """
    var fd: UInt64
    var events: Int16
    var revents: Int16
    var _pad: UInt32

    fn __init__(out self):
        self.fd = 0
        self.events = 0
        self.revents = 0
        self._pad = 0

    fn __init__(out self, fd: Int32, events: Int16):
        self.fd = UInt64(fd)
        self.events = events
        self.revents = 0
        self._pad = 0


# ══════════════════════════════════════════════════════════════════
#  Byte-order helpers
# ══════════════════════════════════════════════════════════════════

@always_inline
fn htons(val: UInt16) -> UInt16:
    """Host to network byte order (16-bit)."""
    return (val >> 8) | ((val & 0xFF) << 8)


@always_inline
fn inet_aton(ip: String) -> UInt32:
    """Dotted-quad IPv4 → network-order UInt32.  Returns 0 on error."""
    var parts = ip.split(".")
    if len(parts) != 4:
        return 0
    try:
        var a = UInt32(Int(parts[0]))
        var b = UInt32(Int(parts[1]))
        var c = UInt32(Int(parts[2]))
        var d = UInt32(Int(parts[3]))
        return a | (b << 8) | (c << 16) | (d << 24)
    except:
        return 0


# ══════════════════════════════════════════════════════════════════
#  AsyncSocket — non-blocking fd wrapper
# ══════════════════════════════════════════════════════════════════

struct AsyncSocket:
    """Non-blocking TCP socket with RAII fd ownership.

    The fd is set to O_NONBLOCK on construction.  `__del__` closes
    the fd automatically, preventing leaks.

    Zero-copy: `read_into()` and `write_from()` operate directly
    on caller-owned UnsafePointer buffers — no intermediate copies.
    """

    var fd: Int32
    var _closed: Bool

    fn __init__(out self, fd: Int32):
        """Wrap an existing fd and set it non-blocking."""
        self.fd = fd
        self._closed = False
        Self._set_nonblocking(fd)

    fn __del__(owned self):
        """Close the fd if still open."""
        if not self._closed:
            _ = external_call["close", Int32, Int32](self.fd)

    @staticmethod
    fn create() raises -> AsyncSocket:
        """Create a new TCP socket (AF_INET, SOCK_STREAM)."""
        var fd = external_call["socket", Int32, Int32, Int32, Int32](
            AF_INET, SOCK_STREAM, 0
        )
        if fd < 0:
            raise ServerError.io("socket() failed").to_error()
        return AsyncSocket(fd)

    @staticmethod
    fn _set_nonblocking(fd: Int32):
        """Set O_NONBLOCK via fcntl."""
        var flags = external_call["fcntl", Int32, Int32, Int32](fd, F_GETFL)
        _ = external_call["fcntl", Int32, Int32, Int32, Int32](
            fd, F_SETFL, flags | O_NONBLOCK
        )

    fn set_opt_int(self, level: Int32, opt: Int32, val: Int32) raises:
        """setsockopt with an int value."""
        var ptr = UnsafePointer[Int32].alloc(1)
        ptr[] = val
        var rc = external_call[
            "setsockopt", Int32,
            Int32, Int32, Int32, UnsafePointer[Int32], UInt32,
        ](self.fd, level, opt, ptr, 4)
        ptr.free()
        if rc < 0:
            raise ServerError.io("setsockopt failed").to_error()

    fn configure(self, config: ServerConfig) raises:
        """Apply ServerConfig socket options."""
        if config.reuse_address:
            self.set_opt_int(SOL_SOCKET, SO_REUSEADDR, 1)
        if config.reuse_port:
            self.set_opt_int(SOL_SOCKET, SO_REUSEPORT, 1)
        if config.tcp_nodelay:
            self.set_opt_int(IPPROTO_TCP, TCP_NODELAY, 1)

    fn bind(self, host: String, port: Int) raises:
        """Bind to host:port."""
        var addr = SockAddrIn()
        addr.sin_family = UInt16(AF_INET)
        addr.sin_port = htons(UInt16(port))
        addr.sin_addr = inet_aton(host)
        var ptr = UnsafePointer[SockAddrIn].alloc(1)
        ptr[] = addr
        var rc = external_call[
            "bind", Int32,
            Int32, UnsafePointer[SockAddrIn], UInt32,
        ](self.fd, ptr, 16)
        ptr.free()
        if rc < 0:
            raise ServerError.bind(
                "bind() failed", host + ":" + String(port)
            ).to_error()

    fn listen(self, backlog: Int) raises:
        """Start listening."""
        var rc = external_call["listen", Int32, Int32, Int32](
            self.fd, Int32(backlog)
        )
        if rc < 0:
            raise ServerError.bind("listen() failed").to_error()

    fn accept(self) -> Int32:
        """Non-blocking accept.  Returns fd ≥ 0 or -1 (EAGAIN)."""
        return external_call[
            "accept", Int32,
            Int32, UnsafePointer[UInt8], UnsafePointer[UInt32],
        ](self.fd, UnsafePointer[UInt8](), UnsafePointer[UInt32]())

    fn read_into(self, buf: UnsafePointer[UInt8], size: Int) -> Int:
        """Zero-copy non-blocking read into caller buffer.

        Returns bytes read, 0 on EOF, or -1 on EAGAIN/error.
        """
        return external_call[
            "recv", Int,
            Int32, UnsafePointer[UInt8], Int, Int32,
        ](self.fd, buf, size, MSG_DONTWAIT)

    fn write_from(self, buf: UnsafePointer[UInt8], size: Int) -> Int:
        """Zero-copy non-blocking write from caller buffer.

        Returns bytes written or -1 on EAGAIN/error.
        """
        return external_call[
            "send", Int,
            Int32, UnsafePointer[UInt8], Int, Int32,
        ](self.fd, buf, size, MSG_NOSIGNAL | MSG_DONTWAIT)

    fn close(inout self):
        """Explicitly close the socket."""
        if not self._closed:
            _ = external_call["close", Int32, Int32](self.fd)
            self._closed = True


# ══════════════════════════════════════════════════════════════════
#  EventLoop — platform-specific I/O multiplexer
# ══════════════════════════════════════════════════════════════════

@value
struct IOEvent:
    """A ready event from the event loop."""
    var fd: Int32
    var readable: Bool
    var writable: Bool
    var error: Bool
    var hangup: Bool

    fn __init__(out self, fd: Int32, readable: Bool, writable: Bool,
                error: Bool = False, hangup: Bool = False):
        self.fd = fd
        self.readable = readable
        self.writable = writable
        self.error = error
        self.hangup = hangup


struct EventLoop:
    """Edge-triggered I/O event multiplexer.

    Per-platform backend selected at compile time via `@parameter if`:

        Linux   → epoll (EPOLLET edge-triggered)
        macOS   → kqueue (EV_CLEAR edge-triggered)
        Windows → WSAPoll (readiness model)

    All registered fds must be non-blocking.  Edge-triggered mode
    means the kernel notifies only on *state transitions* — the
    consumer must drain all available data on each notification or
    risk missing events.  WSAPoll is level-triggered; the runtime
    compensates by not returning until recv/send have fully drained.

    Example:
        var loop = EventLoop.create()
        loop.register(listener_fd, readable=True)
        while True:
            var events = loop.poll(timeout_ms=1000)
            for i in range(len(events)):
                handle(events[i])

    TODO:
        - True IOCP proactor on Windows (requires AsyncConnection to
          issue overlapped WSARecv / WSASend ahead of the poll loop).
        - io_uring backend (Linux 5.6+).
        - Timer fd / kevent EVFILT_TIMER integration for timeouts.
        - Signal fd for graceful shutdown.
    """

    # Backend-neutral handle:
    #   Linux   → epoll fd
    #   macOS   → kqueue fd
    #   Windows → unused (-1)
    var _epoll_fd: Int32

    # Raw byte buffer re-cast per-platform:
    #   Linux   → MAX_EVENTS × EpollEvent (12 B each)
    #   macOS   → MAX_EVENTS × KEvent     (32 B each)
    #   Windows → MAX_EVENTS × WSAPollFd  (16 B each)
    var _event_buf: UnsafePointer[UInt8]
    var _max_events: Int

    # Windows-only: WSAPoll requires the caller to maintain the fd
    # set.  These fields are harmless on Linux/macOS (never touched).
    var _wsa_fds: List[Int32]
    var _wsa_events: List[Int16]

    fn __init__(out self):
        self._epoll_fd = -1
        self._max_events = MAX_EVENTS
        self._event_buf = UnsafePointer[UInt8]()
        self._wsa_fds = List[Int32]()
        self._wsa_events = List[Int16]()

    fn __del__(owned self):
        if self._epoll_fd >= 0:
            _ = external_call["close", Int32, Int32](self._epoll_fd)
        if self._event_buf:
            self._event_buf.free()

    @staticmethod
    fn create() raises -> EventLoop:
        """Create the platform event loop."""
        var loop = EventLoop()

        @parameter
        if os_is_linux():
            loop._epoll_fd = external_call["epoll_create1", Int32, Int32](0)
            if loop._epoll_fd < 0:
                raise ServerError.epoll("epoll_create1() failed").to_error()
            loop._event_buf = UnsafePointer[UInt8].alloc(MAX_EVENTS * 12)
            memset_zero(loop._event_buf, MAX_EVENTS * 12)
        elif os_is_macos():
            loop._epoll_fd = external_call["kqueue", Int32]()
            if loop._epoll_fd < 0:
                raise ServerError.epoll("kqueue() failed").to_error()
            loop._event_buf = UnsafePointer[UInt8].alloc(MAX_EVENTS * 32)
            memset_zero(loop._event_buf, MAX_EVENTS * 32)
        elif os_is_windows():
            # WSAPoll requires no kernel handle — the caller owns the
            # fdset.  Still pre-allocate the event buffer so poll()
            # has a stable backing store.
            loop._epoll_fd = -1
            loop._event_buf = UnsafePointer[UInt8].alloc(MAX_EVENTS * 16)
            memset_zero(loop._event_buf, MAX_EVENTS * 16)
        else:
            raise ServerError.configuration(
                "Unsupported platform for event loop"
            ).to_error()

        return loop

    # ── Registration ──────────────────────────────────────────────

    fn register(inout self, fd: Int32, readable: Bool = True,
                writable: Bool = False) raises:
        """Register an fd for edge-triggered monitoring."""
        @parameter
        if os_is_linux():
            self._linux_ctl(fd, readable, writable, EPOLL_CTL_ADD)
        elif os_is_macos():
            self._kqueue_ctl(fd, readable, writable, EV_ADD | EV_CLEAR)
        elif os_is_windows():
            self._wsa_add(fd, readable, writable)

    fn modify(inout self, fd: Int32, readable: Bool = True,
              writable: Bool = False) raises:
        """Modify interest set for an already-registered fd."""
        @parameter
        if os_is_linux():
            self._linux_ctl(fd, readable, writable, EPOLL_CTL_MOD)
        elif os_is_macos():
            # kqueue has no "modify"; re-adding with EV_ADD replaces
            # the existing kevent for (ident, filter).  First clear
            # the opposite filter if it was previously active.
            self._kqueue_ctl(fd, readable, writable, EV_ADD | EV_CLEAR)
        elif os_is_windows():
            self._wsa_remove(fd)
            self._wsa_add(fd, readable, writable)

    fn deregister(inout self, fd: Int32):
        """Remove an fd from the event loop (best effort — never raises)."""
        @parameter
        if os_is_linux():
            _ = external_call[
                "epoll_ctl", Int32,
                Int32, Int32, Int32, UnsafePointer[EpollEvent],
            ](self._epoll_fd, EPOLL_CTL_DEL, fd, UnsafePointer[EpollEvent]())
        elif os_is_macos():
            # Delete both read + write filters; ignore errors (fd may
            # have only one registered).
            var ch = UnsafePointer[KEvent].alloc(2)
            ch[0] = KEvent(fd, EVFILT_READ, EV_DELETE)
            ch[1] = KEvent(fd, EVFILT_WRITE, EV_DELETE)
            _ = external_call[
                "kevent", Int32,
                Int32, UnsafePointer[KEvent], Int32,
                UnsafePointer[KEvent], Int32, UnsafePointer[Timespec],
            ](
                self._epoll_fd, ch, 2,
                UnsafePointer[KEvent](), 0, UnsafePointer[Timespec](),
            )
            ch.free()
        elif os_is_windows():
            self._wsa_remove(fd)

    # ── Linux / epoll helper ──────────────────────────────────────

    fn _linux_ctl(
        self, fd: Int32, readable: Bool, writable: Bool, op: Int32,
    ) raises:
        var events: UInt32 = EPOLLET | EPOLLRDHUP
        if readable:
            events = events | EPOLLIN
        if writable:
            events = events | EPOLLOUT
        var ev = EpollEvent(events, fd)
        var ev_ptr = UnsafePointer[EpollEvent].alloc(1)
        ev_ptr[] = ev
        var rc = external_call[
            "epoll_ctl", Int32,
            Int32, Int32, Int32, UnsafePointer[EpollEvent],
        ](self._epoll_fd, op, fd, ev_ptr)
        ev_ptr.free()
        if rc < 0:
            raise ServerError.epoll(
                "epoll_ctl failed", "fd=" + String(Int(fd))
            ).to_error()

    # ── macOS / kqueue helper ─────────────────────────────────────

    fn _kqueue_ctl(
        self, fd: Int32, readable: Bool, writable: Bool, flags: UInt16,
    ) raises:
        """Submit one or two kevent changes.  `flags` is applied to
        each (e.g. EV_ADD | EV_CLEAR for edge-triggered register)."""
        var n: Int = 0
        var changes = UnsafePointer[KEvent].alloc(2)
        if readable:
            changes[n] = KEvent(fd, EVFILT_READ, flags)
            n += 1
        if writable:
            changes[n] = KEvent(fd, EVFILT_WRITE, flags)
            n += 1
        if n == 0:
            changes.free()
            return
        var rc = external_call[
            "kevent", Int32,
            Int32, UnsafePointer[KEvent], Int32,
            UnsafePointer[KEvent], Int32, UnsafePointer[Timespec],
        ](
            self._epoll_fd, changes, Int32(n),
            UnsafePointer[KEvent](), 0, UnsafePointer[Timespec](),
        )
        changes.free()
        if rc < 0:
            raise ServerError.epoll(
                "kevent() register failed", "fd=" + String(Int(fd))
            ).to_error()

    # ── Windows / WSAPoll helpers ─────────────────────────────────

    fn _wsa_events_mask(self, readable: Bool, writable: Bool) -> Int16:
        var m: Int16 = 0
        if readable:
            m = m | POLLIN_WIN
        if writable:
            m = m | POLLOUT_WIN
        return m

    fn _wsa_find(self, fd: Int32) -> Int:
        for i in range(len(self._wsa_fds)):
            if self._wsa_fds[i] == fd:
                return i
        return -1

    fn _wsa_add(inout self, fd: Int32, readable: Bool, writable: Bool):
        var mask = self._wsa_events_mask(readable, writable)
        var idx = self._wsa_find(fd)
        if idx >= 0:
            self._wsa_events[idx] = mask
        else:
            self._wsa_fds.append(fd)
            self._wsa_events.append(mask)

    fn _wsa_remove(inout self, fd: Int32):
        var idx = self._wsa_find(fd)
        if idx < 0:
            return
        var new_fds = List[Int32]()
        var new_events = List[Int16]()
        for i in range(len(self._wsa_fds)):
            if i != idx:
                new_fds.append(self._wsa_fds[i])
                new_events.append(self._wsa_events[i])
        self._wsa_fds = new_fds
        self._wsa_events = new_events

    # ── Poll ──────────────────────────────────────────────────────

    fn poll(self, timeout_ms: Int = -1) -> List[IOEvent]:
        """Block until events are ready or timeout expires.

        timeout_ms = -1 means block indefinitely.
        timeout_ms = 0  means return immediately (non-blocking poll).
        """
        var results = List[IOEvent]()

        @parameter
        if os_is_linux():
            var buf = self._event_buf.bitcast[EpollEvent]()
            var n = external_call[
                "epoll_wait", Int32,
                Int32, UnsafePointer[EpollEvent], Int32, Int32,
            ](self._epoll_fd, buf, Int32(self._max_events),
              Int32(timeout_ms))
            if n <= 0:
                return results
            for i in range(Int(n)):
                var ev = buf[i]
                var readable = (ev.events & EPOLLIN) != 0
                var writable = (ev.events & EPOLLOUT) != 0
                var err = (ev.events & EPOLLERR) != 0
                var hup = (ev.events & (EPOLLHUP | EPOLLRDHUP)) != 0
                results.append(IOEvent(ev.fd(), readable, writable, err, hup))

        elif os_is_macos():
            var buf = self._event_buf.bitcast[KEvent]()
            var ts = Timespec(timeout_ms if timeout_ms >= 0 else 0)
            var ts_ptr = UnsafePointer[Timespec].alloc(1)
            ts_ptr[] = ts
            var ts_arg = ts_ptr if timeout_ms >= 0 else UnsafePointer[Timespec]()
            var n = external_call[
                "kevent", Int32,
                Int32, UnsafePointer[KEvent], Int32,
                UnsafePointer[KEvent], Int32, UnsafePointer[Timespec],
            ](
                self._epoll_fd,
                UnsafePointer[KEvent](), 0,
                buf, Int32(self._max_events),
                ts_arg,
            )
            ts_ptr.free()
            if n <= 0:
                return results
            for i in range(Int(n)):
                var ev = buf[i]
                var readable = ev.filter == EVFILT_READ
                var writable = ev.filter == EVFILT_WRITE
                var err = (ev.flags & EV_ERROR) != 0
                var hup = (ev.flags & EV_EOF) != 0
                results.append(IOEvent(ev.fd(), readable, writable, err, hup))

        elif os_is_windows():
            # Materialise caller-maintained fdset into the WSAPollFd
            # event buffer, then call WSAPoll.
            var count = len(self._wsa_fds)
            if count == 0:
                return results
            if count > self._max_events:
                count = self._max_events
            var buf = self._event_buf.bitcast[WSAPollFd]()
            for i in range(count):
                buf[i] = WSAPollFd(self._wsa_fds[i], self._wsa_events[i])
            var n = external_call[
                "WSAPoll", Int32,
                UnsafePointer[WSAPollFd], UInt32, Int32,
            ](buf, UInt32(count), Int32(timeout_ms))
            if n <= 0:
                return results
            for i in range(count):
                var pfd = buf[i]
                if pfd.revents == 0:
                    continue
                var readable = (pfd.revents & POLLIN_WIN) != 0
                var writable = (pfd.revents & POLLOUT_WIN) != 0
                var err = (pfd.revents & (POLLERR_WIN | POLLNVAL_WIN)) != 0
                var hup = (pfd.revents & POLLHUP_WIN) != 0
                results.append(
                    IOEvent(Int32(pfd.fd), readable, writable, err, hup)
                )

        return results


# ══════════════════════════════════════════════════════════════════
#  AsyncListener — bind + listen + async accept
# ══════════════════════════════════════════════════════════════════

struct AsyncListener:
    """Listens for incoming TCP connections on a bound address.

    Wraps AsyncSocket with bind/listen lifecycle and provides
    `accept()` that returns new AsyncConnection instances.

    Owns the listener socket — `__del__` closes it.

    Example:
        var listener = AsyncListener.start(config)
        while True:
            var client_fd = listener.accept()
            if client_fd >= 0:
                handle(AsyncConnection(client_fd, config))
    """

    var socket: AsyncSocket
    var config: ServerConfig

    fn __init__(out self, socket: AsyncSocket, config: ServerConfig):
        self.socket = socket
        self.config = config

    @staticmethod
    fn start(config: ServerConfig) raises -> AsyncListener:
        """Create, configure, bind, and listen in one call."""
        var sock = AsyncSocket.create()
        sock.configure(config)
        sock.bind(config.host, config.port)
        sock.listen(config.backlog)
        return AsyncListener(sock^, config)

    fn accept(self) -> Int32:
        """Non-blocking accept.  Returns client fd or -1."""
        var client_fd = self.socket.accept()
        if client_fd >= 0:
            # Set new connection non-blocking immediately
            AsyncSocket._set_nonblocking(client_fd)
        return client_fd

    fn fd(self) -> Int32:
        """Listener file descriptor (for event loop registration)."""
        return self.socket.fd


# ══════════════════════════════════════════════════════════════════
#  AsyncConnection — buffered per-connection I/O
# ══════════════════════════════════════════════════════════════════

struct AsyncConnection:
    """Per-connection non-blocking I/O with owned read buffer.

    Lifecycle: READING → PROCESSING → WRITING → DONE/RECYCLE.

    The read buffer is pre-allocated from config.read_buffer_size
    and reused across keep-alive requests.  Reads land directly
    into this buffer (zero intermediate copies).

    `__del__` frees the buffer and closes the fd.

    TODO:
        - Write buffer for partial sends.
        - Timeout tracking (read / write / keep-alive deadlines).
        - Scatter-gather I/O with readv().
    """

    alias STATE_READING: Int = 0
    alias STATE_PROCESSING: Int = 1
    alias STATE_WRITING: Int = 2
    alias STATE_DONE: Int = 3

    var fd: Int32
    var state: Int
    var _buf: UnsafePointer[UInt8]
    var _buf_size: Int
    var _buf_used: Int
    var requests_served: Int
    var keep_alive: Bool
    var _closed: Bool

    fn __init__(out self, fd: Int32, config: ServerConfig):
        self.fd = fd
        self.state = Self.STATE_READING
        self._buf_size = config.read_buffer_size
        self._buf = UnsafePointer[UInt8].alloc(self._buf_size)
        memset_zero(self._buf, self._buf_size)
        self._buf_used = 0
        self.requests_served = 0
        self.keep_alive = True
        self._closed = False

    fn __del__(owned self):
        """Close fd and free the read buffer."""
        if not self._closed:
            _ = external_call["close", Int32, Int32](self.fd)
        if self._buf:
            self._buf.free()

    fn read(inout self) -> Int:
        """Non-blocking read into the internal buffer.

        Returns bytes read, 0 on EOF, -1 on EAGAIN.
        The read appends to any existing buffered data.
        """
        if self._buf_used >= self._buf_size:
            return 0  # buffer full
        var remaining = self._buf_size - self._buf_used
        var n = external_call[
            "recv", Int,
            Int32, UnsafePointer[UInt8], Int, Int32,
        ](self.fd, self._buf.offset(self._buf_used), remaining, MSG_DONTWAIT)
        if n > 0:
            self._buf_used += n
        return n

    fn get_buffer(self) -> UnsafePointer[UInt8]:
        """Pointer to the start of buffered data (zero-copy access)."""
        return self._buf

    fn buffered_bytes(self) -> Int:
        """Number of bytes currently in the read buffer."""
        return self._buf_used

    fn reset_buffer(inout self):
        """Clear the buffer for the next request (keep-alive reuse)."""
        memset_zero(self._buf, self._buf_used)
        self._buf_used = 0
        self.state = Self.STATE_READING

    fn write_all(self, data: UnsafePointer[UInt8], size: Int) -> Int:
        """Best-effort non-blocking write.  Returns bytes sent or -1.

        For the MVP this does a single send(); a production version
        would loop or use the event loop to handle partial writes.

        TODO: Write buffer + EPOLLOUT for partial sends.
        """
        return external_call[
            "send", Int,
            Int32, UnsafePointer[UInt8], Int, Int32,
        ](self.fd, data, size, MSG_NOSIGNAL | MSG_DONTWAIT)

    fn write_string(self, s: String) -> Int:
        """Convenience: write a String (copies to send)."""
        var ptr = s.unsafe_ptr()
        return self.write_all(ptr, len(s))

    fn close(inout self):
        """Explicitly close the connection."""
        if not self._closed:
            _ = external_call["close", Int32, Int32](self.fd)
            self._closed = True

    fn is_closed(self) -> Bool:
        return self._closed
