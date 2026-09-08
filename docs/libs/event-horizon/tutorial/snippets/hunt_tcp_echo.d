#!/usr/bin/env dub
/+ dub.sdl:
    name "hunt_tcp_echo"
    dependency "hunt-net" version="0.7.1"
    dependency "hunt" path=".deps/hunt"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
    platforms "linux"
+/
import core.thread : Thread;
import core.time : seconds;
import core.sync.semaphore : Semaphore;
import std.socket : TcpSocket, InternetAddress, SocketOptionLevel, SocketOption;
import std.stdio : writeln;
import hunt.net.Connection : Connection, NetConnectionHandler;
import hunt.net.NetClientOptions : NetClientOptions;
import hunt.io.channel.Common : DataHandleStatus;
import hunt.net.NetClientImpl : NetClientImpl;
import hunt.event.EventLoop : EventLoop;
import hunt.io.channel.posix.EpollEventChannel : EpollEventChannel;
import hunt.io.ByteBuffer;

void main()
{
    // This pinned dependency graph starts a DateTime daemon before main. Its
    // static destructor only sets a flag; it does not join before GC teardown.
    // This standalone fixture owns the process: stop and join that sole startup
    // thread before creating any application threads. No arbitrary sleep.
    import hunt.util.DateTime : DateTime;
    auto startupThreads = Thread.getAll();
    assert(startupThreads.length <= 2, "review startup ownership if the dependency graph changes");
    DateTime.stopClock();
    foreach (thread; startupThreads)
        if (thread !is Thread.getThis())
        {
            assert(thread.isDaemon);
            thread.join();
        }
    // A Phobos fixture server gives the actual bound ephemeral port. In 0.7.1,
    // NetServer.actualPort returns the configured port (zero), not the bound one.
    auto listener = new TcpSocket();
    scope(exit) listener.close();
    listener.bind(new InternetAddress("127.0.0.1", 0));
    listener.listen(1);
    listener.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 10.seconds);
    const port = (cast(InternetAddress) listener.localAddress).port;
    auto server = new Thread({
        auto socket = listener.accept();
        scope(exit) socket.close();
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 10.seconds);
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, 10.seconds);
        char[5] bytes;
        size_t received;
        while (received < bytes.length)
        {
            auto n = socket.receive(bytes[received .. $]);
            assert(n > 0);
            received += n;
        }
        assert(bytes[] == "hello");
        size_t sent;
        while (sent < bytes.length)
        {
            auto n = socket.send(bytes[sent .. $]);
            assert(n > 0);
            sent += n;
        }
    });
    server.start();
    scope(exit) server.join(false);

    auto done = new Semaphore(0);
    string received;
    // A dedicated, initially stopped loop initializes the connection on its
    // owning thread. Do not mutate a pooled, already-running loop from main.
    auto loop = new EventLoop();
    scope(exit) loop.stop();
    auto client = new NetClientImpl(loop, new NetClientOptions());
    scope(exit) client.close();
    client.onClosed = { done.notify(); };
    client.setHandler(new class NetConnectionHandler {
        override void connectionOpened(Connection connection) {
            connection.write(cast(const(ubyte)[]) "hello");
        }
        override void connectionClosed(Connection connection) {}
        override DataHandleStatus messageReceived(Connection connection, Object message) {
            auto buffer = cast(ByteBuffer) message;
            assert(buffer !is null);
            received ~= (cast(const(char)[]) buffer.peekRemaining()).idup;
            assert(received.length <= 5);
            return DataHandleStatus.Done;
        }
        override void exceptionCaught(Connection connection, Throwable error) {
            assert(false, error.msg);
        }
    });
    // Dispatch initialization after the selector declares itself ready. Hunt's
    // runAsync initializer fires before that point, so NetClient would try to
    // start an already-running loop and lose its connection initialization.
    auto start = new class EpollEventChannel {
        this() { super(loop); }
        override void onRead() {
            super.onRead();
            client.connect("127.0.0.1", port);
            close();
        }
    };
    assert(loop.register(start));
    start.trigger();
    auto loopThread = new Thread({
        scope(exit) done.notify();
        loop.run(10);
    });
    loopThread.start();
    const completed = done.wait(15.seconds);
    loop.stop();
    // stop() may have been initiated on the loop itself and handed to a worker.
    // Join the actual loop thread even if a second stop() returns early.
    loopThread.join();
    assert(completed, "Hunt event loop did not finish within the fixture deadline");
    server.join();
    assert(received == "hello");
    writeln("echoed: ", received);
}
