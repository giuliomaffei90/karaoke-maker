"""Forced alignment of known lyrics to a recording, word by word.

Karaoke Maker runs it with the Python that has Demucs: `python align.py job.json`. The job is
{"audio": 16 kHz mono 16-bit WAV, "lines": [[word, ...], ...], "start": s, "end": s, "vocals": bool};
`start`/`end` (optional) limit it to part of the recording. Prints [[[start, end] | null, ...], ...] in seconds,
one entry per word; null for words it can't spell (numbers, symbols).

The acoustic model is Meta's MMS forced aligner (torchaudio.pipelines.MMS_FA, ~1.2 GB, downloaded on first use).
Lines are separated by a "star" token that soaks up whatever isn't in the lyrics (intros, ad-libs). CTC marks
where each word starts; a word ends where the voice stops (vocals) or just before the next one starts.
"""
import json
import sys
import unicodedata
import wave

import torch
import torchaudio
import torchaudio.functional as F

SAMPLE_RATE = 16_000


def say(kind, value):
    print(kind, value, file=sys.stderr, flush=True)


def spell(word, dictionary):
    """'Perché,' -> 'perche'; letters outside the model's alphabet are dropped."""
    word = unicodedata.normalize("NFKD", word.replace("’", "'")).lower()
    return "".join(c for c in word if c in dictionary and c not in "-*")


def load(path, start, end):
    with wave.open(path) as w:
        assert w.getframerate() == SAMPLE_RATE and w.getnchannels() == 1 and w.getsampwidth() == 2
        first = int(start * SAMPLE_RATE)
        w.setpos(min(first, w.getnframes()))
        count = w.getnframes() - first if end is None else int((end - start) * SAMPLE_RATE)
        data = w.readframes(max(0, count))
    return torch.frombuffer(bytearray(data), dtype=torch.int16).float() / 32768


def emissions(model, audio):
    """Log-probabilities per 20 ms frame, in 30 s windows with 2 s of context each side (memory stays flat)."""
    window, context = 30 * SAMPLE_RATE, 2 * SAMPLE_RATE
    parts, starts = [], list(range(0, len(audio), window))
    with torch.inference_mode():
        for n, start in enumerate(starts):
            a, b = max(0, start - context), min(len(audio), start + window + context)
            out, _ = model(audio[a:b].unsqueeze(0))
            per_sample = out.shape[1] / (b - a)
            first = round((start - a) * per_sample)
            last = round((min(start + window, len(audio)) - a) * per_sample)
            parts.append(out[0, first:last])
            say("PROGRESS", (n + 1) / len(starts) * 0.8)
    return torch.cat(parts).log_softmax(-1)


def main():
    job = json.load(open(sys.argv[1]))
    start, end = job.get("start") or 0.0, job.get("end")
    bundle = torchaudio.pipelines.MMS_FA
    dictionary = bundle.get_dict()
    say("STATUS", "model")
    model = bundle.get_model(with_star=True)
    audio = load(job["audio"], start, end)
    emission = emissions(model, audio)
    seconds_per_frame = len(audio) / SAMPLE_RATE / emission.shape[0]

    # Targets: * line * line * ... *, remembering which word each letter belongs to.
    star = dictionary["*"]
    targets, owner, words = [star], [-1], []
    for line in job["lines"]:
        for word in line:
            spelled = spell(word, dictionary)
            words.append(bool(spelled))
            for c in spelled:
                targets.append(dictionary[c])
                owner.append(len(words) - 1)
        targets.append(star)
        owner.append(-1)

    times = [None] * len(words)
    if any(words):
        path, scores = F.forced_align(emission.unsqueeze(0), torch.tensor([targets], dtype=torch.int32), blank=0)
        spans = F.merge_tokens(path[0], scores[0].exp())
        for span, w in zip(spans, owner):
            if w < 0:
                continue
            s, e = span.start, span.end
            times[w] = [s, e] if times[w] is None else [times[w][0], e]
    say("PROGRESS", 0.9)

    # Ends: carry on while the voice does, up to the next word.
    energy = audio[: emission.shape[0] * int(seconds_per_frame * SAMPLE_RATE)]
    hop = int(seconds_per_frame * SAMPLE_RATE)
    rms = energy[: len(energy) // hop * hop].reshape(-1, hop).pow(2).mean(1).sqrt()
    quiet = 0.15 * (rms.quantile(0.95).item() if len(rms) else 0)
    timed = [i for i, t in enumerate(times) if t]
    for k, i in enumerate(timed):
        limit = times[timed[k + 1]][0] if k + 1 < len(timed) else emission.shape[0]
        e = times[i][1]
        if job.get("vocals"):
            while e < limit and e < len(rms) and rms[e] > quiet:
                e += 1
        else:
            e = min(limit, e + int(0.25 / seconds_per_frame))
        times[i][1] = max(e, min(limit, times[i][0] + 4))  # at least 80 ms when there's room

    out, k = [], 0
    for line in job["lines"]:
        row = []
        for _ in line:
            t = times[k]
            row.append(None if t is None else [round(start + t[0] * seconds_per_frame, 3),
                                                round(start + t[1] * seconds_per_frame, 3)])
            k += 1
        out.append(row)
    print(json.dumps(out))


if __name__ == "__main__":
    main()
