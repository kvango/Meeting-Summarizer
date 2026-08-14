# Meeting Notes — Free, Forever, Local, and Private

Turn any meeting into clean, actionable notes in seconds. **100% on your Mac.** No subscriptions. No bots. No privacy trade-offs. Just one word: `meeting`.

---

## Why This Exists

I cancelled my Otter subscription. The notes were good, but the price wasn't the issue — the *principle* was. Every call I had was being shipped to their servers to transcribe. For conversations about comp, reviews, health decisions, or deals, that felt wrong. So I built a tool that runs the whole pipeline locally: record, transcribe, summarize — all on my own hardware.

The result: **clean notes in about a minute, no monthly bill, and zero bytes of audio ever leaving my laptop.**

---

## What You Get

Drop into a meeting, run one command, and when it ends you get a Markdown file like this:

```markdown
## TL;DR
Launch moved to Tuesday; the billing fix must land Friday.

## Decisions
- Delay the launch to next Tuesday to clear the billing bug first.

## Action Items
- [ ] Ship the billing fix — Priya (Friday)
- [ ] Draft the press release — You

## Open Questions
- Who owns the press release?
```

Notes appear in **Desktop ▸ Meeting Notes** and are emailed to you automatically.

**Speaker-aware action items:** your mic and the far side (everyone else on the call) are recorded as two separate streams, so the transcript knows who said what — labeled `You:` / `Them:` by timestamp. When someone commits to a task without stating a name, it's assigned to `You` or `Them` correctly instead of `unassigned`. If a name *is* mentioned in the conversation (like "Priya" above), that takes priority over the tag.

---

## Speed: The Numbers

On a MacBook Pro M5 Max:

- **Transcription**: A 9-minute meeting → text in **7 seconds** (78× faster than real time, via GPU)
- **Summarization**: Clean notes in **3–5 seconds** depending on your model choice
- **One-time setup**: ~2–3 minutes and 2–3 GB download

For a full one-hour meeting, you're looking at transcription in under 60 seconds, then another few seconds for notes. By the time you close your laptop, you're done.

---

## Install It — One Line

### macOS

```bash
curl -fsSL https://raw.githubusercontent.com/kvango/Meeting-Summarizer/main/install.sh | bash
```

### Windows

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
curl -fsSL https://raw.githubusercontent.com/kvango/Meeting-Summarizer/main/install-windows.ps1 | powershell
```

### Linux

```bash
curl -fsSL https://raw.githubusercontent.com/kvango/Meeting-Summarizer/main/install-linux.sh | bash
```

#### What the installer does (macOS):

1. Checks for Homebrew — prompts to install if missing
2. Installs `ffmpeg`, audio routing tools, and **llama.cpp** (a lightweight local inference engine — skipped if already installed)
3. Registers `llama-server` as a background service (via `launchd`) so it's always running, the same way the old Ollama app was — skipped/left alone if it's already registered and healthy
4. Sets up a Python virtual environment with `mlx-whisper` and the OpenAI client
5. Downloads the speech model (~800 MB) and the default LLM GGUF (~4 GB for Gemma 4 E4B at `Q8_0`)
6. Creates folders for notes and a support directory
7. Asks for your email (for automatic note delivery)
8. Walks you through a one-click audio setup (macOS asks for microphone permission) — creating a single Multi-Output Device so your Mac's speaker audio also reaches BlackHole. Your microphone and BlackHole are then recorded directly as two separate streams; no Aggregate Device needed.

**The first run takes a few minutes.** After that, everything is cached locally, and re-running the installer (e.g. after a `git pull`) won't redownload or restart anything that's already in place.

---

## Run It — One Word

```bash
meeting
```

That's it. Recording starts. Talk normally. When the call ends, press **q**.

A minute later, your notes are ready in `Desktop/Meeting Notes` and in your inbox.

---

## Customize Your Setup

### Use a different AI model for a single call:

```bash
meeting gemma4:e4b
```

### Switch AI providers:

```bash
meeting -p ollama                     # Use Ollama instead of llama.cpp
meeting -u http://localhost:1234/v1   # Point at any OpenAI-compatible endpoint
```

Supported `-p/--provider` values: `llamacpp` (default) | `ollama` | `lmstudio` | `omlx` | `openai`

### Reprocess an existing recording:

Every normal `meeting` call records two files — `rec_<timestamp>_mic.wav` (you) and `rec_<timestamp>_system.wav` (the far side) — both kept in `~/Library/Application Support/MeetingNotes/` if a run ever fails partway through, so nothing is lost.

Skip recording and re-run transcription + summarization on any single `.m4a`/`.mp3`/`.wav` you already have — a call recorded elsewhere, or anything you want to re-summarize with a different model:

```bash
meeting -f "~/Library/Application Support/MeetingNotes/rec_2026-08-10_12-59_mic.wav"
```

Note that `-f` takes **one** file, so it always runs in legacy single-stream mode — no `You:`/`Them:` speaker labels, since there's no second stream to compare timestamps against. It's meant for recovery and for summarizing recordings that were never split into mic/system in the first place.

If a run ever fails partway through, the recordings are **never deleted** — the error message tells you the exact `meeting -f ...` command to retry with (using the mic-only file, since that alone is enough to produce notes without speaker labels).

### List available models:

```bash
meeting --list
```

### View help:

```bash
meeting --help
```

---

## Advanced Configuration

Two different config files control two different things — worth knowing the difference:

- **`~/Library/Application Support/MeetingNotes/config.sh`** — per-run settings read every time you type `meeting`:
  - `LLM`, `BASE_URL`, `API_KEY` — your default model and endpoint.
  - `MIC_DEVICE` — your microphone's exact AVFoundation device name. Defaults to `Microphone`; if that doesn't match your Mac (e.g. a named USB mic), run `ffmpeg -f avfoundation -list_devices true -i ""` to find the real name.
  - `MIC_FALLBACK_DEVICE` — used automatically if `MIC_DEVICE` isn't connected (e.g. you configured a USB mic but are traveling without it). Defaults to `MacBook Pro Microphone`. Your primary `MIC_DEVICE` setting is never overwritten — it just falls back for that one recording.
  - `SYSTEM_DEVICE` — the far-side/loopback device, normally `BlackHole 2ch`.
  - `OUTPUT_DEVICE` — the Multi-Output Device created during setup, normally `Meeting Output`.
- **Near the top of `install.sh`** — one-time settings baked into the `llama-server` background service when it's (re)installed: `MODEL_REPO`, `MODEL_QUANT`, and `MODEL_CTX`.
  - `MODEL_QUANT` controls how compressed the model weights are (size/speed/quality trade-off) — it has nothing to do with how much text you can send the model.
  - `MODEL_CTX` is the context window — the max combined tokens (prompt + transcript + response) the server will accept in one request. Long meetings can exceed this; if you see an `exceeds the available context size` error, raise `MODEL_CTX` (Gemma 4 E4B supports up to 131072) and re-run `install.sh` — it'll detect the change and restart the service automatically.

---

## How It Works (No Magic, Just Code)

The entire pipeline is five steps:

### Step 1: Capture Your Audio, As Two Streams

One `ffmpeg` process opens your microphone and BlackHole (system/loopback audio) as two independent inputs at once, so they share a clock and stay in sync — no Aggregate Device required:

```bash
ffmpeg -f avfoundation -i ":Microphone" -f avfoundation -i ":BlackHole 2ch" \
  -map 0:a:0 -ac 1 -ar 16000 -c:a pcm_s16le mic.wav \
  -map 1:a:0 -ac 1 -ar 16000 -c:a pcm_s16le system.wav
```

Nothing is sent anywhere. Both files are just written to your disk. Keeping them separate — rather than mixing to one file — is what makes speaker labeling possible: whatever's in `mic.wav` is unambiguously you, and whatever's in `system.wav` is unambiguously the far side, no diarization or voice-matching needed.

### Step 2: Transcribe (On Your GPU)

**Whisper** runs directly on your Apple Silicon GPU via MLX, transcribing both files independently. A 9-minute call becomes text in ~7 seconds per stream:

```python
import mlx_whisper

mic_result = mlx_whisper.transcribe(
    "mic.wav",
    path_or_hf_repo="mlx-community/whisper-large-v3-turbo",
    condition_on_previous_text=False,  # prevents Whisper from looping on silence
)
system_result = mlx_whisper.transcribe("system.wav", path_or_hf_repo="mlx-community/whisper-large-v3-turbo")
```

### Step 3: Merge By Timestamp, Tagged By Speaker

Each transcript comes back as timestamped segments. They're interleaved into one transcript ordered by `start` time, tagged `You:` for every mic segment and `Them:` for every system segment:

```
[00:12] You: Can we push the deadline to Friday?
[00:15] Them: Yeah, Friday works on our end.
[00:18] You: Great, I'll update the doc.
```

### Step 4: Summarize (With a Local LLM)

The same OpenAI client everyone uses for ChatGPT — just pointed at `localhost`, at a **llama.cpp** server instead of a cloud API:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8080/v1", api_key="not-needed")

resp = client.chat.completions.create(
    model="gemma4:e4b",
    messages=[
        {"role": "system", "content": "Summarize into TL;DR, Decisions, Action Items. "
                                       "Lines are tagged You:/Them: — use the tag to assign "
                                       "ownership when no name is stated. Don't invent."},
        {"role": "user", "content": transcript},
    ],
)
notes = resp.choices[0].message.content
```

`llama-server` (from llama.cpp) exposes the same OpenAI-compatible `/v1` API as Ollama, LM Studio, and every other local runtime — so this code doesn't change no matter which one you point it at. The model runs on your machine. No internet. No API key. No bill.

### Step 5: Save and Email

Notes are written to Markdown, and a few lines of AppleScript send them to your Mail app.

---

## Comparison: Why This Is Different

| Feature | Meeting Notes | Otter (free) | Granola | Fathom (free) |
|---------|---|---|---|---|
| **Monthly cost** | $0 | $0 (capped) | ~$18 | $0 (capped) |
| **Minutes / month** | Unlimited | ~300 | Unlimited (paid) | Unlimited record |
| **AI summaries** | Unlimited | Limited | Unlimited (paid) | ~5/month |
| **Bot joins call** | Never | Yes | No | Yes |
| **Audio leaves device** | **Never** | Yes | Yes | Yes |
| **Works offline** | **Yes** | No | No | No |

---

## Privacy & Ownership

Your audio never leaves your Mac. Period.

- No vendor has it
- No cloud backup
- No terms of service to trust
- No monthly bill

This isn't about the $18. It's that your most sensitive conversations — comp, reviews, legal, health, deals — get the same effortless AI treatment as everything else, without you having to decide whether to trust a vendor with them.

---

## Troubleshooting

### "Command not found: meeting"

The installer adds a command to your shell. Restart Terminal or run:

```bash
source ~/.zshrc      # if using zsh
# or
source ~/.bashrc     # if using bash
```

### Transcription is slow

1. Verify Whisper is running on GPU: check Activity Monitor for GPU usage
2. Try a smaller Whisper model: edit the installer and use `whisper-tiny-multilingual` instead

### No notes in my inbox

1. Check the `Desktop/Meeting Notes` folder — the file should be there
2. Make sure you've given Mail permission to send (macOS will prompt on first run)
3. Verify your email in the settings (check `~/Library/Application Support/MeetingNotes/config.sh`)

### "Couldn't generate notes — is the local model server running?"

`llama-server` isn't answering. Check the logs and, if needed, restart it:

```bash
tail -f "$HOME/Library/Application Support/MeetingNotes/llama-server.log"
launchctl kickstart -k "gui/$(id -u)/com.meetingnotes.llamaserver"
```

Your recording is never deleted on failure — retry with `meeting -f "<path to the _mic.wav>"` once the server's back up.

### "Audio device ... not found"

Your `MIC_DEVICE` (or `SYSTEM_DEVICE`) in `config.sh` doesn't match a currently connected device — most often because a configured USB mic isn't plugged in. If a `MIC_FALLBACK_DEVICE` is set (defaults to `MacBook Pro Microphone`) and it's available, `meeting` automatically uses it for that recording and prints a heads-up — your `MIC_DEVICE` setting isn't changed, so plugging the USB mic back in works normally next time. If you see the error anyway, list your actual device names and update `config.sh` to match:

```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

### "exceeds the available context size" error

Your transcript + prompt is longer than the server's configured context window. Raise `MODEL_CTX` near the top of `install.sh` (default `32768`; Gemma 4 E4B supports up to `131072`) and re-run `install.sh` — it detects the change and restarts the service with the new setting automatically. Then retry with `meeting -f "<path to the _mic.wav>"`.

### Model download failed

The default model is fetched automatically by `llama-server` on first launch. If it stalls or fails:

```bash
tail -f "$HOME/Library/Application Support/MeetingNotes/llama-server.log"
launchctl kickstart -k "gui/$(id -u)/com.meetingnotes.llamaserver"
```

Then run `meeting` again once `llama-server.log` shows it's ready.

### Whisper model download fails with an SSL/certificate error

Common on corporate networks with a TLS-inspecting proxy. Rather than fighting Python's certificate store, download the model manually once via browser and drop it in place — the tool automatically prefers a local copy over Hugging Face:

1. Open **https://huggingface.co/mlx-community/whisper-large-v3-turbo/tree/main** (or, on Windows/Linux, search Hugging Face for a CTranslate2-format `faster-whisper-large-v3` build) and download every file listed.
2. Place the files directly inside:
   - macOS: `~/Library/Application Support/MeetingNotes/models/whisper-large-v3-turbo/`
   - Windows: `%LOCALAPPDATA%\MeetingNotes\models\faster-whisper-large-v3-turbo\`
   - Linux: `~/.local/share/meeting-notes/models/faster-whisper-large-v3-turbo/`
3. Run `meeting` again — no network needed from here on for transcription.

---

## Project Structure

```
Meeting-Summarizer/
├── install.sh              # macOS installer (llama.cpp-based)
├── install-windows.ps1     # Windows installer
├── install-linux.sh        # Linux installer
├── notes.py                # Core transcription + summarization logic
└── README.md               # This file
```

After installation, files are stored in:

```
~/Library/Application Support/MeetingNotes/    # Config, venv, models, llama-server.log
~/Desktop/Meeting Notes/                        # Your notes (one file per meeting)
```

---

## Requirements

- **macOS 11+, Apple Silicon** (Whisper transcription runs on the GPU via MLX, which is Apple Silicon-only; llama.cpp itself also runs on Intel Macs)
- **Windows 10+** (with Python 3.9+)
- **Linux** (Ubuntu 20.04+ recommended, with PipeWire or PulseAudio)
- **~5 GB free disk space** (for models)
- **Internet** (one-time for downloads; offline after that)

---

## What's Under the Hood

This tool relies on two open-source models:

1. **Whisper** (OpenAI) — speech-to-text
   - Runs locally via MLX on Apple Silicon
   - ~78× faster than real time for transcription

2. **Gemma 4 E4B** (Google) — text summarization
   - Run as a `.gguf` via llama.cpp, quantized to `Q8_0` by default
   - Can swap for any other llama.cpp/Ollama/LM Studio-compatible model

Both run via **llama.cpp**, a lightweight local inference engine that requires no cloud connection. `llama-server` runs as a background `launchd` service and exposes an OpenAI-compatible API, so it's a drop-in replacement for Ollama or any other local runtime.

---

## For Developers

Want to modify the setup, swap in a different model, or contribute? Everything is open source.

- The installer is a single bash/PowerShell/sh script — read it before you run it
- The notes engine is standard Python with no proprietary dependencies
- All models are downloaded from Hugging Face or Meta

Fork, break, improve. The only person who needs to approve your changes is you.

---

## FAQ

**Q: Does this work with Zoom, Teams, Google Meet, FaceTime?**
A: Yes. Your Mac plays the call through its speakers (routed to BlackHole via the Multi-Output Device) and hears you through its mic. This tool captures both at the OS level as separate streams, so it works with any meeting app — and knows who said what, since your voice and the call audio never get mixed together.

**Q: What if I want to use a bigger model for fancier summaries?**
A: Run `meeting <model-name>` or swap the default in `config.sh`. Same one-word command.

**Q: Can I run this on multiple Macs?**
A: Install on each one independently. Each machine handles its own notes.

**Q: What happens to notes if I close the app mid-call?**
A: Press **q** to stop recording cleanly. If you force-quit, the audio files are saved but won't be transcribed until you run `meeting -f "<path to the _mic.wav>"`.

**Q: I use a USB mic but sometimes travel without it — what happens?**
A: If your configured `MIC_DEVICE` isn't connected, `meeting` automatically falls back to `MIC_FALLBACK_DEVICE` (the built-in mic, by default) for that recording and tells you it did so. Your saved `MIC_DEVICE` setting is untouched, so things go back to normal once the USB mic is reconnected.

**Q: Can I share notes with my team?**
A: Your notes are Markdown files in `Desktop/Meeting Notes`. Email them, paste them, commit them — they're yours.

**Q: Is this HIPAA or SOC 2 compliant?**
A: This tool runs entirely on your machine, so compliance depends on your broader setup. Audio never touches a third-party server, so that piece is inherently private.

---

## What This Really Buys You

It isn't about the $18 a month. It's that the most sensitive conversations you have — comp, reviews, legal, health, deals — finally get the same effortless AI treatment as everything else, **without you having to decide whether you trust a vendor with them.**

The old trade-off: *convenience or privacy.*

Now? You get both. And you get them for free, on hardware you already own.

---

## Next Steps

1. **Install:** Paste the one-liner for your OS above
2. **Configure:** Set your email when prompted
3. **Test:** Join a short call and run `meeting`
4. **Customize:** Swap models with `meeting --list` and pick a different one
5. **Share:** If this saved you an hour, star the repo and tell a friend

---

## License

Open source. See LICENSE file for details.

## Thanks

- OpenAI (Whisper)
- Google (Gemma)
- The MLX team (Apple Silicon acceleration)
- llama.cpp (lightweight local inference engine)

---

**The cloud is convenient. Owning the whole thing is better.**
