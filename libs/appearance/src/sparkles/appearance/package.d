/**
The desktop's appearance preferences: the vocabulary
($(MREF sparkles,appearance,types)) and, on Linux, the settings portal that
fills it ($(MREF sparkles,appearance,portal)).
*/
module sparkles.appearance;

public import sparkles.appearance.types;

// Desktop Linux: Android is `linux` too, and has no portal.
version (Android) {} else version (linux)
    public import sparkles.appearance.portal;
