#!/bin/bash
# ============================================================
#  Meeting Notes installer.  Run once with:
#    curl -fsSL <YOUR-URL>/install.sh | bash
#  Afterwards, just type  meeting  whenever a call starts.
# ============================================================
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
echo "Installing Meeting Notes — a few minutes the first time…"

if ! command -v brew >/dev/null 2>&1; then
  echo ""
  echo "Homebrew is required first. Paste this, then re-run the installer:"
  echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  exit 1
fi

BREW_BIN="$(brew --prefix)/bin"
SUPPORT="$HOME/Library/Application Support/MeetingNotes"
OUT_DIR="$HOME/Desktop/Meeting Notes"
mkdir -p "$SUPPORT" "$OUT_DIR"

echo ">>> Installing audio tools + local AI runtime…"
brew install ffmpeg switchaudio-osx blackhole-2ch 2>/dev/null || true
# llama.cpp — a small, fast local inference engine. Its `llama-server` binary
# speaks the same OpenAI-compatible /v1 API Ollama did, so notes_engine.py
# doesn't need to know the difference. Homebrew builds it with Metal support
# on Apple Silicon automatically.
if command -v llama-server >/dev/null 2>&1; then
  echo "    llama.cpp already installed — skipping."
else
  brew install llama.cpp 2>/dev/null || true
fi
sudo killall coreaudiod 2>/dev/null || true   # makes BlackHole appear

LLAMA_SERVER_BIN="$(brew --prefix)/bin/llama-server"
MODEL_REPO="unsloth/gemma-4-E4B-it-GGUF"
MODEL_QUANT="Q8_0"
MODEL_ALIAS="gemma4:e4b"
# Gemma 4 E4B supports up to 128K tokens. 32K comfortably covers a multi-hour
# meeting transcript + prompt overhead without eating excessive RAM for the
# KV cache. Raise this (up to 131072) if you hit context errors on very long
# recordings and have RAM to spare — each doubling roughly doubles KV-cache RAM.
MODEL_CTX="32768"

echo ">>> Checking the llama.cpp background service…"
mkdir -p "$HOME/Library/LaunchAgents"
PLIST="$HOME/Library/LaunchAgents/com.meetingnotes.llamaserver.plist"
NEW_PLIST=$(cat << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.meetingnotes.llamaserver</string>
  <key>ProgramArguments</key>
  <array>
    <string>$LLAMA_SERVER_BIN</string>
    <string>-hf</string><string>$MODEL_REPO:$MODEL_QUANT</string>
    <string>--alias</string><string>$MODEL_ALIAS</string>
    <string>--port</string><string>8080</string>
    <string>-c</string><string>$MODEL_CTX</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$SUPPORT/llama-server.log</string>
  <key>StandardErrorPath</key><string>$SUPPORT/llama-server.log</string>
</dict>
</plist>
PLIST_EOF
)

if [ -f "$PLIST" ] && [ "$(cat "$PLIST")" = "$NEW_PLIST" ] \
   && curl -fsS http://localhost:8080/v1/models >/dev/null 2>&1; then
  echo "    Already registered and running — leaving it alone."
else
  echo "$NEW_PLIST" > "$PLIST"
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
fi

echo ">>> Building the local AI environment…"
python3 -m venv "$SUPPORT/venv"
"$SUPPORT/venv/bin/pip" install --quiet --upgrade pip
"$SUPPORT/venv/bin/pip" install --quiet mlx-whisper openai

echo ">>> Making sure the LLM is downloaded and the server is ready…"
for i in $(seq 1 180); do
  if curl -fsS http://localhost:8080/v1/models >/dev/null 2>&1; then
    echo "    Model ready."
    break
  fi
  sleep 5
done
if ! curl -fsS http://localhost:8080/v1/models >/dev/null 2>&1; then
  echo "    ⚠️  Still downloading/starting — it'll finish in the background."
  echo "        Check progress: tail -f \"$SUPPORT/llama-server.log\""
fi

WHISPER_MODEL_DIR="$SUPPORT/models/whisper-large-v3-turbo"
if [ -d "$WHISPER_MODEL_DIR" ] && [ -n "$(ls -A "$WHISPER_MODEL_DIR" 2>/dev/null)" ]; then
  echo "    Found a local Whisper model at $WHISPER_MODEL_DIR — skipping download."
else
  ffmpeg -hide_banner -loglevel error -f lavfi -i anullsrc=r=16000:cl=mono -t 1 "$SUPPORT/_warm.wav" -y 2>/dev/null || true
  if "$SUPPORT/venv/bin/python3" -c "import mlx_whisper; mlx_whisper.transcribe('$SUPPORT/_warm.wav', path_or_hf_repo='mlx-community/whisper-large-v3-turbo')" 2>/tmp/meeting-notes-whisper-warm.log; then
    echo "    Whisper model downloaded and cached."
  else
    echo ""
    echo "    ⚠️  Couldn't download the Whisper model automatically."
    echo "        This is usually a corporate SSL/proxy issue, not a real problem with the tool."
    echo "        Fix (no network required after this):"
    echo "          1. In a browser, open:"
    echo "             https://huggingface.co/mlx-community/whisper-large-v3-turbo/tree/main"
    echo "          2. Download every file listed there."
    echo "          3. Put them directly inside:"
    echo "             $WHISPER_MODEL_DIR"
    echo "        'meeting' will automatically use that folder instead of downloading — see log:"
    echo "        /tmp/meeting-notes-whisper-warm.log"
  fi
  rm -f "$SUPPORT/_warm.wav"
fi

echo ">>> Installing the note engine…"
cat > "$SUPPORT/notes_engine.py" << 'PYEOF'
#!/usr/bin/env python3
"""notes_engine.py - used by the Meeting Notes app. Transcribes + summarizes an audio
file locally, writes a Markdown file into --out-dir, and prints ONLY that path on stdout
(all progress goes to stderr so the app can capture the result cleanly)."""
import argparse, re, sys, time
from pathlib import Path


def log(msg):  # progress -> stderr
    print(msg, file=sys.stderr, flush=True)


def _local_whisper_dir():
    """Where a manually-downloaded model lives, if you placed one there."""
    return Path.home() / "Library" / "Application Support" / "MeetingNotes" / "models" / "whisper-large-v3-turbo"


def resolve_whisper_source(model_arg):
    """Prefer an explicit --model, then a local manually-downloaded copy, then the HF repo id."""
    if model_arg:
        return model_arg
    local = _local_whisper_dir()
    if local.is_dir() and any(local.iterdir()):
        return str(local)
    return "mlx-community/whisper-large-v3-turbo"


def fmt(s):
    m, s = divmod(int(round(s)), 60); h, m = divmod(m, 60)
    return f"{h}h {m}m {s}s" if h else (f"{m}m {s}s" if m else f"{s}s")


def collapse_repeats(text, max_run=3):
    out, run = [], 0
    for w in text.split():
        if out and w.lower() == out[-1].lower():
            run += 1
            if run >= max_run:
                continue
        else:
            run = 0
        out.append(w)
    return " ".join(out)


SYSTEM_PROMPT = """You are an expert meeting-notes assistant. Given a raw, possibly messy meeting \
transcript, produce clean Markdown notes with exactly these sections:

## TL;DR
One or two sentences with the single most important outcome.

## Key Points
Main topics, as concise bullets.

## Decisions
Concrete decisions made. If none, write "None recorded."

## Action Items
A checklist. Each line: - [ ] <task> - <owner if mentioned, else 'unassigned'> (<due date if mentioned>)

## Open Questions
Anything left unresolved.

Be faithful to the transcript. Do NOT invent names, numbers, dates, or commitments. Keep it tight."""

# Used only when the transcript carries "You:" / "Them:" speaker tags (dual mic/system capture).
SYSTEM_PROMPT_LABELED = """You are an expert meeting-notes assistant. Given a raw, possibly messy \
meeting transcript, produce clean Markdown notes with exactly these sections:

## TL;DR
One or two sentences with the single most important outcome.

## Key Points
Main topics, as concise bullets.

## Decisions
Concrete decisions made. If none, write "None recorded."

## Action Items
A checklist. Each line: - [ ] <task> - <owner> (<due date if mentioned>)
Each line of the transcript is tagged with who said it: "You" is the note-taker (this user), \
"Them" is whoever else was on the call. When a speaker commits to a task and no other name is \
stated, assign it to "You" or "Them" based on the tag on that line. If a specific name is \
mentioned in the dialogue (e.g. "Priya" saying she'll do something), prefer that name over the tag.

## Open Questions
Anything left unresolved.

Be faithful to the transcript. Do NOT invent names, numbers, dates, or commitments. Keep it tight."""


def transcribe_file(audio_path, whisper_source):
    """Run Whisper on one audio file. Returns (segments, elapsed_seconds)."""
    import mlx_whisper
    t0 = time.perf_counter()
    try:
        result = mlx_whisper.transcribe(str(audio_path), path_or_hf_repo=whisper_source,
                                        condition_on_previous_text=False)
    except Exception as e:
        if "CERTIFICATE" in str(e).upper() or "SSL" in str(e).upper():
            local = _local_whisper_dir()
            log("Could not download the Whisper model (SSL/certificate error — common on corporate networks).")
            log("Fix: download the files from")
            log("  https://huggingface.co/mlx-community/whisper-large-v3-turbo/tree/main")
            log(f"and place them directly in: {local}")
            log("No network will be needed once they're there.")
            sys.exit(1)
        raise
    return result.get("segments", []), time.perf_counter() - t0


def merge_labeled_transcript(mic_segments, sys_segments):
    """Interleave two speaker-tagged segment lists by start time into one readable transcript.
    Ties (equal start time) are broken deterministically: You before Them."""
    tagged = [(seg["start"], 0, "You", seg["text"].strip()) for seg in mic_segments if seg["text"].strip()]
    tagged += [(seg["start"], 1, "Them", seg["text"].strip()) for seg in sys_segments if seg["text"].strip()]
    tagged.sort(key=lambda t: (t[0], t[1]))
    lines = []
    for start, _, speaker, text in tagged:
        m, s = divmod(int(start), 60)
        lines.append(f"[{m:02d}:{s:02d}] {speaker}: {collapse_repeats(text)}")
    return "\n".join(lines)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("audio", nargs="?", help="Single combined audio file (legacy/no speaker labels)")
    p.add_argument("--mic", help="Mic-only audio file (your voice)")
    p.add_argument("--system", help="System/loopback-only audio file (the far side)")
    p.add_argument("--out-dir", required=True)
    p.add_argument("--model", default=None, help="Whisper model repo or local folder (default: local copy if present, else download)")
    p.add_argument("--llm", default="gemma4:e4b")
    p.add_argument("--base-url", default="http://localhost:8080/v1")
    p.add_argument("--api-key", default="not-needed")
    args = p.parse_args()

    dual_mode = bool(args.mic and args.system)
    if not dual_mode and not args.audio:
        log("Provide either a single audio file, or --mic and --system.")
        sys.exit(1)

    source = resolve_whisper_source(args.model)

    if dual_mode:
        mic_path = Path(args.mic).expanduser()
        sys_path = Path(args.system).expanduser()
        for pth in (mic_path, sys_path):
            if not pth.exists():
                log(f"Audio not found: {pth}"); sys.exit(1)

        log(f"Transcribing your mic on the GPU ({source})...")
        mic_segments, t_mic = transcribe_file(mic_path, source)
        log(f"Transcribing the far side on the GPU ({source})...")
        sys_segments, t_sys = transcribe_file(sys_path, source)
        t_tx = t_mic + t_sys

        transcript = merge_labeled_transcript(mic_segments, sys_segments)
        if not transcript:
            transcript = "(No speech detected in the recording.)"
        system_prompt = SYSTEM_PROMPT_LABELED
    else:
        audio = Path(args.audio).expanduser()
        if not audio.exists():
            log(f"Audio not found: {audio}"); sys.exit(1)

        log(f"Transcribing on the GPU ({source})...")
        segments, t_tx = transcribe_file(audio, source)
        transcript = collapse_repeats(" ".join(seg["text"].strip() for seg in segments).strip())
        if not transcript:
            transcript = "(No speech detected in the recording.)"
        system_prompt = SYSTEM_PROMPT

    from openai import OpenAI
    log("Summarizing with the local model...")
    client = OpenAI(base_url=args.base_url, api_key=args.api_key)
    t0 = time.perf_counter()
    resp = client.chat.completions.create(
        model=args.llm, temperature=0.2,
        messages=[{"role": "system", "content": system_prompt},
                  {"role": "user", "content": f"Here is the meeting transcript:\n\n{transcript}"}],
    )
    t_sum = time.perf_counter() - t0
    notes = resp.choices[0].message.content.strip()

    out_dir = Path(args.out_dir).expanduser(); out_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y-%m-%d_%H-%M")
    out_path = out_dir / f"Meeting Notes {stamp}.md"
    header = (f"# Meeting Notes - {stamp}\n\n"
              f"*Generated 100% locally - transcription {fmt(t_tx)} - summary {fmt(t_sum)}*\n\n")
    out_path.write_text(header + notes + "\n\n---\n\n## Full Transcript\n\n" + transcript + "\n",
                        encoding="utf-8")

    log(f"Done in {fmt(t_tx + t_sum)} - $0.00")
    print(str(out_path))   # the ONLY thing on stdout: the file path


if __name__ == "__main__":
    main()
PYEOF

# Ask who to email notes to (osascript works even through curl | bash)
EMAIL=$(osascript -e 'text returned of (display dialog "Email a copy of every meeting note to:\n(leave blank to skip)" default answer "" with title "Meeting Notes")' 2>/dev/null || echo "")

cat > "$SUPPORT/config.sh" << CFG
EMAIL="$EMAIL"
MIC_DEVICE="Microphone"
MIC_FALLBACK_DEVICE="MacBook Pro Microphone"
SYSTEM_DEVICE="BlackHole 2ch"
OUTPUT_DEVICE="Meeting Output"
# --- LLM provider (any OpenAI-compatible server). Edit these to switch. ---
# llama.cpp :8080/v1 (default) | Ollama :11434/v1 | LM Studio :1234/v1 | oMLX :8005/v1 | OpenAI https://api.openai.com/v1
LLM="gemma4:e4b"
BASE_URL="http://localhost:8080/v1"
API_KEY="not-needed"
CFG

echo ">>> Installing the 'meeting' command…"
cat > "$BREW_BIN/meeting" << 'MEETEOF'
#!/bin/bash
# `meeting` - run this whenever a call starts. Records you + everyone you hear,
# then writes notes locally and emails you a copy. No app, no cloud, no bill.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

SUPPORT="$HOME/Library/Application Support/MeetingNotes"
OUT_DIR="$HOME/Desktop/Meeting Notes"
[ -f "$SUPPORT/config.sh" ] && . "$SUPPORT/config.sh"
: "${MIC_DEVICE:=Microphone}"; : "${MIC_FALLBACK_DEVICE:=MacBook Pro Microphone}"; : "${SYSTEM_DEVICE:=BlackHole 2ch}"; : "${OUTPUT_DEVICE:=Meeting Output}"
: "${LLM:=gemma4:e4b}"; : "${BASE_URL:=http://localhost:8080/v1}"; : "${API_KEY:=not-needed}"

# Start the local llama.cpp service if it's not already answering (e.g. after a
# reboot before login-item startup, or if it was quit manually).
ensure_llm_running() {
  case "$BASE_URL" in
    http://localhost:8080/v1*)
      curl -fsS "$BASE_URL/models" >/dev/null 2>&1 && return
      echo "🧠  Starting llama.cpp…"
      launchctl kickstart -k "gui/$(id -u)/com.meetingnotes.llamaserver" >/dev/null 2>&1 || true
      for i in $(seq 1 60); do
        curl -fsS "$BASE_URL/models" >/dev/null 2>&1 && return
        sleep 2
      done
      echo "⚠️  llama.cpp didn't come up in time — check: tail -f \"$SUPPORT/llama-server.log\""
      ;;
  esac
}

# List models at whatever OpenAI-compatible endpoint is selected (works for any provider)
list_models() {
  "$SUPPORT/venv/bin/python3" - "$BASE_URL" "$API_KEY" 2>/dev/null << 'PY' || echo "  (could not reach $BASE_URL)"
import sys
from openai import OpenAI
for m in OpenAI(base_url=sys.argv[1], api_key=sys.argv[2] or "x").models.list().data:
    print("  -", m.id)
PY
}

# --- pick model / provider / endpoint for this run (any OpenAI-compatible server) ---
INPUT_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--model)    LLM="$2"; shift 2 ;;
    -u|--url)      BASE_URL="$2"; shift 2 ;;
    -k|--key)      API_KEY="$2"; shift 2 ;;
    -p|--provider)
      case "$2" in
        llamacpp) BASE_URL="http://localhost:8080/v1" ;;
        ollama)   BASE_URL="http://localhost:11434/v1" ;;
        lmstudio) BASE_URL="http://localhost:1234/v1" ;;
        omlx)     BASE_URL="http://localhost:8005/v1" ;;
        openai)   BASE_URL="https://api.openai.com/v1" ;;
        *) echo "Unknown provider '$2' (use: llamacpp|ollama|lmstudio|omlx|openai)"; exit 1 ;;
      esac; shift 2 ;;
    -f|--file)     INPUT_FILE="$2"; shift 2 ;;
    -l|--list)     echo "Models at $BASE_URL:"; list_models; exit 0 ;;
    -h|--help)
      echo "Usage: meeting [options]"
      echo "  -m, --model MODEL    model for this run (default: $LLM)"
      echo "  -p, --provider NAME  llamacpp | ollama | lmstudio | omlx | openai"
      echo "  -u, --url URL        any OpenAI-compatible endpoint ending in /v1"
      echo "  -k, --key KEY        API key (for cloud providers)"
      echo "  -f, --file PATH      reprocess an existing recording instead of recording a new one"
      echo "  -l, --list           list models at the current endpoint"
      exit 0 ;;
    *) LLM="$1"; shift ;;
  esac
done
echo "📋  Model: $LLM   @  $BASE_URL"

mkdir -p "$OUT_DIR"
STAMP=$(date +"%Y-%m-%d_%H-%M")

if [ -n "$INPUT_FILE" ]; then
  AUDIO="$(cd "$(dirname "$INPUT_FILE")" 2>/dev/null && pwd)/$(basename "$INPUT_FILE")"
  if [ -z "$AUDIO" ] || [ ! -f "$AUDIO" ]; then
    echo "❌  File not found: $INPUT_FILE"
    exit 1
  fi
  echo "📄  Reprocessing existing recording: $AUDIO"
else
  MIC_AUDIO="$SUPPORT/rec_${STAMP}_mic.wav"
  SYS_AUDIO="$SUPPORT/rec_${STAMP}_system.wav"

  if ! SwitchAudioSource -a -t input 2>/dev/null | grep -q "$MIC_DEVICE"; then
    if [ -n "$MIC_FALLBACK_DEVICE" ] && SwitchAudioSource -a -t input 2>/dev/null | grep -q "$MIC_FALLBACK_DEVICE"; then
      echo "ℹ️  \"$MIC_DEVICE\" not connected — using \"$MIC_FALLBACK_DEVICE\" instead."
      MIC_DEVICE="$MIC_FALLBACK_DEVICE"
    else
      echo "⚠️  Audio device \"$MIC_DEVICE\" not found (fallback \"$MIC_FALLBACK_DEVICE\" not found either)."
      echo "    Check your input device names with:"
      echo "      ffmpeg -f avfoundation -list_devices true -i \"\""
      echo "    then set MIC_DEVICE / MIC_FALLBACK_DEVICE in \"$SUPPORT/config.sh\" to match."
      exit 1
    fi
  fi
  if ! SwitchAudioSource -a -t input 2>/dev/null | grep -q "$SYSTEM_DEVICE"; then
    echo "⚠️  Audio device \"$SYSTEM_DEVICE\" not found."
    echo "    Install BlackHole (https://github.com/ExistentialAudio/BlackHole) if you haven't,"
    echo "    or set SYSTEM_DEVICE in \"$SUPPORT/config.sh\" to match its name."
    exit 1
  fi

  # Route what you hear into BlackHole so the call is captured; always restore on exit
  ORIG_OUT=$(SwitchAudioSource -c -t output)
  trap 'SwitchAudioSource -t output -s "$ORIG_OUT" >/dev/null 2>&1' EXIT
  SwitchAudioSource -t output -s "$OUTPUT_DEVICE" >/dev/null 2>&1
fi

ensure_llm_running

if [ -z "$INPUT_FILE" ]; then
  echo "🔴  Recording — join your meeting now."
  echo "    Press  q  to stop when it ends."
  # One ffmpeg process, two independent AVFoundation inputs, so both streams
  # share the same clock and stay in sync. No Aggregate Device needed.
  ffmpeg -hide_banner -loglevel error \
    -thread_queue_size 1024 -f avfoundation -i ":$MIC_DEVICE" \
    -thread_queue_size 1024 -f avfoundation -i ":$SYSTEM_DEVICE" \
    -map 0:a:0 -ac 1 -ar 16000 -c:a pcm_s16le "$MIC_AUDIO" \
    -map 1:a:0 -ac 1 -ar 16000 -c:a pcm_s16le "$SYS_AUDIO"
fi

echo ""
echo "🧠  Transcribing & summarizing locally…"
if [ -n "$INPUT_FILE" ]; then
  NOTE_FILE=$("$SUPPORT/venv/bin/python3" "$SUPPORT/notes_engine.py" "$INPUT_FILE" \
              --out-dir "$OUT_DIR" --llm "$LLM" --base-url "$BASE_URL" --api-key "$API_KEY")
else
  NOTE_FILE=$("$SUPPORT/venv/bin/python3" "$SUPPORT/notes_engine.py" \
              --mic "$MIC_AUDIO" --system "$SYS_AUDIO" \
              --out-dir "$OUT_DIR" --llm "$LLM" --base-url "$BASE_URL" --api-key "$API_KEY")
fi
if [ -z "$NOTE_FILE" ]; then
  echo "❌  Couldn't generate notes — is the local model server running?"
  echo "    Check:  tail -f \"$SUPPORT/llama-server.log\""
  echo "    Restart: launchctl kickstart -k \"gui/\$(id -u)/com.meetingnotes.llamaserver\""
  if [ -z "$INPUT_FILE" ]; then
    echo "    Your recordings were NOT deleted — retry anytime with:"
    echo "      meeting -f \"$MIC_AUDIO\"   (mic only, no speaker labels)"
  fi
  exit 1
fi

# Email a copy through the built-in Mail app (uses your existing account; no passwords stored)
if [ -n "$EMAIL" ]; then
  osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "Mail"
  set theBody to (read (POSIX file "$NOTE_FILE"))
  set msg to make new outgoing message with properties {subject:"Meeting Notes - $STAMP", content:theBody, visible:false}
  tell msg
    make new to recipient at end of to recipients with properties {address:"$EMAIL"}
    try
      make new attachment with properties {file name:(POSIX file "$NOTE_FILE")} at after last paragraph
    end try
  end tell
  send msg
end tell
APPLESCRIPT
  echo "📧  Emailed to $EMAIL"
fi

if [ -z "$INPUT_FILE" ]; then
  rm -f "$MIC_AUDIO" "$SYS_AUDIO"
fi
echo "✅  Saved to:  $OUT_DIR"
open "$OUT_DIR"
MEETEOF
chmod +x "$BREW_BIN/meeting"

# Guide the one-time audio device setup (can't be safely scripted)
open -a "Audio MIDI Setup" 2>/dev/null || true
osascript -e 'display dialog "One quick audio setup so the app can hear your meetings.\n\nIn Audio MIDI Setup (now open), click + at bottom-left:\n\nCreate Multi-Output Device — tick Speakers AND BlackHole 2ch. Rename it:  Meeting Output\n\nThat'"'"'s it — your Microphone and BlackHole 2ch are used directly, no Aggregate Device needed.\n\n(No BlackHole listed? Restart your Mac once.)" buttons {"Done"} default button 1 with title "Meeting Notes"' >/dev/null 2>&1 || true

echo ""
echo "============================================================"
echo "  ✅  All set!"
echo ""
echo "  Whenever a meeting starts, just type:    meeting"
echo "  Press q to stop. Notes land in: Desktop > Meeting Notes"
echo "============================================================"
