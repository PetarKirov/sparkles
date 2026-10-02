/**
Opens the terminal's pages (docs/specs/terminal/pages.md) over the panes —
about (`TPG1`–`TPG3`), the log (`TPG8`) and the notification log (`TPG9`–
`TPG11`, `TPG18`) — and gives them what they may ask of the application
($(REF PageServices, page_kit)): the clipboard, the share sheet on Android,
links through the allow-list (`TPR6`, `WorkspaceHost.open`), toasts and the
panes.
*/
module pages;

import keymap : TermCommand;
import page_kit : PageServices;
import workspace_host : WorkspaceHost;

/**
Shows the page `cmd` names (`openAbout`, `openLogs`, `openNotifications`) on
top of `host`'s surfaces. A page already on top is not opened twice.
*/
void openPage(ref WorkspaceHost host, TermCommand cmd) @system
{
    import about_page : AboutPage, gatherAboutFacts;
    import log_page : LogPage;
    import logging : previousLogPath, terminalLog, terminalStateDir;
    import notification_page : NotificationPage;
    import std.path : buildPath;

    auto services = servicesFor(host);
    if (host.surfaces.stack.length)
    {
        auto top = host.surfaces.stack[$ - 1];
        if ((cmd == TermCommand.openAbout && cast(AboutPage) top !is null)
            || (cmd == TermCommand.openLogs && cast(LogPage) top !is null)
            || (cmd == TermCommand.openNotifications && cast(NotificationPage) top !is null))
            return;
    }
    switch (cmd)
    {
        case TermCommand.openAbout:
            host.surfaces.push(new AboutPage(gatherAboutFacts(), services));
            break;
        case TermCommand.openLogs:
            host.surfaces.push(new LogPage(terminalLog(), previousLogPath(), services));
            break;
        case TermCommand.openNotifications:
            const state = terminalStateDir();
            host.surfaces.push(new NotificationPage(&host.notifications, host.notificationsConfig,
                state.length ? buildPath(state, "pages.json") : null, services));
            break;
        default:
            assert(false, "not a page");
    }
    host.invalidate();
}

/// What `host`'s pages may ask of it.
PageServices servicesFor(ref WorkspaceHost host) @system
{
    auto h = &host;
    PageServices s;
    s.copy = (string text) { h.setClipboard(text); };
    s.toast = (string text) { h.surfaces.toast(text); };
    s.openUri = (string uri) { h.open(uri); }; // the allow-list (`TPR6`)
    s.focusPane = (ulong id) {
        if (id > uint.max || h.pool.byId(cast(uint) id) is null)
            return false;
        cast(void) h.ws.focusPane(cast(uint) id);
        h.invalidate();
        return true;
    };
    s.paneOpen = (ulong id) => id <= uint.max && h.pool.byId(cast(uint) id) !is null;
    s.repaint = () @safe { h.invalidate(); };
    version (Android)
        s.share = (string text) {
            import sparkles.android.intents : shareText;
            import sparkles.base.logger : warning;

            const err = shareText(text, "sparkles:terminal log");
            if (err.length)
                warning(i"pages: share failed: $(err)");
        };
    return s;
}
