echo "Scroll with the Steam Deck back buttons"

if omarchy-hw-steam-deck; then
  omarchy-pkg-add python-evdev steam-devices

  # steam-devices opens /dev/uinput to the logged-in user through a udev rule.
  # Apply it now so the paddle reader works from the next login, not the next boot.
  sudo udevadm control --reload-rules
  sudo udevadm trigger --action=change --name-match=uinput || true
fi
