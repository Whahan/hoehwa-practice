# -*- coding: utf-8 -*-
"""PA5a: record the user's calibration clips (docs/v201_design.md 2.4 and 4.1, docs/v200_phone_design.md 1.6).

  calib_record.py --list-devices
  calib_record.py --out <dir> [--device <number or part of a name>] [--dry-run] [--seed 11]

The user reads 30 English sentences twice: once correctly, once with the one word the screen names replaced by another (60 clips,
about 8 minutes). Microphone: `sounddevice` of backend\\.venv (already installed; nothing is installed or downloaded). A clip is
recorded at the sample rate of the chosen device (WASAPI and others do not take 16 kHz) and converted to 16 kHz mono 16 bit (soxr, or
scipy resample_poly) before it is written; stereo is averaged.
--list-devices only prints the input devices (number, readable name, API, channels, default rate; WDM-KS is left out, the Windows
default is marked, one real microphone is recommended: not a game pad, not a virtual device) and opens no microphone.
Nothing starts before the consent text (CONSENT_TEXT, docs 4.1) is shown and `y` is typed. Then the device is chosen (--device, or the
list and a number; Enter = the recommended one) and a 3 second sound check is shown on the screen (a bar and the size only, kept in
memory, never saved; too quiet -> choose another device / check again / go on). Per clip: Enter starts a 6 second recording with a
visible countdown, the size of the take is shown (a warning when it is too quiet or clipped), then Enter = next, `r` = record this clip
again, `q` = stop here (what is recorded stays).
--out is required (no default folder, except for --list-devices) and must be empty or new. Everything goes under --out: clips\\<clip>.wav
and manifest.json ({"v":1,"kind":"user","seed","consent":{"given":true,"text_sha256","date"},"capture_hz","resampled","clips":[...]},
same clip fields as calib_make_set.py with variant "user_clean" / "user_wrong" and voice "user"; the device is not named there: only the
sample rate as a number and whether it was converted, 0 or 1). The recordings never leave this PC: no network, no repository path, and
no file of this tool keeps what was said or read (the screen shows the sentences, nothing else is kept). At the end only the number of
clips and the total length are printed. Deleting the folder after the calibration is the user's choice (docs 4.1: the default is delete).
--dry-run opens no microphone, does not even list devices, writes nothing (not even --out) and prints the consent text and the 30 sentences.
Consent is exactly the lower case letter `y` (spaces around it are ignored): `Y`, `yes`, `n`, an empty line all mean no.
--out may not be inside a repository, a worktree or backend (exit 2, nothing written, not even for --dry-run).
Exit code: 0 ok (also `q` after some clips), 1 consent not given / microphone problem / --out not empty, 2 usage error or a forbidden --out.
"""
import argparse
import datetime
import hashlib
import json
import math
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

SILENT_RMS = 0.003      # a take or a sound check below this size (rms) or below SILENT_PEAK (peak) is "too quiet"
SILENT_PEAK = 0.02
CLIP_PEAK = 0.99        # a take whose peak reaches this is clipped
CHECK_SECONDS = 3
STEP = 0.25             # screen update step while recording
BAR_WIDTH = 30

HIDDEN_WORDS = ("sound mapper", "사운드 매퍼", "주 사운드 캡처", "primary sound capture")   # aliases of the Windows default, not devices
GAMEPAD_WORDS = ("wireless controller", "gamepad", "game pad", "dualshock", "dualsense", "xbox", "게임패드", "게임 패드", "무선 컨트롤러")
VIRTUAL_WORDS = ("stereo mix", "스테레오 믹스", "virtual", "가상", "vb-audio", "voicemeeter", "loopback", "nvidia broadcast",
                 "steam streaming", "remote audio", "원격 오디오", "cable input", "cable output")


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


# ---------------------------------------------------------------------------------------------------------------- input devices
def has_hangul(text):
    return any("가" <= c <= "힣" for c in text)


def readable_name(name):
    """a printable device name: control characters out; Korean that came through the ANSI code page (cp949 bytes shown as cp1252 or
    latin-1 letters) is restored when that gives Hangul"""
    name = " ".join("".join(c if c.isprintable() else " " for c in str(name)).split())
    if not has_hangul(name) and any(ord(c) >= 128 for c in name):
        for enc in ("cp1252", "latin-1"):
            try:
                fixed = name.encode(enc).decode("cp949")
            except (UnicodeEncodeError, UnicodeDecodeError):
                continue
            if has_hangul(fixed):
                return fixed
    return name


def load_sd():
    try:
        import sounddevice as sd
    except Exception as e:
        raise RecError("microphone (%s)" % type(e).__name__)
    return sd


def default_input_index(sd):
    try:
        v = sd.default.device
        v = v[0] if hasattr(v, "__getitem__") and not isinstance(v, str) else v
        return int(v) if int(v) >= 0 else None
    except Exception:
        return None


def list_input_devices(sd):
    """[{index, name, api, channels, rate, default, gamepad, virtual}] of the input devices. WDM-KS is left out (unstable), so are
    the Windows mapper entries. One readable name per device: a name that MME cut at 31 letters takes the full name of the same
    device from another API. Only queries the list; nothing is opened."""
    try:
        apis = sd.query_hostapis()
        raw = list(sd.query_devices())
    except Exception as e:
        raise RecError("microphone (%s)" % type(e).__name__)
    default = default_input_index(sd)
    rows = []
    for i, d in enumerate(raw):
        try:
            if int(d["max_input_channels"]) <= 0:
                continue
            api = str(apis[d["hostapi"]]["name"])
            if "wdm" in api.lower():
                continue
            rows.append({"index": i, "name": readable_name(d["name"]), "api": api, "channels": int(d["max_input_channels"]),
                         "rate": int(round(float(d["default_samplerate"])))})
        except (KeyError, IndexError, TypeError, ValueError):
            continue
    fulls = [r["name"] for r in rows if "mme" not in r["api"].lower()]
    out = []
    for r in rows:
        if "mme" in r["api"].lower() and len(r["name"]) >= 28:
            longer = [n for n in fulls if len(n) > len(r["name"]) and n.startswith(r["name"])]
            if longer:
                r["name"] = longer[0]
        low = r["name"].lower()
        if any(w in low for w in HIDDEN_WORDS):
            continue
        r["default"] = r["index"] == default
        r["gamepad"] = any(w in low for w in GAMEPAD_WORDS)
        r["virtual"] = any(w in low for w in VIRTUAL_WORDS)
        out.append(r)
    return out


def recommended_device(devs):
    """the first real microphone: not a game pad, not a virtual device"""
    for r in devs:
        if not r["gamepad"] and not r["virtual"]:
            return r
    return None


def device_line(r, rec_index=None):
    notes = []
    if r["default"]:
        notes.append("Windows 기본 입력")
    if r["gamepad"]:
        notes.append("게임 패드: 추천 안 함")
    elif r["virtual"]:
        notes.append("가상 장치: 추천 안 함")
    if r["index"] == rec_index:
        notes.append("추천")
    return "%3d  %s  [%s, %dch, %d Hz]%s" % (r["index"], r["name"], r["api"], r["channels"], r["rate"],
                                             ("  <- " + ", ".join(notes)) if notes else "")


def show_devices(devs, out=print):
    rec_dev = recommended_device(devs)
    out("입력 장치 (번호  이름  [API, 채널, 기본 샘플레이트])")
    for r in devs:
        out(device_line(r, rec_dev["index"] if rec_dev else None))
    return rec_dev


def resolve_device(devs, spec):
    """--device: a number of the list, or a part of a name (case ignored; the first match = the lowest number)"""
    spec = str(spec).strip()
    if spec.isdigit():
        for r in devs:
            if r["index"] == int(spec):
                return r
        raise RecError("device")
    low = spec.lower()
    for r in devs:
        if low and low in r["name"].lower():
            return r
    raise RecError("device")


def pick_device(sd, spec, input_fn, out):
    devs = list_input_devices(sd)
    if not devs:
        raise RecError("no input device")
    if spec is not None:
        chosen = resolve_device(devs, spec)
    else:
        rec_dev = show_devices(devs, out)
        chosen = None
        for _ in range(5):
            ans = input_fn("  번호를 고르세요%s > " % (" (Enter = 추천 %d)" % rec_dev["index"] if rec_dev else "")).strip()
            if ans == "" and rec_dev:
                chosen = rec_dev
                break
            if ans.isdigit():
                found = [r for r in devs if r["index"] == int(ans)]
                if found:
                    chosen = found[0]
                    break
            out("  목록에 없는 번호예요.")
        if chosen is None:
            raise RecError("device")
    out("  선택한 장치: %s" % device_line(chosen))
    return chosen


def list_devices(out=print, sd=None):
    """--list-devices: the list only (no microphone is opened)"""
    devs = list_input_devices(sd or load_sd())
    show_devices(devs, out)
    out("CALIB_REC_DEVICES n=%d (no microphone opened)" % len(devs))
    return 0


# ---------------------------------------------------------------------------------------------------------------- audio
def level_of(samples):
    """(rms, peak) on a 0..1 scale of a float (-1..1) or int16 array; (0, 0) when empty"""
    import numpy as np
    x = np.asarray(samples)
    if x.size == 0:
        return 0.0, 0.0
    scale = 32768.0 if x.dtype.kind in "iu" else 1.0
    x = x.astype("float64") / scale
    return float(math.sqrt(float(np.mean(x * x)))), float(np.max(np.abs(x)))


def too_quiet(rms, peak):
    return rms < SILENT_RMS or peak < SILENT_PEAK


def bar(rms, width=BAR_WIDTH):
    """a text bar for a size of 0..1 (square root scale, so that speech sits in the middle)"""
    n = int(round(min(1.0, math.sqrt(max(0.0, rms))) * width))
    return "[" + "#" * n + "." * (width - n) + "]"


def to_16k(x, rate):
    """float mono at `rate` -> float mono at 16 kHz (soxr when it is installed, else scipy resample_poly)"""
    import numpy as np
    x = np.asarray(x, dtype="float32")
    if int(rate) == RATE:
        return x
    try:
        import soxr
        return np.asarray(soxr.resample(x, int(rate), RATE, quality="HQ"), dtype="float32")
    except ImportError:
        from scipy.signal import resample_poly
        g = math.gcd(int(rate), RATE)
        return np.asarray(resample_poly(x, RATE // g, int(rate) // g), dtype="float32")


def to_int16(x):
    import numpy as np
    return np.round(np.clip(np.asarray(x, dtype="float64"), -1.0, 1.0) * 32767.0).astype("int16")


def capture(sd, dev, seconds, tick=None, live=None, sleep=time.sleep):
    """record `seconds` from the device at its own sample rate: mono float32 (stereo averaged), in memory only.
    tick(remaining whole seconds) once per second, live(rms of the last step) every STEP seconds"""
    import numpy as np
    rate, ch = dev["rate"], max(1, min(2, dev["channels"]))
    try:
        buf = sd.rec(int(seconds * rate), samplerate=rate, channels=ch, dtype="float32", device=dev["index"])
        steps = max(1, int(round(seconds / STEP)))
        per_sec = max(1, int(round(1.0 / STEP)))
        for k in range(steps):
            if tick and k % per_sec == 0:
                tick(int(seconds) - k // per_sec)
            sleep(STEP)
            if live:
                a, b = int(k * STEP * rate), int((k + 1) * STEP * rate)
                live(level_of(np.asarray(buf)[a:b].reshape(-1))[0])
        sd.wait()
    except Exception as e:
        raise RecError("microphone (%s)" % type(e).__name__)
    x = np.asarray(buf, dtype="float32")
    return x.reshape(len(x), -1).mean(axis=1) if x.size else x.reshape(-1)


class DeviceRecorder:
    """recorder(seconds, tick) -> 16 kHz mono int16 samples from the chosen device (resampled when its rate is not 16 kHz)"""

    def __init__(self, sd, dev, sleep=time.sleep):
        self.sd, self.dev, self.sleep = sd, dev, sleep
        self.rate = dev["rate"]
        self.resampled = int(self.rate != RATE)

    def __call__(self, seconds, tick=None):
        return to_int16(to_16k(capture(self.sd, self.dev, seconds, tick=tick, sleep=self.sleep), self.rate))


def sound_check(sd, dev, input_fn, out, live=None, sleep=time.sleep):
    """3 seconds on the screen, kept in memory only and thrown away (never written). Returns the device to use (it may be changed)."""
    while True:
        out("소리 확인: %d초 동안 아무 말이나 해 보세요 (저장하지 않아요)" % CHECK_SECONDS)
        x = capture(sd, dev, CHECK_SECONDS, live=live, sleep=sleep)
        rms, peak = level_of(x)
        del x
        out("")
        out("  %s 크기 rms %.4f, peak %.3f" % (bar(rms), rms, peak))
        if not too_quiet(rms, peak):
            return dev
        out("  소리가 거의 안 들려요.")
        while True:
            ans = input_fn("  d = 다른 장치 고르기, r = 다시 확인, Enter = 그대로 진행 > ").strip().lower()
            if ans in ("d", "r", ""):
                break
        if ans == "d":
            dev = pick_device(sd, None, input_fn, out)
        elif ans == "":
            return dev


def write_wav(path, samples):
    import soundfile as sf
    cf.guard_write(path)   # the real place of this file, checked right before it is written
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    sf.write(path, samples, RATE, subtype="PCM_16", format="WAV")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def take_report(samples, out):
    """show the size of a take; warn (never force) when it is too quiet or clipped"""
    rms, peak = level_of(samples)
    out("  %s 크기 rms %.4f, peak %.3f" % (bar(rms), rms, peak))
    if too_quiet(rms, peak):
        out("  소리가 너무 작아요. 마이크를 확인하고 r 로 다시 녹음해 보세요.")
    if peak >= CLIP_PEAK:
        out("  소리가 너무 커서 잘렸어요. 마이크에서 조금 떨어져서 r 로 다시 녹음해 보세요.")


def live_print(rms):
    print("\r  %s " % bar(rms), end="", flush=True)


def run(out_dir, dry_run, seed, input_fn=input, recorder=None, out=print, wav_writer=write_wav, device=None, sd=None,
        sleep=time.sleep, live=live_print):
    """recorder: a function (seconds, tick) -> 16 kHz int16 samples. Without one, the microphone path is used: the device is chosen
    (`device` = number or part of a name, else the list) and a sound check is shown, after the consent only."""
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
    if recorder is None:
        sd = sd or load_sd()
        dev = pick_device(sd, device, input_fn, out)
        dev = sound_check(sd, dev, input_fn, out, live=live, sleep=sleep)
        recorder = DeviceRecorder(sd, dev, sleep=sleep)
    capture_hz = int(getattr(recorder, "rate", RATE))
    resampled = int(getattr(recorder, "resampled", 0))
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
                    take_report(samples, out)
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
                          {"v": 1, "kind": "user", "seed": seed, "consent": consent, "capture_hz": capture_hz,
                           "resampled": resampled, "clips": clips})
    out("CALIB_REC_OK clips=%d seconds=%.1f" % (len(clips), total_seconds))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="record the user's calibration clips (consent first; stays on this PC)")
    ap.add_argument("--out", help="empty or new folder for clips\\ and manifest.json (required, no default)")
    ap.add_argument("--dry-run", action="store_true", help="show the consent text and the sentences; no microphone, nothing written")
    ap.add_argument("--list-devices", action="store_true", help="print the input devices and exit (no microphone is opened)")
    ap.add_argument("--device", help="input device: a number of --list-devices, or a part of its name (default: ask after the consent)")
    ap.add_argument("--seed", type=int, default=11)
    args = ap.parse_args(argv)
    for stream in (sys.stdout, sys.stderr):   # a device name or a sentence must not crash the print on a legacy code page
        try:
            stream.reconfigure(errors="replace")
        except Exception:
            pass
    try:
        if args.list_devices:
            return list_devices()
        if not args.out:
            ap.error("--out is required")   # exit code 2
        return run(os.path.abspath(args.out), args.dry_run, args.seed, device=args.device)
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
