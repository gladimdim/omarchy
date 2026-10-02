#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

hooks_dir="$ROOT/default/systemd/system-sleep"

# systemd-sleep only runs executable files from system-sleep directories, so a
# hook shipped without the bit is dead on arrival wherever it is copied with -p.
for hook in keyboard-backlight force-igpu unmount-fuse; do
  [[ -x $hooks_dir/$hook ]] || fail "$hook is executable in the repo"
  bash -n "$hooks_dir/$hook" || fail "$hook parses"
  pass "$hook is an executable, parseable sleep hook"
done

# The installers must set the mode themselves rather than trust the source file.
for script in omarchy-hibernation-setup omarchy-toggle-hybrid-gpu; do
  if grep -q 'cp -p .*system-sleep' "$ROOT/bin/$script"; then
    fail "$script installs sleep hooks with an explicit mode, not cp -p"
  fi
  pass "$script installs sleep hooks with an explicit mode"
done

# keyboard-backlight zeroes only ASUS keyboard LEDs before hibernate, and puts
# them back on resume (#12657).
leds="$tmp_dir/leds"
state="$tmp_dir/kbd-state"
mkdir -p "$leds/asus::kbd_backlight" "$leds/tpacpi::kbd_backlight"
echo 3 >"$leds/asus::kbd_backlight/brightness"
echo 2 >"$leds/tpacpi::kbd_backlight/brightness"
run_keyboard_hook() {
  OMARCHY_LEDS_DIR="$leds" OMARCHY_KBD_BACKLIGHT_STATE_DIR="$state" "$hooks_dir/keyboard-backlight" "$@"
}

run_keyboard_hook pre suspend
[[ $(<"$leds/asus::kbd_backlight/brightness") == 3 ]] || fail "keyboard-backlight leaves the LEDs alone on suspend"
pass "keyboard-backlight ignores suspend"

run_keyboard_hook pre hibernate
[[ $(<"$leds/asus::kbd_backlight/brightness") == 0 ]] || fail "keyboard-backlight turns the ASUS keyboard off before hibernate"
[[ $(<"$leds/tpacpi::kbd_backlight/brightness") == 2 ]] || fail "keyboard-backlight leaves non-ASUS keyboards alone"
pass "keyboard-backlight turns off only the ASUS keyboard before hibernate"

run_keyboard_hook post hibernate
[[ $(<"$leds/asus::kbd_backlight/brightness") == 3 ]] || fail "keyboard-backlight restores the ASUS keyboard on resume"
[[ ! -e $state ]] || fail "keyboard-backlight clears its saved state on resume"
pass "keyboard-backlight restores the ASUS keyboard on resume"

# suspend-then-hibernate passes the phase in SYSTEMD_SLEEP_ACTION.
SYSTEMD_SLEEP_ACTION=hibernate run_keyboard_hook pre suspend-then-hibernate
[[ $(<"$leds/asus::kbd_backlight/brightness") == 0 ]] || fail "keyboard-backlight handles the hibernate phase of suspend-then-hibernate"
SYSTEMD_SLEEP_ACTION=hibernate run_keyboard_hook post suspend-then-hibernate
[[ $(<"$leds/asus::kbd_backlight/brightness") == 3 ]] || fail "keyboard-backlight restores after suspend-then-hibernate"
pass "keyboard-backlight handles suspend-then-hibernate"

run_keyboard_hook post hibernate || fail "keyboard-backlight resume without saved state succeeds"
[[ $(<"$leds/asus::kbd_backlight/brightness") == 3 ]] || fail "keyboard-backlight resume without saved state changes nothing"
pass "keyboard-backlight resume without saved state is a no-op"

# The migration repairs copies that earlier releases left without the bit, and
# leaves everything else alone.
mkdir -p "$tmp_dir/system-sleep"
# The hook as shipped before #12657: zeroes any keyboard LED, never restores it.
cat >"$tmp_dir/system-sleep/keyboard-backlight" <<'SH'
#!/bin/bash

# Turn off keyboard backlight before hibernate to prevent hang on power-off.
# The ASUS keyboard controller can block S4 shutdown if LEDs are active.

sleep_action=${SYSTEMD_SLEEP_ACTION:-$2}

if [[ $1 == "pre" && $sleep_action == "hibernate" ]]; then
  device=""
  for candidate in /sys/class/leds/*kbd_backlight*; do
    if [[ -e "$candidate" ]]; then
      device="$(basename "$candidate")"
      break
    fi
  done

  if [[ -n "$device" ]]; then
    brightnessctl -d "$device" set 0 >/dev/null 2>&1
  fi
fi
SH
[[ $(sha256sum "$tmp_dir/system-sleep/keyboard-backlight" | cut -d' ' -f1) == 79215eed4da8036e25cd70ad09276823aad92d386a68c69d589d587c93b79c60 ]] ||
  fail "keyboard-backlight legacy fixture no longer matches the migration fingerprint"
chmod 644 "$tmp_dir/system-sleep/keyboard-backlight"
install -m644 /dev/null "$tmp_dir/system-sleep/unrelated"

OMARCHY_PATH="$ROOT" OMARCHY_SYSTEM_SLEEP_DIR="$tmp_dir/system-sleep" bash -euo pipefail "$ROOT/migrations/1788695343.sh" >/dev/null ||
  fail "migration completes on a 644 hook"
[[ -x $tmp_dir/system-sleep/keyboard-backlight ]] || fail "migration makes keyboard-backlight executable"
cmp -s "$hooks_dir/keyboard-backlight" "$tmp_dir/system-sleep/keyboard-backlight" ||
  fail "migration replaces a shipped keyboard-backlight hook with the current one"
[[ ! -x $tmp_dir/system-sleep/unrelated ]] || fail "migration leaves other files alone"
pass "migration replaces a shipped 644 keyboard-backlight hook with the current, executable one"

OMARCHY_PATH="$ROOT" OMARCHY_SYSTEM_SLEEP_DIR="$tmp_dir/system-sleep" bash -euo pipefail "$ROOT/migrations/1788695343.sh" >/dev/null ||
  fail "migration is idempotent"
pass "migration is a no-op the second time"

# A customized hook is the administrator's: keep its content, only make it run.
printf '#!/bin/bash\n# custom\n' >"$tmp_dir/system-sleep/keyboard-backlight"
chmod 644 "$tmp_dir/system-sleep/keyboard-backlight"
OMARCHY_PATH="$ROOT" OMARCHY_SYSTEM_SLEEP_DIR="$tmp_dir/system-sleep" bash -euo pipefail "$ROOT/migrations/1788695343.sh" >/dev/null ||
  fail "migration completes on a customized hook"
grep -q custom "$tmp_dir/system-sleep/keyboard-backlight" || fail "migration keeps a customized keyboard-backlight hook"
[[ -x $tmp_dir/system-sleep/keyboard-backlight ]] || fail "migration makes a customized hook executable"
pass "migration keeps a customized keyboard-backlight hook"

rm -rf "$tmp_dir/system-sleep"
OMARCHY_PATH="$ROOT" OMARCHY_SYSTEM_SLEEP_DIR="$tmp_dir/system-sleep" bash -euo pipefail "$ROOT/migrations/1788695343.sh" >/dev/null ||
  fail "migration completes with no hooks installed"
pass "migration completes with no hooks installed"
