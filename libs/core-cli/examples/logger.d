#!/usr/bin/env dub
/+ dub.sdl:
    name "logger"
    dependency "sparkles:core-cli" path="../../.."
    targetPath "build"
+/

import sparkles.core_cli.logger : initLogger, info, warning, error, critical, log, trace, LogLevel;

void main()
{
    initLogger(LogLevel.trace);

    trace(i"Application starting up");
    info(i"Listening on port {green 8080}");
    warning(i"Disk usage above {yellow 80%}");
    error(i"Connection to {red database} lost");
    critical(i"{bold.red Out of memory}");

    // Styled IES with interpolated values
    immutable host = "db-01.prod";
    immutable port = 5432;
    info(i"Reconnected to {green $(host)}:{cyan $(port)}");

    // Explicit log level with styled IES
    log(LogLevel.warning, i"Latency spike: {yellow.bold 230ms} on {dim $(host)}");
}
