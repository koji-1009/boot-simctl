# Notes for agents working on this repo

A composite GitHub Action that boots an iOS Simulator, implemented as one POSIX shell script. The constraint that matters most is: **do not add dependencies.** The allowed toolbox is `xcrun`, `plutil`, and POSIX `sed` / `awk` / `sort` / `ps` / `mktemp`.

```
action.yml                     composite action wrapping the script
shutdown/action.yml            clean-up action; composite actions cannot post
boot-simctl                    the whole implementation
test/test.sh                   the test suite; --all also boots real simulators
test/candidates-fixture.tsv    candidate list used by the selection tests
README.md                      for people using the action
docs/README.ja.md              same, in Japanese; keep the two in step
.github/workflows/ci.yml       CI; also the only test of action.yml
```

The action is the product; the script is how it is implemented. A change to the script's options is not shipped until `action.yml` passes it through, and the only thing that catches broken wiring is `uses: ./` in ci.yml — nothing local can run a composite action.

Action inputs reach the script as `env:` variables, never as `${{ }}` expanded into `run:`, so a model name containing quotes cannot break out of the command. Keep it that way. Optional flags are appended with `set --` because POSIX sh has no arrays.

Run `./test/test.sh` after any change, and `./test/test.sh --all` before committing. The slow run takes a few minutes and boots three simulators; it cleans up after itself and asserts that it did.

## Design

Every "iOS version × model" pairing the machine can run is built into one list, ordered newest iOS first and, within a version, in simctl's own model order (newest first). Options narrow the list through `narrow`; the first survivor wins. Keep this shape — it is what lets a failure name the requirement that emptied the list and show what could have satisfied it.

Every list-shaped output — `list candidates`, `list runtimes`, `list devicetypes`, `--dry-run` — is the same tab-separated row format, so callers can `cut` columns out of any of them. Do not space-separate: model names contain spaces.

The list comes from each runtime's `supportedDeviceTypes`, which contains exactly the pairings CoreSimulator accepts. Nothing needs to guess compatibility, and there is no create-and-retry fallback because there is nothing to fall back from.

Devices are created fresh on every run rather than reused, which is why no `simctl erase` is needed.

## simctl facts

All verified by running it. They cost real time to rediscover.

**Documentation does not exist.** There is no `simctl` man page. `simctl help` and `simctl help <subcommand>` are the entire reference, and neither documents the JSON schema.

**JSON is available only on `list`** (`-j` / `--json`, plus `--json-fd` and `--json-output`). None of the other ~35 subcommands emit JSON.

**Field names read from JSON**, all by name, never by position:

| Payload | Fields |
| --- | --- |
| `list runtimes --json` | `platform`, `isAvailable`, `version`, `identifier`, and each `supportedDeviceTypes` entry's `name`, `identifier`, `productFamily` |
| `list devices --json` | dictionary keyed by runtime identifier; each device's `name`, `udid`, `state`, `isAvailable` |

Both are flat objects one level deep, so `awk` can split them on the object boundary without a real JSON parser. Do not reintroduce text parsing of human-readable output; `list devices` without `--json` is used only to *display* a list to the user.

**Version numbers are truncated everywhere except the JSON `version` field.** A runtime that is really 26.4.1 displays as `iOS 26.4` and identifies as `...SimRuntime.iOS-26-4`. Only `version` (or the parenthesised value in `list runtimes` text output) carries the third component. Deriving a version from the identifier loses it.

**Listing order is inconsistent.** `list runtimes` is ascending (oldest first). `list devicetypes` is descending (newest first). So "take the head of the list" gives the oldest iOS and the newest model. The script sorts versions explicitly for this reason; the test fixture is deliberately written oldest-first so that a regression in the sort fails the tests.

**`list devices available` still prints `-- Unavailable: ... --` sections.** The `available` filter does not remove them from the text output.

**`list <type> <search term>` matches a case-insensitive substring of the item's description.** A runtime identifier does not appear in a device's description, so filtering devices by runtime identifier silently yields only section headers. Filter in the script, not in simctl.

**`bootstatus <udid> -b` boots and waits in one call, and is idempotent** — 0.2s when already booted, 19–23s for a cold boot here. Plain `boot` is *not* idempotent; it fails on an already-booted device, which `--reuse` can produce.

**Exit codes**: 145 invalid runtime, 147 incompatible device, 148 invalid device. Error messages go to **stdout**, so piping to `tail` and reading `$?` gives you the exit status of `tail`, not of simctl.

**A booted device is not necessarily ready to launch apps.** On a GitHub runner, `simctl openurl` timed out (exit 60) on an iPad that `bootstatus -b` had reported as finished. There is no known signal for app-launch readiness; if a caller needs one, it belongs to the app, not here.

A CPU-quiet heuristic used to sit after boot, ported from `simulator-action`: wait until the total CPU of `launchd_sim`'s children stays under a threshold. It was removed. On GitHub runners three of four jobs never met the threshold, the one that did went on to fail at launching an app anyway, and each job spent 161-237s there. Do not reintroduce it without evidence that waiting changes an outcome.

**`xcrun` execs `simctl` rather than forking it.** `$!` after `xcrun simctl ... &` is simctl's own pid, so `kill -TERM` reaches it and leaves no orphan. Verified: no simctl process survives a timeout kill.

## Environment gotchas

**macOS has no `timeout(1)`.** `boot_and_wait` implements it with a background job plus a polling loop, measuring elapsed time with `date +%s`. Never count sleeps instead: whatever the loop body does is unpaid time. A wait that counted sleeps once overran a 120s limit by 41s, because each pass sampled `ps` over every process on the machine.

**BSD `grep` does not honour `\|` as BRE alternation.** `grep -c '^iPhone$\|^iPad$'` silently matched only one of the two alternatives here and produced a false test failure. Use `grep -E`.

**`/bin/sh` is bash 3.2 in sh mode.** Keep to POSIX; no arrays, no `[[`, no `<<<`, no `local`.

**Nothing here has been through `shellcheck`.** Run it if you have it.

**If every simctl call fails** with `CoreSimulatorService connection became invalid`, the process is sandboxed away from XPC. That is the sandbox, not the script.

## Testing

`BOOT_SIMCTL_CANDIDATES_FILE` replaces the candidate list with a fixture, which is how version and model combinations no single machine has installed get tested. It is a test hook; do not use it for anything else.

The tests deliberately verify results by parsing simctl's *text* output, while the script parses JSON. Keeping the two independent means a change that breaks one is not masked by the same change breaking the other.

`--boot-timeout 1` reliably exercises the timeout-and-retry path, including that the failed device is left shut down and no simctl process leaks.

**Known untested path:** the retry branch for `bootstatus` failing for a reason *other* than timeout. There is no reliable way found so far to provoke it.

**Never verified on a GitHub-hosted runner.** Everything here was checked on one machine (macOS 26.6, Xcode 26.6, iOS 18.6 and 26.5 runtimes). Runners carry several Xcodes and a different simulator lineup, so `ci.yml` passing is the real proof.

## Releasing

Releases are immutable and there is no moving `v1` tag: a fix ships as a new version, never as a repointed tag. Update the version in both READMEs when releasing.

## Conventions

Findings, rationale, and background go in this file, not in code comments. A comment states what a function takes and returns, or names the one constraint a line is working around, in a single line.

The two READMEs must stay in step. English is the source; `docs/README.ja.md` is the translation. Both are for people using the script — implementation detail belongs here.
