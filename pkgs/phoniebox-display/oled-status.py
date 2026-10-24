#!/usr/bin/env python3
"""Phoniebox status display for a 128x64 I2C OLED (SSD1306 or SH1106).

Shows a volume bar and play state in the top strip, and the scrolling
song title, artist and progress below. Wakes on changes (new song,
play/pause, volume) and goes dark after a few seconds. Also shows
"Starting up...", "Jukebox offline" and "Goodbye!" screens.

Configured through environment variables, so a service can set them:
  OLED_BUS            I2C bus number               (default 1)
  OLED_ADDRESS        I2C address                  (default 0x3C)
  OLED_DRIVER         ssd1306 or sh1106            (default ssd1306)
  OLED_TIMEOUT        seconds before going dark    (default 6)
  OLED_OFFLINE_AFTER  seconds of silence = offline (default 25)
  PHONIEBOX_PUB       publisher address            (default tcp://localhost:5558)
"""
import json
import os
import signal
import subprocess
import sys
import time

import zmq
from PIL import ImageFont
from luma.core.interface.serial import i2c
from luma.core.render import canvas
from luma.oled.device import ssd1306, sh1106

# --- Settings ---------------------------------------------------------------

BUS = int(os.environ.get("OLED_BUS", "1"))
ADDR = int(os.environ.get("OLED_ADDRESS", "0x3C"), 0)
DRIVER = os.environ.get("OLED_DRIVER", "ssd1306")
PUB = os.environ.get("PHONIEBOX_PUB", "tcp://localhost:5558")
TIMEOUT = float(os.environ.get("OLED_TIMEOUT", "6"))
# The daemon publishes the CPU temperature every 10 s even when idle,
# so silence longer than this means the daemon is down.
OFFLINE_AFTER = float(os.environ.get("OLED_OFFLINE_AFTER", "25"))
FPS = 10

# --- Display ----------------------------------------------------------------

device = {"ssd1306": ssd1306, "sh1106": sh1106}[DRIVER](i2c(port=BUS, address=ADDR))
device.persist = True  # keep the last image on screen when the script exits

font_big = ImageFont.load_default(size=16)
font_small = ImageFont.load_default(size=11)

# --- Connection to the Phoniebox daemon -------------------------------------

sub = zmq.Context().socket(zmq.SUB)
sub.connect(PUB)
sub.setsockopt(zmq.SUBSCRIBE, b"")  # everything; any message counts as a heartbeat

# Latest known state
status = {}
volume = {"volume": 0, "mute": 0}
last_msg = None  # time of the last message from the daemon (None = none yet)


def drain():
    """Read every queued message, keeping only the newest of each kind."""
    global status, volume, last_msg
    while sub.poll(0):
        topic, payload = sub.recv_multipart()
        last_msg = time.monotonic()
        if not payload:
            continue
        try:
            data = json.loads(payload)
        except ValueError:
            continue
        if topic == b"playerstatus":
            status = data
        elif topic == b"volume.level":
            volume = data


# --- Drawing helpers --------------------------------------------------------

def num(x):
    """Convert to float; the daemon sends numbers as strings."""
    try:
        return float(x)
    except (TypeError, ValueError):
        return 0.0


def state_icon(d, state):
    if state == "play":
        d.polygon([(1, 3), (1, 12), (9, 7)], fill="white")
    elif state == "pause":
        d.rectangle((1, 3, 3, 12), fill="white")
        d.rectangle((6, 3, 8, 12), fill="white")
    else:
        d.rectangle((1, 3, 9, 12), outline="white")


def message(line1, line2=""):
    """Full-screen message (startup, offline, goodbye)."""
    with canvas(device) as d:
        d.text((4, 20), line1, font=font_big, fill="white")
        if line2:
            d.text((4, 42), line2, font=font_small, fill="white")


# --- Shutdown handling ------------------------------------------------------

def shutting_down():
    """True only during a real shutdown or reboot, not a service restart."""
    try:
        result = subprocess.run(
            ["systemctl", "is-system-running"],
            capture_output=True, text=True, timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.stdout.strip() == "stopping"


def on_stop(*_):
    device.show()
    if shutting_down():
        message("Goodbye!", "Shutting down...")
    else:
        device.clear()  # e.g. a redeploy restarted the service: stay quiet
    sys.exit(0)


signal.signal(signal.SIGTERM, on_stop)

# --- Main loop --------------------------------------------------------------


def main():
    scroll = 0
    last_title = None
    last_key = None
    last_active = time.monotonic()
    blanked = False
    frame = 1 / FPS

    while True:
        t0 = time.monotonic()
        drain()

        # Daemon not started yet, or gone quiet: show a waiting screen.
        if last_msg is None or t0 - last_msg > OFFLINE_AFTER:
            if blanked:
                device.show()
                blanked = False
            if last_msg is None:
                message("Starting up...")
            else:
                message("Jukebox offline", "waiting...")
            last_key = None  # wake the normal display when it comes back
            time.sleep(0.5)
            continue

        state = status.get("state", "stop")
        title = status.get("title") or os.path.basename(status.get("file", ""))
        artist = status.get("artist", "")
        if title != last_title:
            scroll, last_title = 0, title

        # Wake on anything a person did: new song, play/pause, volume or mute.
        key = (status.get("songid"), state, volume.get("volume"), volume.get("mute"))
        if key != last_key:
            last_key, last_active = key, t0
        idle = t0 - last_active > TIMEOUT
        if idle != blanked:
            if idle:
                device.hide()
            else:
                device.show()
                scroll = 0  # start the title from the beginning on wake
            blanked = idle

        if not blanked:
            with canvas(device) as d:
                # Yellow strip (rows 0-15): state icon + volume bar
                state_icon(d, state)
                vol = 0 if volume.get("mute") else int(volume.get("volume", 0))
                d.rectangle((14, 4, 127, 11), outline="white")
                d.rectangle((14, 4, 14 + 113 * vol // 100, 11), fill="white")

                # Blue area (rows 16-63): title, artist, progress
                if not title:
                    d.text((4, 26), "Tap a card!", font=font_big, fill="white")
                else:
                    w = d.textlength(title, font=font_big)
                    if w <= 128:
                        d.text(((128 - w) // 2, 18), title, font=font_big, fill="white")
                    else:
                        gap = 40
                        x = -(scroll % (w + gap))
                        d.text((x, 18), title, font=font_big, fill="white")
                        d.text((x + w + gap, 18), title, font=font_big, fill="white")
                        scroll += 2
                    d.text((0, 40), artist, font=font_small, fill="white")
                    dur = num(status.get("duration"))
                    if dur > 0:
                        pos = min(num(status.get("elapsed")) / dur, 1)
                        d.rectangle((0, 61, int(127 * pos), 63), fill="white")

        time.sleep(max(0, frame - (time.monotonic() - t0)))


try:
    main()
except KeyboardInterrupt:
    # Ctrl-C while testing: clear the screen instead of leaving it frozen.
    device.clear()
    device.hide()
