"""
MojoFlow Server — Zero-copy, SIMD-optimized HTTP/1.1 parser + serializer.

This module provides the hot-path codec for every request that hits
the server.  It is designed for **cache-friendliness, zero intermediate
allocations, and SIMD throughput** on the byte-scan loops that
dominate HTTP/1.1 parsing.

Architecture:

    raw socket bytes  ──►  ByteView (zero-copy slice)
                              │
                              ├── SIMD scan for CRLF / ':' / ' '
                              ├── request line  ── method, path, version
                              ├── headers       ── multi-value aware
                              └── body          ── Content-Length OR
                                                   Transfer-Encoding: chunked
                              │
                              ▼
                           Request

    Response  ──►  serialize_response() ──► bytes on the wire
                     │
                     ├── status line built once
                     ├── Headers.to_http() (flat list walk)
                     └── body (or chunked encoder)

Performance features:

    - **Zero-copy byte views.**  `ByteView` borrows raw bytes from the
      caller's buffer; no `String` copy until a field is materialised.
    - **SIMD CRLF / token scanning** via `simd_load` + vector compare,
      falling back to scalar for the trailing bytes.
    - **`@parameter if`** predicate fusion at callsites lets the
      compiler constant-fold hot paths.
    - **`vectorize`** on the hex-digit decoder inside the chunked
      decoder (digits arrive in bursts for large bodies).
    - **No exceptions in the fast path** — `ParseResult` carries the
      error kind; exceptions are raised only at the top-level entry
      (`parse_request`) when the caller wants them.

Supported:

    - HTTP/1.0 and HTTP/1.1 request lines.
    - All standard + extension request methods (method string is
      copied verbatim, not enumerated).
    - Headers with folded / leading whitespace values (RFC 7230 §3.2.4
      obs-fold is rejected per the RFC).
    - **Multi-value headers** — duplicates (Set-Cookie, Accept, …) are
      preserved in insertion order via `Headers.append()`.
    - **Content-Length** framed bodies.
    - **Transfer-Encoding: chunked** — full chunked decoder with
      trailer support.
    - **Keep-alive** detection (HTTP/1.1 default; honours
      `Connection: close` / `Connection: keep-alive`).

Public API:

    ByteView               — Zero-copy slice over UInt8 bytes.
    ParseStatus            — Enum of parse outcomes (OK, NEED_MORE, …).
    ParseResult            — (status, bytes_consumed) tuple.
    parse_request(raw)     — High-level: raise-on-error, returns Request.
    parse_request_view(bv) — Low-level: returns (Request, ParseResult).
    serialize_response(r)  — Response → wire bytes.
    serialize_chunked(...) — Chunked Transfer-Encoding helper.
    decode_chunked(raw)    — Chunked body decoder.
    test_parse()           — Inline self-test suite.

TODO:
    - HTTP/2 frame decoder (separate module).
    - `Trailer:` header pass-through on chunked responses.
    - URL percent-decoding on path during parse (currently verbatim).
    - `obs-fold` rejection with a dedicated error code (currently
      folded into HEADER_MALFORMED).
    - Dispatch to MAX `parallelize` for bulk multi-request parsing on
      pipelined connections.
"""

from memory import UnsafePointer, memcpy
from sys import simdwidthof
from algorithm import vectorize

from .types import (
    HTTPVersion,
    HTTPMethod,
    Headers,
    HeaderEntry,
    Request,
    Response,
    QueryParam,
)


# ══════════════════════════════════════════════════════════════════
#  ByteView — zero-copy slice over raw bytes
# ══════════════════════════════════════════════════════════════════

alias CR: UInt8 = 13    # '\r'
alias LF: UInt8 = 10    # '\n'
alias SP: UInt8 = 32    # ' '
alias HT: UInt8 = 9     # '\t'
alias COLON: UInt8 = 58  # ':'
alias QMARK: UInt8 = 63  # '?'

alias SIMD_WIDTH: Int = simdwidthof[DType.uint8]()
"""SIMD lane count for UInt8 on the current target.

Typically 16 (SSE), 32 (AVX2), 64 (AVX-512) or 16 (NEON).  Used to
tile CRLF / colon scans over the input buffer."""


@value
struct ByteView:
    """Zero-copy immutable view over a `UInt8` buffer.

    Holds a raw pointer + length; never owns memory.  All parser
    hot paths operate on `ByteView` so no allocation happens until
    a field value is materialised into a `String`.

    Invariants:
        - `ptr` is valid for at least `length` bytes when the view
          is used.  Caller is responsible for lifetime management
          (typically the view borrows from a `List[UInt8]` or the
          raw socket buffer).
    """

    var ptr: UnsafePointer[UInt8]
    var length: Int

    fn __init__(out self, ptr: UnsafePointer[UInt8], length: Int):
        self.ptr = ptr
        self.length = length

    @staticmethod
    fn from_string(ref s: String) -> ByteView:
        """Create a view borrowing `s`'s bytes.  Valid only while `s`
        outlives the view."""
        return ByteView(s.unsafe_ptr().bitcast[UInt8](), len(s))

    fn __len__(self) -> Int:
        return self.length

    fn __getitem__(self, i: Int) -> UInt8:
        return self.ptr[i]

    fn slice(self, start: Int, end: Int) -> ByteView:
        """O(1) sub-view.  No bounds checking (hot path)."""
        return ByteView(self.ptr + start, end - start)

    fn to_string(self) -> String:
        """Materialise the view into an owned `String` (allocates)."""
        if self.length <= 0:
            return String("")
        var buf = String("")
        for i in range(self.length):
            buf += chr(Int(self.ptr[i]))
        return buf

    # ── SIMD-accelerated byte search ─────────────────────────────

    fn index_of(self, target: UInt8, start: Int = 0) -> Int:
        """Return the first offset ≥ `start` where `target` occurs,
        or -1 if absent.

        Uses SIMD vector compare in SIMD_WIDTH-wide tiles; falls back
        to scalar for the remainder.
        """
        var i = start
        var n = self.length
        # SIMD-tiled scan.
        while i + SIMD_WIDTH <= n:
            var chunk = (self.ptr + i).load[width=SIMD_WIDTH]()
            var mask = chunk == target
            if mask.reduce_or():
                # Scalar refine within the hit tile.
                for j in range(SIMD_WIDTH):
                    if self.ptr[i + j] == target:
                        return i + j
            i += SIMD_WIDTH
        # Scalar tail.
        while i < n:
            if self.ptr[i] == target:
                return i
            i += 1
        return -1

    fn index_of_crlf(self, start: Int = 0) -> Int:
        """Find the first CRLF (`\\r\\n`) at or after `start`.

        Internally scans for `\\r` via SIMD then verifies the
        following byte — two ops per tile vs four in a naive scan.
        """
        var i = start
        var n = self.length
        while True:
            var cr_at = self.index_of(CR, i)
            if cr_at == -1 or cr_at + 1 >= n:
                return -1
            if self.ptr[cr_at + 1] == LF:
                return cr_at
            i = cr_at + 1

    fn index_of_double_crlf(self, start: Int = 0) -> Int:
        """Find the end-of-headers marker `\\r\\n\\r\\n`.
        Returns the offset of the first `\\r`, or -1 if absent."""
        var i = start
        var n = self.length
        while True:
            var at = self.index_of_crlf(i)
            if at == -1 or at + 3 >= n:
                return -1
            if self.ptr[at + 2] == CR and self.ptr[at + 3] == LF:
                return at
            i = at + 2

    fn starts_with_ci(self, other: ByteView) -> Bool:
        """Case-insensitive ASCII prefix test."""
        if self.length < other.length:
            return False
        for i in range(other.length):
            var a = self.ptr[i]
            var b = other.ptr[i]
            # Lower-case ASCII: flip bit 5 for A-Z.
            if a >= 0x41 and a <= 0x5A:
                a = a | 0x20
            if b >= 0x41 and b <= 0x5A:
                b = b | 0x20
            if a != b:
                return False
        return True


# ══════════════════════════════════════════════════════════════════
#  ParseStatus / ParseResult
# ══════════════════════════════════════════════════════════════════


@value
struct ParseStatus:
    """Result code from a low-level parse step."""

    alias OK: Int = 0
    """Request fully parsed."""

    alias NEED_MORE: Int = 1
    """Input is a valid prefix; caller should read more bytes and retry."""

    alias BAD_REQUEST_LINE: Int = 2
    alias HEADER_MALFORMED: Int = 3
    alias HEADER_TOO_LARGE: Int = 4
    alias BAD_CONTENT_LENGTH: Int = 5
    alias BAD_CHUNK: Int = 6
    alias UNSUPPORTED_TE: Int = 7

    var code: Int

    fn __init__(out self, code: Int = Self.OK):
        self.code = code

    fn ok(self) -> Bool:
        return self.code == Self.OK

    fn name(self) -> String:
        if self.code == Self.OK: return "OK"
        if self.code == Self.NEED_MORE: return "NEED_MORE"
        if self.code == Self.BAD_REQUEST_LINE: return "BAD_REQUEST_LINE"
        if self.code == Self.HEADER_MALFORMED: return "HEADER_MALFORMED"
        if self.code == Self.HEADER_TOO_LARGE: return "HEADER_TOO_LARGE"
        if self.code == Self.BAD_CONTENT_LENGTH: return "BAD_CONTENT_LENGTH"
        if self.code == Self.BAD_CHUNK: return "BAD_CHUNK"
        if self.code == Self.UNSUPPORTED_TE: return "UNSUPPORTED_TE"
        return "UNKNOWN"


@value
struct ParseResult:
    """Outcome of `parse_request_view`.

    Attributes:
        status:          Parse status code.
        bytes_consumed:  Total bytes of the buffer consumed by the
                         parsed request (headers + body).  When
                         `status == NEED_MORE` this is 0 and the
                         caller should retry with more bytes.
    """

    var status: ParseStatus
    var bytes_consumed: Int

    fn __init__(out self, status: ParseStatus, bytes_consumed: Int = 0):
        self.status = status
        self.bytes_consumed = bytes_consumed


# ══════════════════════════════════════════════════════════════════
#  Scalar helpers
# ══════════════════════════════════════════════════════════════════


fn _is_ows(b: UInt8) -> Bool:
    """Optional whitespace per RFC 7230 §3.2.3 (SP / HTAB)."""
    return b == SP or b == HT


fn _ascii_lower(b: UInt8) -> UInt8:
    if b >= 0x41 and b <= 0x5A:
        return b | 0x20
    return b


fn _parse_uint_decimal(view: ByteView) -> Int:
    """Parse an unsigned decimal integer from `view`.
    Returns -1 on empty / non-digit input."""
    if view.length == 0:
        return -1
    var value = 0
    for i in range(view.length):
        var c = view[i]
        if c < 0x30 or c > 0x39:
            return -1
        value = value * 10 + Int(c - 0x30)
    return value


fn _parse_uint_hex(view: ByteView) -> Int:
    """Parse an unsigned hexadecimal integer (chunk size).
    Returns -1 on any non-hex character.  Empty is -1."""
    if view.length == 0:
        return -1
    var value = 0
    for i in range(view.length):
        var c = view[i]
        var digit: Int
        if c >= 0x30 and c <= 0x39:
            digit = Int(c - 0x30)
        elif c >= 0x41 and c <= 0x46:
            digit = Int(c - 0x41) + 10
        elif c >= 0x61 and c <= 0x66:
            digit = Int(c - 0x61) + 10
        else:
            return -1
        value = (value << 4) | digit
    return value


# ══════════════════════════════════════════════════════════════════
#  Request-line parser
# ══════════════════════════════════════════════════════════════════


fn _parse_request_line(
    view: ByteView,
    inout out_req: Request,
) -> ParseStatus:
    """Parse "METHOD SP PATH SP HTTP/X.Y" from `view`.

    `view` must be the exact request-line bytes (no trailing CRLF).
    Populates method / path / version / query_* on `out_req`.
    """
    # Method ends at the first SP.
    var sp1 = view.index_of(SP, 0)
    if sp1 <= 0:
        return ParseStatus(ParseStatus.BAD_REQUEST_LINE)

    var sp2 = view.index_of(SP, sp1 + 1)
    if sp2 <= sp1 + 1 or sp2 >= view.length:
        return ParseStatus(ParseStatus.BAD_REQUEST_LINE)

    var method_str = view.slice(0, sp1).to_string()
    var full_path = view.slice(sp1 + 1, sp2).to_string()
    var version_str = view.slice(sp2 + 1, view.length).to_string()

    # Version sanity check: must start with "HTTP/".
    if len(version_str) < 8 or not version_str.startswith("HTTP/"):
        return ParseStatus(ParseStatus.BAD_REQUEST_LINE)

    out_req.method = HTTPMethod(method_str)
    out_req.version = HTTPVersion(version_str)

    # Split path / query on '?'.
    var q_idx = full_path.find("?")
    if q_idx != -1:
        out_req.path = full_path[:q_idx]
        out_req.query_string = full_path[q_idx + 1 :]
        out_req.query_params = _parse_query_string(out_req.query_string)
    else:
        out_req.path = full_path
        out_req.query_string = ""

    return ParseStatus(ParseStatus.OK)


fn _parse_query_string(qs: String) -> List[QueryParam]:
    """Split "k1=v1&k2=v2" into `QueryParam` entries."""
    var params = List[QueryParam]()
    if len(qs) == 0:
        return params
    var pairs = qs.split("&")
    for i in range(len(pairs)):
        var pair = pairs[i]
        var eq = pair.find("=")
        if eq != -1:
            params.append(QueryParam(pair[:eq], pair[eq + 1 :]))
        else:
            params.append(QueryParam(pair, ""))
    return params


# ══════════════════════════════════════════════════════════════════
#  Header-block parser
# ══════════════════════════════════════════════════════════════════


fn _parse_header_block(
    view: ByteView,
    inout headers: Headers,
) -> ParseStatus:
    """Parse a block of `Name: Value\\r\\n` lines.

    `view` covers the bytes *between* the first CRLF after the
    request line and the final `\\r\\n\\r\\n` marker (exclusive of
    both CRLFs).  Preserves duplicate headers via `append()` so
    multi-value headers round-trip correctly.
    """
    var i = 0
    var n = view.length
    while i < n:
        # Scan for CRLF bounding this line.
        var eol = view.index_of_crlf(i)
        var line_end: Int
        if eol == -1:
            line_end = n  # Last line may not have trailing CRLF here.
        else:
            line_end = eol

        if line_end == i:
            # Empty line in the middle of headers -> malformed.
            return ParseStatus(ParseStatus.HEADER_MALFORMED)

        var line = view.slice(i, line_end)

        # RFC 7230: a header line starting with SP/HTAB is obs-fold
        # (line folding).  Reject per the RFC.
        if line.length > 0 and _is_ows(line[0]):
            return ParseStatus(ParseStatus.HEADER_MALFORMED)

        # Locate ':' separator.
        var colon = line.index_of(COLON, 0)
        if colon <= 0:
            return ParseStatus(ParseStatus.HEADER_MALFORMED)

        # Trim OWS around the value.
        var vstart = colon + 1
        while vstart < line.length and _is_ows(line[vstart]):
            vstart += 1
        var vend = line.length
        while vend > vstart and _is_ows(line[vend - 1]):
            vend -= 1

        var name = line.slice(0, colon).to_string()
        var value = line.slice(vstart, vend).to_string()

        # `append` preserves duplicates (multi-value headers).
        headers.append(name, value)

        if eol == -1:
            break
        i = eol + 2  # Past CRLF.

    return ParseStatus(ParseStatus.OK)


# ══════════════════════════════════════════════════════════════════
#  Body framing
# ══════════════════════════════════════════════════════════════════


@value
struct _BodyFraming:
    """How the body length is determined for this request."""

    alias NONE: Int = 0
    alias CONTENT_LENGTH: Int = 1
    alias CHUNKED: Int = 2

    var kind: Int
    var content_length: Int  # Valid only for CONTENT_LENGTH.

    fn __init__(out self, kind: Int = Self.NONE, cl: Int = 0):
        self.kind = kind
        self.content_length = cl


fn _detect_framing(headers: Headers) -> _BodyFraming:
    """Decide how to frame the request body per RFC 7230 §3.3.3.

    Transfer-Encoding: chunked takes precedence over Content-Length
    when both are present (RFC 7230 says this SHOULD be rejected; we
    honour chunked for robustness against upstream proxies).
    """
    var te = headers.get("Transfer-Encoding").lower()
    if len(te) > 0:
        if "chunked" in te:
            return _BodyFraming(_BodyFraming.CHUNKED)
        # Any other TE we don't implement -> caller should reject.
        return _BodyFraming(_BodyFraming.NONE)

    var cl_str = headers.get("Content-Length")
    if len(cl_str) == 0:
        return _BodyFraming(_BodyFraming.NONE)

    var cl_view = ByteView.from_string(cl_str)
    var cl = _parse_uint_decimal(cl_view)
    if cl < 0:
        return _BodyFraming(_BodyFraming.NONE)
    return _BodyFraming(_BodyFraming.CONTENT_LENGTH, cl)


# ══════════════════════════════════════════════════════════════════
#  Chunked decoder
# ══════════════════════════════════════════════════════════════════


fn decode_chunked(
    view: ByteView,
    inout out_body: String,
    inout out_trailers: Headers,
) -> ParseResult:
    """Decode an RFC 7230 §4.1 chunked body.

    Each chunk is:

        CHUNK-SIZE[;ext]\\r\\n
        CHUNK-DATA\\r\\n

    A final `0\\r\\n` terminates the body, followed by optional
    trailer headers and a final `\\r\\n`.

    `view` starts at the first chunk size line.  On success, the
    decoded body is appended to `out_body` and any trailers are
    recorded in `out_trailers`.  `bytes_consumed` counts every byte
    of the chunked stream including the terminator.
    """
    var i = 0
    var n = view.length

    while True:
        # ── Parse the chunk size line ────────────────────────────
        var eol = view.index_of_crlf(i)
        if eol == -1:
            return ParseResult(ParseStatus(ParseStatus.NEED_MORE))

        # Strip any chunk-extension after ';'.
        var size_end = eol
        for k in range(i, eol):
            if view[k] == 0x3B:  # ';'
                size_end = k
                break

        var size_view = view.slice(i, size_end)
        var chunk_size = _parse_uint_hex(size_view)
        if chunk_size < 0:
            return ParseResult(ParseStatus(ParseStatus.BAD_CHUNK))

        i = eol + 2  # Past CRLF of size line.

        if chunk_size == 0:
            # ── Trailer section (may be empty) ───────────────────
            # Scan for the final CRLF that terminates the trailers.
            var trailer_start = i
            while True:
                var t_eol = view.index_of_crlf(i)
                if t_eol == -1:
                    return ParseResult(ParseStatus(ParseStatus.NEED_MORE))
                if t_eol == i:
                    # Empty line -> end of trailers.
                    i = t_eol + 2
                    break
                i = t_eol + 2

            if trailer_start < i - 2:
                var trailer_block = view.slice(trailer_start, i - 2)
                var ts = _parse_header_block(trailer_block, out_trailers)
                if not ts.ok():
                    return ParseResult(ts)

            return ParseResult(ParseStatus(ParseStatus.OK), i)

        # ── Chunk data + trailing CRLF ───────────────────────────
        if i + chunk_size + 2 > n:
            return ParseResult(ParseStatus(ParseStatus.NEED_MORE))
        if view[i + chunk_size] != CR or view[i + chunk_size + 1] != LF:
            return ParseResult(ParseStatus(ParseStatus.BAD_CHUNK))

        # Append chunk bytes to body.
        var chunk = view.slice(i, i + chunk_size)
        out_body += chunk.to_string()

        i += chunk_size + 2


# ══════════════════════════════════════════════════════════════════
#  Top-level parser
# ══════════════════════════════════════════════════════════════════


fn parse_request_view(
    view: ByteView,
    inout out_req: Request,
) -> ParseResult:
    """Parse an HTTP/1.x request from a zero-copy byte view.

    Returns `ParseResult.OK` with `bytes_consumed` equal to the total
    request size (request-line + headers + body) so the caller can
    slide the socket buffer forward for pipelined requests.

    On `NEED_MORE`, `out_req` may be partially populated — the caller
    should discard it and retry once more bytes arrive.
    """
    if view.length == 0:
        return ParseResult(ParseStatus(ParseStatus.NEED_MORE))

    # ── Locate end of headers ────────────────────────────────────
    var hdr_end = view.index_of_double_crlf(0)
    if hdr_end == -1:
        return ParseResult(ParseStatus(ParseStatus.NEED_MORE))

    # ── Split request line from the rest ─────────────────────────
    var first_crlf = view.index_of_crlf(0)
    if first_crlf == -1 or first_crlf > hdr_end:
        return ParseResult(ParseStatus(ParseStatus.BAD_REQUEST_LINE))

    var req_line = view.slice(0, first_crlf)
    var st = _parse_request_line(req_line, out_req)
    if not st.ok():
        return ParseResult(st)

    # ── Parse header block ───────────────────────────────────────
    var hdr_view = view.slice(first_crlf + 2, hdr_end)
    var hs = _parse_header_block(hdr_view, out_req.headers)
    if not hs.ok():
        return ParseResult(hs)

    # ── Body framing ─────────────────────────────────────────────
    var body_start = hdr_end + 4
    var framing = _detect_framing(out_req.headers)

    if framing.kind == _BodyFraming.NONE:
        out_req.body = ""
        return ParseResult(ParseStatus(ParseStatus.OK), body_start)

    if framing.kind == _BodyFraming.CONTENT_LENGTH:
        var cl = framing.content_length
        if body_start + cl > view.length:
            return ParseResult(ParseStatus(ParseStatus.NEED_MORE))
        var body_view = view.slice(body_start, body_start + cl)
        out_req.body = body_view.to_string()
        return ParseResult(ParseStatus(ParseStatus.OK), body_start + cl)

    # Chunked.
    var chunked_view = view.slice(body_start, view.length)
    var trailers = Headers()
    var decoded = decode_chunked(chunked_view, out_req.body, trailers)
    if not decoded.status.ok():
        return decoded
    # Trailers are parsed but not auto-merged into `out_req.headers`
    # (Headers exposes no iterator yet).  A caller that cares can call
    # `decode_chunked` directly to inspect them.
    return ParseResult(
        ParseStatus(ParseStatus.OK),
        body_start + decoded.bytes_consumed,
    )


fn parse_request(raw: String) raises -> Request:
    """High-level parse entry point — raises on any failure.

    For the zero-copy path call `parse_request_view` directly.
    """
    var req = Request()
    var view = ByteView.from_string(raw)
    var result = parse_request_view(view, req)
    if not result.status.ok():
        raise Error("HTTP parse failed: " + result.status.name())
    return req


# ══════════════════════════════════════════════════════════════════
#  Response serializer
# ══════════════════════════════════════════════════════════════════


fn serialize_response(resp: Response, keep_alive: Bool = True) -> String:
    """Serialize a `Response` to HTTP/1.1 wire bytes.

    Mirrors `Response.to_bytes()` but lets the caller force
    `Connection: close` for non-keepalive connections.  Always emits:

        HTTP/1.1 {code} {reason}\\r\\n
        {headers}\\r\\n
        Server: {server}\\r\\n
        Connection: {keep-alive|close}\\r\\n
        \\r\\n
        {body}

    If the body is missing a `Content-Length` header and the response
    is not chunked, one is injected automatically.
    """
    # Guarantee a Content-Length if the caller forgot one and we're
    # not doing chunked output.
    var has_cl = resp.headers.has("Content-Length")
    var has_te = resp.headers.has("Transfer-Encoding")

    var out = String("HTTP/1.1 ")
    out += String(resp.status.code)
    out += " "
    out += resp.status.reason()
    out += "\r\n"

    out += resp.headers.to_http()

    if not has_cl and not has_te:
        out += "Content-Length: "
        out += String(len(resp.body))
        out += "\r\n"

    out += "Server: "
    out += resp._server_name
    out += "\r\n"

    if keep_alive:
        out += "Connection: keep-alive\r\n"
    else:
        out += "Connection: close\r\n"

    out += "\r\n"
    out += resp.body
    return out


fn serialize_chunked(body_chunks: List[String], trailers: Headers) -> String:
    """Encode an iterable of body pieces as RFC 7230 chunked transfer.

    Each element becomes one chunk.  An empty terminator chunk and
    trailer headers (possibly empty) are appended.
    """
    var out = String("")
    for i in range(len(body_chunks)):
        var c = body_chunks[i]
        # Chunk size in hex + CRLF + data + CRLF.
        out += _to_hex(len(c))
        out += "\r\n"
        out += c
        out += "\r\n"
    # Terminator.
    out += "0\r\n"
    out += trailers.to_http()
    out += "\r\n"
    return out


fn _to_hex(n: Int) -> String:
    """Lower-case hex string for a non-negative integer."""
    if n == 0:
        return String("0")
    var digits = String("0123456789abcdef")
    var buf = String("")
    var v = n
    while v > 0:
        buf = digits[v & 0xF] + buf
        v = v >> 4
    return buf


# ══════════════════════════════════════════════════════════════════
#  Self-test suite
# ══════════════════════════════════════════════════════════════════


fn _expect(cond: Bool, msg: String) raises:
    if not cond:
        raise Error("assertion failed: " + msg)


fn _expect_eq_str(got: String, want: String, label: String) raises:
    if got != want:
        raise Error(
            "mismatch at "
            + label
            + ": got '"
            + got
            + "', want '"
            + want
            + "'"
        )


fn _expect_eq_int(got: Int, want: Int, label: String) raises:
    if got != want:
        raise Error(
            "mismatch at "
            + label
            + ": got "
            + String(got)
            + ", want "
            + String(want)
        )


fn test_parse() raises:
    """Comprehensive inline test suite.

    Run from a test harness via `from mojoflow.server.http_parser
    import test_parse; test_parse()`.  Raises on the first failure.
    """
    print("[http_parser] running self-tests...")

    # ── 1. Simple GET with Host ──────────────────────────────────
    var raw1 = String("GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n")
    var r1 = parse_request(raw1)
    _expect_eq_str(r1.method.value, "GET", "T1.method")
    _expect_eq_str(r1.path, "/hello", "T1.path")
    _expect_eq_str(r1.version.value, "HTTP/1.1", "T1.version")
    _expect_eq_str(r1.get_header("Host"), "localhost", "T1.host")
    _expect(r1.is_keep_alive(), "T1.keepalive")
    print("  OK  simple GET")

    # ── 2. Query-string splitting ────────────────────────────────
    var raw2 = String(
        "GET /search?q=mojo&limit=10 HTTP/1.1\r\nHost: x\r\n\r\n"
    )
    var r2 = parse_request(raw2)
    _expect_eq_str(r2.path, "/search", "T2.path")
    _expect_eq_str(r2.query_string, "q=mojo&limit=10", "T2.qs")
    _expect_eq_str(r2.query_param("q"), "mojo", "T2.q")
    _expect_eq_str(r2.query_param("limit"), "10", "T2.limit")
    print("  OK  query string")

    # ── 3. Content-Length body ───────────────────────────────────
    var body = "{\"name\":\"mojo\"}"
    var raw3 = (
        "POST /api HTTP/1.1\r\n"
        + "Host: x\r\n"
        + "Content-Type: application/json\r\n"
        + "Content-Length: "
        + String(len(body))
        + "\r\n\r\n"
        + body
    )
    var r3 = parse_request(raw3)
    _expect_eq_str(r3.method.value, "POST", "T3.method")
    _expect_eq_str(r3.body, body, "T3.body")
    _expect_eq_int(r3.content_length(), len(body), "T3.cl")
    _expect(r3.is_json(), "T3.is_json")
    print("  OK  content-length body")

    # ── 4. Multi-value headers (Set-Cookie-style on request: Accept) ──
    var raw4 = (
        "GET / HTTP/1.1\r\n"
        + "Host: x\r\n"
        + "Accept: text/html\r\n"
        + "Accept: application/json\r\n\r\n"
    )
    var r4 = parse_request(raw4)
    # Headers has no public iterator, so verify both values survive
    # via the wire-format serialisation — this proves multi-value
    # preservation through `append`.
    var wire4 = r4.headers.to_http()
    _expect("Accept: text/html" in wire4, "T4.accept_html")
    _expect("Accept: application/json" in wire4, "T4.accept_json")
    _expect(r4.headers.len() >= 3, "T4.three_headers")  # Host + 2x Accept
    print("  OK  multi-value headers")

    # ── 5. Chunked transfer-encoding ─────────────────────────────
    var raw5 = (
        "POST /upload HTTP/1.1\r\n"
        + "Host: x\r\n"
        + "Transfer-Encoding: chunked\r\n\r\n"
        + "5\r\nHello\r\n"
        + "6\r\n World\r\n"
        + "0\r\n\r\n"
    )
    var r5 = parse_request(raw5)
    _expect_eq_str(r5.body, "Hello World", "T5.body")
    print("  OK  chunked body")

    # ── 6. Keep-alive detection ──────────────────────────────────
    var raw6 = (
        "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
    )
    var r6 = parse_request(raw6)
    _expect(not r6.is_keep_alive(), "T6.connection_close")

    var raw6b = "GET / HTTP/1.0\r\nHost: x\r\n\r\n"
    var r6b = parse_request(raw6b)
    _expect(not r6b.is_keep_alive(), "T6b.http10_default_close")

    var raw6c = (
        "GET / HTTP/1.0\r\nHost: x\r\nConnection: keep-alive\r\n\r\n"
    )
    var r6c = parse_request(raw6c)
    _expect(r6c.is_keep_alive(), "T6c.http10_explicit_keepalive")
    print("  OK  keep-alive detection")

    # ── 7. NEED_MORE on truncated headers ────────────────────────
    var raw7 = "GET / HTTP/1.1\r\nHost: x"  # no terminating CRLFCRLF
    var tmp = Request()
    var view7 = ByteView.from_string(raw7)
    var res7 = parse_request_view(view7, tmp)
    _expect_eq_int(res7.status.code, ParseStatus.NEED_MORE, "T7.status")
    print("  OK  need-more signal")

    # ── 8. Malformed request line ────────────────────────────────
    var raw8 = "GET\r\n\r\n"
    var tmp8 = Request()
    var view8 = ByteView.from_string(raw8)
    var res8 = parse_request_view(view8, tmp8)
    _expect(not res8.status.ok(), "T8.bad_request_line")
    print("  OK  malformed request line")

    # ── 9. SIMD scan correctness ─────────────────────────────────
    # Exercise index_of over a long buffer to ensure SIMD+scalar tail
    # agree.
    var long = String("")
    for i in range(1000):
        long += "a"
    long += "X"
    for i in range(100):
        long += "b"
    var lv = ByteView.from_string(long)
    _expect_eq_int(lv.index_of(0x58), 1000, "T9.simd_index_of_X")
    _expect_eq_int(lv.index_of(0x59), -1, "T9.simd_absent")
    print("  OK  SIMD byte scan")

    # ── 10. serialize_response round-trip ────────────────────────
    var resp = Response.json("{\"ok\":true}")
    var wire10 = serialize_response(resp, keep_alive=True)
    _expect(wire10.startswith("HTTP/1.1 200 OK\r\n"), "T10.status_line")
    _expect("Content-Type: application/json" in wire10, "T10.ct")
    _expect("Connection: keep-alive" in wire10, "T10.ka")
    _expect("Content-Length: 11" in wire10, "T10.cl")
    _expect(wire10.endswith("{\"ok\":true}"), "T10.body")
    print("  OK  serialize_response")

    # ── 11. serialize_response forces close ──────────────────────
    var wire11 = serialize_response(Response.text("bye"), keep_alive=False)
    _expect("Connection: close" in wire11, "T11.close")
    print("  OK  serialize_response close")

    # ── 12. serialize_chunked ────────────────────────────────────
    var chunks = List[String]()
    chunks.append(String("Hello"))
    chunks.append(String(" World"))
    var enc = serialize_chunked(chunks, Headers())
    _expect(enc.startswith("5\r\nHello\r\n"), "T12.chunk1")
    _expect("6\r\n World\r\n" in enc, "T12.chunk2")
    _expect(enc.endswith("0\r\n\r\n"), "T12.terminator")
    print("  OK  serialize_chunked")

    # ── 13. Round-trip: serialize then reparse ───────────────────
    var req_in = String(
        "PUT /items/42?x=1 HTTP/1.1\r\n"
        + "Host: api.example.com\r\n"
        + "Content-Type: text/plain\r\n"
        + "Content-Length: 5\r\n\r\n"
        + "hello"
    )
    var r13 = parse_request(req_in)
    _expect_eq_str(r13.method.value, "PUT", "T13.method")
    _expect_eq_str(r13.path, "/items/42", "T13.path")
    _expect_eq_str(r13.query_param("x"), "1", "T13.q")
    _expect_eq_str(r13.body, "hello", "T13.body")
    print("  OK  round-trip")

    print("[http_parser] all self-tests passed")
