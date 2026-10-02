/**
The notification log (`TPG9`): every notification a pane raised
(`TPR8`), shown or not, with what was true of its pane at that moment.

The log is application-wide — panes record into one log their embedder owns
(`TerminalViewOptions.notificationLog`) — and bounded: the last
$(LREF NotificationLog.capacity) entries are kept, in memory, oldest first.
The page that lists them is the application's ([`TPG`]); this is its data.
*/
module sparkles.terminal_view.notification_log;

import std.datetime.systime : SysTime;

import sparkles.terminal_view.osc_scan : NotificationProtocol;

/**
Where a notification went (`TPR9`): a system notification, a toast on its
pane, or neither (the embedder had no surface, or a post failed).
*/
enum NotificationRoute : ubyte
{
    none,
    toast,
    system,
}

/// When a notification becomes a system notification (`notifications.when`).
enum NotifyWhen : ubyte
{
    unseen, /// only when its pane cannot be seen (default)
    always, /// always
    never,  /// never — a toast instead
}

/**
The route for a notification from a pane the user can or cannot see now
(`TPR9`): a system notification only under `always`, or under `unseen`
when the pane is not visible (application in the background, screen off,
pane on another tab); a toast otherwise.
*/
NotificationRoute routeNotification(NotifyWhen when, bool paneSeen) @safe pure nothrow @nogc
{
    final switch (when)
    {
        case NotifyWhen.always:
            return NotificationRoute.system;
        case NotifyWhen.never:
            return NotificationRoute.toast;
        case NotifyWhen.unseen:
            return paneSeen ? NotificationRoute.toast : NotificationRoute.system;
    }
}

///
@("notification_log.routeNotification.onlyIfUnseen")
@safe pure nothrow @nogc unittest
{
    assert(routeNotification(NotifyWhen.unseen, paneSeen: true) == NotificationRoute.toast);
    assert(routeNotification(NotifyWhen.unseen, paneSeen: false) == NotificationRoute.system);
    assert(routeNotification(NotifyWhen.always, paneSeen: true) == NotificationRoute.system);
    assert(routeNotification(NotifyWhen.never, paneSeen: false) == NotificationRoute.toast);
}

/// One log entry (`TPG9`): the notification and its pane, as of then.
struct NotificationRecord
{
    SysTime time;
    string tabTitle;   /// the tab's label then
    string paneTitle;  /// the pane's title then
    string process;    /// the pane's foreground process then ("" if unknown)
    string cwd;        /// the pane's working directory then ("" if unknown)
    string title;
    string body;
    NotificationProtocol protocol;
    NotificationRoute route;
}

/// The last $(LREF capacity) notifications, oldest first.
struct NotificationLog
{
    enum size_t capacity = 500;

    private NotificationRecord[] ring;
    private size_t head; // index of the oldest entry once full

    /// Appends `r`, evicting the oldest entry when full.
    void record(NotificationRecord r) @safe pure nothrow
    {
        if (ring.length < capacity)
        {
            ring ~= r;
            return;
        }
        ring[head] = r;
        head = (head + 1) % capacity;
    }

    /// The number of entries kept.
    size_t length() const @safe pure nothrow @nogc => ring.length;

    /// The `i`-th entry, oldest first.
    ref const(NotificationRecord) opIndex(size_t i) const return @safe pure nothrow @nogc
    in (i < ring.length)
        => ring[(head + i) % ring.length];

    /// The newest entry.
    ref const(NotificationRecord) back() const return @safe pure nothrow @nogc
    in (ring.length > 0)
        => this[ring.length - 1];
}

///
@("notification_log.NotificationLog.keepsTheLast500")
@safe unittest
{
    import std.conv : to;

    NotificationLog log;
    foreach (i; 0 .. 503)
        log.record(NotificationRecord(title: i.to!string));
    assert(log.length == NotificationLog.capacity);
    assert(log[0].title == "3", "the three oldest went");
    assert(log.back.title == "502");
    assert(log[499].title == "502");
}
