#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3

output=$(PYTHONDONTWRITEBYTECODE=1 PADDLES="$ROOT/bin/omarchy-hw-steam-deck-paddles" python3 - <<'PY' 2>&1
import importlib.machinery
import importlib.util
import os

loader = importlib.machinery.SourceFileLoader("paddles", os.environ["PADDLES"])
spec = importlib.util.spec_from_loader("paddles", loader)
paddles = importlib.util.module_from_spec(spec)
loader.exec_module(paddles)

L4, R4, L5, R5 = paddles.BTN_GRIPL, paddles.BTN_GRIPR, paddles.BTN_GRIPL2, paddles.BTN_GRIPR2
delay, interval = paddles.REPEAT_DELAY, paddles.REPEAT_INTERVAL


def check(condition, message):
    if not condition:
        raise SystemExit(f"FAIL {message}")


def report(*set_bits, kind=0x09, size=64):
    data = bytearray(size)
    data[0:3] = bytes([0x01, 0x00, kind])
    for byte, bit in set_bits:
        data[byte] |= 1 << bit
    return bytes(data)


held = paddles.held_buttons
check(held(report()) == set(), "an idle report holds nothing")
check(held(report((13, 1))) == {L4}, "byte 13 bit 1 is L4")
check(held(report((13, 2))) == {R4}, "byte 13 bit 2 is R4")
check(held(report((9, 7))) == {L5}, "byte 9 bit 7 is L5")
check(held(report((10, 0))) == {R5}, "byte 10 bit 0 is R5")
check(held(report((8, 7), (9, 6), (10, 1))) == set(), "neighbouring buttons are not back buttons")
check(held(report((13, 1), kind=0x01)) is None, "other report types are ignored")
check(held(report((13, 1), size=63)) is None, "short reports are ignored")

p = paddles.Paddles()
check(p.update({L4}, 0.0) == 1, "L4 scrolls up when pressed")
check(p.update({L4}, 0.1) == 0, "a button still held does not scroll again on the next report")
check(p.due(delay - 0.01) == 0, "no repeat before the delay")
check(p.timeout(0.0) == delay, "the loop wakes for the first repeat")
check(p.due(delay) == 1, "a held upper button repeats up")
check(p.due(delay + interval) == 1, "and keeps repeating")
check(p.update(set(), 1.0) == 0 and p.due(5.0) == 0, "release stops the scroll")
check(p.timeout(5.0) is None, "the loop sleeps with nothing held")

check(p.update({R5}, 10.0) == -1, "R5 scrolls down when pressed")
check(p.update({R5, R4}, 10.1) == 0, "up and down held together cancel")
check(p.due(10.0 + delay + 0.05) == 0, "a cancelled hold does not repeat")
p.update({R5}, 10.0 + delay + 0.1)
check(p.due(10.0 + delay + 0.1) == -1, "releasing the upper button resumes the lower one")
p.update(set(), 10.0 + delay + 0.2)
check(p.update({L4, R4}, 30.0) == 1, "both upper buttons together scroll one notch")

stale = paddles.STALE_AFTER
p = paddles.Paddles()
p.update({L5}, 40.0)
check(abs(p.timeout(40.0) - delay) < 1e-9, "the loop wakes for the first repeat before the stale limit")
p.update({L5}, 40.0 + delay)
check(p.due(40.0 + delay) == -1, "a hold refreshed by reports keeps repeating")
check(p.timeout(40.0 + delay + interval) == 0.0, "a repeat is due")
check(p.timeout(40.0 + delay + 0.01) <= stale, "the loop wakes by the stale limit")
check(p.due(40.0 + delay + stale) == 0, "a hold with no reports for the stale limit stops scrolling")
check(p.held == set(), "and is forgotten")
check(p.update({L5}, 50.0) == -1, "a fresh report of the same button scrolls again")

import tempfile

root = tempfile.mkdtemp()
paddles.HIDRAW_CLASS = os.path.join(root, "hidraw")
paddles.DEV_ROOT = os.path.join(root, "dev")
paddles.PROC_ROOT = os.path.join(root, "proc")
paddles.LIZARD_MODE = os.path.join(root, "lizard_mode")


def write(path, data, mode="w"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, mode) as file:
        file.write(data)


def hidraw(name, hid_id, descriptor):
    write(os.path.join(paddles.HIDRAW_CLASS, name, "device/uevent"), f"HID_ID=0003:{hid_id}\nHID_NAME=Valve\n")
    write(os.path.join(paddles.HIDRAW_CLASS, name, "device/report_descriptor"), descriptor, "wb")


check(paddles.find_controller() is None, "no hidraw nodes, no controller")
hidraw("hidraw0", "000028DE:00001205", bytes([0x05, 0x01, 0x09, 0x02]))  # Deck trackpad mouse
hidraw("hidraw1", "0000046D:0000C52B", bytes([0x06, 0x00, 0xFF]))  # someone else's vendor page
check(paddles.find_controller() is None, "the Deck's mouse interface and other vendors' devices are not the controller")
hidraw("hidraw2", "000028DE:00001205", bytes([0x06, 0xFF, 0xFF, 0x09, 0x01]))
check(paddles.find_controller() == os.path.join(paddles.DEV_ROOT, "hidraw2"), "the Deck interface on a vendor page is the controller")

node = os.path.join(paddles.DEV_ROOT, "hidraw2")
check(not paddles.lizard_mode_on() and not paddles.should_run(), "a missing hid_steam parameter stands aside")
write(paddles.LIZARD_MODE, "N\n")
check(not paddles.should_run(), "lizard mode off means a mapper owns the controller")
write(paddles.LIZARD_MODE, "Y\n")
check(paddles.should_run() and paddles.should_run(node), "lizard mode on with nothing else running scrolls")

write(os.path.join(paddles.PROC_ROOT, "100/comm"), "hyprland\n")
os.makedirs(os.path.join(paddles.PROC_ROOT, "100/fd"))
os.symlink("/dev/null", os.path.join(paddles.PROC_ROOT, "100/fd/0"))
check(paddles.should_run(node), "unrelated processes don't stand it aside")

os.makedirs(os.path.join(paddles.PROC_ROOT, f"{os.getpid()}/fd"))
os.symlink(node, os.path.join(paddles.PROC_ROOT, f"{os.getpid()}/fd/5"))
check(paddles.should_run(node), "its own open of the controller doesn't count")

write(os.path.join(paddles.PROC_ROOT, "200/comm"), "SDLGame\n")
os.makedirs(os.path.join(paddles.PROC_ROOT, "200/fd"))
os.symlink(node, os.path.join(paddles.PROC_ROOT, "200/fd/7"))
check(not paddles.should_run(node), "another program reading the controller stands it aside")
check(paddles.should_run(), "the open check needs the node")
os.unlink(os.path.join(paddles.PROC_ROOT, "200/fd/7"))

write(os.path.join(paddles.PROC_ROOT, "300/comm"), "steam\n")
check(not paddles.should_run(), "Steam running stands it aside")
print("ok")
PY
) || fail "paddle scroll logic" "$output"

[[ $output == "ok" ]] || fail "paddle scroll logic" "$output"
pass "Steam Deck back buttons scroll, stop on stale reports, find the controller and stand aside"
