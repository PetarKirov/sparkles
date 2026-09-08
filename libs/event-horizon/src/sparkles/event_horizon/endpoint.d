/// Native endpoint queries, usable from callbacks without a fiber runtime.
module sparkles.event_horizon.endpoint;

version (Posix):

import core.stdc.errno : errno, EAFNOSUPPORT;
import core.sys.posix.sys.socket : getsockname, sockaddr, socklen_t, AF_INET, AF_INET6;
import core.sys.posix.netinet.in_ : sockaddr_in, sockaddr_in6;
import core.sys.posix.arpa.inet : ntohs;
import sparkles.event_horizon.net : SockAddr;
import sparkles.event_horizon.io : Stream, Listener, DgramSocket;
import sparkles.event_horizon.errors : IoResult, OpKind, IoErrorStage, ioOk, ioErr;

/// Returns the native local address, including the ephemeral port assigned by
/// bind. The socket is borrowed; no ownership transfer or scheduler is needed.
IoResult!SockAddr localAddress(H)(ref H handle)
if (is(H == Stream) || is(H == Listener) || is(H == DgramSocket))
{
    SockAddr address;
    socklen_t size = cast(socklen_t) address.storage.length;
    const result = (() @trusted => getsockname(handle.fd,
        cast(sockaddr*) address.storage.ptr, &size))();
    if (result != 0)
        return ioErr!SockAddr(errno, OpKind.none, IoErrorStage.completion, "getsockname");
    address.len = size;
    return ioOk(address);
}

/// Extracts an IPv4/IPv6 port in host byte order. Other address families and
/// truncated addresses return EAFNOSUPPORT rather than reading invalid bytes.
IoResult!ushort port(in SockAddr address) @safe nothrow @nogc
{
    // Copy into aligned native structs: SockAddr's byte array need not have
    // native sockaddr alignment, and BSD family offsets differ from Linux.
    sockaddr header;
    if (address.len >= header.sizeof && address.len <= address.storage.length)
    {
        (() @trusted { (cast(ubyte*) &header)[0 .. header.sizeof] = address.storage[0 .. header.sizeof]; })();
        if (header.sa_family == AF_INET && address.len >= sockaddr_in.sizeof)
        {
            sockaddr_in native;
            (() @trusted { (cast(ubyte*) &native)[0 .. native.sizeof] = address.storage[0 .. native.sizeof]; })();
            return ioOk(ntohs(native.sin_port));
        }
        if (header.sa_family == AF_INET6 && address.len >= sockaddr_in6.sizeof)
        {
            sockaddr_in6 native;
            (() @trusted { (cast(ubyte*) &native)[0 .. native.sizeof] = address.storage[0 .. native.sizeof]; })();
            return ioOk(ntohs(native.sin6_port));
        }
    }
    return ioErr!ushort(EAFNOSUPPORT, OpKind.none);
}

@("endpoint.portAndInvalidDescriptor") @system unittest
{
    sockaddr_in native;
    import core.sys.posix.arpa.inet : htons;
    native.sin_family = AF_INET;
    native.sin_port = htons(4321);
    SockAddr address;
    address.storage[0 .. native.sizeof] = (cast(ubyte*) &native)[0 .. native.sizeof];
    address.len = native.sizeof;
    assert(port(address).value == 4321);
    address.len = 1;
    assert(port(address).hasError);
    Listener invalid;
    assert(localAddress(invalid).hasError);
}
