echo "Make the keyboard-backlight and force-igpu sleep hooks executable so systemd-sleep runs them"

# omarchy-hibernation-setup and omarchy-toggle-hybrid-gpu used to copy these
# hooks with cp -p from a 644 file, so the installed copies were never
# executable and systemd-sleep silently skipped them: the keyboard LEDs stayed on
# into S4 (which the hook exists to prevent on ASUS keyboards) and force-igpu
# never detached the dGPU before hibernate. Both scripts now install them 0755.
# Migration 1788662350 replaces copies a user could write, but leaves
# root-owned ones alone, and cp -p from the root-owned packaged source produced
# exactly that: a root-owned 644 hook. Make those executable.
hook_dir="${OMARCHY_SYSTEM_SLEEP_DIR:-/usr/lib/systemd/system-sleep}"

for hook in "$hook_dir/keyboard-backlight" "$hook_dir/force-igpu"; do
  [[ -f $hook && ! -x $hook ]] || continue
  if [[ -O $hook ]]; then
    chmod 755 "$hook"
  else
    sudo chmod 755 "$hook"
  fi
done
