# ============================================================
#  Meeting Notes for Windows.  Run once in PowerShell:
#    irm <YOUR-URL>/install-windows.ps1 | iex
#  Then type  meeting  whenever a call starts.
#  NOTE: requires the free VB-CABLE virtual audio device (guided below).
# ============================================================
$ErrorActionPreference = "Stop"
Write-Host "Installing Meeting Notes for Windows..."

$Support = "$env:LOCALAPPDATA\MeetingNotes"
$Bin     = "$env:LOCALAPPDATA\MeetingNotes\bin"
New-Item -ItemType Directory -Force -Path $Support, $Bin, "$env:USERPROFILE\Desktop\Meeting Notes" | Out-Null

# 1) Dependencies via winget (built into Windows 10/11)
Write-Host ">>> Installing ffmpeg, Python, and Ollama via winget..."
winget install --silent --accept-source-agreements --accept-package-agreements -e --id Gyan.FFmpeg    2>$null
winget install --silent --accept-package-agreements -e --id Python.Python.3.12                          2>$null
winget install --silent --accept-package-agreements -e --id Ollama.Ollama                               2>$null

# 2) Python env + cross-platform deps
Write-Host ">>> Building the local AI environment..."
py -3 -m venv "$Support\venv"
& "$Support\venv\Scripts\python.exe" -m pip install --quiet --upgrade pip
& "$Support\venv\Scripts\pip.exe" install --quiet faster-whisper openai

# 3) Pull the summary model (one-time)
Write-Host ">>> Downloading the summary model (one-time)..."
Start-Process -NoNewWindow ollama -ArgumentList "serve"; Start-Sleep 2
ollama pull gemma4:e4b 2>$null

# 4) Write the engine
Write-Host ">>> Installing the note engine..."
$engine = @'
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
    p.add_argument("--llm", default="gemma4:e4b")
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
'@
Set-Content -Path "$Support\notes_engine.py" -Value $engine -Encoding UTF8

# 5) Discover audio devices and ask the user to confirm them
Write-Host ""
Write-Host ">>> Your audio input devices (look for 'CABLE Output' and your microphone):"
ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | Select-String "audio"
$SysDevice = Read-Host "`nPaste your SYSTEM-audio device name (usually: CABLE Output (VB-Audio Virtual Cable))"
if ([string]::IsNullOrWhiteSpace($SysDevice)) { $SysDevice = "CABLE Output (VB-Audio Virtual Cable)" }
$MicDevice = Read-Host "Paste your MICROPHONE device name (from the list above)"

# 6) Config
@"
# LLM provider (any OpenAI-compatible server). Edit to switch:
# Ollama :11434/v1 | LM Studio :1234/v1 | oMLX :8005/v1 | llama.cpp :8080/v1 | OpenAI https://api.openai.com/v1
`$Llm = "gemma4:e4b"
`$BaseUrl = "http://localhost:11434/v1"
`$ApiKey = "not-needed"
`$SysDevice = "$SysDevice"
`$MicDevice = "$MicDevice"
"@ | Set-Content -Path "$Support\config.ps1" -Encoding UTF8

# 7) Write the meeting command
$meeting = @'
# meeting.ps1 (Windows) - records system audio (via VB-CABLE) + mic, makes notes locally.
param([string]$Model, [string]$Provider, [string]$Url, [string]$Key, [switch]$List)
$Support = "$env:LOCALAPPDATA\MeetingNotes"
$OutDir  = "$env:USERPROFILE\Desktop\Meeting Notes"
. "$Support\config.ps1"   # sets $Llm, $BaseUrl, $ApiKey, $SysDevice, $MicDevice
if (-not $ApiKey) { $ApiKey = "not-needed" }
switch ($Provider) {
  "ollama"   { $BaseUrl = "http://localhost:11434/v1" }
  "lmstudio" { $BaseUrl = "http://localhost:1234/v1" }
  "omlx"     { $BaseUrl = "http://localhost:8005/v1" }
  "llamacpp" { $BaseUrl = "http://localhost:8080/v1" }
  "openai"   { $BaseUrl = "https://api.openai.com/v1" }
}
if ($Url)   { $BaseUrl = $Url }
if ($Key)   { $ApiKey = $Key }
if ($Model) { $Llm = $Model }
if ($List) {
  & "$Support\venv\Scripts\python.exe" -c "from openai import OpenAI; [print(' -', m.id) for m in OpenAI(base_url='$BaseUrl', api_key='$ApiKey').models.list().data]"
  exit
}
Write-Host "Model: $Llm  @  $BaseUrl"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Stamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$Audio = "$Support\rec_$Stamp.wav"

Write-Host "Recording - join your meeting now. Press  q  in this window to stop."
# input 1 = system audio captured via VB-CABLE; input 2 = your microphone; mixed to mono 16k
ffmpeg -hide_banner -loglevel error `
  -f dshow -i "audio=$SysDevice" `
  -f dshow -i "audio=$MicDevice" `
  -filter_complex "amix=inputs=2:duration=longest:normalize=0" -ac 1 -ar 16000 "$Audio"

Write-Host "Transcribing and summarizing locally..."
$NoteFile = & "$Support\venv\Scripts\python.exe" "$Support\notes_engine.py" "$Audio" `
              --out-dir "$OutDir" --backend faster --llm $Llm --base-url $BaseUrl --api-key $ApiKey
if (-not $NoteFile) { Write-Host "Could not generate notes - is Ollama running? Try: ollama serve"; exit 1 }
Remove-Item $Audio -ErrorAction SilentlyContinue
Write-Host "Saved to: $OutDir"
Invoke-Item $OutDir
'@
Set-Content -Path "$Bin\meeting.ps1" -Value $meeting -Encoding UTF8

# 8) Create a `meeting` shim on PATH
@"
@echo off
powershell -ExecutionPolicy Bypass -File `"$Bin\meeting.ps1`" %*
"@ | Set-Content -Path "$Bin\meeting.cmd" -Encoding ASCII
$userPath = [Environment]::GetEnvironmentVariable("Path","User")
if ($userPath -notlike "*$Bin*") {
  [Environment]::SetEnvironmentVariable("Path", "$userPath;$Bin", "User")
}

Write-Host ""
Write-Host "============================================================"
Write-Host "  ALMOST DONE - one manual step (like Mac's BlackHole):"
Write-Host ""
Write-Host "  1) Install the FREE VB-CABLE driver:  https://vb-audio.com/Cable/"
Write-Host "     (download, run Setup as admin, then REBOOT)"
Write-Host "  2) Windows Sound settings -> set 'CABLE Input' as your"
Write-Host "     default OUTPUT during calls, and enable 'Listen to this"
Write-Host "     device' on 'CABLE Output' so you still hear the call."
Write-Host ""
Write-Host "  Then open a NEW terminal and run:   meeting   (press q to stop)"
Write-Host "  Notes land in:  Desktop\Meeting Notes"
Write-Host "============================================================"
