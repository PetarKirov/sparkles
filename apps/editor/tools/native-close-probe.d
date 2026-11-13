#!/usr/bin/env dub
/+ dub.sdl:
    name "editor-native-close-probe"
    dependency "sparkles:wsi" path="../../.."
    dependency "sparkles:ui" path="../../.."
    dependency "sparkles:wired" path="../../.."
    dflags "-I$PACKAGE_DIR/../src" "-i=session_archive" "-i=session_record" "-i=session_directory" "-i=document_files"
    targetPath "../build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/// Exercise native process recovery and dirty-close decisions on a private X11 server.
module editor_native_close_probe;

import xcb_native;
import core.stdc.stdlib : free;
import core.thread : Thread;
import core.sys.posix.signal : SIGKILL;
import core.time : MonoTime, seconds, msecs;
import std.process : Config, execute, spawnProcess, thisProcessID, tryWait, kill, wait;
import std.stdio : File, stdin, write, writeln;
import std.path : baseName, buildPath, dirName;
import std.file : dirEntries, mkdir, readText, rmdirRecurse, SpanMode, tempDir, thisExePath;
import std.uuid : randomUUID;
import std.conv : text;
import session_archive : readSessionGeneration, sessionGenerationOfName;

int main(string[] args) @system
{
    if (args.length == 1 || (args.length == 2 && args[1] == "--clipboard"))
    {
        auto command = ["xvfb-run", "-a", thisExePath, "--private-server"];
        if (args.length == 2) command ~= "--clipboard";
        const result = execute(command);
        write(result.output);
        return result.status;
    }
    assert((args.length == 2 || args.length == 3) && args[1] == "--private-server");
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
    const state = buildPath(tempDir, "editor-native-state-" ~ randomUUID().toString());
    mkdir(state);
    scope (exit) rmdirRecurse(state);
    auto log = File(buildPath(tempDir, text("editor-native-close-", thisProcessID, ".log")), "w");
    const editor = buildPath(__FILE_FULL_PATH__.dirName.dirName, "build", "editor");
    auto child = spawnProcess([editor,
        "--gui", "--window-system", "x11", "--state-dir", state], stdin, log, log,
        null, Config.retainStdout | Config.retainStderr);
    scope (exit)
    {
        if (!tryWait(child).terminated) kill(child);
        wait(child);
    }
    uint window;
    void findWindow() @system
    {
        window = 0;
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
            assert(!tryWait(child).terminated, "Editor exited before its window appeared: " ~ readText(log.name));
            Thread.sleep(20.msecs);
        }
        assert(window, "Editor window did not appear.");
        Thread.sleep(400.msecs);
    }
    findWindow();
    void key(ubyte code, ushort modifiers = 0) @system
    {
        xcb_key_press_event_t event;
        event.response_type = XCB_KEY_PRESS;
        event.detail = code;
        event.root = root;
        event.event = window;
        event.same_screen = 1;
        event.state = modifiers;
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
    bool hasDraft(string expected) @system
    {
        foreach (archive; dirEntries(state, SpanMode.shallow))
        {
            if (!archive.isDir || archive.isSymlink) continue;
            foreach (file; dirEntries(archive.name, SpanMode.shallow))
            {
                const generation = sessionGenerationOfName(baseName(file.name));
                if (!generation) continue;
                const record = readSessionGeneration(archive.name, generation);
                if (record.hasError) continue;
                foreach (tab; record.value.tabs) if (tab.content == expected) return true;
            }
        }
        return false;
    }
    void awaitDraft(string expected) @system
    {
        const deadline = MonoTime.currTime + 5.seconds;
        while (!hasDraft(expected) && MonoTime.currTime < deadline)
        {
            assert(!tryWait(child).terminated, readText(log.name));
            Thread.sleep(10.msecs);
        }
        assert(hasDraft(expected), "Expected recovery contents were not checkpointed: " ~ expected ~ "\n" ~ readText(log.name));
    }
    if (args.length == 3 && args[2] == "--clipboard")
    {
        const clipboard = atom("CLIPBOARD"), targets = atom("TARGETS"), utf8 = atom("UTF8_STRING");
        const owner = xcb_generate_id(connection);
        xcb_create_window(connection, 0, owner, root, -1, -1, 1, 1, 0,
            XCB_WINDOW_CLASS_INPUT_ONLY, XCB_COPY_FROM_PARENT, 0, null);
        xcb_set_selection_owner(connection, owner, clipboard, XCB_CURRENT_TIME);
        xcb_flush(connection);
        xcb_selection_request_event_t[] requests;
        bool advertised;
        void answer(in xcb_selection_request_event_t request, string value, bool advertise = false)
        {
            const property = request.property == XCB_NONE ? request.target : request.property;
            if (advertise)
            {
                uint[2] supported = [targets, utf8];
                xcb_change_property(connection, XCB_PROP_MODE_REPLACE, request.requestor,
                    property, XCB_ATOM_ATOM, 32, 2, supported.ptr);
            }
            else xcb_change_property(connection, XCB_PROP_MODE_REPLACE, request.requestor,
                property, utf8, 8, cast(uint) value.length, value.ptr);
            xcb_selection_notify_event_t response;
            response.response_type = XCB_SELECTION_NOTIFY;
            response.time = request.time;
            response.requestor = request.requestor;
            response.selection = request.selection;
            response.target = request.target;
            response.property = property;
            xcb_send_event(connection, 0, request.requestor, XCB_EVENT_MASK_NO_EVENT,
                cast(const(char)*) &response);
            xcb_flush(connection);
        }
        void pump()
        {
            while (auto event = xcb_poll_for_event(connection))
            {
                scope (exit) free(event);
                if ((event.response_type & 0x7F) != XCB_SELECTION_REQUEST) continue;
                const request = *cast(xcb_selection_request_event_t*) event;
                if (request.target == targets) { answer(request, "", true); advertised = true; }
                else { assert(request.target == utf8); requests ~= request; }
            }
        }
        const offerDeadline = MonoTime.currTime + 5.seconds;
        while (!advertised && MonoTime.currTime < offerDeadline) { pump(); Thread.sleep(10.msecs); }
        assert(advertised, "The native backend did not discover the private clipboard offer.");
        Thread.sleep(100.msecs);
        void awaitRequest(size_t count)
        {
            const deadline = MonoTime.currTime + 5.seconds;
            while (requests.length < count && MonoTime.currTime < deadline)
            {
                assert(!tryWait(child).terminated, readText(log.name));
                pump();
                Thread.sleep(10.msecs);
            }
            assert(requests.length == count, "The native host did not request clipboard contents.");
        }
        key(55, XCB_MOD_MASK_CONTROL); // Ctrl+V in the first tab; hold its reply.
        awaitRequest(1);
        key(57, XCB_MOD_MASK_CONTROL); // Ctrl+N creates a second tab.
        Thread.sleep(100.msecs);
        key(55, XCB_MOD_MASK_CONTROL);
        awaitRequest(2);
        answer(requests[1], "from B");
        awaitDraft("from B");
        answer(requests[0], "from A");
        bool paired;
        const pairDeadline = MonoTime.currTime + 5.seconds;
        while (!paired && MonoTime.currTime < pairDeadline)
        {
            foreach (archive; dirEntries(state, SpanMode.shallow))
            {
                if (!archive.isDir) continue;
                foreach (file; dirEntries(archive.name, SpanMode.shallow))
                {
                    const generation = sessionGenerationOfName(baseName(file.name));
                    if (!generation) continue;
                    const record = readSessionGeneration(archive.name, generation);
                    if (record.hasValue && record.value.tabs.length == 2
                        && record.value.tabs[0].content == "from A"
                        && record.value.tabs[1].content == "from B") paired = true;
                }
            }
            Thread.sleep(10.msecs);
        }
        assert(paired, "Out-of-order native clipboard replies did not retain their requesting tabs.");
        closeWindow();
        Thread.sleep(100.msecs);
        key(40);
        Thread.sleep(100.msecs);
        key(40);
        const deadline = MonoTime.currTime + 5.seconds;
        while (!tryWait(child).terminated && MonoTime.currTime < deadline) Thread.sleep(10.msecs);
        assert(tryWait(child).terminated && tryWait(child).status == 0, readText(log.name));
        writeln("out-of-order native X11 clipboard replies retained their requesting tabs");
        return 0;
    }
    key(38); // Xvfb's default XKB map: a.
    awaitDraft("a");
    kill(child, SIGKILL); // Only the process owned by this probe.
    wait(child);
    Thread.sleep(100.msecs);
    child = spawnProcess([editor,
        "--gui", "--window-system", "x11", "--state-dir", state], stdin, log, log,
        null, Config.retainStdout | Config.retainStderr);
    findWindow();
    key(70); // F4, R: the shared Restore command.
    key(27);
    Thread.sleep(100.msecs);
    key(36); // Enter accepts the offer.
    Thread.sleep(100.msecs);
    key(56); // b continues editing at the restored caret.
    awaitDraft("ab");
    closeWindow();
    Thread.sleep(250.msecs);
    assert(!tryWait(child).terminated, "Native close discarded dirty text.");
    key(9); // Escape cancels the close decision.
    Thread.sleep(150.msecs);
    assert(!tryWait(child).terminated);
    closeWindow();
    Thread.sleep(250.msecs);
    key(40); // d explicitly discards the dirty document.
    const deadline = MonoTime.currTime + 5.seconds;
    while (!tryWait(child).terminated && MonoTime.currTime < deadline) Thread.sleep(20.msecs);
    assert(tryWait(child).terminated, "Discard did not approve native close.");
    assert(tryWait(child).status == 0, readText(log.name));
    writeln("native draft survived SIGKILL; Restore and editing produced ab; dirty close deferred; Escape retained the document; explicit Discard flushed and exited");
    return 0;
}
