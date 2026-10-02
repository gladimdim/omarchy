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

# If the level can't be saved the keyboard still goes dark (an ASUS controller
# can hang S4 otherwise), the failure is logged, and resume restores nothing.
touch "$tmp_dir/not-a-dir"
save_error=$(OMARCHY_LEDS_DIR="$leds" OMARCHY_KBD_BACKLIGHT_STATE_DIR="$tmp_dir/not-a-dir/state" \
  "$hooks_dir/keyboard-backlight" pre hibernate 2>&1 >/dev/null)
[[ $(<"$leds/asus::kbd_backlight/brightness") == 0 ]] || fail "keyboard-backlight turns the keyboard off even when it cannot save it"
[[ $save_error == *"could not save asus::kbd_backlight"* ]] || fail "keyboard-backlight logs a failed save" "$save_error"
echo 3 >"$leds/asus::kbd_backlight/brightness"
pass "keyboard-backlight still turns off and logs when it cannot save the level"

mkdir -p "$state"
: >"$state/asus::kbd_backlight"
run_keyboard_hook post hibernate || fail "keyboard-backlight resume with an empty saved level succeeds"
[[ $(<"$leds/asus::kbd_backlight/brightness") == 3 ]] || fail "keyboard-backlight never restores an empty saved level"
[[ ! -e $state ]] || fail "keyboard-backlight clears an empty saved level"
pass "keyboard-backlight ignores an empty saved level"

run_keyboard_hook post hibernate || fail "keyboard-backlight resume without saved state succeeds"
[[ $(<"$leds/asus::kbd_backlight/brightness") == 3 ]] || fail "keyboard-backlight resume without saved state changes nothing"
pass "keyboard-backlight resume without saved state is a no-op"

# Installed hooks are root-owned, so the migration repairs them through sudo.
# A stub records each privileged call and runs it as this user.
stub_bin="$tmp_dir/bin"
sudo_calls="$tmp_dir/sudo-calls"
mkdir -p "$stub_bin"
cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$SUDO_CALLS"
"$@"
SH
chmod +x "$stub_bin/sudo"
run_migration() {
  PATH="$stub_bin:$PATH" SUDO_CALLS="$sudo_calls" OMARCHY_PATH="$ROOT" OMARCHY_SYSTEM_SLEEP_DIR="$tmp_dir/system-sleep" \
    bash -euo pipefail "$ROOT/migrations/1788695343.sh" >/dev/null
}

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
legacy_keyboard_backlight=$(<"$tmp_dir/system-sleep/keyboard-backlight")
install -m644 "$hooks_dir/force-igpu" "$tmp_dir/system-sleep/force-igpu"
install -m644 /dev/null "$tmp_dir/system-sleep/unrelated"

# A replacement that fails leaves the shipped hook in place, so a retry still
# recognizes and replaces it instead of treating a partial copy as custom.
if PATH="$stub_bin:$PATH" SUDO_CALLS="$sudo_calls" OMARCHY_PATH="$tmp_dir/missing" OMARCHY_SYSTEM_SLEEP_DIR="$tmp_dir/system-sleep" \
  bash -euo pipefail "$ROOT/migrations/1788695343.sh" >/dev/null 2>&1; then
  fail "migration reports a failed hook replacement"
fi
[[ $(<"$tmp_dir/system-sleep/keyboard-backlight") == "$legacy_keyboard_backlight" ]] ||
  fail "a failed replacement leaves the shipped hook untouched"
[[ -z $(find "$tmp_dir/system-sleep" -name '.keyboard-backlight.omarchy.*') ]] ||
  fail "a failed replacement leaves no staged copy behind"
pass "a failed hook replacement leaves the shipped hook for the retry"
rm -f "$sudo_calls"

run_migration ||
  fail "migration completes on a 644 hook"
[[ -x $tmp_dir/system-sleep/keyboard-backlight ]] || fail "migration makes keyboard-backlight executable"
cmp -s "$hooks_dir/keyboard-backlight" "$tmp_dir/system-sleep/keyboard-backlight" ||
  fail "migration replaces a shipped keyboard-backlight hook with the current one"
[[ ! -x $tmp_dir/system-sleep/unrelated ]] || fail "migration leaves other files alone"
grep -Eq -- "^mv -Tf -- $tmp_dir/system-sleep/\.keyboard-backlight\.omarchy\.[[:alnum:]]{6} $tmp_dir/system-sleep/keyboard-backlight$" "$sudo_calls" ||
  fail "migration renames the replacement into place through sudo"
[[ -z $(find "$tmp_dir/system-sleep" -name '.keyboard-backlight.omarchy.*') ]] ||
  fail "migration leaves no staged copy behind"
[[ -x $tmp_dir/system-sleep/force-igpu ]] || fail "migration makes force-igpu executable"
grep -Fqx -- "chmod 755 $tmp_dir/system-sleep/force-igpu" "$sudo_calls" ||
  fail "migration makes the root-owned force-igpu executable through sudo"
cmp -s "$hooks_dir/force-igpu" "$tmp_dir/system-sleep/force-igpu" || fail "migration leaves force-igpu's content alone"
grep -Eq -- "^install -m 0755 -T -- $ROOT/default/systemd/system-sleep/keyboard-backlight $tmp_dir/system-sleep/\.keyboard-backlight\.omarchy\.[[:alnum:]]{6}$" "$sudo_calls" ||
  fail "migration stages the root-owned replacement executable through sudo"
pass "migration replaces a shipped 644 keyboard-backlight hook and makes a 644 force-igpu executable"

rm -f "$sudo_calls"
run_migration || fail "migration is idempotent"
[[ ! -e $sudo_calls ]] || fail "migration runs nothing privileged once the hooks are repaired"
pass "migration is a no-op the second time"

# A customized hook is the administrator's: keep its content, only make it run.
printf '#!/bin/bash\n# custom\n' >"$tmp_dir/system-sleep/keyboard-backlight"
chmod 644 "$tmp_dir/system-sleep/keyboard-backlight"
run_migration ||
  fail "migration completes on a customized hook"
grep -q custom "$tmp_dir/system-sleep/keyboard-backlight" || fail "migration keeps a customized keyboard-backlight hook"
[[ -x $tmp_dir/system-sleep/keyboard-backlight ]] || fail "migration makes a customized hook executable"
pass "migration keeps a customized keyboard-backlight hook"

rm -rf "$tmp_dir/system-sleep"
run_migration ||
  fail "migration completes with no hooks installed"
pass "migration completes with no hooks installed"
