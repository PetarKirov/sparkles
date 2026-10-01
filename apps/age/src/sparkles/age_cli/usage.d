/++
Help/usage text for the `age` and `age-keygen` tools, plus the `--help`/`-h`
detection both entry points consult $(I before) any other work.

Detecting help up front matters especially for `age-keygen`: without it, a
`--help` request falls through to the default flow and would $(B generate and
print a fresh private key). $(LREF requestedHelp) is a pure scan run as the very
first step of each `main`, so `-h`/`--help` always prints usage and exits `0`
with no side effects.

Copyright: © 2026, Petar Kirov
License: $(HTTP boost.org/LICENSE_1_0.txt, Boost License 1.0)
Authors: Petar Kirov
+/
module sparkles.age_cli.usage;

/++
Does the command line request help?

Scans the arguments (skipping `args[0]`, the program name) for a bare `-h` or
`--help` token. This is deliberately a simple token scan rather than a `getopt`
pass so it can run before any parsing and cannot trigger a side effect (such as
key generation) on the way to discovering the help flag.

Params:
    args = the full process argument vector (including `args[0]`).

Returns: `true` if `-h` or `--help` appears anywhere after the program name.
+/
bool requestedHelp(scope const(string)[] args) @safe pure nothrow @nogc
{
    foreach (arg; args.length > 1 ? args[1 .. $] : null)
        if (arg == "-h" || arg == "--help")
            return true;
    return false;
}

/// Usage text for the `age` tool. Printed to standard output on `-h`/`--help`.
enum string ageUsage =
`Usage:
    age [--encrypt] (-r RECIPIENT | -R PATH)... [-a] [-i PATH] [-o OUTPUT] [INPUT]
    age [--encrypt] --passphrase [-a] [-o OUTPUT] [INPUT]
    age --decrypt [-i PATH] [-o OUTPUT] [INPUT]

Encrypt or decrypt a file in the age format (age-encryption.org/v1).

Options:
    -e, --encrypt               Encrypt the input (the default).
    -d, --decrypt               Decrypt the input.
    -o, --output OUTPUT         Write the result to OUTPUT (default: stdout).
    -a, --armor                 Encrypt to a PEM-encoded ("armored") format.
    -p, --passphrase            Encrypt with a passphrase.
    -r, --recipient RECIPIENT   Encrypt to the explicit RECIPIENT. May be repeated.
    -R, --recipients-file PATH  Encrypt to the recipients listed in PATH. May be repeated.
    -i, --identity PATH         Use the identity file at PATH. May be repeated.
        --max-work-factor N     Cap the scrypt work factor when decrypting.
    -h, --help                  Print this help message and exit.

INPUT defaults to standard input. Use "-" to mean standard input/output explicitly.

RECIPIENT is an age public key ("age1...") or an SSH public key
("ssh-ed25519 ..."). PATH for -i is an age identity file or an SSH private key.
`;

/// Usage text for the `age-keygen` tool. Printed to standard output on `-h`/`--help`.
enum string keygenUsage =
`Usage:
    age-keygen [-o OUTPUT]
    age-keygen -y [-o OUTPUT] [INPUT]

Generate a new age identity, or convert an identity file to its recipients.

Options:
    -o, --output OUTPUT  Write the result to OUTPUT (default: stdout).
    -y                   Convert the identity file INPUT to a recipients list.
    -h, --help           Print this help message and exit.

Without -y, a fresh X25519 identity is generated (a file is created with mode
0600 and is never overwritten). With -y, INPUT (or standard input) is read and
one "age1..." recipient is written per identity.
`;

@("cli.usage.requestedHelp.detects")
@safe pure nothrow @nogc
unittest
{
    assert(requestedHelp(["age", "--help"]));
    assert(requestedHelp(["age", "-h"]));
    assert(requestedHelp(["age", "-d", "-i", "k", "--help"]));
    assert(requestedHelp(["age-keygen", "-h"]));
}

@("cli.usage.requestedHelp.absent")
@safe pure nothrow @nogc
unittest
{
    assert(!requestedHelp(["age"]));
    assert(!requestedHelp(["age", "-e", "-r", "age1abc", "in.txt"]));
    assert(!requestedHelp(["age-keygen", "-o", "key.txt"]));
    // A program name of "-h" alone (no args) is not a help request.
    assert(!requestedHelp(["age"]));
}

@("cli.usage.text.coversFlags")
@safe pure nothrow @nogc
unittest
{
    import std.algorithm.searching : canFind;

    // The age usage mentions each documented flag.
    foreach (flag; ["--encrypt", "--decrypt", "--passphrase", "--armor",
            "--recipient", "--recipients-file", "--identity", "--output",
            "--max-work-factor", "--help"])
        assert(ageUsage.canFind(flag), flag);

    foreach (flag; ["-o", "-y", "-h"])
        assert(keygenUsage.canFind(flag), flag);
}
