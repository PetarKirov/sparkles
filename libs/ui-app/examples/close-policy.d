#!/usr/bin/env dub
/+ dub.sdl:
    name "close-policy"
    targetPath "build"
    dependency "sparkles:ui-app" path="../../.."
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/

/// A close decision can outlive the native request that opened it.
module close_policy;

import sparkles.ui_app.record : RecordingHost;
import sparkles.ui_app.run_app : requestAppClose;
import std.stdio : writeln;

struct App
{
    bool approved;

    void closeRequested(H)(ref H host)
    {
        if (approved) host.quit();
    }
}

void main() @safe
{
    App app;
    RecordingHost host;
    requestAppClose(app, host);
    assert(!host.quitRequested);
    writeln("close deferred");
    app.approved = true;
    requestAppClose(app, host);
    assert(host.quitRequested);
    writeln("close approved");
}
