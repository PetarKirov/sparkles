# Run and filter tests

Options go after `--`, exactly as with silly:

```bash
dub test :base                       # run everything, in parallel
dub test :base -- -i "SmallBuffer"   # only tests matching a regex
dub test :base -- -e "slow"          # skip tests matching a regex
dub test :base -- -v                 # durations, locations, full traces
dub test :base -- -t 1               # single-threaded
dub test :base -- -l                 # list tests without running them
```

## Filtering

`-i`/`-e` are regular expressions matched against
`<fully.qualified.symbol> <test name>` — so both `-i "smallbuffer"` (module)
and `-i "SmallBuffer.basic"` (name UDA) work. When both are given they combine:
a test must match `-i` **and** not match `-e`.

## Listing

`--list` prints every discovered test with its special-handling markers:

```console
$ dub test :test-runner -- -l
 sparkles.test_runner.discovery discovery.selfTest @betterC
 sparkles.test_runner.discovery discovery.moduleTests
 sparkles.test_runner.discovery.NestedCtfeHost discovery.nestedCtfe @ctfe
```

## Verbose output and source links

`-v` appends per-test durations and `[file:line]` locations. On a terminal,
locations are OSC 8 hyperlinks (`file://` URIs) when the tested package has
`sparkles:core-cli` in its dependency closure.

## The runner's own tests

The runner is compiled into every in-tree test build, so its self-tests are
discoverable everywhere; they are hidden unless you ask:

```bash
dub test :test-runner        # the runner's own suite (runs by default here)
dub test :base -- --self-test # base's tests + the runner's, in one process
```

## Exit status

The test binary exits non-zero when any test fails, in every mode — safe for
CI and `git bisect run`.
