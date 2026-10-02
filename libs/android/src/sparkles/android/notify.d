/**
System notifications, over JNI with no Java: a channel, a post that brings
the app forward when tapped, and what can be learnt on the way back.

$(B Posting.) A notification lives in a channel (API 26), which the app
creates once ($(LREF createChannel); creating it again changes nothing).
$(LREF post) builds it with `Notification.Builder` and posts it under a
$(I tag) — a later post with the same tag replaces the earlier one, so one
source never stacks more than one notification. Tapping it starts the app's
own launch intent, which brings the running task forward rather than starting
a second activity, and auto-cancels the notification.

$(B Permission.) Android 13 made notifications a runtime permission
(`POST_NOTIFICATIONS`). An app targeting API 32 or lower — this package's apps
target 28 — does not ask for it: the system asks the user the first time the
app, in the foreground, creates a channel. A post while it is refused, or
into a channel the user blocked, fails with a reason and nothing is shown.

$(B Finding the source of a tap.) A NativeActivity cannot override
`onNewIntent`, so the intent of the tap — which carries the source's id —
reaches no native code: `Activity.getIntent` keeps returning the intent the
activity was created with. What native code $(I can) see is which of its
notifications are gone ($(LREF activeTags)): a tapped notification
auto-cancels. (Measured on Android 14, docs/specs/terminal/testing.md: after a
tap, `getIntent()` and the task's `baseIntent` both still lack the extra.)
*/
module sparkles.android.notify;

version (Android):

import sparkles.android.jni;

/// The extra a posted notification's launch intent carries: the id
/// $(LREF post) was given.
enum sourceExtra = "sparkles.notification.source";

/// The notification id every post uses; the tag tells them apart.
private enum int notificationId = 1;

private enum int importanceDefault = 3; // NotificationManager.IMPORTANCE_DEFAULT
private enum int importanceNone = 0; // NotificationManager.IMPORTANCE_NONE
private enum int flagUpdateCurrent = 0x0800_0000; // PendingIntent.FLAG_UPDATE_CURRENT
private enum int flagImmutable = 0x0400_0000; // PendingIntent.FLAG_IMMUTABLE

/**
Create the channel `id`, shown to the user as `name`, at the default
importance. Idempotent: the user's later changes to the channel are kept.
`null` on success, else the reason.
*/
string createChannel(string id, string name) @trusted nothrow
{
    return withJni((ref JniFrame f) {
        import sparkles.android.intents : utf8String;

        auto nm = f.systemService("notification");
        if (nm is null)
            return "no NotificationManager";
        jvalue[3] a = [jv(utf8String(f, id)), jv(utf8String(f, name)), jv(importanceDefault)];
        auto channel = f.newObject("android/app/NotificationChannel",
            "(Ljava/lang/String;Ljava/lang/CharSequence;I)V", a);
        jvalue[1] c = [jv(channel)];
        if (!f.callVoid(nm, "createNotificationChannel", "(Landroid/app/NotificationChannel;)V", c))
            return "cannot create the notification channel";
        return string.init;
    });
}

/// What $(LREF post) shows.
struct NotificationPost
{
    string channel; /// a channel made by $(LREF createChannel)
    string tag; /// a post with the same tag replaces this one
    string title;
    string text;
    int source; /// carried by the tap's intent as $(LREF sourceExtra)
}

/**
Post `p`, replacing any notification with the same tag. `null` on success,
else the reason it was not shown: notifications refused (the permission), the
channel blocked, or a framework failure (described in logcat).
*/
string post(in NotificationPost p) @trusted nothrow
{
    return withJni((ref JniFrame f) {
        import sparkles.android.intents : utf8String;

        auto nm = f.systemService("notification");
        if (nm is null)
            return "no NotificationManager";
        if (!f.callBool(nm, "areNotificationsEnabled", "()Z"))
            return f.failed ? "cannot query the notification permission"
                : "notifications are not allowed for this app";

        auto channelId = utf8String(f, p.channel);
        jvalue[1] ch = [jv(channelId)];
        auto channel = f.callObject(nm, "getNotificationChannel",
            "(Ljava/lang/String;)Landroid/app/NotificationChannel;", ch);
        if (channel is null)
            return "no notification channel " ~ p.channel;
        if (f.callInt(channel, "getImportance", "()I", null, importanceDefault) == importanceNone)
            return "the notification channel " ~ p.channel ~ " is blocked";

        // The tap: the app's launch intent brings the running task forward.
        auto pm = f.callObject(f.activity, "getPackageManager",
            "()Landroid/content/pm/PackageManager;");
        auto pkg = f.callObject(f.activity, "getPackageName", "()Ljava/lang/String;");
        jvalue[1] pk = [jv(pkg)];
        auto intent = f.callObject(pm, "getLaunchIntentForPackage",
            "(Ljava/lang/String;)Landroid/content/Intent;", pk);
        jvalue[2] extra = [jv(f.newString(sourceExtraW)), jv(p.source)];
        f.callObject(intent, "putExtra", "(Ljava/lang/String;I)Landroid/content/Intent;", extra);
        jvalue[4] pa = [jv(f.activity), jv(p.source), jv(intent),
            jv(flagUpdateCurrent | flagImmutable)];
        auto pending = f.callStaticObject("android/app/PendingIntent", "getActivity",
            "(Landroid/content/Context;ILandroid/content/Intent;I)Landroid/app/PendingIntent;", pa);
        if (pending is null)
            return "cannot build the notification's intent";

        jvalue[2] ba = [jv(f.activity), jv(channelId)];
        auto b = f.newObject("android/app/Notification$Builder",
            "(Landroid/content/Context;Ljava/lang/String;)V", ba);
        jvalue[1] icon = [jv(appIcon(f))];
        f.callObject(b, "setSmallIcon", "(I)Landroid/app/Notification$Builder;", icon);
        auto title = utf8String(f, p.title);
        auto text = utf8String(f, p.text);
        jvalue[1] t = [jv(title)];
        f.callObject(b, "setContentTitle", "(Ljava/lang/CharSequence;)Landroid/app/Notification$Builder;", t);
        jvalue[1] x = [jv(text)];
        f.callObject(b, "setContentText", "(Ljava/lang/CharSequence;)Landroid/app/Notification$Builder;", x);
        // A long body unfolds instead of being cut at one line.
        auto style = f.newObject("android/app/Notification$BigTextStyle", "()V");
        f.callObject(style, "bigText",
            "(Ljava/lang/CharSequence;)Landroid/app/Notification$BigTextStyle;", x);
        jvalue[1] st = [jv(style)];
        f.callObject(b, "setStyle", "(Landroid/app/Notification$Style;)Landroid/app/Notification$Builder;", st);
        jvalue[1] pi = [jv(pending)];
        f.callObject(b, "setContentIntent", "(Landroid/app/PendingIntent;)Landroid/app/Notification$Builder;", pi);
        jvalue[1] yes = [jv(true)];
        f.callObject(b, "setAutoCancel", "(Z)Landroid/app/Notification$Builder;", yes);
        auto n = f.callObject(b, "build", "()Landroid/app/Notification;");
        if (n is null)
            return "cannot build the notification";

        jvalue[3] na = [jv(utf8String(f, p.tag)), jv(notificationId), jv(n)];
        if (!f.callVoid(nm, "notify", "(Ljava/lang/String;ILandroid/app/Notification;)V", na))
            return "the notification manager refused the post";
        return string.init;
    });
}

private static immutable wstring sourceExtraW = sourceExtra;

/// Remove the notification posted under `tag`, if it is still shown.
void cancel(string tag) @trusted nothrow
{
    withJni((ref JniFrame f) {
        import sparkles.android.intents : utf8String;

        auto nm = f.systemService("notification");
        jvalue[2] a = [jv(utf8String(f, tag)), jv(notificationId)];
        f.callVoid(nm, "cancel", "(Ljava/lang/String;I)V", a);
    });
}

/**
The tags of this app's notifications still shown (`getActiveNotifications`):
one posted earlier and missing now was tapped (it auto-cancels), dismissed,
or cancelled. `ok` is `false` when the list could not be read.
*/
string[] activeTags(out bool ok) @trusted nothrow
{
    string[] tags;
    ok = withJni((ref JniFrame f) {
        auto env = f.env;
        auto nm = f.systemService("notification");
        auto arr = f.callObject(nm, "getActiveNotifications",
            "()[Landroid/service/notification/StatusBarNotification;");
        if (arr is null)
            return false;
        const n = (*env).GetArrayLength(env, arr);
        foreach (i; 0 .. n)
        {
            auto sbn = (*env).GetObjectArrayElement(env, arr, i);
            auto tag = f.callObject(sbn, "getTag", "()Ljava/lang/String;");
            if (f.failed)
                return false;
            if (tag !is null)
                tags ~= f.toDString(tag);
            (*env).DeleteLocalRef(env, tag);
            (*env).DeleteLocalRef(env, sbn);
        }
        return true;
    });
    return tags;
}

/// The app's launcher icon (`ApplicationInfo.icon`): the small icon a
/// notification must have.
private int appIcon(ref JniFrame f) @trusted nothrow @nogc
{
    auto env = f.env;
    auto info = f.callObject(f.activity, "getApplicationInfo",
        "()Landroid/content/pm/ApplicationInfo;");
    if (info is null)
        return 0;
    auto field = (*env).GetFieldID(env, (*env).GetObjectClass(env, info), "icon", "I");
    if (field is null || f.failed)
        return 0;
    return (*env).GetIntField(env, info, field);
}
