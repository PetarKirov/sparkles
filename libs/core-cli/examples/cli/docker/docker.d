#!/usr/bin/env dub
/+ dub.sdl:
    name "docker"
    dependency "sparkles:core-cli" path="../../../../.."
    targetPath "build"
+/
// ci: build-only

import sparkles.core_cli.args;
import sparkles.core_cli.prettyprint : prettyPrint;
import std.sumtype;

private enum string[] restartPolicies = [
    "no", "on-failure", "always", "unless-stopped",
];

// ─── shared run-options mixin ────────────────────────────────────────────

private mixin template ContainerRunFields()
{
    @(Option(`d|detach`, description: "Run the container in the background and print its ID"))
    bool detach;

    @(Option(`i|interactive`, description: "Keep STDIN open even if not attached"))
    bool interactive;

    @(Option(`t|tty`, description: "Allocate a pseudo-TTY"))
    bool tty;

    @(Option(`name`, description: "Assign a name to the container"))
    string name;

    @(Option(`e|env`, description: "Set environment variables in the container. Can be specified multiple times."))
    string[] env;

    @(Option(`v|volume`, description: "Bind-mount a volume into the container. Can be specified multiple times."))
    string[] volumes;

    @(Option(`p|publish`, description: "Publish a container port to the host. Can be specified multiple times."))
    string[] publish;

    @(Option(`l|label`, description: "Set metadata on the container. Can be specified multiple times."))
    string[] labels;

    @(Option(`network`, description: "Connect the container to a named network"))
    string network;

    @(Option(`restart`, allowedValues: restartPolicies))
    string restart = "no";

    @(Option(`rm`, description: "Automatically remove the container when it exits"))
    bool autoRemove;

    @(Argument("image"))
    string image;

    @(Argument("command", optional: true))
    string[] command;
}

// ─── container group ─────────────────────────────────────────────────────

@(Command("run",
    shortDescription: "Create and run a new container from an image",
    helpSections: ["description"],
))
struct ContainerRun
{
    mixin ContainerRunFields;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker container run with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("ls",
    aliases: ["ps"],
    shortDescription: "List containers",
    helpSections: ["description"],
))
struct ContainerLs
{
    @(Option(`a|all`, description: "Show all containers (default shows just running)"))
    bool all;

    @(Option(`q|quiet`, description: "Only display container IDs"))
    bool quiet;

    @(Option(`f|filter`, description: "Filter output based on conditions provided. Can be specified multiple times."))
    string[] filters;

    @(Option(`format`, description: "Pretty-print containers using a Go template"))
    string format;

    @(Option(`s|size`, description: "Display total file sizes"))
    bool size;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker container ls with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("stop",
    shortDescription: "Stop one or more running containers",
    helpSections: ["description"],
))
struct ContainerStop
{
    @(Option(`t|time`, description: "Seconds to wait for stop before killing the container"))
    int time = 10;

    @(Argument("containers"))
    string[] containers;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker container stop with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("rm",
    shortDescription: "Remove one or more containers",
    helpSections: ["description"],
))
struct ContainerRm
{
    @(Option(`f|force`, description: "Force-remove a running container (uses SIGKILL)"))
    bool force;

    @(Option(`v|volumes`, description: "Remove anonymous volumes associated with the container"))
    bool volumes;

    @(Argument("containers"))
    string[] containers;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker container rm with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("exec",
    shortDescription: "Run a command in a running container",
    helpSections: ["description"],
))
struct ContainerExec
{
    @(Option(`d|detach`, description: "Detached mode: run the command in the background"))
    bool detach;

    @(Option(`i|interactive`, description: "Keep STDIN open"))
    bool interactive;

    @(Option(`t|tty`, description: "Allocate a pseudo-TTY"))
    bool tty;

    @(Option(`u|user`, description: "Username or UID inside the container"))
    string user;

    @(Option(`w|workdir`, description: "Working directory inside the container"))
    string workdir;

    @(Option(`e|env`, description: "Set environment variables. Can be specified multiple times."))
    string[] env;

    @(Argument("container"))
    string container;

    @(Argument("command"))
    string[] command;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker container exec with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("logs",
    shortDescription: "Fetch the logs of a container",
    helpSections: ["description"],
))
struct ContainerLogs
{
    @(Option(`f|follow`, description: "Follow log output as it is produced"))
    bool follow;

    @(Option(`t|timestamps`, description: "Show timestamps on every log line"))
    bool timestamps;

    @(Option(`since`, description: "Show logs since timestamp (e.g. 2024-01-01) or relative (e.g. 42m for 42 minutes)"))
    string since;

    @(Option(`until`, description: "Show logs before the given timestamp"))
    string until;

    @(Option(`n|tail`, description: "Number of lines to show from the end of the logs (default: all)"))
    string tail = "all";

    @(Argument("container"))
    string container;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker container logs with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("container",
    shortDescription: "Manage containers",
    helpSections: ["description"],
))
struct Container
{
    @Subcommands
    SumType!(
        ContainerExec,
        ContainerLogs,
        ContainerLs,
        ContainerRm,
        ContainerRun,
        ContainerStop,
    ) command;
}

// ─── image group ─────────────────────────────────────────────────────────

@(Command("build",
    shortDescription: "Build an image from a Dockerfile",
    helpSections: ["description"],
))
struct ImageBuild
{
    @(Option(`t|tag`, description: "Name (and optionally tag) for the built image. Can be specified multiple times."))
    string[] tags;

    @(Option(`f|file`, description: "Name of the Dockerfile to use (default: PATH/Dockerfile)"))
    string file;

    @(Option(`build-arg`, description: "Set build-time variables. Can be specified multiple times."))
    string[] buildArgs;

    @(Option(`no-cache`, description: "Do not use cache when building the image"))
    bool noCache;

    @(Option(`pull`, description: "Always attempt to pull a newer version of each base image"))
    bool pull;

    @(Option(`target`, description: "Set the target build stage for multi-stage builds"))
    string target;

    @(Option(`platform`, description: "Set the target platform for the build (e.g. linux/amd64)"))
    string platform;

    @(Argument("path"))
    string path;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker image build with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("ls",
    aliases: ["list"],
    shortDescription: "List images",
    helpSections: ["description"],
))
struct ImageLs
{
    @(Option(`a|all`, description: "Show all images including intermediate layers"))
    bool all;

    @(Option(`q|quiet`, description: "Only display image IDs"))
    bool quiet;

    @(Option(`digests`, description: "Show image digests"))
    bool digests;

    @(Option(`f|filter`, description: "Filter output. Can be specified multiple times."))
    string[] filters;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker image ls with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("pull",
    shortDescription: "Download an image from a registry",
    helpSections: ["description"],
))
struct ImagePull
{
    @(Option(`a|all-tags`, description: "Download all tagged images in the repository"))
    bool allTags;

    @(Option(`q|quiet`, description: "Suppress verbose output"))
    bool quiet;

    @(Option(`platform`, description: "Set the platform if the server supports multi-platform images"))
    string platform;

    @(Argument("image"))
    string image;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker image pull with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("push",
    shortDescription: "Upload an image to a registry",
    helpSections: ["description"],
))
struct ImagePush
{
    @(Option(`a|all-tags`, description: "Push all tagged images in the repository"))
    bool allTags;

    @(Option(`q|quiet`, description: "Suppress verbose output"))
    bool quiet;

    @(Argument("image"))
    string image;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker image push with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("rm",
    aliases: ["rmi"],
    shortDescription: "Remove one or more images",
    helpSections: ["description"],
))
struct ImageRm
{
    @(Option(`f|force`, description: "Force-remove the image even if it has tags or running containers"))
    bool force;

    @(Option(`no-prune`, description: "Do not delete untagged parent layers"))
    bool noPrune;

    @(Argument("images"))
    string[] images;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker image rm with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("image",
    shortDescription: "Manage images",
    helpSections: ["description"],
))
struct Image
{
    @Subcommands
    SumType!(ImageBuild, ImageLs, ImagePull, ImagePush, ImageRm) command;
}

// ─── network group ───────────────────────────────────────────────────────

@(Command("create",
    shortDescription: "Create a network",
    helpSections: ["description"],
))
struct NetworkCreate
{
    @(Option(`d|driver`, allowedValues: ["bridge", "overlay", "host", "macvlan", "none"]))
    string driver = "bridge";

    @(Option(`subnet`, description: "Subnet in CIDR format that represents a network segment. Can be specified multiple times."))
    string[] subnets;

    @(Option(`gateway`, description: "IPv4/IPv6 gateway for the master subnet. Can be specified multiple times."))
    string[] gateways;

    @(Option(`l|label`, description: "Set metadata on the network. Can be specified multiple times."))
    string[] labels;

    @(Option(`internal`, description: "Restrict external access to the network"))
    bool internal;

    @(Argument("name"))
    string name;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker network create with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("ls",
    aliases: ["list"],
    shortDescription: "List networks",
    helpSections: ["description"],
))
struct NetworkLs
{
    @(Option(`q|quiet`, description: "Only display network IDs"))
    bool quiet;

    @(Option(`f|filter`, description: "Filter output. Can be specified multiple times."))
    string[] filters;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker network ls with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("inspect",
    shortDescription: "Display detailed information on one or more networks",
    helpSections: ["description"],
))
struct NetworkInspect
{
    @(Option(`f|format`, description: "Format the output using a Go template"))
    string format;

    @(Option(`v|verbose`, description: "Verbose output for diagnostics"))
    bool verbose;

    @(Argument("networks"))
    string[] networks;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker network inspect with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("connect",
    shortDescription: "Connect a container to a network",
    helpSections: ["description"],
))
struct NetworkConnect
{
    @(Option(`alias`, description: "Add a network-scoped alias for the container. Can be specified multiple times."))
    string[] aliases;

    @(Option(`ip`, description: "IPv4 address (e.g. 172.30.100.104) to assign to the container"))
    string ip;

    @(Argument("network"))
    string network;

    @(Argument("container"))
    string container;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker network connect with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("rm",
    aliases: ["remove"],
    shortDescription: "Remove one or more networks",
    helpSections: ["description"],
))
struct NetworkRm
{
    @(Option(`f|force`, description: "Do not error out when a network does not exist"))
    bool force;

    @(Argument("networks"))
    string[] networks;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker network rm with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("network",
    shortDescription: "Manage networks",
    helpSections: ["description"],
))
struct Network
{
    @Subcommands
    SumType!(NetworkConnect, NetworkCreate, NetworkInspect, NetworkLs, NetworkRm) command;
}

// ─── volume group ────────────────────────────────────────────────────────

@(Command("create",
    shortDescription: "Create a volume",
    helpSections: ["description"],
))
struct VolumeCreate
{
    @(Option(`d|driver`, allowedValues: ["local", "nfs", "tmpfs"]))
    string driver = "local";

    @(Option(`o|opt`, description: "Set driver-specific options. Can be specified multiple times."))
    string[] driverOpts;

    @(Option(`l|label`, description: "Set metadata on the volume. Can be specified multiple times."))
    string[] labels;

    @(Argument("name", optional: true))
    string name;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker volume create with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("ls",
    aliases: ["list"],
    shortDescription: "List volumes",
    helpSections: ["description"],
))
struct VolumeLs
{
    @(Option(`q|quiet`, description: "Only display volume names"))
    bool quiet;

    @(Option(`f|filter`, description: "Filter output. Can be specified multiple times."))
    string[] filters;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker volume ls with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("inspect",
    shortDescription: "Display detailed information on one or more volumes",
    helpSections: ["description"],
))
struct VolumeInspect
{
    @(Option(`f|format`, description: "Format the output using a Go template"))
    string format;

    @(Argument("volumes"))
    string[] volumes;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker volume inspect with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("prune",
    shortDescription: "Remove all unused local volumes",
    helpSections: ["description"],
))
struct VolumePrune
{
    @(Option(`f|force`, description: "Do not prompt for confirmation"))
    bool force;

    @(Option(`a|all`, description: "Remove all unused volumes, not just anonymous ones"))
    bool all;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker volume prune with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("rm",
    aliases: ["remove"],
    shortDescription: "Remove one or more volumes",
    helpSections: ["description"],
))
struct VolumeRm
{
    @(Option(`f|force`, description: "Force the removal of one or more volumes"))
    bool force;

    @(Argument("volumes"))
    string[] volumes;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker volume rm with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("volume",
    shortDescription: "Manage volumes",
    helpSections: ["description"],
))
struct Volume
{
    @Subcommands
    SumType!(VolumeCreate, VolumeInspect, VolumeLs, VolumePrune, VolumeRm) command;
}

// ─── system group ────────────────────────────────────────────────────────

@(Command("df",
    shortDescription: "Show docker disk usage",
    helpSections: ["description"],
))
struct SystemDf
{
    @(Option(`v|verbose`, description: "Show detailed information on space usage"))
    bool verbose;

    @(Option(`format`, description: "Format the output using a Go template"))
    string format;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker system df with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("prune",
    shortDescription: "Remove unused data",
    helpSections: ["description"],
))
struct SystemPrune
{
    @(Option(`f|force`, description: "Do not prompt for confirmation"))
    bool force;

    @(Option(`a|all`, description: "Remove all unused images, not just dangling ones"))
    bool all;

    @(Option(`volumes`, description: "Prune anonymous volumes too"))
    bool volumes;

    @(Option(`filter`, description: "Provide filter values (e.g. 'label=foo'). Can be specified multiple times."))
    string[] filters;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker system prune with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("info",
    shortDescription: "Display system-wide information",
    helpSections: ["description"],
))
struct SystemInfo
{
    @(Option(`f|format`, description: "Format the output using a Go template"))
    string format;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker system info with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("events",
    shortDescription: "Stream real-time events from the docker daemon",
    helpSections: ["description"],
))
struct SystemEvents
{
    @(Option(`since`, description: "Show events created since timestamp"))
    string since;

    @(Option(`until`, description: "Stream events until timestamp"))
    string until;

    @(Option(`f|filter`, description: "Filter events. Can be specified multiple times."))
    string[] filters;

    @(Option(`format`, description: "Format the output using a Go template"))
    string format;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker system events with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("system",
    shortDescription: "Manage Docker",
    helpSections: ["description"],
))
struct System
{
    @Subcommands
    SumType!(SystemDf, SystemEvents, SystemInfo, SystemPrune) command;
}

// ─── top-level shortcut commands ─────────────────────────────────────────

@(Command("run",
    shortDescription: "Create and run a new container from an image (alias for `container run`)",
    helpSections: ["description"],
))
struct Run
{
    mixin ContainerRunFields;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker run with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("ps",
    shortDescription: "List containers (alias for `container ls`)",
    helpSections: ["description"],
))
struct Ps
{
    @(Option(`a|all`, description: "Show all containers (default shows just running)"))
    bool all;

    @(Option(`q|quiet`, description: "Only display container IDs"))
    bool quiet;

    @(Option(`f|filter`, description: "Filter output based on conditions provided. Can be specified multiple times."))
    string[] filters;

    @(Option(`format`, description: "Pretty-print containers using a Go template"))
    string format;

    @(Option(`s|size`, description: "Display total file sizes"))
    bool size;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker ps with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("images",
    shortDescription: "List images (alias for `image ls`)",
    helpSections: ["description"],
))
struct Images
{
    @(Option(`a|all`, description: "Show all images including intermediate layers"))
    bool all;

    @(Option(`q|quiet`, description: "Only display image IDs"))
    bool quiet;

    @(Option(`digests`, description: "Show image digests"))
    bool digests;

    @(Option(`f|filter`, description: "Filter output. Can be specified multiple times."))
    string[] filters;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker images with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("rm",
    shortDescription: "Remove one or more containers (alias for `container rm`)",
    helpSections: ["description"],
))
struct Rm
{
    @(Option(`f|force`, description: "Force-remove a running container (uses SIGKILL)"))
    bool force;

    @(Option(`v|volumes`, description: "Remove anonymous volumes associated with the container"))
    bool volumes;

    @(Argument("containers"))
    string[] containers;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker rm with params:");
        writeln(prettyPrint(this));
    }
}

@(Command("rmi",
    shortDescription: "Remove one or more images (alias for `image rm`)",
    helpSections: ["description"],
))
struct Rmi
{
    @(Option(`f|force`, description: "Force-remove the image even if it has tags or running containers"))
    bool force;

    @(Option(`no-prune`, description: "Do not delete untagged parent layers"))
    bool noPrune;

    @(Argument("images"))
    string[] images;

    void run()
    {
        import std.stdio : writeln;
        writeln("Running docker rmi with params:");
        writeln(prettyPrint(this));
    }
}

// ─── root ────────────────────────────────────────────────────────────────

@(Command("docker",
    shortDescription: "A self-sufficient runtime for containers",
    helpSections: ["description", "examples"],
))
struct Docker
{
    @(Option(`H|host`, description: "Daemon socket(s) to connect to. Can be specified multiple times."))
    string[] hosts;

    @(Option(`l|log-level`, allowedValues: ["debug", "info", "warn", "error", "fatal"]))
    string logLevel = "info";

    @(Option(`D|debug`, description: "Enable debug mode"))
    bool debug_;

    @Subcommands
    SumType!(
        Container,
        Image,
        Images,
        Network,
        Ps,
        Rm,
        Rmi,
        Run,
        System,
        Volume,
    ) command;
}

int main(string[] args)
{
    return runCli!Docker(args);
}
