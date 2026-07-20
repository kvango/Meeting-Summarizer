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
# Use the official prebuilt Ollama (the Homebrew *formula* ships without its
# llama-server runner on 0.30.x and can't run models — the cask bundles it).
brew install --cask ollama 2>/dev/null || true
open -a Ollama 2>/dev/null || true; sleep 3
sudo killall coreaudiod 2>/dev/null || true   # makes BlackHole appear

echo ">>> Building the local AI environment…"
python3 -m venv "$SUPPORT/venv"
"$SUPPORT/venv/bin/pip" install --quiet --upgrade pip
"$SUPPORT/venv/bin/pip" install --quiet mlx-whisper openai

echo ">>> Downloading models (one-time, a few GB)…"
ollama pull gemma4:e4b 2>/dev/null || true

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


def main():
    p = argparse.ArgumentParser()
    p.add_argument("audio")
    p.add_argument("--out-dir", required=True)
    p.add_argument("--model", default=None, help="Whisper model repo or local folder (default: local copy if present, else download)")
    p.add_argument("--llm", default="gemma4:e4b")
    p.add_argument("--base-url", default="http://localhost:11434/v1")
    p.add_argument("--api-key", default="not-needed")
    args = p.parse_args()

    audio = Path(args.audio).expanduser()
    if not audio.exists():
        log(f"Audio not found: {audio}"); sys.exit(1)

    import mlx_whisper
    source = resolve_whisper_source(args.model)
    log(f"Transcribing on the GPU ({source})...")
    t0 = time.perf_counter()
    try:
        result = mlx_whisper.transcribe(str(audio), path_or_hf_repo=source,
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
    t_tx = time.perf_counter() - t0
    transcript = collapse_repeats(result["text"].strip())
    if not transcript:
        transcript = "(No speech detected in the recording.)"

    from openai import OpenAI
    log("Summarizing with the local model...")
    client = OpenAI(base_url=args.base_url, api_key=args.api_key)
    t0 = time.perf_counter()
    resp = client.chat.completions.create(
        model=args.llm, temperature=0.2,
        messages=[{"role": "system", "content": SYSTEM_PROMPT},
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
CAPTURE_DEVICE="Meeting Capture"
OUTPUT_DEVICE="Meeting Output"
# --- LLM provider (any OpenAI-compatible server). Edit these to switch. ---
# Ollama :11434/v1 | LM Studio :1234/v1 | oMLX :8005/v1 | llama.cpp :8080/v1 | OpenAI https://api.openai.com/v1
LLM="gemma4:e4b"
BASE_URL="http://localhost:11434/v1"
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
: "${CAPTURE_DEVICE:=Meeting Capture}"; : "${OUTPUT_DEVICE:=Meeting Output}"
: "${LLM:=gemma4:e4b}"; : "${BASE_URL:=http://localhost:11434/v1}"; : "${API_KEY:=not-needed}"

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
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--model)    LLM="$2"; shift 2 ;;
    -u|--url)      BASE_URL="$2"; shift 2 ;;
    -k|--key)      API_KEY="$2"; shift 2 ;;
    -p|--provider)
      case "$2" in
        ollama)   BASE_URL="http://localhost:11434/v1" ;;
        lmstudio) BASE_URL="http://localhost:1234/v1" ;;
        omlx)     BASE_URL="http://localhost:8005/v1" ;;
        llamacpp) BASE_URL="http://localhost:8080/v1" ;;
        openai)   BASE_URL="https://api.openai.com/v1" ;;
        *) echo "Unknown provider '$2' (use: ollama|lmstudio|omlx|llamacpp|openai)"; exit 1 ;;
      esac; shift 2 ;;
    -l|--list)     echo "Models at $BASE_URL:"; list_models; exit 0 ;;
    -h|--help)
      echo "Usage: meeting [options]"
      echo "  -m, --model MODEL    model for this run (default: $LLM)"
      echo "  -p, --provider NAME  ollama | lmstudio | omlx | llamacpp | openai"
      echo "  -u, --url URL        any OpenAI-compatible endpoint ending in /v1"
      echo "  -k, --key KEY        API key (for cloud providers)"
      echo "  -l, --list           list models at the current endpoint"
      exit 0 ;;
    *) LLM="$1"; shift ;;
  esac
done
echo "📋  Model: $LLM   @  $BASE_URL"

mkdir -p "$OUT_DIR"
STAMP=$(date +"%Y-%m-%d_%H-%M")
AUDIO="$SUPPORT/rec_$STAMP.m4a"

if ! SwitchAudioSource -a -t input 2>/dev/null | grep -q "$CAPTURE_DEVICE"; then
  echo "⚠️  Audio device \"$CAPTURE_DEVICE\" not found."
  echo "    Open Audio MIDI Setup and create an Aggregate Device"
  echo "    (Microphone + BlackHole 2ch) named exactly: $CAPTURE_DEVICE"
  exit 1
fi

# Route what you hear into BlackHole so the call is captured; always restore on exit
ORIG_OUT=$(SwitchAudioSource -c -t output)
trap 'SwitchAudioSource -t output -s "$ORIG_OUT" >/dev/null 2>&1' EXIT
SwitchAudioSource -t output -s "$OUTPUT_DEVICE" >/dev/null 2>&1

echo "🔴  Recording — join your meeting now."
echo "    Press  q  to stop when it ends."
ffmpeg -hide_banner -loglevel error -f avfoundation -i ":$CAPTURE_DEVICE" -ac 1 -ar 16000 "$AUDIO"

echo ""
echo "🧠  Transcribing & summarizing locally…"
NOTE_FILE=$("$SUPPORT/venv/bin/python3" "$SUPPORT/notes_engine.py" "$AUDIO" \
            --out-dir "$OUT_DIR" --llm "$LLM" --base-url "$BASE_URL" --api-key "$API_KEY")
if [ -z "$NOTE_FILE" ]; then
  echo "❌  Couldn't generate notes — is your local model running?  Try:  ollama serve"
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

rm -f "$AUDIO"
echo "✅  Saved to:  $OUT_DIR"
open "$OUT_DIR"
MEETEOF
chmod +x "$BREW_BIN/meeting"

# Guide the one-time audio device setup (can't be safely scripted)
open -a "Audio MIDI Setup" 2>/dev/null || true
osascript -e 'display dialog "One quick audio setup so the app can hear your meetings.\n\nIn Audio MIDI Setup (now open), click + at bottom-left and make TWO devices:\n\n1) Create Multi-Output Device — tick Speakers AND BlackHole 2ch. Rename it:  Meeting Output\n\n2) Create Aggregate Device — tick Microphone AND BlackHole 2ch. Rename it:  Meeting Capture\n\n(No BlackHole listed? Restart your Mac once.)" buttons {"Done"} default button 1 with title "Meeting Notes"' >/dev/null 2>&1 || true

echo ""
echo "============================================================"
echo "  ✅  All set!"
echo ""
echo "  Whenever a meeting starts, just type:    meeting"
echo "  Press q to stop. Notes land in: Desktop > Meeting Notes"
echo "============================================================"
