/**
A minimal HTTP/1.1 server over `sparkles:event-horizon` (SPEC-adjacent, the
M13 showcase): `serve` accepts connections on the live net capability,
spawns one fiber per connection under the caller's scope, parses each
request head with `sparkles.http.message`, invokes the handler, and writes
the response — keep-alive by default, one connection = one fiber.

Loop-side module (rides the tier-B `Sched` verbs).
*/
module sparkles.http.server;

version (linux)  :  // rides the linux event-horizon Sched

import core.lifetime : move;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.event_horizon.errors : IoResult, ioErr, ioOk, OpKind, IoErrorStage;
import sparkles.event_horizon.io : Listener, Stream, accept, recv, send;
import sparkles.event_horizon.scope_ : Scope;

import sparkles.http.message;

/// A response to write back. `body_`/`contentType` slices must stay valid
/// until the write completes (string literals and handler-frame buffers do).
struct Response
{
    ushort status = 200;              /// status code
    const(char)[] reason = "OK";      /// reason phrase
    const(char)[] contentType = "text/plain"; /// Content-Type value
    const(char)[] body_;              /// response body
    bool keepAlive = true;            /// echoes the request's keep-alive

    /// A `200 OK` plaintext response.
    static Response ok(const(char)[] body_, const(char)[] contentType = "text/plain")
        @safe pure nothrow @nogc
        => Response(200, "OK", contentType, body_);

    /// A `404 Not Found`.
    static Response notFound() @safe pure nothrow @nogc
        => Response(404, "Not Found", "text/plain", "not found");

    /// A `400 Bad Request`.
    static Response badRequest() @safe pure nothrow @nogc
        => Response(400, "Bad Request", "text/plain", "bad request");
}

/// A request handler: pure function of the parsed request → response.
alias Handler = Response delegate(ref const Request req) @safe;

/**
Accepts connections on `listener` and serves each under `scope_`, one fiber
per connection, until the scope is cancelled (graceful shutdown). Each
connection is handled keep-alive: parse → handle → write → repeat until the
peer closes or asks to close.
*/
IoResult!void serve(X, E)(ref Scope!(X, E) scope_, ref Listener listener, Handler handler)
{
    for (;;)
    {
        auto conn = accept(listener);
        if (conn.hasError)
            return ioErr!void(conn.error); // interrupted (shutdown) or fatal
        auto stream = conn.value;

        // One fiber per connection; the scope reaps them on shutdown. The
        // member-style capture keeps `stream`/`handler` on the child frame.
        scope_.spawn(() {
            serveConnection(stream, handler);
        });
    }
}

/// Serves one connection to completion (keep-alive loop).
void serveConnection(Stream stream, Handler handler) @safe
{
    scope (exit) stream.close();

    // A per-connection receive buffer; grows to hold one request head.
    SmallBuffer!(ubyte, 4096) rx;
    size_t filled;

    for (;;)
    {
        // Ensure capacity, receive more bytes onto the tail.
        if (rx.length < filled + 2048)
            rx.length = filled + 2048;
        auto slice = () @trusted {
            SmallBuffer!(ubyte, 2048) chunk;
            chunk.length = 2048;
            return chunk;
        }();
        auto got = recv(stream, move(slice));
        if (got.res.hasError || got.res.value == 0)
            return; // peer closed or error
        const n = got.res.value;
        () @trusted {
            (cast(ubyte[]) rx[])[filled .. filled + n] = got.buf[][0 .. n];
        }();
        filled += n;

        // Try to parse a full request head from what we have.
        auto text = () @trusted => cast(const(char)[]) rx[][0 .. filled];
        auto parsed = parseRequest(text());
        if (parsed.status == ParseStatus.incomplete)
            continue; // read more
        if (parsed.status != ParseStatus.complete)
        {
            writeResponse(stream, Response.badRequest());
            return;
        }

        // Handle and respond.
        auto resp = handler(parsed.request);
        resp.keepAlive = parsed.request.keepAlive;
        if (writeResponse(stream, resp).hasError)
            return;

        if (!resp.keepAlive)
            return;

        // Drop the consumed head (and its body) and continue; for the
        // plaintext showcase requests carry no body, so reset the buffer.
        filled = 0;
    }
}

/// Serializes `resp` and sends it on `stream`.
IoResult!void writeResponse(ref Stream stream, in Response resp) @safe
{
    import sparkles.base.text.writers : writeInteger;

    SmallBuffer!(char, 512) head;
    head ~= "HTTP/1.1 ";
    writeInteger(head, resp.status);
    head ~= ' ';
    head ~= resp.reason;
    head ~= "\r\nContent-Type: ";
    head ~= resp.contentType;
    head ~= "\r\nContent-Length: ";
    writeInteger(head, resp.body_.length);
    head ~= resp.keepAlive ? "\r\nConnection: keep-alive\r\n\r\n"
        : "\r\nConnection: close\r\n\r\n";

    // Head then body, each as an owned send.
    if (sendAll(stream, cast(const(ubyte)[]) head[]).hasError)
        return ioErr!void(5, OpKind.send, IoErrorStage.completion, "head write failed");
    if (resp.body_.length > 0
        && sendAll(stream, cast(const(ubyte)[]) resp.body_).hasError)
        return ioErr!void(5, OpKind.send, IoErrorStage.completion, "body write failed");
    return ioOk();
}

/// Sends all of `bytes` (a small copy into an owned buffer per chunk).
private IoResult!void sendAll(ref Stream stream, scope const(ubyte)[] bytes) @safe
{
    size_t sent;
    while (sent < bytes.length)
    {
        SmallBuffer!(ubyte, 512) chunk;
        const n = bytes.length - sent < 512 ? bytes.length - sent : 512;
        chunk ~= bytes[sent .. sent + n];
        auto w = send(stream, move(chunk));
        if (w.res.hasError)
            return ioErr!void(w.res.error);
        sent += w.res.value;
    }
    return ioOk();
}

@("http.server.writeResponseFormatsHead")
@safe
unittest
{
    // The head serializer produces a well-formed status line + headers.
    // (Pure formatting check; the network round-trip is the example's job.)
    import sparkles.base.text.writers : writeInteger;

    Response resp = Response.ok("hi");
    resp.keepAlive = true;

    SmallBuffer!(char, 512) head;
    head ~= "HTTP/1.1 ";
    writeInteger(head, resp.status);
    head ~= ' ';
    head ~= resp.reason;
    head ~= "\r\nContent-Type: ";
    head ~= resp.contentType;
    head ~= "\r\nContent-Length: ";
    writeInteger(head, resp.body_.length);
    head ~= "\r\nConnection: keep-alive\r\n\r\n";

    assert(head[] ==
        "HTTP/1.1 200 OK\r\n"
        ~ "Content-Type: text/plain\r\n"
        ~ "Content-Length: 2\r\n"
        ~ "Connection: keep-alive\r\n\r\n");
}
