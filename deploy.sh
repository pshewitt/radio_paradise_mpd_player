#!/usr/bin/env bash

set -euo pipefail

if [ "$EUID" -eq 0 ]; then
  echo "[-] Please run this script as a normal user (e.g., 'pi'), not root."
  exit 1
fi

USER_NAME=$(whoami)
USER_HOME=$HOME
APP_DIR="${USER_HOME}/rp_app"

echo "=================================================="
echo " Starting Radio Paradise MPD Deployment"
echo " User: ${USER_NAME}"
echo " Directory: ${APP_DIR}"
echo "=================================================="

# 1. Update APT & Install Dependencies
echo "[+] Installing system packages via APT..."
sudo apt update
sudo apt install -y mpd mpc python3-flask python3-mpd python3-requests

# 2. Configure MPD & Fix Socket Conflicts
echo "[+] Configuring /etc/mpd.conf..."
if grep -q "^#*bind_to_address" /etc/mpd.conf; then
    sudo sed -i 's/^#*bind_to_address.*/bind_to_address "localhost"/' /etc/mpd.conf
fi

echo "[+] Disabling conflicting mpd.socket..."
sudo systemctl stop mpd.socket || true
sudo systemctl disable mpd.socket || true

echo "[+] Enabling and restarting MPD service..."
sudo systemctl enable mpd
sudo systemctl restart mpd

# 3. Setup App Directory and app.py
echo "[+] Setting up application directory at ${APP_DIR}..."
mkdir -p "${APP_DIR}"

echo "[+] Writing app.py..."
cat << 'EOF' > "${APP_DIR}/app.py"
import time
import threading
import requests
from flask import Flask, render_template_string, redirect, url_for, request, jsonify
from mpd import MPDClient

app = Flask(__name__)

CHANNELS = {
    "Main Mix": 0,
    "Mellow Mix": 1,
    "Rock Mix": 2,
    "Global/World Mix": 3
}

QUALITIES = {
    "FLAC Lossless": 4,
    "AAC 320k High": 2,
    "AAC 128k Standard": 1
}

PAUSE_TIMEOUT_SECONDS = 30

current_state = {
    "chan_id": 0,
    "bitrate": 4,
    "event": None,
    "end_event": None,
    "block_start_time": 0,
    "pause_start_time": None,
    "songs": [],
    "audio_url": None,
    "is_skipping": False
}

def get_mpd_client():
    client = MPDClient()
    client.connect("localhost", 6600)
    return client

def auto_stop_monitor():
    while True:
        time.sleep(2)
        if current_state["pause_start_time"] is not None:
            paused_duration = time.time() - current_state["pause_start_time"]
            if paused_duration >= PAUSE_TIMEOUT_SECONDS:
                try:
                    client = get_mpd_client()
                    status_info = client.status()
                    if status_info.get("state") == "pause":
                        client.stop()
                    client.disconnect()
                except Exception as e:
                    print(f"Auto-stop monitor error: {e}")
                finally:
                    current_state["pause_start_time"] = None

monitor_thread = threading.Thread(target=auto_stop_monitor, daemon=True)
monitor_thread.start()

def fetch_rp_block(chan_id=0, bitrate=4, event=None):
    url = f"[https://api.radioparadise.com/api/get_block?chan=](https://api.radioparadise.com/api/get_block?chan=){chan_id}&bitrate={bitrate}&info=true"
    if event is not None:
        url += f"&event={event}"

    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "Accept": "application/json"
    }

    try:
        response = requests.get(url, headers=headers, timeout=5)
        data = response.json()

        audio_url = data.get("url")
        if audio_url and not audio_url.startswith("http"):
            audio_url = f"https:{audio_url}"

        raw_songs = data.get("song")
        if isinstance(raw_songs, dict):
            song_items = list(raw_songs.values())
        elif isinstance(raw_songs, list):
            song_items = raw_songs
        else:
            song_items = []

        songs = []
        for song in song_items:
            songs.append({
                "title": song.get("title", "UNKNOWN_TRACK"),
                "artist": song.get("artist", "UNKNOWN_ARTIST"),
                "duration": float(song.get("duration", 0)) / 1000.0,
                "elapsed": float(song.get("elapsed", 0)) / 1000.0
            })

        return {
            "audio_url": audio_url,
            "event": data.get("event"),
            "end_event": data.get("end_event"),
            "songs": songs
        }
    except Exception as e:
        print(f"RP API Fetch Error: {e}")
        return None

HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MATRIX // RP MPD TERMINAL</title>
    <style>
        @import url('[https://fonts.googleapis.com/css2?family=Share+Tech+Mono&display=swap](https://fonts.googleapis.com/css2?family=Share+Tech+Mono&display=swap)');

        :root {
            --matrix-green: #00ff66;
            --matrix-dark-green: #003311;
            --matrix-dim: #008833;
            --matrix-bg: #050b05;
            --matrix-alert: #ff3333;
        }

        * { box-sizing: border-box; }

        body {
            background-color: var(--matrix-bg);
            color: var(--matrix-green);
            font-family: 'Share Tech Mono', monospace;
            margin: 0;
            padding: 20px;
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
            position: relative;
            overflow-x: hidden;
        }

        body::before {
            content: " ";
            display: block;
            position: fixed;
            top: 0; left: 0; bottom: 0; right: 0;
            background: linear-gradient(rgba(18, 16, 16, 0) 50%, rgba(0, 0, 0, 0.25) 50%), linear-gradient(90deg, rgba(255, 0, 0, 0.03), rgba(0, 255, 0, 0.01), rgba(0, 0, 255, 0.03));
            z-index: 10;
            background-size: 100% 3px, 6px 100%;
            pointer-events: none;
        }

        .terminal-container {
            width: 100%;
            max-width: 480px;
            border: 2px solid var(--matrix-green);
            border-radius: 4px;
            padding: 24px;
            background: rgba(0, 15, 5, 0.85);
            box-shadow: 0 0 20px rgba(0, 255, 102, 0.2), inset 0 0 15px rgba(0, 255, 102, 0.1);
            position: relative;
            z-index: 1;
        }

        .header-bar {
            display: flex;
            justify-content: space-between;
            align-items: center;
            border-bottom: 1px dashed var(--matrix-dim);
            padding-bottom: 12px;
            margin-bottom: 20px;
        }

        h1 {
            font-size: 1.2rem;
            margin: 0;
            text-transform: uppercase;
            letter-spacing: 2px;
            text-shadow: 0 0 8px var(--matrix-green);
        }

        .led-container {
            display: flex;
            align-items: center;
            gap: 8px;
            font-size: 0.8rem;
            letter-spacing: 1px;
        }

        .led {
            width: 12px;
            height: 12px;
            border-radius: 50%;
            background-color: var(--matrix-dark-green);
            border: 1px solid var(--matrix-dim);
            transition: all 0.3s ease;
        }

        .led.online {
            background-color: var(--matrix-green);
            box-shadow: 0 0 10px var(--matrix-green), 0 0 20px var(--matrix-green);
        }

        .led.offline {
            background-color: var(--matrix-alert);
            box-shadow: 0 0 10px var(--matrix-alert), 0 0 20px var(--matrix-alert);
            animation: pulse-red 1s infinite;
        }

        @keyframes pulse-red { 50% { opacity: 0.4; } }

        .status-box {
            border: 1px solid var(--matrix-dim);
            background: rgba(0, 30, 10, 0.4);
            padding: 15px;
            margin-bottom: 20px;
            text-align: left;
            box-shadow: inset 0 0 10px rgba(0, 255, 102, 0.05);
        }

        .status-line {
            margin: 6px 0;
            font-size: 0.95rem;
            word-break: break-word;
        }

        .label { color: var(--matrix-dim); text-transform: uppercase; }
        .val { color: var(--matrix-green); text-shadow: 0 0 5px var(--matrix-green); }

        .blink { animation: blinker 1s linear infinite; }
        @keyframes blinker { 50% { opacity: 0; } }

        .btn-group { display: flex; gap: 10px; margin-bottom: 20px; }
        .btn-group form { flex: 1; }

        button, select {
            width: 100%;
            background: transparent;
            color: var(--matrix-green);
            border: 1px solid var(--matrix-green);
            padding: 12px;
            font-family: 'Share Tech Mono', monospace;
            font-size: 0.95rem;
            text-transform: uppercase;
            letter-spacing: 1px;
            cursor: pointer;
            transition: all 0.2s ease;
            text-shadow: 0 0 4px var(--matrix-green);
        }

        select {
            background-color: var(--matrix-bg);
            appearance: none;
            -webkit-appearance: none;
            background-image: url('data:image/svg+xml;utf8,<svg fill="%2300ff66" height="24" viewBox="0 0 24 24" width="24" xmlns="[http://www.w3.org/2000/svg](http://www.w3.org/2000/svg)"><path d="M7 10l5 5 5-5z"/></svg>');
            background-repeat: no-repeat;
            background-position: right 10px center;
        }

        select option { background-color: var(--matrix-bg); color: var(--matrix-green); }

        button:hover, select:hover {
            background-color: var(--matrix-green);
            color: var(--matrix-bg);
            box-shadow: 0 0 15px var(--matrix-green);
            text-shadow: none;
        }

        button:hover .btn-led {
            border-color: var(--matrix-bg);
        }

        button:active { transform: scale(0.98); }

        .section-title {
            font-size: 0.9rem;
            color: var(--matrix-dim);
            text-align: left;
            margin-bottom: 10px;
            text-transform: uppercase;
            letter-spacing: 1px;
        }

        .control-block { margin-bottom: 20px; }

        .channel-list {
            display: flex;
            flex-direction: column;
            gap: 10px;
            margin-bottom: 20px;
        }

        .chan-btn {
            display: flex;
            align-items: center;
            justify-content: flex-start;
            gap: 12px;
            text-align: left;
        }

        .btn-led {
            width: 10px;
            height: 10px;
            border-radius: 50%;
            background-color: #051505;
            border: 1px solid var(--matrix-dim);
            flex-shrink: 0;
            transition: all 0.3s ease;
        }

        .btn-led.active {
            background-color: var(--matrix-green);
            box-shadow: 0 0 8px var(--matrix-green), 0 0 12px var(--matrix-green);
            border-color: var(--matrix-green);
        }

        .btn-stop {
            border-color: var(--matrix-alert);
            color: var(--matrix-alert);
            text-shadow: 0 0 4px var(--matrix-alert);
        }

        .btn-stop:hover {
            background: var(--matrix-alert);
            color: #000;
            box-shadow: 0 0 15px var(--matrix-alert);
        }
    </style>
</head>
<body>

    <div class="terminal-container">
        <div class="header-bar">
            <h1>[ AUDIO_NODE ]</h1>
            <div class="led-container">
                <span id="mpd-led" class="led"></span>
                <span id="mpd-label" class="label">MPD: CHECKING</span>
            </div>
        </div>
        
        <div class="status-box">
            <div class="status-line"><span class="label">STATE:</span> <span class="val" id="player-state">INITIALIZING...</span><span class="blink">_</span></div>
            <div class="status-line"><span class="label">TRACK:</span> <span class="val" id="track-title">--</span></div>
            <div class="status-line"><span class="label">ARTIST:</span> <span class="val" id="track-artist">--</span></div>
            <div class="status-line"><span class="label">BITRATE:</span> <span class="val" id="current-bitrate">--</span></div>
        </div>

        <div class="control-block">
            <div class="section-title">>> STREAM QUALITY CONFIG:</div>
            <select id="quality-selector" onchange="updateQuality(this.value)">
                {% for name, val in qualities.items() %}
                    <option value="{{ val }}" {% if val == selected_bitrate %}selected{% endif %}>{{ name }}</option>
                {% endfor %}
            </select>
        </div>

        <div class="btn-group">
            <form method="POST" action="/toggle_play">
                <button type="submit" id="toggle-btn">[ PAUSE ]</button>
            </form>
            <form method="POST" action="/skip">
                <button type="submit">[ SKIP >> ]</button>
            </form>
        </div>

        <div class="section-title">>> SELECT STREAM SIGNAL:</div>
        <div class="channel-list">
        {% for name, chan_id in channels.items() %}
            <form method="POST" action="/play_channel" style="width: 100%;">
                <input type="hidden" name="chan_id" value="{{ chan_id }}">
                <button type="submit" class="chan-btn">
                    <span id="chan-led-{{ chan_id }}" class="btn-led"></span>
                    CONNECT: {{ name }}
                </button>
            </form>
        {% endfor %}
        </div>

        <form method="POST" action="/control/stop">
            <button type="submit" class="btn-stop">[ TERMINATE STREAM ]</button>
        </form>
    </div>

    <script>
        function clearTrackInfo() {
            document.getElementById('track-title').innerText = 'FETCHING_TRACK...';
            document.getElementById('track-artist').innerText = 'FETCHING_ARTIST...';
        }

        document.addEventListener('DOMContentLoaded', () => {
            document.querySelectorAll('form').forEach(form => {
                form.addEventListener('submit', () => {
                    clearTrackInfo();
                });
            });
        });

        async function fetchStatus() {
            try {
                const response = await fetch('/status');
                const data = await response.json();
                
                const mpdLed = document.getElementById('mpd-led');
                const mpdLabel = document.getElementById('mpd-label');
                const toggleBtn = document.getElementById('toggle-btn');

                if (data.mpd_online) {
                    mpdLed.className = 'led online';
                    mpdLabel.innerText = 'MPD: ONLINE';
                    mpdLabel.style.color = 'var(--matrix-green)';
                    
                    const stateUpper = data.state.toUpperCase();
                    document.getElementById('player-state').innerText = stateUpper;
                    document.getElementById('track-title').innerText = data.title || '--';
                    document.getElementById('track-artist').innerText = data.artist || '--';
                    document.getElementById('current-bitrate').innerText = data.bitrate || '--';

                    if (stateUpper === 'PLAY') {
                        toggleBtn.innerText = '[ PAUSE ]';
                    } else {
                        toggleBtn.innerText = '[ PLAY ]';
                    }

                    document.querySelectorAll('.btn-led').forEach(el => el.classList.remove('active'));
                    if (stateUpper === 'PLAY' || stateUpper === 'PAUSE') {
                        const activeLed = document.getElementById(`chan-led-${data.active_chan}`);
                        if (activeLed) activeLed.classList.add('active');
                    }
                } else {
                    mpdLed.className = 'led offline';
                    mpdLabel.innerText = 'MPD: OFFLINE';
                    mpdLabel.style.color = 'var(--matrix-alert)';
                    document.getElementById('player-state').innerText = 'SOCKET_DISCONNECTED';
                    document.getElementById('track-title').innerText = '--';
                    document.getElementById('track-artist').innerText = '--';
                    document.getElementById('current-bitrate').innerText = '--';
                    document.querySelectorAll('.btn-led').forEach(el => el.classList.remove('active'));
                }
            } catch (err) {
                const mpdLed = document.getElementById('mpd-led');
                const mpdLabel = document.getElementById('mpd-label');
                mpdLed.className = 'led offline';
                mpdLabel.innerText = 'MPD: OFFLINE';
                mpdLabel.style.color = 'var(--matrix-alert)';
                document.getElementById('player-state').innerText = 'SERVER_UNREACHABLE';
                document.querySelectorAll('.btn-led').forEach(el => el.classList.remove('active'));
            }
        }

        async function updateQuality(val) {
            clearTrackInfo();
            await fetch('/set_quality', {
                method: 'POST',
                headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                body: `bitrate=${val}`
            });
            fetchStatus();
        }

        setInterval(fetchStatus, 3000);
        fetchStatus();
    </script>
</body>
</html>
"""

@app.route("/")
def index():
    return render_template_string(
        HTML_TEMPLATE, 
        channels=CHANNELS, 
        qualities=QUALITIES, 
        selected_bitrate=current_state["bitrate"]
    )

@app.route("/toggle_play", methods=["POST"])
def toggle_play():
    current_state["is_skipping"] = True
    try:
        client = get_mpd_client()
        status_info = client.status()
        state = status_info.get("state", "stop")

        if state == "play":
            client.pause(1)
            current_state["pause_start_time"] = time.time()
        elif state == "pause":
            client.pause(0)
            current_state["pause_start_time"] = None
        elif state == "stop":
            current_state["pause_start_time"] = None
            if current_state["audio_url"]:
                client.play()
            else:
                block = fetch_rp_block(chan_id=current_state["chan_id"], bitrate=current_state["bitrate"])
                if block and block["audio_url"]:
                    current_state["event"] = block["event"]
                    current_state["end_event"] = block["end_event"]
                    current_state["songs"] = block["songs"]
                    current_state["audio_url"] = block["audio_url"]
                    current_state["block_start_time"] = time.time()
                    client.clear()
                    client.add(block["audio_url"])
                    client.play()
        client.disconnect()
    except Exception as e:
        print(f"Toggle Play Error: {e}")
    finally:
        current_state["is_skipping"] = False

    return redirect(url_for("index"))

@app.route("/set_quality", methods=["POST"])
def set_quality():
    new_bitrate = int(request.form.get("bitrate", 4))
    current_state["bitrate"] = new_bitrate
    current_state["is_skipping"] = True
    current_state["pause_start_time"] = None
    
    block = fetch_rp_block(chan_id=current_state["chan_id"], bitrate=new_bitrate)
    if block and block["audio_url"]:
        current_state["event"] = block["event"]
        current_state["end_event"] = block["end_event"]
        current_state["songs"] = block["songs"]
        current_state["audio_url"] = block["audio_url"]
        current_state["block_start_time"] = time.time()

        try:
            client = get_mpd_client()
            client.clear()
            client.add(block["audio_url"])
            client.play()
            client.disconnect()
        except Exception as e:
            print(f"Quality Set MPD Error: {e}")

    current_state["is_skipping"] = False
    return jsonify({"status": "ok", "bitrate": new_bitrate})

@app.route("/play_channel", methods=["POST"])
def play_channel():
    chan_id = int(request.form.get("chan_id", 0))
    current_state["is_skipping"] = True
    current_state["pause_start_time"] = None
    block = fetch_rp_block(chan_id=chan_id, bitrate=current_state["bitrate"])

    if block and block["audio_url"]:
        current_state["chan_id"] = chan_id
        current_state["event"] = block["event"]
        current_state["end_event"] = block["end_event"]
        current_state["songs"] = block["songs"]
        current_state["audio_url"] = block["audio_url"]
        current_state["block_start_time"] = time.time()

        try:
            client = get_mpd_client()
            client.clear()
            client.add(block["audio_url"])
            client.play()
            client.disconnect()
        except Exception as e:
            print(f"Play Channel MPD Error: {e}")

    current_state["is_skipping"] = False
    return redirect(url_for("index"))

@app.route("/skip", methods=["POST"])
def skip():
    current_state["is_skipping"] = True
    current_state["pause_start_time"] = None
    try:
        client = get_mpd_client()
        status_info = client.status()
        current_elapsed = float(status_info.get("elapsed", 0))

        next_song = None
        for song in current_state["songs"]:
            if song["elapsed"] > (current_elapsed + 2):
                next_song = song
                break

        if next_song:
            client.seek(0, int(next_song["elapsed"]))
        else:
            next_block = fetch_rp_block(
                chan_id=current_state["chan_id"], 
                bitrate=current_state["bitrate"], 
                event=current_state["end_event"]
            )
            if next_block and next_block["audio_url"]:
                current_state["event"] = next_block["event"]
                current_state["end_event"] = next_block["end_event"]
                current_state["songs"] = next_block["songs"]
                current_state["audio_url"] = next_block["audio_url"]
                current_state["block_start_time"] = time.time()

                client.clear()
                client.add(next_block["audio_url"])
                client.play()
        client.disconnect()
    except Exception as e:
        print(f"Skip Error: {e}")
    finally:
        current_state["is_skipping"] = False

    return redirect(url_for("index"))

@app.route("/status")
def status():
    try:
        client = get_mpd_client()
        mpd_status = client.status()
        state = mpd_status.get("state", "stop")
        current_elapsed = float(mpd_status.get("elapsed", 0))
        client.disconnect()

        if current_state["is_skipping"]:
            title = "FETCHING_TRACK..."
            artist = "FETCHING_ARTIST..."
        elif state not in ["play", "pause"]:
            title = "--"
            artist = "--"
        else:
            title = "--"
            artist = "--"
            if current_state["songs"]:
                active_song = current_state["songs"][0]
                for song in current_state["songs"]:
                    if current_elapsed >= song["elapsed"]:
                        active_song = song
                    else:
                        break
                title = active_song["title"]
                artist = active_song["artist"]

        bitrate_label = next(
            (k for k, v in QUALITIES.items() if v == current_state["bitrate"]), 
            "CUSTOM"
        )

        return jsonify({
            "mpd_online": True,
            "state": state,
            "title": title,
            "artist": artist,
            "bitrate": bitrate_label,
            "active_chan": current_state["chan_id"]
        })
    except Exception:
        return jsonify({
            "mpd_online": False,
            "state": "offline",
            "title": "--",
            "artist": "--",
            "bitrate": "--",
            "active_chan": None
        })

@app.route("/control/<action>", methods=["POST"])
def control(action):
    try:
        client = get_mpd_client()
        if action == "stop":
            client.stop()
            current_state["pause_start_time"] = None
        client.disconnect()
    except Exception:
        pass
    return redirect(url_for("index"))

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
EOF

# 4. Create Systemd Service
echo "[+] Configuring systemd service (/etc/systemd/system/rp-web.service)..."
sudo bash -c "cat << EOF > /etc/systemd/system/rp-web.service
[Unit]
Description=Radio Paradise MPD Web Controller
After=network.target mpd.service
Wants=mpd.service

[Service]
Type=simple
User=${USER_NAME}
WorkingDirectory=${APP_DIR}
ExecStart=/usr/bin/python3 ${APP_DIR}/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

# 5. Reload & Start Service
echo "[+] Enabling and starting rp-web.service..."
sudo systemctl daemon-reload
sudo systemctl enable --now rp-web.service

echo "=================================================="
echo " Deployment Complete!"
echo " Access terminal at: http://$(hostname -I | awk '{print $1}'):5000"
echo "=================================================="
