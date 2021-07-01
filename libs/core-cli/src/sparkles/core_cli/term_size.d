module sparkles.core_cli.term_size;

// TODO: upstream
version (linux) enum SIGWINCH = 28;

import core.sys.posix.signal : signal;

alias Handler = void delegate(ushort width, ushort height) nothrow @nogc;

@nogc nothrow
void setTermWindowSizeHandler(Handler handler)
in (handler)
{
    if (_handler)
        _handler = handler;
    else
    {
        _handler = handler;
        signal(SIGWINCH, &onTerminalWindowChange);
    }
}

private Handler _handler;

// Handler for SIGWINCH
private extern (C) nothrow @nogc
void onTerminalWindowChange(int sig)
{
    import core.sys.posix.sys.ioctl : ioctl, winsize, TIOCGWINSZ;
    import core.sys.posix.unistd : STDIN_FILENO;

    if (sig != SIGWINCH) return;

    winsize s;
    ioctl(STDIN_FILENO, TIOCGWINSZ, &s);

    assert (_handler, "No user-defined handler for SIGWINCH set");
    _handler(s.ws_col, s.ws_row);
}
