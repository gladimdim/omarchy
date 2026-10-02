#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3

output=$(PADDLES="$ROOT/bin/omarchy-hw-steam-deck-paddles" python3 - <<'PY' 2>&1
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
check(p.due(20.0) == 0, "a cancelled hold does not repeat")
p.update({R5}, 20.1)
check(p.due(20.2) == -1, "releasing the upper button resumes the lower one")
p.update(set(), 20.3)
check(p.update({L4, R4}, 30.0) == 1, "both upper buttons together scroll one notch")
print("ok")
PY
) || fail "paddle scroll logic" "$output"

[[ $output == "ok" ]] || fail "paddle scroll logic" "$output"
pass "Steam Deck back buttons scroll up, down, repeat and stop"
