echo "Repair the installed keyboard-backlight and force-igpu sleep hooks"

# omarchy-hibernation-setup and omarchy-toggle-hybrid-gpu used to copy these
# hooks with cp -p from a 644 file, so the installed copies were never
# executable and systemd-sleep silently skipped them: the keyboard LEDs stayed on
# into S4 (which the hook exists to prevent on ASUS keyboards) and force-igpu
# never detached the dGPU before hibernate. Both scripts now install them 0755.
# Migration 1788662350 replaces copies a user could write, but leaves
# root-owned ones alone, and cp -p from the root-owned packaged source produced
# exactly that: a root-owned 644 hook. Make those executable.
#
# Every keyboard-backlight hook shipped before this one zeroed any
# *kbd_backlight* LED before hibernate and never restored it, which left
# non-ASUS keyboards dark for good. Making those copies executable would spread
# that, so replace any copy that is still a shipped version with the current
# hook, which only touches ASUS LEDs and restores them on resume.
hook_dir="${OMARCHY_SYSTEM_SLEEP_DIR:-/usr/lib/systemd/system-sleep}"
keyboard_backlight="$hook_dir/keyboard-backlight"
legacy_keyboard_sha256s=(
  f313a81e47401f0d38b8602e5997f52c5286d5e97f74027564ddd515b3d16511
  79215eed4da8036e25cd70ad09276823aad92d386a68c69d589d587c93b79c60
)

as_root() {
  if (( EUID == 0 )); then
    "$@"
  else
    sudo "$@"
  fi
}

if [[ -f $keyboard_backlight && ! -L $keyboard_backlight ]]; then
  digest=$(sha256sum -- "$keyboard_backlight" 2>/dev/null || true)
  if [[ -n $digest && " ${legacy_keyboard_sha256s[*]} " == *" ${digest%% *} "* ]]; then
    # Stage the new hook beside the old one and rename it into place, so a
    # failed copy leaves the shipped version that a retry still recognizes.
    # systemd-sleep skips hidden files, so the stage never runs.
    stage=$(as_root mktemp -- "$hook_dir/.keyboard-backlight.omarchy.XXXXXX")
    if as_root install -m 0755 -T -- "$OMARCHY_PATH/default/systemd/system-sleep/keyboard-backlight" "$stage" &&
      as_root mv -Tf -- "$stage" "$keyboard_backlight"; then
      :
    else
      as_root rm -f -- "$stage"
      echo "Could not replace $keyboard_backlight; rerun omarchy-migrate to retry" >&2
      exit 1
    fi
  fi
fi

for hook in "$keyboard_backlight" "$hook_dir/force-igpu"; do
  [[ -f $hook && ! -L $hook && ! -x $hook ]] || continue
  as_root chmod 755 "$hook"
done
