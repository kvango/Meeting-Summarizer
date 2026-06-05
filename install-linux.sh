#!/usr/bin/env bash
# ============================================================
#  Meeting Notes for Linux. Run once:
#    curl -fsSL <YOUR-URL>/install-linux.sh | bash
#  Then type  meeting  whenever a call starts. (No virtual
#  audio device needed — PipeWire/PulseAudio handles it.)
# ============================================================
set -e
echo "Installing Meeting Notes for Linux…"

# 1) System packages by distro
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y && sudo apt-get install -y ffmpeg python3-venv python3-pip pulseaudio-utils curl
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y ffmpeg python3-pip python3-virtualenv pulseaudio-utils curl
elif command -v pacman >/dev/null 2>&1; then
  sudo pacman -S --noconfirm ffmpeg python python-pip libpulse curl
else
  echo "Unsupported distro. Please install: ffmpeg, python3-venv, pulseaudio-utils, curl — then re-run."
  exit 1
fi

# 2) Ollama (local LLM, official cross-distro installer)
command -v ollama >/dev/null 2>&1 || curl -fsSL https://ollama.com/install.sh | sh
(ollama serve >/dev/null 2>&1 &) ; sleep 2

SUPPORT="$HOME/.local/share/meeting-notes"
BIN="$HOME/.local/bin"
mkdir -p "$SUPPORT" "$BIN"

# 3) Python env + the cross-platform transcription/summary deps
echo ">>> Building the local AI environment…"
python3 -m venv "$SUPPORT/venv"
"$SUPPORT/venv/bin/pip" install --quiet --upgrade pip
"$SUPPORT/venv/bin/pip" install --quiet faster-whisper openai

# 4) Pull the summary model (one-time)
echo ">>> Downloading the summary model (one-time)…"
ollama pull qwen3:4b-instruct 2>/dev/null || ollama pull qwen2.5:7b 2>/dev/null || true

# 5) Write the engine
echo ">>> Installing the note engine…"
cat > "$SUPPORT/notes_engine.py" << 'PYEOF'
#!/usr/bin/env python3
"""notes_engine.py - cross-platform. Transcribes + summarizes an audio file locally,
writes Markdown into --out-dir, prints ONLY that path on stdout (progress -> stderr).

Transcription backend is chosen automatically:
  - macOS on Apple Silicon  -> mlx-whisper (Metal GPU)
  - Windows / Linux         -> faster-whisper (NVIDIA GPU if present, else CPU)
Summarization is identical everywhere: a local Ollama / OpenAI-compatible server."""
import argparse, platform, sys, time
from pathlib import Path


def log(msg):
    print(msg, file=sys.stderr, flush=True)


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


def pick_backend(forced):
    if forced:
        return forced
    if sys.platform == "darwin" and platform.machine() == "arm64":
        return "mlx"
    return "faster"


def transcribe(audio_path, backend, model):
    """Returns (text, seconds, audio_duration_seconds)."""
    t0 = time.perf_counter()
    if backend == "mlx":
        import mlx_whisper
        repo = model or "mlx-community/whisper-large-v3-turbo"
        log(f"Transcribing on the Apple GPU ({repo})...")
        r = mlx_whisper.transcribe(str(audio_path), path_or_hf_repo=repo,
                                   condition_on_previous_text=False)
        text = r["text"].strip()
        segs = r.get("segments", [])
        dur = segs[-1]["end"] if segs else 0.0
    else:
        from faster_whisper import WhisperModel
        try:
            import ctranslate2
            cuda = ctranslate2.get_cuda_device_count() > 0
        except Exception:
            cuda = False
        device = "cuda" if cuda else "cpu"
        compute = "float16" if cuda else "int8"
        name = model or "large-v3-turbo"
        log(f"Transcribing with faster-whisper ({name}, {device})...")
        wm = WhisperModel(name, device=device, compute_type=compute)
        segments, info = wm.transcribe(str(audio_path), condition_on_previous_text=False)
        text = " ".join(seg.text.strip() for seg in segments).strip()
        dur = getattr(info, "duration", 0.0) or 0.0
    return collapse_repeats(text), time.perf_counter() - t0, dur


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


def summarize(transcript, llm, base_url, api_key):
    from openai import OpenAI
    log("Summarizing with the local model...")
    client = OpenAI(base_url=base_url, api_key=api_key)
    t0 = time.perf_counter()
    resp = client.chat.completions.create(
        model=llm, temperature=0.2,
        messages=[{"role": "system", "content": SYSTEM_PROMPT},
                  {"role": "user", "content": f"Here is the meeting transcript:\n\n{transcript}"}],
    )
    return resp.choices[0].message.content.strip(), time.perf_counter() - t0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("audio")
    p.add_argument("--out-dir", required=True)
    p.add_argument("--backend", choices=["mlx", "faster"], default=None,
                   help="Force a transcription backend (default: auto by OS)")
    p.add_argument("--model", default=None, help="Whisper model (default per backend)")
    p.add_argument("--llm", default="qwen3:4b-instruct")
    p.add_argument("--base-url", default="http://localhost:11434/v1")
    p.add_argument("--api-key", default="not-needed")
    args = p.parse_args()

    audio = Path(args.audio).expanduser()
    if not audio.exists():
        log(f"Audio not found: {audio}"); sys.exit(1)

    backend = pick_backend(args.backend)
    transcript, t_tx, dur = transcribe(audio, backend, args.model)
    if not transcript:
        transcript = "(No speech detected in the recording.)"

    notes, t_sum = summarize(transcript, args.llm, args.base_url, args.api_key)

    out_dir = Path(args.out_dir).expanduser(); out_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y-%m-%d_%H-%M")
    out_path = out_dir / f"Meeting Notes {stamp}.md"
    header = (f"# Meeting Notes - {stamp}\n\n"
              f"*Generated 100% locally ({backend}) - transcription {fmt(t_tx)} - summary {fmt(t_sum)}*\n\n")
    out_path.write_text(header + notes + "\n\n---\n\n## Full Transcript\n\n" + transcript + "\n",
                        encoding="utf-8")

    log(f"Done in {fmt(t_tx + t_sum)} - $0.00")
    print(str(out_path))


if __name__ == "__main__":
    main()
PYEOF

# 6) Config (set summary model + endpoint)
cat > "$SUPPORT/config.sh" << CFG
# --- LLM provider (any OpenAI-compatible server). Edit these to switch. ---
# Ollama :11434/v1 | LM Studio :1234/v1 | oMLX :8005/v1 | llama.cpp :8080/v1 | OpenAI https://api.openai.com/v1
LLM="qwen3:4b-instruct"
BASE_URL="http://localhost:11434/v1"
API_KEY="not-needed"
CFG

# 7) Install the `meeting` command
echo ">>> Installing the 'meeting' command…"
cat > "$BIN/meeting" << 'MEETEOF'
#!/usr/bin/env bash
# `meeting` (Linux) - records system audio + mic via PipeWire/PulseAudio, makes notes locally.
SUPPORT="$HOME/.local/share/meeting-notes"
OUT_DIR="$HOME/Desktop/Meeting Notes"; [ -d "$HOME/Desktop" ] || OUT_DIR="$HOME/Meeting Notes"
[ -f "$SUPPORT/config.sh" ] && . "$SUPPORT/config.sh"
: "${LLM:=qwen3:4b-instruct}"; : "${BASE_URL:=http://localhost:11434/v1}"; : "${API_KEY:=not-needed}"

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
STAMP=$(date +"%Y-%m-%d_%H-%M"); AUDIO="$SUPPORT/rec_$STAMP.wav"

SINK=$(pactl get-default-sink 2>/dev/null)
[ -z "$SINK" ] && { echo "No PulseAudio/PipeWire sink found. Is your audio server running?"; exit 1; }
MONITOR="${SINK}.monitor"

echo "🔴  Recording — join your meeting now. Press  q  to stop."
# input 1 = what you hear (sink monitor); input 2 = your mic (default source); mix to mono 16k
ffmpeg -hide_banner -loglevel error \
  -f pulse -i "$MONITOR" \
  -f pulse -i default \
  -filter_complex "amix=inputs=2:duration=longest:normalize=0" -ac 1 -ar 16000 "$AUDIO"

echo ""
echo "🧠  Transcribing & summarizing locally…"
NOTE_FILE=$("$SUPPORT/venv/bin/python3" "$SUPPORT/notes_engine.py" "$AUDIO" \
            --out-dir "$OUT_DIR" --backend faster --llm "$LLM" --base-url "$BASE_URL" --api-key "$API_KEY")
[ -z "$NOTE_FILE" ] && { echo "❌  Couldn't generate notes — is Ollama running?  Try:  ollama serve"; exit 1; }
rm -f "$AUDIO"
echo "✅  Saved to: $OUT_DIR"
command -v xdg-open >/dev/null 2>&1 && xdg-open "$OUT_DIR" >/dev/null 2>&1 || true
MEETEOF
chmod +x "$BIN/meeting"

# 8) Make sure ~/.local/bin is on PATH
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
     echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc" 2>/dev/null || true ;;
esac

echo ""
echo "============================================================"
echo "  ✅  All set!  Open a NEW terminal, then for any meeting:"
echo ""
echo "        meeting        (press q to stop)"
echo ""
echo "  Notes land in:  ~/Desktop/Meeting Notes"
echo "  No virtual audio device needed on Linux."
echo "============================================================"
