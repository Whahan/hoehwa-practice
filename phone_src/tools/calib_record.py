# -*- coding: utf-8 -*-
"""PA5a: record the user's calibration clips (docs/v201_design.md 2.4 and 4.1, docs/v200_phone_design.md 1.6).

  calib_record.py --out <dir> [--dry-run] [--seed 11]

The user reads 30 English sentences twice: once correctly, once with the one word the screen names replaced by another (60 clips,
about 8 minutes). Microphone: `sounddevice` of backend\\.venv (already installed; nothing is installed or downloaded), 16 kHz mono.
Nothing starts before the consent text (CONSENT_TEXT, docs 4.1) is shown and `y` is typed. Per clip: Enter starts a 6 second recording
with a visible countdown, then Enter = next, `r` = record this clip again, `q` = stop here (what is recorded stays).
--out is required (no default folder) and must be empty or new. Everything goes under --out: clips\\<clip>.wav and manifest.json
({"v":1,"kind":"user","seed","consent":{"given":true,"text_sha256","date"},"clips":[...]}, same clip fields as calib_make_set.py with
variant "user_clean" / "user_wrong" and voice "user"). The recordings never leave this PC: no network, no repository path, and no
file of this tool keeps what was said or read (the screen shows the sentences, nothing else is kept). At the end only the number of
clips and the total length are printed. Deleting the folder after the calibration is the user's choice (docs 4.1: the default is delete).
--dry-run opens no microphone, writes nothing (not even --out) and prints the consent text and the 30 sentences.
Consent is exactly the lower case letter `y` (spaces around it are ignored): `Y`, `yes`, `n`, an empty line all mean no.
--out may not be inside a repository, a worktree or backend (exit 2, nothing written, not even for --dry-run).
Exit code: 0 ok (also `q` after some clips), 1 consent not given / microphone problem / --out not empty, 2 usage error or a forbidden --out.
"""
import argparse
import datetime
import hashlib
import json
import os
import random
import sys
import time

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.append(HERE)   # -I does not add the script folder

import calib_fit as cf   # noqa: E402
import calib_make_set as ms   # noqa: E402  (sentence pool and the word replacement are shared with the synthetic set)

CONSENT_TEXT = ("영어 문장 30개를 한 번은 바르게, 한 번은 화면이 알려 주는 낱말 하나를 바꿔서 읽어요(약 8분). "
                "녹음은 이 PC 의 임시 폴더에만 저장되고 저장소·인터넷으로 나가지 않아요. 보정이 끝나면 지워요(원하면 보관). "
                "시작할까요? (y/n)")
N_SENTENCES = 30
RECORD_SECONDS = 6
RATE = 16000
USER_WORDS = (4, 8)   # sentence length for reading aloud


class RecError(Exception):
    pass


def plan(seed, n=N_SENTENCES):
    """[(sentence_id, text, wrong {index, said}, spoken text)] for the user: fixed by the seed, so the dry run shows what will be asked"""
    with cf.no_network():
        pool = ms.load_pool(USER_WORDS[0], USER_WORDS[1], n)
    if len(pool) < n:
        raise RecError("only %d sentences available" % len(pool))
    chosen = ms.pick_sentences(pool, n, seed)
    vocab = ms.vocabulary(pool)
    rng = random.Random(seed * 1000003 + 29)
    out = []
    for sid, text in chosen:
        wrong, spoken = ms.choose_wrong(text, rng, vocab)
        out.append((sid, text, wrong, spoken))
    return out


def describe(k, total, item, out=print):
    sid, text, wrong, spoken = item
    out("문장 %02d/%d" % (k, total))
    out("  바르게 읽기 : %s" % text)
    out("  바꿔 읽기   : %s   (%d번째 낱말을 '%s' 로 바꿔요)" % (spoken, wrong["index"] + 1, wrong["said"]))


def default_recorder(seconds, tick=None):
    """16 kHz mono int16 samples recorded from the default microphone (numpy array)"""
    try:
        import sounddevice as sd
        stream = sd.rec(int(seconds * RATE), samplerate=RATE, channels=1, dtype="int16")
    except Exception as e:
        raise RecError("microphone (%s)" % type(e).__name__)
    for s in range(seconds, 0, -1):
        if tick:
            tick(s)
        time.sleep(1.0)
    sd.wait()
    return stream.reshape(-1)


def write_wav(path, samples):
    import soundfile as sf
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    sf.write(path, samples, RATE, subtype="PCM_16", format="WAV")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def peak_of(samples):
    try:
        return float(max(abs(int(samples.max())), abs(int(samples.min())))) / 32767.0
    except Exception:
        return 0.0


def run(out_dir, dry_run, seed, input_fn=input, recorder=default_recorder, out=print, wav_writer=write_wav):
    cf.require_out_paths(out_dir)
    items = plan(seed)
    if dry_run:
        out(CONSENT_TEXT)
        out("")
        for k, item in enumerate(items, 1):
            describe(k, len(items), item, out)
        out("CALIB_REC_DRY_RUN sentences=%d clips=%d (no microphone opened, nothing written)" % (len(items), 2 * len(items)))
        return 0
    if os.path.isdir(out_dir) and os.listdir(out_dir):
        out("CALIB_REC_FAIL --out folder is not empty")
        return 1
    out(CONSENT_TEXT)
    if input_fn("> ").strip() != "y":
        out("CALIB_REC_FAIL consent not given (nothing recorded)")
        return 1
    consent = {"given": True, "text_sha256": hashlib.sha256(CONSENT_TEXT.encode("utf-8")).hexdigest(),
               "date": datetime.date.today().isoformat()}
    clips, total_seconds, stopped = [], 0.0, False
    try:
        for k, item in enumerate(items, 1):
            sid, text, wrong, spoken = item
            describe(k, len(items), item, out)
            for kind in ("clean", "wrong"):
                shown = text if kind == "clean" else spoken
                while True:
                    out("  읽을 문장 (%s): %s" % ("바르게" if kind == "clean" else "바꿔서", shown))
                    ans = input_fn("  Enter = 녹음 시작 (q = 여기서 그만) > ").strip().lower()
                    if ans == "q":
                        stopped = True
                        break
                    samples = recorder(RECORD_SECONDS, lambda s: print("\r  녹음 중... %d " % s, end="", flush=True))
                    out("")
                    if peak_of(samples) < 0.003:
                        out("  소리가 거의 들어오지 않았어요. 마이크를 확인하고 다시 해 보세요.")
                    ans = input_fn("  Enter = 다음, r = 다시 녹음 > ").strip().lower()
                    if ans == "r":
                        continue
                    clip = "u%02d_%s" % (k, kind)
                    rel = "clips/%s.wav" % clip
                    wav_writer(os.path.join(out_dir, rel), samples)
                    seconds = len(samples) / float(RATE)
                    total_seconds += seconds
                    clips.append({"clip": clip, "file": rel, "sentence_id": sid, "target": text, "variant": "user_" + kind,
                                  "voice": "user", "wrong": dict(wrong) if kind == "wrong" else None, "spoken": shown,
                                  "seconds": round(seconds, 3), "sha256": sha256_file(os.path.join(out_dir, rel))})
                    break
                if stopped:
                    break
            if stopped:
                break
    finally:   # an interrupted session keeps the clips that were already recorded
        if clips:
            ms.write_json(os.path.join(out_dir, "manifest.json"),
                          {"v": 1, "kind": "user", "seed": seed, "consent": consent, "clips": clips})
    out("CALIB_REC_OK clips=%d seconds=%.1f" % (len(clips), total_seconds))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="record the user's calibration clips (consent first; stays on this PC)")
    ap.add_argument("--out", required=True, help="empty or new folder for clips\\ and manifest.json (no default)")
    ap.add_argument("--dry-run", action="store_true", help="show the consent text and the sentences; no microphone, nothing written")
    ap.add_argument("--seed", type=int, default=11)
    args = ap.parse_args(argv)
    try:
        return run(os.path.abspath(args.out), args.dry_run, args.seed)
    except cf.OutPathRefused:
        print("CALIB_REC_FAIL out_path")
        return 2
    except RecError as e:
        print("CALIB_REC_FAIL %s" % e)
        return 1
    except ms.SetError as e:
        print("CALIB_REC_FAIL %s" % e)
        return 1
    except (EOFError, KeyboardInterrupt):
        print("CALIB_REC_FAIL stopped")
        return 1


if __name__ == "__main__":
    sys.exit(main())
