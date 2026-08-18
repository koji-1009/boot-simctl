# boot-simctl

[![CI](https://github.com/koji-1009/boot-simctl/actions/workflows/ci.yml/badge.svg)](https://github.com/koji-1009/boot-simctl/actions/workflows/ci.yml)

Boot an iPhone or iPad simulator in GitHub Actions. A composite action wrapping one POSIX shell script, which calls `xcrun simctl` and uses `plutil` and POSIX `sed` / `awk` / `sort` / `ps`.

*日本語版は [docs/README.ja.md](docs/README.ja.md) にあります。*

```yaml
- id: sim
  uses: koji-1009/boot-simctl@v1.0.0
  with:
    device: iPhone
    os: '26.1'

- run: xcodebuild test -destination "id=${{ steps.sim.outputs.udid }}" ...

- if: always() && steps.sim.outputs.udid != ''
  uses: koji-1009/boot-simctl/shutdown@v1.0.0
  with:
    udid: ${{ steps.sim.outputs.udid }}
```

`actions/checkout` is not required — the action carries its own script.

## Inputs

The action is a thin wrapper, so every input is one option of the script.

| Input | Option | Default | Description |
| --- | --- | --- | --- |
| `device` | `--device` | `iPhone` | `iPhone` or `iPad`. Ignored when a model is set |
| `os` | `--os` | any | iOS version requirement (see below) |
| `xcode-version` | `--xcode` | current | Xcode to select first, same syntax. Sets `DEVELOPER_DIR` for the rest of the job |
| `model` | `--model` | none | Exact model name, e.g. `iPhone 17 Pro`. Takes precedence over `device` |
| `name` | `--name` | `ci-simulator` | Name of the simulator to create |
| `reuse` | `--reuse` | `false` | Reuse an existing simulator of that name **and** iOS version |
| `wait` | `--no-wait` | `true` | Wait for the boot to finish. When off, the rows below do not apply |
| `boot-timeout` | `--boot-timeout` | `360` | Seconds allowed for one boot attempt; `0` disables the limit |
| `boot-retries` | `--boot-retries` | `2` | Retries after a failed boot |
| `settle-timeout` | `--settle-timeout` | `0` | Seconds to wait for background daemons to quiet down; `0` skips the wait |
| `settle-cpu` | `--settle-cpu` | `20` | CPU percentage below which the device counts as settled |
| `settle-samples` | `--settle-samples` | `3` | Consecutive samples required below the threshold |
| `settle-interval` | `--settle-interval` | `2` | Seconds between settle samples |

The only output is `udid`. The script additionally takes `--dry-run`, which prints the narrowed list and exits.

The `shutdown` action takes `udid` (required) and `keep` (default `false`, delete after stopping). It is a separate action because a composite action cannot register a post step, so clean-up has to be a step you write.

## Running the script directly

```sh
boot-simctl boot [options]
boot-simctl shutdown [--keep] <udid-or-name>
boot-simctl list [runtimes|devicetypes|devices|candidates|xcodes]
```

On success the UDID is printed on stdout as the only line. Every diagnostic goes to stderr, so `udid=$(./boot-simctl boot ...)` works directly.

## How a device is chosen

This is what both the action and the script do; the inputs above map one-to-one onto the options below.

Every "iOS version × model" pairing the machine can actually run is collected into one list. Each option you pass narrows that list, and the **first surviving entry wins**. The list is ordered newest iOS first and, within one iOS version, in the order Xcode itself lists models — newest first.

| Options | What you get |
| --- | --- |
| (none) | newest iPhone on the newest iOS |
| `--device iPad` | newest iPad on the newest iOS |
| `--os 26.1` | newest iPhone on the newest 26.1.x |
| `--os 26.1 --model "iPhone 17"` | exactly that pairing |

`--model` overrides `--device`. Given a model alone, you get the newest iOS that can run it.

`list candidates` prints the whole list. `--dry-run` prints what survived the narrowing — the chosen entry first — without creating or booting anything. Both emit the same tab-separated columns, so `cut -f4` and friends work on either.

```
$ ./boot-simctl boot --device iPad --os '>=26' --dry-run
26.5	…SimRuntime.iOS-26-5	iPad	iPad Pro 13-inch (M5) (16GB)	…SimDeviceType.iPad-Pro-13-inch-M5-16GB
26.5	…SimRuntime.iOS-26-5	iPad	iPad Pro 13-inch (M5)	…SimDeviceType.iPad-Pro-13-inch-M5-12GB
…
```

Only pairings that CoreSimulator actually accepts are ever in the list. A combination that cannot work — iPhone 17 on iOS 18.6, say — never appears, so a run never fails because you asked for a device that does not exist on the version you asked for.

When the narrowing empties the list, the failure names the requirement that emptied it and shows what was still on the table.

```
$ ./boot-simctl boot --os 26.1
boot-simctl: available iOS versions:
  26.5
  18.6
boot-simctl: no iOS version satisfies '26.1'
```

### Version requirements

`--os` takes a version prefix or a comparison. Space-separated requirements are ANDed.

| Spec | Meaning |
| --- | --- |
| `26` | any 26.x.y |
| `26.1` | any 26.1.x |
| `26.1.1` | exactly 26.1.1 |
| `>=26.1` | 26.1.0 or newer |
| `<26.5` | older than 26.5 |
| `">=26.0 <26.5"` | both must hold |

`>`, `<`, `>=` and `<=` are available. Prefixes stop at dot boundaries: `2` does not match 26.5, and `26.1` does not match 26.10.

There is no `^` or `~`. A prefix already means what `~` would: `26.1` is exactly `>=26.1.0 <26.2`.

Three-component versions are worth knowing about. Xcode shows a runtime as `iOS 26.4` even when what is installed is really 26.4.1, so a runner can carry a version you cannot name anywhere it is displayed. `--os 26.4.1` and `--os 26.4.0` select different things here, and `--os 26.4` takes either.

## Notes for CI

The simulator is created fresh with `simctl create` on every run, so its state is always clean and no `simctl erase` is needed. If one of the same name is left over, it is deleted before the new one is created, so a previous job's debris cannot break the next run.

Which runtimes are on offer depends on the selected Xcode, so `xcode-version` runs first and the rest of the job inherits it through `DEVELOPER_DIR`. No `sudo` and no `xcode-select` involved.

```yaml
- id: sim
  uses: koji-1009/boot-simctl@v1.0.0
  with:
    xcode-version: '26.5'
    os: '26'

- run: xcodebuild test -destination "id=${{ steps.sim.outputs.udid }}" ...
```

Versions are read from each bundle's `version.plist`, not from its path, so the naming a runner image uses for `/Applications/Xcode*.app` does not matter. `list xcodes` shows what is installed.

If the runner has no runtime for the version you need, `xcodebuild -downloadPlatform iOS -buildVersion 26.1` fetches one. Expect a multi-gigabyte download.

## Tests

```sh
./test/test.sh          # selection logic and argument handling (seconds)
./test/test.sh --all    # also boots real simulators (minutes)
```

## Limitations

`shutdown` deletes the device after stopping it. Pass `--keep` to stop it only. It assumes disposable CI simulators, so take care not to hand it the name of a simulator you actually use.

Only iPhone and iPad are supported. Apple TV and Apple Watch are not.
