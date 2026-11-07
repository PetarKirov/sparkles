#!/usr/bin/env dub
/+ dub.sdl:
    name "editor-native-close-probe"
    dependency "sparkles:wsi" path="../../.."
    targetPath "../build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/// Exercise native dirty-close decisions on a private X11 server.
module editor_native_close_probe;

import xcb_native;
import core.stdc.stdlib : free;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.process : execute, spawnProcess, thisProcessID, tryWait, kill, wait;
import std.stdio : File, stdin, write, writeln;
import std.path : buildPath, dirName;
import std.file : tempDir, thisExePath;
import std.conv : text;

int main(string[] args) @system
{
    if (args.length == 1)
    {
        const result = execute(["xvfb-run", "-a", thisExePath, "--private-server"]);
        write(result.output);
        return result.status;
    }
    assert(args.length == 2 && args[1] == "--private-server");
    auto connection = xcb_connect(null, null);
    assert(connection !is null && !xcb_connection_has_error(connection));
    scope (exit) xcb_disconnect(connection);
    const root = xcb_setup_roots_iterator(xcb_get_setup(connection)).data.root;
    uint atom(string name) @system
    {
        auto reply = xcb_intern_atom_reply(connection,
            xcb_intern_atom(connection, 0, cast(ushort) name.length, name.ptr), null);
        assert(reply !is null);
        scope (exit) free(reply);
        return reply.atom;
    }
    const nameAtom = atom("_NET_WM_NAME");
    auto log = File(buildPath(tempDir, text("editor-native-close-", thisProcessID, ".log")), "w");
    const editor = buildPath(__FILE_FULL_PATH__.dirName.dirName, "build", "editor");
    auto child = spawnProcess([editor,
        "--gui", "--window-system", "x11"], stdin, log, log);
    scope (exit)
    {
        if (!tryWait(child).terminated) kill(child);
        wait(child);
    }
    uint window;
    const deadline = MonoTime.currTime + 15.seconds;
    while (!window && MonoTime.currTime < deadline)
    {
        auto reply = xcb_query_tree_reply(connection, xcb_query_tree(connection, root), null);
        assert(reply !is null);
        scope (exit) free(reply);
        foreach (candidate; xcb_query_tree_children(reply)[0 .. xcb_query_tree_children_length(reply)])
        {
            auto property = xcb_get_property_reply(connection,
                xcb_get_property(connection, 0, candidate, nameAtom, XCB_GET_PROPERTY_TYPE_ANY, 0, 100), null);
            if (property is null) continue;
            scope (exit) free(property);
            const length = xcb_get_property_value_length(property);
            const name = (cast(const(char)*) xcb_get_property_value(property))[0 .. length];
            if (name == "Sparkles Editor") { window = candidate; break; }
        }
        assert(!tryWait(child).terminated, "Editor exited before its window appeared.");
        Thread.sleep(20.msecs);
    }
    assert(window, "Editor window did not appear.");
    Thread.sleep(400.msecs);
    void key(ubyte code) @system
    {
        xcb_key_press_event_t event;
        event.response_type = XCB_KEY_PRESS;
        event.detail = code;
        event.root = root;
        event.event = window;
        event.same_screen = 1;
        xcb_send_event(connection, 0, window, XCB_EVENT_MASK_KEY_PRESS, cast(const(char)*) &event);
        event.response_type = XCB_KEY_RELEASE;
        xcb_send_event(connection, 0, window, XCB_EVENT_MASK_KEY_RELEASE, cast(const(char)*) &event);
        xcb_flush(connection);
    }
    void closeWindow() @system
    {
        xcb_client_message_event_t event;
        event.response_type = XCB_CLIENT_MESSAGE;
        event.format = 32;
        event.window = window;
        event.type = atom("WM_PROTOCOLS");
        event.data.data32[0] = atom("WM_DELETE_WINDOW");
        xcb_send_event(connection, 0, window, XCB_EVENT_MASK_NO_EVENT, cast(const(char)*) &event);
        xcb_flush(connection);
    }
    key(38); // Xvfb's default XKB map: a.
    Thread.sleep(150.msecs);
    closeWindow();
    Thread.sleep(250.msecs);
    assert(!tryWait(child).terminated, "Native close discarded dirty text.");
    key(9); // Escape cancels the close decision.
    Thread.sleep(150.msecs);
    assert(!tryWait(child).terminated);
    closeWindow();
    Thread.sleep(250.msecs);
    key(40); // d explicitly discards the dirty document.
    while (!tryWait(child).terminated && MonoTime.currTime < deadline) Thread.sleep(20.msecs);
    assert(tryWait(child).terminated, "Discard did not approve native close.");
    assert(tryWait(child).status == 0);
    writeln("native dirty close deferred; Escape retained the document; explicit Discard exited");
    return 0;
}
