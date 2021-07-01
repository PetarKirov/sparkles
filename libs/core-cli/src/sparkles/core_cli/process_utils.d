module sparkles.core_cli.process_utils;

void enforceExitStatus(int status, string command)
{
    import std.format : format;
    import std.exception : enforce;
    enforce(status == 0,
        "Command `%s` failed with exit code %s.".format(command, status)
    );
}

string executeShell(in string command)
{
    import std.process : executeShell;
    const result = command.executeShell;
    enforceExitStatus(result.status, command);
    return result.output;
}
