/**
From the resolved configuration to what the host and the emulator take: the
window and font options (`GuiOptions`) and the session options
(`TerminalViewOptions`). The desktop's flags are the configuration's highest
layer (`TCF2`), spelled as they always were; this module owns that mapping
too, so `app.d` only parses.
*/
module cli;

import std.sumtype : SumType;

import sparkles.base.assert_handler : AssertHandlerKind;
import sparkles.base.logger : LogLevel;
import sparkles.core_cli.args : Argument, Command, CommandNode, Option, parseCli,
    Subcommands;
import sparkles.terminal_view.component : TerminalViewOptions;
import sparkles.terminal_view.input : ExitBehavior;
import sparkles.terminal_view.notification_log : NotifyWhen;
import sparkles.terminal_view.protocols : ProtocolPolicy;
import sparkles.ui_app.gui_options : GuiOptions;
import sparkles.wired.overlay : Sparse;

import settings : OnExit, TerminalConfig;
import settings_load : desktopConfigPath;

/// The host's window/font options for a configuration and a window size in
/// cells. An empty styled face is left null, so the loader derives it from
/// the primary (the terminal's long-standing default, not the shared Maple
/// faces `GuiOptions` itself carries).
@safe pure nothrow
GuiOptions guiOptionsFrom(TerminalConfig c, int windowCols = 100, int windowRows = 30)
{
    static string orNull(string s) => s.length ? s : null;

    const f = c.appearance.font;
    GuiOptions gui;
    gui.font = f.family;
    gui.fontSize = f.size;
    gui.fontBold = orNull(f.bold);
    gui.fontItalic = orNull(f.italic);
    gui.fontBoldItalic = orNull(f.boldItalic);
    gui.fontCodepointMap = f.codepointMap.dup;
    gui.fontDir = f.fontDir.dup;
    gui.windowWidth = windowCols;
    gui.windowHeight = windowRows;
    gui.gui = true; // a terminal emulator IS a window; no backend probing
    return gui;
}

/**
The emulator's session options a configuration decides: scrollback, the exit
behaviour and the colour scheme in effect (`systemDark` picks it when
`appearance.followSystem` is on). Colour typos land in `warnings`.
*/
TerminalViewOptions viewOptionsFrom(TerminalConfig c, bool systemDark,
    ref string[] warnings) @safe
{
    import settings_load : activeScheme, colorOverrides;

    TerminalViewOptions o;
    o.scrollbackLimit = c.behaviour.scrollback < 0 ? size_t.max
        : cast(size_t) c.behaviour.scrollback;
    o.exitBehavior = exitBehaviorFor(c.behaviour.onExit);
    o.policy = protocolPolicyFrom(c);
    o.colors = colorOverrides(activeScheme(c, systemDark),
        !c.appearance.followSystem || systemDark ? "appearance.colors.dark"
            : "appearance.colors.light", warnings);
    return o;
}

/**
The protocol policy a configuration sets (`TPR9`, `TPR19`–`TPR21`). With
notifications turned off, nothing reaches the system; a pane still shows its
toast and the log still records it.
*/
ProtocolPolicy protocolPolicyFrom(TerminalConfig c) @safe pure nothrow @nogc
    => ProtocolPolicy(
        notifyWhen: c.notifications.enabled ? c.notifications.when : NotifyWhen.never,
        pasteConfirm: c.paste.confirm,
        osc52Write: c.clipboard.osc52.write,
        osc52Read: c.clipboard.osc52.read,
    );

/**
`behaviour.onExit` as the emulator's exit behaviour. Until the exit prompt
exists (`TSS2`), `prompt` keeps the screen until a key is pressed and
`promptOnFailure` does so only after a failure.
*/
ExitBehavior exitBehaviorFor(OnExit e) @safe pure nothrow @nogc
{
    final switch (e)
    {
        case OnExit.promptOnFailure:
            return ExitBehavior.holdOnFailure;
        case OnExit.prompt:
            return ExitBehavior.waitForKey;
        case OnExit.close:
            return ExitBehavior.close;
        case OnExit.hold:
            return ExitBehavior.hold;
    }
}

/// `--exit-behavior`'s historical spellings as `behaviour.onExit`; false for
/// an unknown one.
bool onExitFromFlag(scope const(char)[] s, out OnExit e) @safe pure nothrow @nogc
{
    switch (s)
    {
        case "close":
            e = OnExit.close;
            return true;
        case "wait-for-key":
            e = OnExit.prompt;
            return true;
        case "hold":
            e = OnExit.hold;
            return true;
        case "hold-on-failure":
            e = OnExit.promptOnFailure;
            return true;
        default:
            return false;
    }
}

/**
The desktop command line (`TCF2`, `TCF5`). `config` is the subcommand; any
other word, and everything after it, is the shell command (`terminal vim -R`,
`terminal -- vim -R`). `--version` is `runCli`'s, not a field here.

`isDefault` lets a bare `terminal` reach `run` when no subcommand was selected.
*/
@(Command("terminal",
    isDefault: true,
    description: "A minimal terminal emulator using libghostty-vt.",
    usage: "terminal [options] [-- command [args...]]\n"
        ~ "       terminal config show [--changed] | write [--force] | keys",
    epilog: "With no command, the login shell runs interactively. With a command, "
        ~ "the shell runs it via -c and then exits (for example `terminal -- vim file`). "
        ~ "Settings come from the configuration file; a flag overrides it.",
))
struct TerminalCli
{
    @(Option("log-level", description: "Log level: trace | info | warning | error | critical | off (default: info)."))
    LogLevel logLevel = LogLevel.info;

    @(Option("assert-handler", description: "Assert failure behavior: default (throws AssertError) | abort (dumps core with backtrace preserved) | halt."))
    AssertHandlerKind assertHandler = AssertHandlerKind.default_;

    @(Option("config", description: "Configuration file (default: the platform config dir)."))
    string configPath;

    @(Option("font|f", description: "Font path or name (e.g. '/path/to/font.ttf' or 'Fira Code')."))
    string font;

    @(Option("font-size|s", description: "Font size in points (default: 13)."))
    int fontSize = 13;

    @(Option("window-width", description: "Initial window width in columns (default: 100)."))
    int windowWidth = 100;

    @(Option("window-height", description: "Initial window height in rows (default: 30)."))
    int windowHeight = 30;

    @(Option("scrollback-limit", description: "Maximum number of lines to keep in scrollback history (0 to disable, default: infinite)."))
    long scrollbackLimit;

    @(Option("font-codepoint-map", description: "Render codepoints from a specific font (repeatable): 'U+XXXX-U+YYYY,U+ZZZZ=Family'."))
    string[] fontCodepointMap;

    @(Option("font-dir", description: "Resolve fonts by scanning this directory instead of fontconfig (repeatable). Makes a build portable and its font selection deterministic: no fc-match subprocess, no dependence on the host's fontconfig configuration. Pair with the bundle from `nix build .#sparkles-fonts`."))
    string[] fontDir;

    @(Option("exit-behavior", description: "On child exit: close | wait-for-key | hold | hold-on-failure (default)."))
    string exitBehavior;

    @(Option("debug-take-screenshot-and-exit", description: "Takes a screenshot after 2 seconds and exits."))
    bool debugScreenshot;

    /// Not `command`: `CommandNode` already uses that name for the selected child.
    @Subcommands
    SumType!ConfigCmd sub;

    @(Argument("command", optional: true, rest: true,
        description: "Command to run in the shell. Option parsing stops at its first token."))
    string[] command;

    int run(Program)(ref Program program)
    {
        import app : launchDesktop;

        return launchDesktop(program);
    }
}

@(Command("config",
    description: "Show or write the configuration, or list the key table.",
    usage: "terminal config show [--changed] | write [--force] | keys",
))
struct ConfigCmd
{
    @(Option("changed", description: "Show only values that differ from the defaults."))
    bool changed;

    @(Option("force", description: "Overwrite an existing configuration file."))
    bool force;

    @(Option("config", description: "Configuration file (default: the platform config dir)."))
    string configPath;

    @(Argument("action", optional: true, description: "show, write, or keys (default: show)."))
    string action = "show";

    int run() => runConfig(configPath, changed, force, action);
}

/// One flag the user typed, and the spelling `config show` records as its origin.
struct CliFlag
{
    Sparse!TerminalConfig overlay;
    string flag;
}

/// What `launchDesktop` needs from a parsed root command.
struct LaunchFlags
{
    CliFlag[] flags;
    string badExit;
    string configPath;
    int windowCols = 100;
    int windowRows = 30;
    bool debugScreenshot;
    string[] command;
}

/// The flags that were actually typed, as sparse overlays. An empty
/// `configPath` is the platform default.
LaunchFlags parsedLaunch(in CommandNode!TerminalCli node)
{
    LaunchFlags r;
    r.configPath = node.configPath.length ? node.configPath : desktopConfigPath();
    r.windowCols = node.windowWidth;
    r.windowRows = node.windowHeight;
    r.debugScreenshot = node.debugScreenshot;
    r.command = node.value.command.dup;
    const seen = node.seenOptions;

    void take(string field, string flag, scope void delegate(ref Sparse!TerminalConfig) apply)
    {
        if (field !in seen)
            return;
        CliFlag f = { flag: flag };
        apply(f.overlay);
        r.flags ~= f;
    }

    take("font", "--font", (ref Sparse!TerminalConfig s) {
        s.appearance.font.family = node.font;
    });
    take("fontSize", "--font-size", (ref Sparse!TerminalConfig s) {
        s.appearance.font.size = node.fontSize;
    });
    take("scrollbackLimit", "--scrollback-limit", (ref Sparse!TerminalConfig s) {
        s.behaviour.scrollback = node.scrollbackLimit;
    });
    take("fontCodepointMap", "--font-codepoint-map", (ref Sparse!TerminalConfig s) {
        s.appearance.font.codepointMap = node.fontCodepointMap.dup;
    });
    take("fontDir", "--font-dir", (ref Sparse!TerminalConfig s) {
        s.appearance.font.fontDir = node.fontDir.dup;
    });
    if ("exitBehavior" in seen)
    {
        OnExit e;
        if (onExitFromFlag(node.exitBehavior, e))
            take("exitBehavior", "--exit-behavior", (ref Sparse!TerminalConfig s) {
                s.behaviour.onExit = e;
            });
        else
            r.badExit = node.exitBehavior;
    }
    return r;
}

/// `terminal config show|write|keys` (`TCF5`).
private int runConfig(string configPath, bool changed, bool force, string action)
{
    import std.array : appender;
    import std.file : exists, fileWrite = write, mkdirRecurse;
    import std.path : dirName;
    import std.stdio : stderr, stdout, writeln;

    import keymap : bindingsMarkdown;
    import settings_io : renderConfigShow, renderStarterConfig;
    import settings_load : loadTerminalConfig;

    if (!configPath.length)
        configPath = desktopConfigPath();
    switch (action)
    {
        case "show":
            auto w = appender!string;
            renderConfigShow(w, loadTerminalConfig(configPath, null), changedOnly: changed);
            stdout.write(w[]);
            return 0;
        case "write":
            if (!configPath.length)
            {
                stderr.writeln("terminal: no config location (no config dir; pass --config)");
                return 1;
            }
            if (configPath.exists && !force)
            {
                stderr.writeln("terminal: ", configPath, " already exists — pass --force to overwrite");
                return 1;
            }
            auto w = appender!string;
            renderStarterConfig(w);
            try
            {
                mkdirRecurse(configPath.dirName);
                fileWrite(configPath, w[]);
            }
            catch (Exception e)
            {
                stderr.writeln("terminal: ", e.msg);
                return 1;
            }
            writeln("wrote ", configPath);
            return 0;
        case "keys":
            stdout.write(bindingsMarkdown());
            return 0;
        default:
            stderr.writeln("terminal config: unknown action '", action, "' (show, write, keys)");
            return 2;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

@("cli.guiOptionsFrom.preservesTheTerminalDefaults")
@safe pure nothrow
unittest
{
    // `terminal` opens with 13 pt monospace in a 100×30 window, styled faces
    // auto-derived — NOT the shared 18 pt Maple defaults GuiOptions carries.
    version (Android) {} else
    {
        const gui = guiOptionsFrom(TerminalConfig.init);
        assert(gui.font == "monospace");
        assert(gui.fontSize == 13);
        assert(gui.windowWidth == 100);
        assert(gui.windowHeight == 30);
        assert(gui.fontBold is null && gui.fontItalic is null
            && gui.fontBoldItalic is null);
        assert(gui.gui, "the backend decision is forced to the window");
    }
}

@("cli.guiOptionsFrom.passesTheFontThrough")
@safe pure nothrow
unittest
{
    TerminalConfig c;
    c.appearance.font.family = "/tmp/f.ttf";
    c.appearance.font.size = 20;
    c.appearance.font.bold = "Iosevka Bold";
    c.appearance.font.codepointMap = ["U+2600-U+26FF=Noto"];
    c.appearance.font.fontDir = ["/tmp/fonts"];
    const gui = guiOptionsFrom(c, 80, 24);
    assert(gui.font == "/tmp/f.ttf");
    assert(gui.fontSize == 20);
    assert(gui.fontBold == "Iosevka Bold" && gui.fontItalic is null);
    assert(gui.fontCodepointMap == ["U+2600-U+26FF=Noto"]);
    assert(gui.fontDir == ["/tmp/fonts"]);
    assert(gui.windowWidth == 80 && gui.windowHeight == 24);
}

@("cli.viewOptionsFrom.mapsTheSessionSettings")
@safe unittest
{
    import sparkles.base.term_color : RgbColor;

    TerminalConfig c;
    string[] warnings;
    auto o = viewOptionsFrom(c, systemDark: false, warnings);
    assert(o.scrollbackLimit == size_t.max, "-1 keeps everything");
    assert(o.exitBehavior == ExitBehavior.holdOnFailure);
    assert(o.colors.background == RgbColor(0xef, 0xf1, 0xf5), "light follows the system");

    c.behaviour.scrollback = 0;
    c.behaviour.onExit = OnExit.close;
    c.appearance.followSystem = false;
    o = viewOptionsFrom(c, systemDark: false, warnings);
    assert(o.scrollbackLimit == 0);
    assert(o.exitBehavior == ExitBehavior.close);
    assert(o.colors.background == RgbColor(0x1e, 0x1e, 0x2e), "pinned: the dark scheme");
    assert(warnings.length == 0);
}

@("cli.protocolPolicyFrom.carriesTheSettings")
@safe pure nothrow @nogc
unittest
{
    import sparkles.terminal_view.protocols : ClipboardReadPolicy, PasteConfirm;

    TerminalConfig c;
    assert(protocolPolicyFrom(c) == ProtocolPolicy.init, "the defaults agree");
    c.paste.confirm = PasteConfirm.never;
    c.clipboard.osc52.read = ClipboardReadPolicy.deny;
    c.notifications.enabled = false;
    const p = protocolPolicyFrom(c);
    assert(p.pasteConfirm == PasteConfirm.never);
    assert(p.osc52Read == ClipboardReadPolicy.deny);
    assert(p.notifyWhen == NotifyWhen.never);
}

@("cli.onExitFromFlag.keepsTheHistoricalSpellings")
@safe pure nothrow @nogc
unittest
{
    OnExit e;
    assert(onExitFromFlag("hold-on-failure", e) && e == OnExit.promptOnFailure);
    assert(onExitFromFlag("wait-for-key", e) && e == OnExit.prompt);
    assert(onExitFromFlag("close", e) && e == OnExit.close);
    assert(!onExitFromFlag("sometimes", e));
}

@("cli.TerminalCli.flagsRestAndConfig")
@system unittest
{
    import std.sumtype : match;

    auto shell = parseCli!TerminalCli(["terminal", "--font", "Fira", "--font-size", "14", "vim", "-R"]);
    assert(shell, shell.error.message);
    assert(shell.value.font == "Fira");
    assert(shell.value.fontSize == 14);
    assert(shell.value.value.command == ["vim", "-R"]);
    assert(!shell.value.commandSelected);
    auto launched = parsedLaunch(shell.value);
    assert(launched.command == ["vim", "-R"]);
    assert(launched.flags.length == 2);
    assert(launched.flags[0].flag == "--font");
    assert(launched.flags[0].overlay.appearance.font.family == "Fira");
    assert(launched.flags[1].flag == "--font-size");
    assert(launched.windowCols == 100 && launched.windowRows == 30);

    auto dashed = parseCli!TerminalCli(["terminal", "--", "config", "show"]);
    assert(dashed, dashed.error.message);
    assert(!dashed.value.commandSelected);
    assert(dashed.value.value.command == ["config", "show"]);

    auto sized = parseCli!TerminalCli(
        ["terminal", "--font-size", "14", "--", "vim", "file", "-R"]);
    assert(sized, sized.error.message);
    assert(sized.value.fontSize == 14);
    assert(sized.value.value.command == ["vim", "file", "-R"]);

    auto cfg = parseCli!TerminalCli(["terminal", "config", "show", "--changed"]);
    assert(cfg, cfg.error.message);
    assert(cfg.value.commandSelected);
    assert(cfg.value.value.command.length == 0);
    cfg.value.command.match!(
        (in CommandNode!ConfigCmd c) {
            assert(c.value.action == "show");
            assert(c.value.changed);
            assert(!c.value.force);
        },
    );

    auto bare = parseCli!TerminalCli(["terminal", "config"]);
    assert(bare, bare.error.message);
    bare.value.command.match!(
        (in CommandNode!ConfigCmd c) { assert(c.value.action == "show"); },
    );

    auto bad = parseCli!TerminalCli(["terminal", "--exit-behavior", "sometimes"]);
    assert(bad, bad.error.message);
    assert(parsedLaunch(bad.value).badExit == "sometimes");
    assert(parsedLaunch(bad.value).flags.length == 0);
}
