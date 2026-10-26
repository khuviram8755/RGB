#!/usr/bin/env python3
"""
Control of the MSI motherboard ARGB lighting (Mystic Light) on Linux.

Real protocol, obtained by reverse engineering: the actual USB traffic of
MSI Center was captured with usbmon+wireshark inside a Windows VM on
July 23, 2026 (see README.md for the full protocol).

It is a HID SET_REPORT Feature, Report ID 0x50, 290 bytes, sent as a control
transfer (bmRequestType 0x21, bRequest 0x09/SET_REPORT, wValue 0x0350). On top
of the 290-byte template only a few indices are modified:

    273 (_MODE_IDX)  mode:  00 off, 01 wave, 02 static, 04 breathing,
                            05 rainbow.
    274-285          up to 4 palette RGB colors (color1=274-276,
                     color2=277-279, color3=280-282, color4=283-285). In
                     single-color modes, color1 is used.
    286 (_SUB_IDX)   sub-parameter: 03 for palette/rainbow effects, 00 for
                     static/breathing.
    287 (_PARAM_IDX) bit-packs speed, brightness, color source, direction and
                     animation (see _param).

USB device 0db0:0076 "MSI MYSTIC LIGHT". Tested on the MSI MAG B860
TOMAHAWK WIFI. The static color is persistent (survives power-off).

Byte 287 decoded bit by bit (Jul 23, 2026):
    bit 0-1  speed         0 slow, 1 medium, 2 fast
    bit 2-4  brightness    1..5 (5 = maximum)
    bit 5    color source  1 = colors from the buffer, 0 = generated rainbow
    bit 6    direction     0 right, 1 left (only for effects that move around)
    bit 7    animation     1 = moving effect, 0 = standard/static
Formula: byte287 = 128*animated + 64*direction + 32*use_buffer + 4*brightness + speed.

Usage:
    rgb-board.py R G B [brightness]              # static by RGB (0-255)
    rgb-board.py <color> [brightness]            # static
    rgb-board.py breathe <color> [speed] [brightness]
    rgb-board.py wave [colors...|rainbow] [speed] [brightness] [left|right]
    rgb-board.py rainbow [speed] [brightness]    # rainbow wave (mode 05)
    rgb-board.py standard [brightness]           # fixed multicolor (still rainbow)
    rgb-board.py temp [brightness]               # color by CPU temperature (once)
    rgb-board.py temp loop [sec] [brightness]    # refresh in a loop (Ctrl+C to exit)
    rgb-board.py on                              # dim white
    rgb-board.py off                             # turn off
    speed: slow|medium|fast   brightness: 1-5   direction: left|right
    Colors: red green blue white purple cyan yellow orange pink
    Add "temporary" anywhere to avoid writing to flash (volatile).
"""

import fcntl
import glob
import os
import sys

HIDIOCSFEATURE = lambda length: 0xC0004806 | (length << 16)

COLORS = {
    "red": (255, 0, 0), "green": (0, 255, 0), "blue": (0, 0, 255),
    "white": (255, 255, 255), "purple": (160, 0, 255), "violet": (160, 0, 255),
    "cyan": (0, 255, 255), "yellow": (255, 180, 0), "orange": (255, 60, 0),
    "pink": (255, 0, 120),
}

# Real 290-byte template (Report ID 0x50 + data) captured from MSI Center
# sending a static color. The indices that get modified are 273-287.
_TEMPLATE_HEX = """
50 01 00 00 00 00 00 00 00 00 00 00 00 00 03 94
1e 01 00 00 00 00 00 00 00 00 00 00 00 00 03 94
1e 01 00 00 00 00 00 00 00 00 00 00 00 00 03 94
1e 01 00 00 00 00 00 00 00 00 00 00 00 00 03 94
1e 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 01 00 00 00 00 00 00 00 00 00 00 00 00 03 94
ff 01 00 00 00 00 00 00 00 00 00 00 00 00 03 94
ff 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
00 02 ff 00 00 00 ff 00 00 00 ff ff ff ff 00 b5
ff 00
"""

_MODE_IDX = 273          # 00 off / 01 wave / 02 static / 04 breathe / 05 rainbow
_COLOR_IDX = 274         # 4 consecutive RGB colors: 274-285
_SUB_IDX = 286           # 03 for palette/rainbow effects, 00 for static
_PARAM_IDX = 287         # brightness+speed+source+direction+animation (bit-packed)
_SAVE_IDX = 289          # 01 = save to flash (persists after reboot), 00 = volatile

MODE_OFF = 0x00
MODE_WAVE = 0x01
MODE_STATIC = 0x02
MODE_BREATHE = 0x04
MODE_RAINBOW = 0x05

SPEEDS = {"slow": 0, "medium": 1, "mid": 1, "fast": 2}
DIRS = {"right": 0, "r": 0, "left": 1, "l": 1}

TEMPORARY_WORDS = ("temporary", "temp-only", "volatile")


def _param(brightness, speed=1, direction=0, use_buffer=1, animated=1):
    """Byte 287: packs speed, brightness, source, direction and animation."""
    return (((animated & 1) << 7) | ((direction & 1) << 6) | ((use_buffer & 1) << 5)
            | ((brightness & 7) << 2) | (speed & 3))


def _template():
    buf = bytearray(int(x, 16) for x in _TEMPLATE_HEX.split())
    assert len(buf) == 290, len(buf)
    assert buf[0] == 0x50
    return buf


# --- CPU temperature mode (replicates MSI Center's software effect) ----------
# MSI Center does not use a firmware mode: it reads the temperature and sends
# STATIC commands with the appropriate color. We do the same here. Cold->hot
# gradient with anchor points (temperature in °C -> RGB color).
TEMP_MIN = 40    # at this temperature or below: pure green
TEMP_MAX = 85    # at this temperature or above: pure red
_TEMP_GRAD = [
    (40, (0, 255, 0)),      # cold: green
    (55, (0, 200, 255)),    # warm: blue-cyan
    (70, (255, 180, 0)),    # hot: amber
    (85, (255, 0, 0)),      # very hot: red
]


def cpu_temp():
    """CPU temperature in °C, read from the 'coretemp' hwmon (Intel) or,
    failing that, 'k10temp'/'zenpower' (AMD). Returns None if no sensor is found."""
    def read_package(base, labels):
        for lbl in sorted(glob.glob(f"{base}/temp*_label")):
            try:
                if open(lbl).read().strip() in labels:
                    val = open(lbl.replace("_label", "_input")).read().strip()
                    return int(val) / 1000.0
            except OSError:
                continue
        # no useful label: just use temp1_input
        try:
            return int(open(f"{base}/temp1_input").read().strip()) / 1000.0
        except OSError:
            return None

    prefer = {"coretemp": {"Package id 0"}, "k10temp": {"Tctl", "Tdie"},
              "zenpower": {"Tdie"}}
    found = {}
    for name_file in glob.glob("/sys/class/hwmon/hwmon*/name"):
        try:
            name = open(name_file).read().strip()
        except OSError:
            continue
        if name in prefer:
            found[name] = os.path.dirname(name_file)
    for name in ("coretemp", "k10temp", "zenpower"):
        if name in found:
            t = read_package(found[name], prefer[name])
            if t is not None:
                return t
    return None


def color_by_temp(t):
    """Interpolates the temperature gradient and returns (r, g, b)."""
    points = _TEMP_GRAD
    if t <= points[0][0]:
        return points[0][1]
    if t >= points[-1][0]:
        return points[-1][1]
    for (t0, c0), (t1, c1) in zip(points, points[1:]):
        if t0 <= t <= t1:
            f = (t - t0) / (t1 - t0)
            return tuple(round(a + (b - a) * f) for a, b in zip(c0, c1))
    return points[-1][1]


def find_device():
    forced = os.environ.get("MSI_HIDRAW")
    if forced:
        return forced
    for path in sorted(glob.glob("/dev/hidraw*")):
        name = path.split("/")[-1]
        uevent = f"/sys/class/hidraw/{name}/device/uevent"
        try:
            with open(uevent) as fh:
                data = fh.read().upper()
            if "0DB0" in data and "0076" in data:
                return path
        except OSError:
            continue
    return None


def set_argb(colors, device, mode=MODE_STATIC, brightness=5, speed=1,
             direction=0, use_buffer=1, animated=1, sub=None, save=True):
    """Sends an ARGB command. `colors` is a list of 1..4 (r,g,b) tuples.

    With a single color it is replicated across all 4 palette slots, so that
    effects that cycle through colors end up as a uniform tone. `save=True`
    sets byte 289 to 01 so the color persists across reboots (like the Apply
    button in MSI Center); with False it is volatile and does not wear the flash.
    """
    buf = _template()
    if colors:
        if len(colors) == 1:
            colors = colors * 4
        for i, (r, g, b) in enumerate(colors[:4]):
            base = _COLOR_IDX + i * 3
            buf[base], buf[base + 1], buf[base + 2] = r, g, b
    buf[_MODE_IDX] = mode
    if sub is None:
        sub = 0x03 if mode in (MODE_WAVE, MODE_RAINBOW) else 0x00
    buf[_SUB_IDX] = sub
    buf[_PARAM_IDX] = _param(brightness, speed, direction, use_buffer, animated)
    buf[_SAVE_IDX] = 0x01 if save else 0x00
    with open(device, "rb+", buffering=0) as f:
        fcntl.ioctl(f.fileno(), HIDIOCSFEATURE(290), bytes(buf))


def _color(name):
    if name in COLORS:
        return COLORS[name]
    print(f"Unknown color: {name}", file=sys.stderr)
    sys.exit(1)


def _die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def _parse_effect(rest):
    """From a list of words, extracts colors, speed, brightness, direction and
    whether rainbow was requested. Used by `wave` (and as a base for `rainbow`)."""
    colors, speed, brightness, direction, rainbow = [], 1, 5, 0, False
    for a in rest:
        al = a.lower()
        if al == "rainbow":
            rainbow = True
        elif al in COLORS:
            colors.append(COLORS[al])
        elif al in SPEEDS:
            speed = SPEEDS[al]
        elif al in DIRS:
            direction = DIRS[al]
        elif a.isdigit():
            brightness = int(a)
        else:
            _die(f"Unrecognized argument: {a}")
    return colors, speed, brightness, direction, rainbow


def cmd_temp(rest):
    """CPU temperature mode: static color based on temperature. With 'loop'
    it refreshes every N seconds (default 3) until Ctrl+C."""
    import time
    loop, interval, brightness = False, 3.0, 5
    for a in rest:
        al = a.lower()
        if al in ("loop", "continuous"):
            loop = True
        elif "." in a and a.replace(".", "").isdigit():
            interval = float(a)
        elif a.isdigit():
            n = int(a)
            brightness = n if 1 <= n <= 5 else brightness
            if n > 5:
                interval = float(n)
        else:
            _die(f"Unrecognized argument: {a}")

    device = find_device()
    if not device:
        _die("Mystic Light device (0db0:0076) not found")

    def apply():
        t = cpu_temp()
        if t is None:
            _die("CPU temperature sensor not found")
        r, g, b = color_by_temp(t)
        set_argb([(r, g, b)], device, mode=MODE_STATIC, brightness=brightness, save=False)
        return t, (r, g, b)

    if not loop:
        t, (r, g, b) = apply()
        print(f"CPU {t:.0f}°C -> RGB({r}, {g}, {b}) on {device}")
        return
    print(f"Temperature mode looping every {interval:g}s (Ctrl+C to exit).")
    try:
        while True:
            t, (r, g, b) = apply()
            print(f"CPU {t:.0f}°C -> RGB({r}, {g}, {b})", flush=True)
            time.sleep(interval)
    except KeyboardInterrupt:
        print("\nTemperature mode ended.")


def main():
    args = sys.argv[1:]
    # 'temporary' in any position = do not write to flash (byte 289 = 00).
    save = not any(a.lower() in TEMPORARY_WORDS for a in args)
    args = [a for a in args if a.lower() not in TEMPORARY_WORDS]
    if not args:
        _die("Usage: rgb-board.py <color>|R G B|on|off|breathe|wave|rainbow|standard|temp …")

    cmd = args[0].lower()
    # Default values (static).
    mode, brightness, speed, direction, source, animated = MODE_STATIC, 5, 1, 0, 1, 1
    colors = None

    if cmd in ("breathe", "breathing"):
        mode = MODE_BREATHE
        rest = args[1:]
        if not rest:
            _die("Missing color: breathe <color> [speed] [brightness]")
        colors = [_color(rest[0].lower())]
        for extra in rest[1:]:
            if extra.lower() in SPEEDS:
                speed = SPEEDS[extra.lower()]
            elif extra.isdigit():
                brightness = int(extra)
            else:
                _die(f"Unrecognized argument: {extra}")

    elif cmd == "wave":
        mode = MODE_WAVE
        cols, speed, brightness, direction, rainbow = _parse_effect(args[1:])
        # No colors given, or rainbow requested -> generated rainbow source.
        if rainbow or not cols:
            source, colors = 0, None
        else:
            source, colors = 1, cols

    elif cmd == "rainbow":
        mode = MODE_RAINBOW
        _c, speed, brightness, direction, _r = _parse_effect(args[1:])
        source, colors = 0, None

    elif cmd == "standard":
        # Fixed multicolor: wave mode but WITHOUT animation and generated rainbow.
        mode, animated, source, speed = MODE_WAVE, 0, 0, 0
        colors = None
        for extra in args[1:]:
            if extra.isdigit():
                brightness = int(extra)
            else:
                _die(f"Unrecognized argument: {extra}")

    elif cmd in ("temp", "temperature", "cpu"):
        return cmd_temp(args[1:])

    elif cmd == "off":
        mode, colors = MODE_OFF, [(0, 0, 0)]

    elif cmd == "on":
        colors = [(64, 64, 64)]

    elif len(args) >= 3 and args[0].isdigit():
        colors = [tuple(int(x) for x in args[:3])]
        if len(args) >= 4 and args[3].isdigit():
            brightness = int(args[3])

    elif cmd in COLORS:
        colors = [COLORS[cmd]]
        if len(args) >= 2 and args[1].isdigit():
            brightness = int(args[1])

    else:
        _die(f"Unrecognized argument: {args[0]}")

    if colors:
        for c in colors:
            if not all(0 <= v <= 255 for v in c):
                _die("Values must be 0-255")
    if not 1 <= brightness <= 5:
        _die("Brightness must be 1-5")

    device = find_device()
    if not device:
        _die("Mystic Light device (0db0:0076) not found")

    set_argb(colors, device, mode=mode, brightness=brightness, speed=speed,
             direction=direction, use_buffer=source, animated=animated, save=save)

    mode_name = {MODE_OFF: "off", MODE_WAVE: "wave", MODE_STATIC: "static",
                 MODE_BREATHE: "breathing", MODE_RAINBOW: "rainbow"}[mode]
    if mode == MODE_WAVE and not animated:
        mode_name = "standard"
    source_txt = "buffer" if source else "rainbow"
    print(f"ARGB mode {mode_name} brightness {brightness} speed {speed} "
          f"direction {direction} source {source_txt} on {device}")


if __name__ == "__main__":
    main()
