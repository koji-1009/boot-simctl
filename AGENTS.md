# Notes for agents working on this repo

A composite GitHub Action that boots a simulator, implemented as one POSIX shell script. **Do not add dependencies.** The allowed toolbox is `xcrun`, `plutil`, and POSIX `sed` / `awk` / `sort` / `ps` / `mktemp`.

```
action.yml                     composite action wrapping the script
shutdown/action.yml            clean-up action; composite actions cannot post
boot-simctl                    the whole implementation
test/test.sh                   the test suite; --all also boots real simulators
test/candidates-fixture.tsv    candidate list used by the selection tests
test/runtimes-fixture.json     captured simctl JSON, for the parser tests
README.md                      for people using the action
docs/README.ja.md              same, in Japanese; keep the two in step
.github/workflows/ci.yml       CI; also the only test of action.yml
```

A change to the script's options is not shipped until `action.yml` passes it through, and only `uses: ./` in ci.yml catches broken wiring — nothing local can run a composite action.

Action inputs reach the script as `env:` variables, never as `${{ }}` expanded into `run:`. Optional flags are appended with `set --`, since POSIX sh has no arrays.

Results go out through `GITHUB_ENV`: `SIMULATOR_UDID`, `SIMULATOR_MODEL`, `SIMULATOR_PLATFORM`, `SIMULATOR_OS`, and `DEVELOPER_DIR` when an Xcode was selected. Anything the selection resolves belongs there.

Run `./test/test.sh` after any change, and `./test/test.sh --all` before committing.

## Design

Every "OS version × model" pairing the machine can run is built into one list, ordered newest OS first and, within a version, in simctl's own model order. Options narrow the list through `narrow`; the first survivor wins. Keep this shape — it is what lets a failure name the requirement that emptied the list.

Every list-shaped output — `list candidates`, `list runtimes`, `list devicetypes`, `--dry-run` — is the same tab-separated row format. Do not space-separate: model names contain spaces.

The list comes from each runtime's `supportedDeviceTypes`, which contains exactly the pairings CoreSimulator accepts, with `productFamily` on each. Nothing has to guess compatibility, and tvOS and watchOS need no special casing.

Devices are created fresh on every run, so no `simctl erase` is needed.

`SIM_NAME` is a constant and every boot deletes that name first, so **one simulator per job**: a second boot destroys the first device and overwrites `SIMULATOR_UDID`. Two jobs sharing a self-hosted runner collide the same way.

## simctl facts

**Documentation does not exist.** There is no `simctl` man page; `simctl help` is the entire reference and does not cover the JSON schema.

**JSON is available only on `list`** (`-j` / `--json`, plus `--json-fd` and `--json-output`).

**Field names read from JSON**, all by name, never by position:

| Payload | Fields |
| --- | --- |
| `list runtimes --json` | `platform`, `isAvailable`, `version`, `identifier`, and each `supportedDeviceTypes` entry's `name`, `identifier`, `productFamily` |
| `list devices --json` | dictionary keyed by runtime identifier; each device's `name`, `udid`, `state`, `isAvailable` |

Both are flat objects one level deep, which is why `awk` can split them without a real parser. If that stops holding, `plutil -extract` with a keypath per field survives nesting by construction, at about 4s per run instead of 0.2s. Do not parse human-readable output; `list devices` without `--json` is only for showing a list to the user.

**Version numbers are truncated everywhere except the JSON `version` field.** A runtime that is really 26.4.1 displays as `iOS 26.4` and identifies as `...SimRuntime.iOS-26-4`.

**Listing order is inconsistent.** `list runtimes` is ascending, `list devicetypes` descending, and `list devices --json` keys are in neither order. Sort explicitly. The candidate fixture is written oldest-first so a regression in the sort fails the tests.

**`list devices available` still prints `-- Unavailable: ... --` sections.**

**`list <type> <search term>` matches a case-insensitive substring of the item's description.** A runtime identifier is not in a device's description, so filtering devices by it yields only section headers.

**`bootstatus <udid> -b` boots and waits in one call, and is idempotent.** Plain `boot` is not; it fails on an already-booted device.

**Exit codes**: 145 invalid runtime, 147 incompatible device, 148 invalid device. Errors go to **stdout**, so piping to `tail` and reading `$?` gives you `tail`'s status.

**A booted device is not necessarily ready to launch apps.** `simctl openurl` has timed out on a device `bootstatus -b` reported as finished. There is no known readiness signal beyond boot.

**A CPU-quiet wait after boot does not work here.** On GitHub runners three of four jobs never met the threshold, the one that did still failed to launch an app, and each spent 161-237s. Do not reintroduce it without evidence that waiting changes an outcome.

**`xcrun` execs `simctl` rather than forking it**, so `$!` is simctl's own pid and `kill -TERM` reaches it.

## Environment gotchas

**macOS has no `timeout(1)`.** `boot_and_wait` uses a background job and a polling loop, measuring with `date +%s`. Never count sleeps: the loop body's own time goes unpaid, and a `ps` sample per pass is enough to overrun a limit by a third.

**BSD `grep` does not honour `\|` as BRE alternation.** Use `grep -E`.

**`/bin/sh` is bash 3.2 in sh mode.** Keep to POSIX; no arrays, no `[[`, no `<<<`, no `local`. `xpg_echo` is on, so `echo` expands `\t` and truncates at `\c` in whatever the caller passed: use `printf`.

**Never pass a value to awk with `-v`.** BSD awk rejects a newline in a `-v` assignment and re-processes backslash escapes in it. Put it in the environment and read `ENVIRON[]`.

**If every simctl call fails** with `CoreSimulatorService connection became invalid`, the process is sandboxed away from XPC.

## Testing

`shellcheck` runs in CI on `ubuntu-slim`, which ships it.

`BOOT_SIMCTL_CANDIDATES_FILE` replaces the candidate list with a fixture, covering combinations no single machine has installed. `BOOT_SIMCTL_RUNTIMES_JSON` feeds `build_candidates` a captured payload, since the candidate hook bypasses the JSON parsing. `BOOT_SIMCTL_BOOT_TIMEOUT` and `_RETRIES` reach the timeout path without a 360s wait. All are test hooks; the timeout is not a public option.

The tests read simctl's *text* output while the script reads JSON, so one breaking cannot mask the other.

**Known untested path:** the retry branch for `bootstatus` failing for a reason other than timeout. No reliable way to provoke it has been found.

## Releasing

Releases are immutable and there is no moving `v1` tag: a fix ships as a new version, never as a repointed tag. Update the version in both READMEs when releasing.

## Conventions

Code comments state what a function takes and returns, or the one constraint a line works around, in a single line. Everything else belongs here — and here means constraints and facts that change what the next change should be, not a record of how they were found.

The two READMEs must stay in step. English is the source; `docs/README.ja.md` is the translation. Both are for people using the action; implementation detail belongs here.
