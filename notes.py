#!/usr/bin/env python3
"""
notes.py - Turn any meeting recording into clean notes, 100% locally on your Mac.

Pipeline:  audio file -> mlx-whisper (transcribe on the Apple GPU) -> local LLM (summarize) -> Markdown notes
Nothing leaves your machine. No API keys. No bots in your calls. No monthly bill.

Examples:
    python notes.py standup.m4a
    python notes.py call.mp3 --llm gemma4:e4b --base-url http://localhost:11434/v1
"""

import argparse
import sys
import time
from pathlib import Path

def collapse_repeats(text: str, max_run: int = 3) -> str:
    """Squash any word repeated more than max_run times in a row (Whisper loop guard)."""
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

def fmt(seconds: float) -> str:
    """Human-friendly duration: 3725 -> '1h 2m 5s'."""
    m, s = divmod(int(round(seconds)), 60)
    h, m = divmod(m, 60)
    if h:
        return f"{h}h {m}m {s}s"
    if m:
        return f"{m}m {s}s"
    return f"{s}s"


def transcribe(audio_path: Path, whisper_repo: str):
    """Run Whisper on the Apple Silicon GPU via MLX. Returns (result, seconds)."""
    import mlx_whisper  # imported lazily so --help works without the dep

    t0 = time.perf_counter()
    result = mlx_whisper.transcribe(str(audio_path), path_or_hf_repo=whisper_repo, condition_on_previous_text=False)
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
    """Send the transcript to a local OpenAI-compatible LLM. Returns (notes, seconds, usage)."""
    from openai import OpenAI  # lazy import

    client = OpenAI(base_url=base_url, api_key=api_key)
    t0 = time.perf_counter()
    resp = client.chat.completions.create(
        model=llm_model,
        temperature=0.2,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": f"Here is the meeting transcript:\n\n{transcript}"},
        ],
    )
    elapsed = time.perf_counter() - t0
    return resp.choices[0].message.content.strip(), elapsed, getattr(resp, "usage", None)


def main():
    p = argparse.ArgumentParser(description="Local meeting-notes generator for Apple Silicon.")
    p.add_argument("audio", help="Path to the recording (.m4a, .mp3, .wav, .mp4 ...)")
    p.add_argument("--model", default="mlx-community/whisper-large-v3-turbo",
                   help="Whisper MLX model repo (default: large-v3-turbo)")
    p.add_argument("--llm", default="gemma4:e4b",
                   help="Local LLM name exactly as your server reports it")
    p.add_argument("--base-url", default="http://localhost:8005/v1",
                   help="OpenAI-compatible endpoint. LM Studio :1234 | Ollama :11434 | oMLX :8005")
    p.add_argument("--api-key", default="9253", help="Ignored by local servers")
    p.add_argument("-o", "--out", default=None, help="Output .md path (default: next to the audio)")
    args = p.parse_args()

    audio_path = Path(args.audio).expanduser()
    if not audio_path.exists():
        sys.exit(f"File not found: {audio_path}")

    # 1) Transcribe on the GPU
    print(f"Transcribing {audio_path.name} with {args.model} ...")
    result, t_transcribe = transcribe(audio_path, args.model)
    transcript = collapse_repeats(result["text"].strip())
    segments = result.get("segments", [])
    audio_dur = segments[-1]["end"] if segments else 0.0
    rtf = (audio_dur / t_transcribe) if t_transcribe else 0.0
    words = len(transcript.split())
    print(f"   {words:,} words in {fmt(t_transcribe)}  "
          f"({rtf:.1f}x realtime; audio was {fmt(audio_dur)})")

    # 2) Summarize with the local LLM
    print(f"Summarizing with {args.llm} ...")
    notes, t_summary, usage = summarize(transcript, args.llm, args.base_url, args.api_key)
    print(f"   notes written in {fmt(t_summary)}")

    # 3) Save Markdown (notes on top, full transcript below)
    out_path = Path(args.out).expanduser() if args.out else audio_path.with_suffix(".notes.md")
    header = (
        f"# Meeting Notes - {audio_path.stem}\n\n"
        f"*Generated locally on {time.strftime('%Y-%m-%d %H:%M')} - "
        f"transcription {fmt(t_transcribe)} - summary {fmt(t_summary)}*\n\n"
    )
    out_path.write_text(header + notes + "\n\n---\n\n## Full Transcript\n\n" + transcript + "\n",
                        encoding="utf-8")

    # 4) Print the live scoreboard
    total = t_transcribe + t_summary
    line = "=" * 52
    print("\n" + line)
    print("  LIVE RESULTS")
    print(line)
    print(f"  Audio length        : {fmt(audio_dur)}")
    print(f"  Transcription time  : {fmt(t_transcribe)}  ({rtf:.1f}x realtime)")
    print(f"  Summarization time  : {fmt(t_summary)}")
    if usage:
        print(f"  LLM tokens          : {usage.prompt_tokens} in / {usage.completion_tokens} out")
    print(f"  TOTAL wall-clock    : {fmt(total)}")
    print(f"  Cost                : $0.00 (ran entirely on your Mac)")
    print(line)
    print(f"\nSaved to: {out_path}")


if __name__ == "__main__":
    main()
