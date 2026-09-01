# 🟢 Matrix MPD Player for Radio Paradise

An interactive, terminal-style web frontend written in Python (Flask) that controls Music Player Daemon (MPD) on a Raspberry Pi to play high-quality Radio Paradise audio feeds.

Featuring a green-on-black Matrix CRT aesthetic, this application integrates directly with Radio Paradise's interactive API to support track skipping, dynamic stream quality selection (FLAC/AAC), auto-pause timeouts, and live playback metadata parsing.

---

## ⚡ Features

* **Matrix Terminal UI**: CRT scanline overlays, glowing text, and retro terminal styling.
* **True Track Skipping**: Uses Radio Paradise block APIs and MPD stream seeking to jump between individual songs seamlessly.
* **Channel Switching**: Connect to Main, Mellow, Rock, or Global/World mixes with an active-channel LED indicator inside each button.
* **Bitrate Configurator**: Live switching between FLAC Lossless, AAC 320k, and AAC 128k streams.
* **Auto-Pause Bandwidth Saver**: Automatically terminates the stream if left paused for more than 30 seconds.
* **MPD Health Status**: Visual LED indicator displaying local MPD daemon socket connectivity in real-time.
* **Instant UI Feedback**: Automatically clears metadata fields on button pushes to prevent stale track display.
* **Runs as a web fronted on port 5000**.

---

## 🛠 Prerequisites

* A Raspberry Pi running **Raspberry Pi OS** (Bullseye / Bookworm or newer).
* Active internet connection and audio output (3.5mm jack, HDMI, USB DAC, or HAT).

---

## 🚀 One-Step Deployment

You can deploy the entire stack—including dependencies, MPD server configuration, system service creation, and application code—with a single bash script, deploy.sh

