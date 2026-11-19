# -*- coding: utf-8 -*-
"""PA5a: the PC side of the calibration (docs/v201_design.md 2.4).

  calib_pc_run.py --set <dir> --out <json>

Runs the clips of a set (manifest.json from calib_make_set.py or calib_record.py) through the server's own `transcribe` (faster-whisper on
the CPU, the same settings as `server.py --stt-cpu`) and `score_en`, in THIS process: no server process, no port, no network, nothing
written under backend\\. Writes only --out:
  {"v":1,"kind":"pc","date":"YYYY-MM-DD","stt":{"model","device","compute_type"},
   "clips":[{id, sentence_id, group("synth"|"user"), variant, voice, target, text, words:[{w,p,start,end}], duration, score:<score_en result>}]}
`id` is the manifest `clip`. The file holds transcripts: keep it in the scratch folder, never in the repository, and never print it.
Each clip file is checked against its sha256 first (a changed file is "CALIB_PC_FAIL sha256", exit 1).
--out may not be inside a repository, a worktree or backend (CALIB_PC_FAIL out_path, exit 2, nothing written).
Exit code: 0 ok, 1 failure (CALIB_PC_FAIL <reason>), 2 usage error or a forbidden --out.
"""
import argparse
import datetime
import hashlib

import json
import os
import sys

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.append(HERE)   # -I does not add the script folder


class PcRunError(Exception):
    pass


def read_manifest(set_dir):
    path = os.path.join(set_dir, "manifest.json")
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            m = json.load(f)
    except (OSError, ValueError):
        raise PcRunError("manifest")
    if not isinstance(m, dict) or not isinstance(m.get("clips"), list) or not m["clips"]:
        raise PcRunError("manifest")
    seen = set()
    for c in m["clips"]:
        if (not isinstance(c, dict) or not all(isinstance(c.get(k), str) and c[k] for k in ("clip", "file", "target", "sha256"))
                or not isinstance(c.get("sentence_id"), str)):
            raise PcRunError("manifest")
        if c["clip"] in seen:
            raise PcRunError("manifest")
        seen.add(c["clip"])
    return m


def load_audio(path):
    """float32 mono 16 kHz, the way the server decodes a recording (decode_audio_b64)"""
    import numpy as np
    import soundfile as sf
    from math import gcd
    from scipy.signal import resample_poly
    with sf.SoundFile(path) as f:
        sr = f.samplerate
        data = f.read(dtype="float32", always_2d=True).mean(axis=1)
    if sr != 16000 and len(data):
        g = gcd(int(sr), 16000)
        data = resample_poly(data, 16000 // g, int(sr) // g).astype(np.float32)
    return np.ascontiguousarray(data, dtype=np.float32)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def run(set_dir, out_path, out=print):
    import calib_fit
    calib_fit.require_out_paths(out_path)
    m = read_manifest(set_dir)
    group = "user" if m.get("kind") == "user" else "synth"
    for c in m["clips"]:   # check the files before the (slow) model loads
        p = os.path.join(set_dir, c["file"].replace("/", os.sep))
        if not os.path.isfile(p):
            raise PcRunError("missing file")
        if sha256_file(p) != c["sha256"]:
            raise PcRunError("sha256")
    with calib_fit.no_network():
        S = calib_fit.load_server()
        clips = []
        for c in m["clips"]:
            audio = load_audio(os.path.join(set_dir, c["file"].replace("/", os.sep)))
            text, words, duration = S.transcribe(audio, "en")
            score = S.score_en(c["target"], words, text)
            clips.append({"id": c["clip"], "sentence_id": c["sentence_id"], "group": group, "variant": str(c.get("variant", "")),
                          "voice": str(c.get("voice", "")), "target": c["target"], "text": text, "words": words,
                          "duration": duration, "score": score})
        stt = dict(S.CFG["stt"])
    doc = {"v": 1, "kind": "pc", "date": datetime.date.today().isoformat(),
           "stt": {"model": stt.get("model"), "device": stt.get("device"), "compute_type": stt.get("compute_type")}, "clips": clips}
    calib_fit.guard_write(out_path)   # checked again right before the write
    d = os.path.dirname(os.path.abspath(out_path))
    os.makedirs(d, exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
        f.write("\n")
    out("CALIB_PC_OK clips=%d" % len(clips))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="PC side of the calibration: server transcribe + score_en over a clip set, in this process")
    ap.add_argument("--set", required=True, help="folder with manifest.json and the clips")
    ap.add_argument("--out", required=True, help="json file to write (scratch folder)")
    args = ap.parse_args(argv)
    import calib_fit
    try:
        return run(os.path.abspath(args.set), os.path.abspath(args.out))
    except calib_fit.OutPathRefused:
        print("CALIB_PC_FAIL out_path")
        return 2
    except PcRunError as e:
        print("CALIB_PC_FAIL %s" % e)
        return 1
    except Exception as e:   # only the type (an exception text may hold a file name or a transcript)
        print("CALIB_PC_FAIL %s" % type(e).__name__)
        return 1


if __name__ == "__main__":
    sys.exit(main())
