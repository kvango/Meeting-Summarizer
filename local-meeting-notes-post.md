# I Stopped Taking Meeting Notes. My MacBook Does It Now — For Free, and Nothing Ever Leaves My Laptop.

### A 15-minute build: record any Zoom/Meet/Teams call, get a clean summary with decisions and action items, and keep every word on-device. No bot joins your call. No $18/month. No data sent to anyone.

---

I added up what meetings actually cost me. Not the hours *in* them — the hours *after*: rewriting scribbled notes, hunting for "wait, what did we decide?", chasing who-owns-what. So I built a tool that ends it. I talk in the meeting, and by the time I close the lid I have a clean summary, a list of decisions, and a checklist of action items waiting in a file.

It runs entirely on my MacBook Pro M5 Max. No subscription. No bot showing up in the participant list. And — the part that actually matters — **not one second of audio ever leaves the machine.** Your salary negotiation, your therapy-adjacent 1:1, your unannounced acquisition talks: they stay on your SSD.

Here's why local is the whole point and not a nerd flex. The popular cloud note-takers send a *visible bot* that joins your call as a participant — everyone sees "Otter Notetaker has joined." The discreet ones still upload your audio to their servers; bot-free is not the same as private. And it isn't free: Granola's unlimited plan runs $18/month, Otter's free tier caps you at a few hundred minutes, and Fathom's free plan limits you to a handful of AI summaries a month. My version has no caps on anything, because the only computer involved is the one on my desk.

**What you'll have 15 minutes from now:** drop any recording onto a script and get back a Markdown file like this:

```markdown
## TL;DR
Launch moved to Tuesday; billing fix must land Friday.

## Decisions
- Delay launch to next Tuesday to clear the billing bug first.

## Action Items
- [ ] Ship the billing fix — Priya (Friday)
- [ ] Draft the press release — unassigned

## Open Questions
- Who owns the press release?
```

Let's build it.

---

## The stack (and why each piece)

Three parts, all local:

1. **Whisper (large-v3-turbo) via MLX** — Apple's framework runs the speech-to-text model directly on your GPU's unified memory. On Apple Silicon, MLX-based Whisper transcribes far faster than real time.
2. **Your existing local LLM** — the same Qwen 3.6 server you set up in my last post (LM Studio, Ollama, or oMLX). It turns the raw transcript into structured notes. If you haven't set that up yet, install [LM Studio](https://lmstudio.ai), load Qwen 3.6, and start its local server — that's the whole prerequisite.
3. **~150 lines of Python** that glue them together and print a benchmark scoreboard so you can see exactly how fast (and how free) it is.

---

## Step 1 — Install the pieces (2 minutes)

```bash
# ffmpeg lets Whisper read .m4a/.mp3/.mp4 directly; the two Python libs do the work
brew install ffmpeg
pip install mlx-whisper openai
```

The first run downloads the Whisper model (~1.6 GB for large-v3-turbo) once, then caches it. If you're tight on disk or want it even faster, swap in the 8-bit build (`LibraxisAI/whisper-large-v3-turbo-mlx-q8`, ~900 MB) via the `--model` flag later.

---

## Step 2 — Let your Mac actually *hear* the meeting (5 minutes, one-time)

macOS won't let an app record system audio (the other people on the call) out of the box — only your mic. The fix is a free virtual audio cable that loops your speakers back in as a recordable input.

1. **Install BlackHole** (free, open-source virtual audio driver):
   ```bash
   brew install blackhole-2ch
   ```
2. Open **Audio MIDI Setup** (it's in /Applications/Utilities).
3. Click the **+** at the bottom-left → **Create Aggregate Device**. Tick **both** your built-in microphone **and** BlackHole 2ch. This new device hears *you* (mic) and *them* (system audio) at once. Rename it "Meeting Capture."
4. Click **+** again → **Create Multi-Output Device**. Tick your real speakers/headphones **and** BlackHole 2ch — this is so you can still *hear* the call while it's being captured. Set this Multi-Output as your Mac's sound output during calls (Control Center → Sound).

You only do this once. After that, "Meeting Capture" is just another microphone your Mac can record from.

---

## Step 3 — Record the call (one command)

Find your aggregate device's index, then record to a 16 kHz mono WAV (exactly what Whisper wants):

```bash
# List your audio input devices and note the [index] of "Meeting Capture"
ffmpeg -f avfoundation -list_devices true -i ""

# Record (replace :2 with your device index). Ctrl-C when the meeting ends.
ffmpeg -f avfoundation -i ":2" -ac 1 -ar 16000 meeting.m4a
```

Prefer zero terminal? Open **QuickTime Player → File → New Audio Recording**, click the chevron next to the record button, pick **Meeting Capture**, and hit record. Same result.

---

## Step 4 — The notes engine

Save this as `notes.py`. It transcribes on the GPU, sends the transcript to your local LLM for structured notes, writes a Markdown file, and prints a live scoreboard.

```python
#!/usr/bin/env python3
"""notes.py - Turn any meeting recording into clean notes, 100% locally on your Mac."""
import argparse, sys, time
from pathlib import Path


def fmt(seconds: float) -> str:
    m, s = divmod(int(round(seconds)), 60); h, m = divmod(m, 60)
    return f"{h}h {m}m {s}s" if h else (f"{m}m {s}s" if m else f"{s}s")


def transcribe(audio_path: Path, whisper_repo: str):
    import mlx_whisper
    t0 = time.perf_counter()
    result = mlx_whisper.transcribe(str(audio_path), path_or_hf_repo=whisper_repo)
    return result, time.perf_counter() - t0


SYSTEM_PROMPT = """You are an expert meeting-notes assistant. You are given a raw, possibly messy \
transcript of a meeting. Produce clean, useful notes in Markdown with exactly these sections:

## TL;DR
One or two sentences capturing the single most important outcome.

## Key Points
The main topics discussed, as concise bullets.

## Decisions
Concrete decisions that were made. If none, write "None recorded."

## Action Items
A checklist. Format each line as: - [ ] <task> - <owner if mentioned, else 'unassigned'> (<due date if mentioned>)

## Open Questions
Anything left unresolved.

Be faithful to the transcript. Do NOT invent names, numbers, dates, or commitments that are not \
present in the transcript. Keep it tight and skimmable."""


def summarize(transcript: str, llm_model: str, base_url: str, api_key: str):
    from openai import OpenAI
    client = OpenAI(base_url=base_url, api_key=api_key)
    t0 = time.perf_counter()
    resp = client.chat.completions.create(
        model=llm_model, temperature=0.2,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"Here is the meeting transcript:\n\n{transcript}"},
        ],
    )
    return resp.choices[0].message.content.strip(), time.perf_counter() - t0, getattr(resp, "usage", None)


def main():
    p = argparse.ArgumentParser(description="Local meeting-notes generator for Apple Silicon.")
    p.add_argument("audio", help="Path to the recording (.m4a, .mp3, .wav, .mp4 ...)")
    p.add_argument("--model", default="mlx-community/whisper-large-v3-turbo")
    p.add_argument("--llm", default="qwen3.6:35b-mlx", help="Local LLM name as your server reports it")
    p.add_argument("--base-url", default="http://localhost:1234/v1",
                   help="LM Studio :1234 | Ollama :11434 | oMLX :8000")
    p.add_argument("--api-key", default="not-needed")
    p.add_argument("-o", "--out", default=None)
    args = p.parse_args()

    audio_path = Path(args.audio).expanduser()
    if not audio_path.exists():
        sys.exit(f"File not found: {audio_path}")

    print(f"Transcribing {audio_path.name} with {args.model} ...")
    result, t_transcribe = transcribe(audio_path, args.model)
    transcript = result["text"].strip()
    segments = result.get("segments", [])
    audio_dur = segments[-1]["end"] if segments else 0.0
    rtf = (audio_dur / t_transcribe) if t_transcribe else 0.0
    words = len(transcript.split())
    print(f"   {words:,} words in {fmt(t_transcribe)}  ({rtf:.1f}x realtime; audio was {fmt(audio_dur)})")

    print(f"Summarizing with {args.llm} ...")
    notes, t_summary, usage = summarize(transcript, args.llm, args.base_url, args.api_key)
    print(f"   notes written in {fmt(t_summary)}")

    out_path = Path(args.out).expanduser() if args.out else audio_path.with_suffix(".notes.md")
    header = (f"# Meeting Notes - {audio_path.stem}\n\n"
              f"*Generated locally on {time.strftime('%Y-%m-%d %H:%M')} - "
              f"transcription {fmt(t_transcribe)} - summary {fmt(t_summary)}*\n\n")
    out_path.write_text(header + notes + "\n\n---\n\n## Full Transcript\n\n" + transcript + "\n", encoding="utf-8")

    total = t_transcribe + t_summary; line = "=" * 52
    print("\n" + line + "\n  LIVE RESULTS\n" + line)
    print(f"  Audio length        : {fmt(audio_dur)}")
    print(f"  Transcription time  : {fmt(t_transcribe)}  ({rtf:.1f}x realtime)")
    print(f"  Summarization time  : {fmt(t_summary)}")
    if usage:
        print(f"  LLM tokens          : {usage.prompt_tokens} in / {usage.completion_tokens} out")
    print(f"  TOTAL wall-clock    : {fmt(total)}")
    print(f"  Cost                : $0.00 (ran entirely on your Mac)")
    print(line + f"\n\nSaved to: {out_path}")


if __name__ == "__main__":
    main()
```

---

## Step 5 — Run it, and watch the scoreboard

Make sure your local LLM server is running (LM Studio's server tab, or `ollama serve`), then:

```bash
python notes.py meeting.m4a
```

If your server is Ollama instead of LM Studio, point at it:

```bash
python notes.py meeting.m4a --llm qwen3.6:35b-mlx --base-url http://localhost:11434/v1
```

You'll see something like this in the terminal:

```
====================================================
  LIVE RESULTS
====================================================
  Audio length        : 47m 3s        ← replace with your run
  Transcription time  : 3m 48s  (12.4x realtime)
  Summarization time  : 24s
  LLM tokens          : 8,912 in / 412 out
  TOTAL wall-clock    : 4m 12s
  Cost                : $0.00 (ran entirely on your Mac)
====================================================
```

> 📸 **[Insert screenshot of your real terminal output here.]** Run it on an actual recording before publishing and paste your true numbers — that's the part readers trust. A 45–60 minute meeting on an M5 Max should transcribe in roughly 4–6 minutes and summarize in well under a minute, but report what *you* measure.

And the file it drops next to your recording (`meeting.notes.md`):

> 📸 **[Insert screenshot of your generated notes.md here — the TL;DR, Decisions, and Action Items sections are the money shot.]**

---

## Step 6 — Make it a single word

Add an alias so the whole thing is one command from anywhere:

```bash
echo 'alias notes="python ~/scripts/notes.py"' >> ~/.zshrc
source ~/.zshrc

# now, after any meeting:
notes ~/Desktop/meeting.m4a
```

You can take this further — a Folder Action or a tiny `launchd` watcher that auto-runs `notes.py` whenever a new recording lands in a folder — but the alias alone is enough to never write up a meeting by hand again.

---

## The honest comparison

| | This tool | Otter free | Granola | Fathom free |
|---|---|---|---|---|
| **Monthly cost** | $0 | $0 (capped) | $18 | $0 (capped) |
| **Minutes / month** | Unlimited | ~300 | Unlimited (paid) | Unlimited record |
| **AI summaries** | Unlimited | Limited | Unlimited (paid) | ~5 / month |
| **Bot joins your call** | Never | Yes | No | Yes |
| **Audio leaves your device** | **Never** | Yes | Yes | Yes |
| **Works offline / on a plane** | **Yes** | No | No | No |

The paid tools are genuinely good products. But the moment you self-host, the recurring bill goes to zero, the caps disappear, and the privacy question answers itself: there's no server to trust, because there's no server.

---

## What this really buys you

It's not about the $18. It's that the most sensitive conversations you have — comp, performance, legal, health, deals — now get the same AI treatment as everything else *without* you having to decide whether you trust a vendor with them. The trade you used to make ("convenience *or* privacy") just stopped being a trade.

Run it on your next call. Paste your scoreboard. Tell me the slowest meeting your Mac chewed through and how long it took — I read every comment.

---

*If this saved you an hour, give it a clap and follow — I publish a new "replace a paid tool with your own Mac" build every week. Next up: a private second brain that's read every note and PDF you own.*
