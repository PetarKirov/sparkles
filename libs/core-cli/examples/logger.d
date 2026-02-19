#!/usr/bin/env dub
/+ dub.sdl:
    name "logger"
    dependency "sparkles:core-cli" version="*"
    targetPath "build"
+/

import std.logger : log, logf, LogLevel;

import sparkles.core_cli.logger : initLogger;

void main()
{
    initLogger(LogLevel.trace);

    log(LogLevel.trace, "Application starting up");
    log(LogLevel.info, "Listening on port 8080");
    log(LogLevel.warning, "Disk usage above 80%");
    log(LogLevel.error, "Connection to database lost");
    log(LogLevel.critical, "Out of memory");

    // Works with logf too
    immutable host = "db-01.prod";
    immutable port = 5432;
    logf(LogLevel.info, "Reconnected to %s:%d", host, port);
}
