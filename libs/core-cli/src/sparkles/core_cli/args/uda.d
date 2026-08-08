module sparkles.core_cli.args.uda;

import sparkles.core_cli.help_formatting : Sections;

private struct NamedOnly {}

struct Command
{
    string name;
    string[] aliases;
    string description_;
    string shortDescription_;
    string usage_;
    string epilog_;
    Sections sections_;
    string[] sectionsToImport_;
    bool hidden_;
    string viewsRoot_;
    bool isDefault_;

    this(
        string name,
        NamedOnly _ = NamedOnly.init,
        string[] aliases = null,
        string shortDescription = null,
        string description = null,
        string usage = null,
        string epilog = null,
        Sections sections = Sections.init,
        string[] helpSections = null,
        bool hidden = false,
        string viewsRoot = null,
        bool isDefault = false,
    ) @safe
    {
        this.name = name;
        this.aliases = aliases.dup;
        this.shortDescription_ = shortDescription;
        this.description_ = description;
        this.usage_ = usage;
        this.epilog_ = epilog;
        this.sections_ = sections;
        this.sectionsToImport_ = helpSections.dup;
        this.hidden_ = hidden;
        this.viewsRoot_ = viewsRoot;
        this.isDefault_ = isDefault;
    }

    Command description(string text) @safe
    {
        auto result = this;
        result.description_ = text;
        return result;
    }

    Command shortDescription(string text) @safe
    {
        auto result = this;
        result.shortDescription_ = text;
        return result;
    }

    Command usage(string text) @safe
    {
        auto result = this;
        result.usage_ = text;
        return result;
    }

    Command epilog(string text) @safe
    {
        auto result = this;
        result.epilog_ = text;
        return result;
    }

    Command helpSections(string[] sectionFileNamesToImport...) @safe
    {
        auto result = this;
        result.sectionsToImport_ ~= sectionFileNamesToImport.dup;
        return result;
    }

    Command hidden(bool value = true) @safe
    {
        auto result = this;
        result.hidden_ = value;
        return result;
    }

    /// Override the views root used to resolve string-imported help texts
    /// (defaults to the root command's `name`).
    Command viewsRoot(string root) @safe
    {
        auto result = this;
        result.viewsRoot_ = root;
        return result;
    }

    Command makeDefault(bool value = true) @safe
    {
        auto result = this;
        result.isDefault_ = value;
        return result;
    }
}

@("args.Command.namedArguments")
@safe
unittest
{
    Sections sections;
    sections["notes"] = ["Inline section"];

    auto info = Command(
        "git",
        aliases: ["g"],
        shortDescription: "Distributed version control system",
        description: "Track source history",
        usage: "git <command>",
        epilog: "See also git help.",
        helpSections: ["description", "examples"],
        sections: sections,
        hidden: true,
        viewsRoot: "git-cli",
        isDefault: true,
    );

    assert(info.name == "git");
    assert(info.aliases == ["g"]);
    assert(info.shortDescription_ == "Distributed version control system");
    assert(info.description_ == "Track source history");
    assert(info.usage_ == "git <command>");
    assert(info.epilog_ == "See also git help.");
    assert(info.sectionsToImport_ == ["description", "examples"]);
    assert(info.sections_ == sections);
    assert(info.hidden_);
    assert(info.viewsRoot_ == "git-cli");
    assert(info.isDefault_);
}

struct Option
{
    string aliases;
    string description_;
    string placeholder_;
    bool required_;
    bool hidden_;
    bool counter_;
    string[] allowedValues_;

    this(
        string aliases,
        NamedOnly _ = NamedOnly.init,
        string description = null,
        string placeholder = null,
        bool required = false,
        bool hidden = false,
        bool counter = false,
        string[] allowedValues = null,
    ) @safe
    {
        this.aliases = aliases;
        this.description_ = description;
        this.placeholder_ = placeholder;
        this.required_ = required;
        this.hidden_ = hidden;
        this.counter_ = counter;
        this.allowedValues_ = allowedValues.dup;
    }

    Option description(string text) @safe
    {
        auto result = this;
        result.description_ = text;
        return result;
    }

    Option placeholder(string text) @safe
    {
        auto result = this;
        result.placeholder_ = text;
        return result;
    }

    Option required(bool value = true) @safe
    {
        auto result = this;
        result.required_ = value;
        return result;
    }

    Option hidden(bool value = true) @safe
    {
        auto result = this;
        result.hidden_ = value;
        return result;
    }

    Option counter(bool value = true) @safe
    {
        auto result = this;
        result.counter_ = value;
        return result;
    }

    Option allowedValues(string[] values...) @safe
    {
        auto result = this;
        result.allowedValues_ = values.dup;
        return result;
    }
}

@("args.Option.namedArguments")
@safe
unittest
{
    auto info = Option(
        "L|log-level",
        description: "Set the log level.",
        placeholder: "LEVEL",
        required: true,
        hidden: true,
        counter: true,
        allowedValues: ["trace", "info"],
    );

    assert(info.aliases == "L|log-level");
    assert(info.description_ == "Set the log level.");
    assert(info.placeholder_ == "LEVEL");
    assert(info.required_);
    assert(info.hidden_);
    assert(info.counter_);
    assert(info.allowedValues_ == ["trace", "info"]);
}

struct Argument
{
    size_t position = size_t.max;
    string placeholder_;
    string description_;
    bool optional_;
    bool hidden_;

    this(
        string placeholder,
        NamedOnly _ = NamedOnly.init,
        string description = null,
        bool optional = false,
        bool hidden = false,
        size_t position = size_t.max,
    ) @safe
    {
        this.placeholder_ = placeholder;
        this.description_ = description;
        this.optional_ = optional;
        this.hidden_ = hidden;
        this.position = position;
    }

    this(
        size_t position,
        NamedOnly _ = NamedOnly.init,
        string placeholder = null,
        string description = null,
        bool optional = false,
        bool hidden = false,
    ) @safe
    {
        this.position = position;
        this.placeholder_ = placeholder;
        this.description_ = description;
        this.optional_ = optional;
        this.hidden_ = hidden;
    }

    Argument description(string text) @safe
    {
        auto result = this;
        result.description_ = text;
        return result;
    }

    Argument optional(bool value = true) @safe
    {
        auto result = this;
        result.optional_ = value;
        return result;
    }

    Argument hidden(bool value = true) @safe
    {
        auto result = this;
        result.hidden_ = value;
        return result;
    }
}

@("args.Argument.namedArguments")
@safe
unittest
{
    auto byPlaceholder = Argument(
        "path",
        description: "Path to inspect.",
        optional: true,
        hidden: true,
        position: 2,
    );

    assert(byPlaceholder.placeholder_ == "path");
    assert(byPlaceholder.description_ == "Path to inspect.");
    assert(byPlaceholder.optional_);
    assert(byPlaceholder.hidden_);
    assert(byPlaceholder.position == 2);

    auto byPosition = Argument(
        0,
        placeholder: "source",
        description: "Source path.",
        optional: true,
        hidden: true,
    );

    assert(byPosition.position == 0);
    assert(byPosition.placeholder_ == "source");
    assert(byPosition.description_ == "Source path.");
    assert(byPosition.optional_);
    assert(byPosition.hidden_);
}

struct Subcommands {}

struct SubCommandRegistration(T)
{
    alias command = T;
}

struct SubCommandRegistrationWithHandler(T, alias handler_)
{
    alias command = T;
    alias handler = handler_;
}

string identifierSafe(string value) @safe pure nothrow
{
    string result;
    foreach (c; value)
    {
        immutable isLower = c >= 'a' && c <= 'z';
        immutable isUpper = c >= 'A' && c <= 'Z';
        immutable isDigit = c >= '0' && c <= '9';
        result ~= (isLower || isUpper || isDigit) ? c : '_';
    }
    return result;
}

mixin template addSubCommand(T)
{
    import sparkles.core_cli.args.uda : identifierSafe;

    enum fieldName = "__sparklesSubCommand_" ~ identifierSafe(T.mangleof);
    mixin("private import sparkles.core_cli.args.uda : SubCommandRegistration; "
        ~ "private SubCommandRegistration!T "
        ~ fieldName
        ~ ";");
}

mixin template addSubCommand(T, alias handler)
{
    import sparkles.core_cli.args.uda : identifierSafe;

    enum fieldName = "__sparklesSubCommand_" ~ identifierSafe(T.mangleof);
    mixin("private import sparkles.core_cli.args.uda : SubCommandRegistrationWithHandler; "
        ~ "private SubCommandRegistrationWithHandler!(T, handler) "
        ~ fieldName
        ~ ";");
}
