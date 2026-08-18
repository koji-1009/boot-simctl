#!/bin/sh
#
# Tests for boot-simctl.
#
#   test/test.sh          selection logic and argument handling (fast)
#   test/test.sh --all    also boot real simulators (slow, several minutes)

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/../boot-simctl
FIXTURE=$HERE/candidates-fixture.tsv
XCODES=$HERE/xcodes-fixture.tsv
RUN_SLOW=0
[ "${1:-}" != "--all" ] || RUN_SLOW=1

passed=0
failed=0

ok()   { passed=$((passed + 1)); echo "  ok    $*"; }
fail() { failed=$((failed + 1)); echo "  FAIL  $*"; }

# choose <boot args...> -> "<ios version> / <model>", or "-" when nothing matches
choose() {
  if out=$(BOOT_SIMCTL_CANDIDATES_FILE=$FIXTURE "$SCRIPT" boot --dry-run "$@" 2>/dev/null); then
    printf '%s\n' "$out" | awk -F'\t' 'NR == 1 { print $1 " / " $4 }'
  else
    echo -
  fi
}

# expect <want> <boot args...>
expect() {
  want=$1
  shift
  got=$(choose "$@")
  if [ "$got" = "$want" ]; then
    ok "$* -> $got"
  else
    fail "$* -> got '$got', want '$want'"
  fi
}

# Uses the fixture too, so these do not depend on this machine's runtimes.
expect_fail() {
  desc=$1
  shift
  if BOOT_SIMCTL_CANDIDATES_FILE=$FIXTURE "$SCRIPT" "$@" >/dev/null 2>&1; then
    fail "$desc (expected non-zero exit)"
  else
    ok "$desc"
  fi
}

# eq <description> <got> <want>
eq() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    fail "$1 (got '$2', want '$3')"
  fi
}

# The fixture is written oldest-first, so a 26.x result also proves the reorder.
echo "priority: nothing set"
expect "26.5 / iPhone 17 Pro"           # newest iPhone on the newest iOS
expect "26.5 / iPad Pro 13-inch (M5)"   --device iPad

echo "priority: other device families"
expect "26.5 / Apple TV 4K (3rd generation)"  --device tv
expect "26.5 / Apple Watch Series 11 (46mm)"  --device watch
expect "26.2 / Apple TV 4K (3rd generation)"  --device tv --os 26.2
expect "26.5 / Apple Watch SE 3 (44mm)"       --model "Apple Watch SE 3 (44mm)"
expect "-"                                    --device tv --os 18
expect "-"                                    --device vision

echo "priority: iOS version set"
expect "26.1.1 / iPhone 17 Pro"         --os 26.1
expect "26.1.1 / iPhone 17 Pro"         --os 26.1.1
expect "-"                              --os 26.1.0
expect "26.0.1 / iPhone 17 Pro"         --os 26.0
expect "18.6 / iPhone 16 Pro"           --os 18
expect "26.2 / iPad Air 11-inch (M3)"   --device iPad --os 26.2
expect "18.6 / iPad Pro 13-inch (M4)"   --device iPad --os 18

echo "priority: model set"
expect "26.5 / iPhone Air"              --model "iPhone Air"
expect "26.4.1 / iPhone 17e"            --model "iPhone 17e"
expect "26.5 / iPad mini (A17 Pro)"     --model "iPad mini (A17 Pro)"
expect "26.5 / iPad mini (A17 Pro)"     --device iPhone --model "iPad mini (A17 Pro)"
expect "18.6 / iPhone SE (3rd generation)" --model "iPhone SE (3rd generation)"

echo "priority: iOS version and model set"
expect "26.1.1 / iPhone Air"            --os 26.1 --model "iPhone Air"
expect "26.5 / iPhone Air"              --os ">=26.2" --model "iPhone Air"
expect "-"                              --os 18 --model "iPhone 17 Pro"
expect "-"                              --os 26.5 --model "iPhone 17e"

echo "version ranges"
expect "26.5 / iPhone 17 Pro"           --os 26
expect "26.5 / iPhone 17 Pro"           --os ">=26.4"
expect "26.5 / iPhone 17 Pro"           --os ">26.4.1"
expect "26.2 / iPhone 17 Pro"           --os "<26.4"
expect "26.2 / iPhone 17 Pro"           --os "<=26.2"
expect "26.4.1 / iPhone 17 Pro"         --os ">=26.0 <26.5"
expect "26.2 / iPhone 17 Pro"           --os ">=26.0 <=26.2"
expect "18.6 / iPhone 16 Pro"           --os "<26"
expect "-"                              --os 2        # prefixes stop at dots
expect "-"                              --os 26.10
expect "-"                              --os 27
expect "-"                              --os ">=27 <28"

echo "candidate list"
rows=$(BOOT_SIMCTL_CANDIDATES_FILE=$FIXTURE "$SCRIPT" list candidates)
eq "candidates are ordered newest iOS first" \
  "$(printf '%s\n' "$rows" | head -1 | cut -f1)/$(printf '%s\n' "$rows" | tail -1 | cut -f1)" \
  "26.5/18.6"
eq "model order within one iOS version is preserved" \
  "$(printf '%s\n' "$rows" | awk -F'\t' '$1 == "26.5" && $3 == "iPhone" { print $4 }' | tr '\n' ',')" \
  "iPhone 17 Pro,iPhone 17 Pro Max,iPhone Air,iPhone 17,"
eq "list runtimes deduplicates and orders versions" \
  "$(BOOT_SIMCTL_CANDIDATES_FILE=$FIXTURE "$SCRIPT" list runtimes | grep 'SimRuntime\.iOS-' | cut -f1 | tr '\n' ',')" \
  "26.5,26.4.1,26.2,26.1.1,26.0.1,18.6,"
eq "list runtimes keeps every platform" \
  "$(BOOT_SIMCTL_CANDIDATES_FILE=$FIXTURE "$SCRIPT" list runtimes | sed 's/.*SimRuntime\.//; s/-.*//' | awk '!seen[$0]++' | tr '\n' ',')" \
  "iOS,tvOS,watchOS,"

echo "xcode selection"
# xcode_choice <spec> -> the Developer dir it would select, or "-"
xcode_choice() {
  if out=$(BOOT_SIMCTL_XCODES_FILE=$XCODES BOOT_SIMCTL_CANDIDATES_FILE=$FIXTURE \
    "$SCRIPT" boot --xcode "$1" --dry-run 2>&1 >/dev/null); then
    printf '%s\n' "$out" | awk '/^boot-simctl: Xcode / { print $3 }'
  else
    echo -
  fi
}
eq "--xcode picks the newest by default spec" "$(xcode_choice 26)"     "26.6"
eq "--xcode 26.1 reaches a 3-component Xcode" "$(xcode_choice 26.1)"   "26.1.1"
eq "--xcode 26.1.1 is exact"                  "$(xcode_choice 26.1.1)" "26.1.1"
eq "--xcode >=26.2 skips older"               "$(xcode_choice '>=26.2')" "26.6"
eq "--xcode <26.2 takes the newest below"     "$(xcode_choice '<26.2')"  "26.1.1"
eq "--xcode with no match fails"              "$(xcode_choice 27)"     "-"

if BOOT_SIMCTL_XCODES_FILE=$XCODES "$SCRIPT" list xcodes | head -1 | grep -q '^26\.6	'; then
  ok "list xcodes is ordered newest first"
else
  fail "list xcodes gave: $(BOOT_SIMCTL_XCODES_FILE=$XCODES "$SCRIPT" list xcodes | head -1)"
fi

echo "argument handling"
expect_fail "shutdown with no argument fails"       shutdown
expect_fail "shutdown with an empty argument fails" shutdown ""
expect_fail "unknown subcommand fails"              frobnicate
expect_fail "unknown boot option fails"             boot --nope
expect_fail "unknown list target fails"             list nonsense
expect_fail "--device rejects unknown families"     boot --device android --dry-run
expect_fail "--model rejects unknown models"        boot --model "iPhone 99" --dry-run
expect_fail "a removed option is rejected"          boot --reuse --dry-run
expect_fail "invalid version requirement fails"     boot --os ">=abc" --dry-run
# Would pass if the spec were glob-expanded against the working directory.
expect_fail "a globbing --os fails"                 boot --os "*" --dry-run
expect_fail "a globbing --os fails (bracket)"       boot --os "2[0-9]" --dry-run
# Dropped in favour of the prefix form, which means exactly the same thing.
expect_fail "caret --os is rejected"                boot --os "^26.1" --dry-run
expect_fail "tilde --os is rejected"                boot --os "~26.1" --dry-run
expect_fail "equals --os is rejected"               boot --os "=26.1" --dry-run
expect_fail "--os with a missing value fails"       boot --os

echo "candidate list built from the real simctl"
real=$("$SCRIPT" list candidates)
if [ -n "$real" ]; then
  ok "the real candidate list is not empty ($(printf '%s\n' "$real" | wc -l | tr -d ' ') rows)"
else
  fail "the real candidate list is empty"
fi
if printf '%s\n' "$real" | awk -F'\t' 'NF != 5 { exit 1 }'; then
  ok "every real candidate row has five fields"
else
  fail "some real candidate rows are malformed"
fi
# -E, not BRE: BSD grep does not honour \| as alternation.
if printf '%s\n' "$real" | cut -f3 | sort -u | grep -qvE '^(iPhone|iPad|Apple TV|Apple Watch|Apple Vision)$'; then
  fail "the real candidate list holds an unknown family: $(printf '%s\n' "$real" | cut -f3 | sort -u | tr '\n' ' ')"
else
  ok "every family in the real candidate list is one --device accepts"
fi
if printf '%s\n' "$real" | grep -q 'iPhone SE (3rd generation)'; then
  ok "model names containing parentheses survive JSON extraction"
else
  fail "no parenthesised model name found in the real list"
fi

if [ "$RUN_SLOW" = 1 ]; then
  echo "booting real simulators"
  NAME=ci-simulator
  oldest=$("$SCRIPT" list runtimes | cut -f1 | tail -1)

  # Reads simctl's text output while the script reads JSON, so one breaking
  # cannot mask the other.
  sim_state() { xcrun simctl list devices 2>/dev/null | awk -v k="$1" 'index($0, k) { print $NF; exit }'; }

  if udid=$("$SCRIPT" boot --device iPhone 2>/dev/null); then
    eq "iPhone booted ($udid)" "$(sim_state "$udid")" "(Booted)"
    "$SCRIPT" shutdown "$udid" >/dev/null 2>&1
    if xcrun simctl list devices 2>/dev/null | grep -q "$udid"; then
      fail "shutdown must delete the device"
    else
      ok "shutdown deletes the device"
    fi
  else
    fail "booting an iPhone failed"
  fi

  # The newest iPhone models cannot run the oldest runtime, so this also proves
  # the candidate list excluded them.
  if udid=$("$SCRIPT" boot --device iPad --os "$oldest" 2>/dev/null); then
    ok "iPad booted on iOS $oldest ($udid)"
    "$SCRIPT" shutdown "$udid" >/dev/null 2>&1
  else
    fail "booting an iPad on iOS $oldest failed"
  fi

  # A 1s timeout always expires, which is how the failure path gets exercised.
  before=$(ps -Ao comm= | grep -c 'simctl$' || true)
  if BOOT_SIMCTL_BOOT_TIMEOUT=1 BOOT_SIMCTL_BOOT_RETRIES=1 \
    "$SCRIPT" boot --device iPhone >/dev/null 2>"$HERE/.timeout.log"; then
    fail "a 1s boot timeout should have failed the run"
  else
    ok "boot timeout fails the run"
  fi
  if grep -q 'attempt 1/2 timed out' "$HERE/.timeout.log" && grep -q 'attempt 2/2 timed out' "$HERE/.timeout.log"; then
    ok "boot timeout retries the configured number of times"
  else
    fail "expected two timed-out attempts, log says: $(grep warning "$HERE/.timeout.log" | tr '\n' ' ')"
  fi
  eq "a device that failed to boot is left shut down" "$(sim_state "$NAME (")" "(Shutdown)"
  sleep 2
  after=$(ps -Ao comm= | grep -c 'simctl$' || true)
  if [ "$after" -le "$before" ]; then
    ok "no simctl process is left behind after a timeout"
  else
    fail "simctl processes went from $before to $after"
  fi
  rm -f "$HERE/.timeout.log"

  "$SCRIPT" shutdown "$NAME" >/dev/null 2>&1 || true
  if xcrun simctl list devices 2>/dev/null | grep -q "$NAME"; then
    fail "test devices were left behind"
  else
    ok "no test devices left behind"
  fi
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
