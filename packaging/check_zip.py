# -*- coding: utf-8 -*-
"""Checks a built package zip before it is published (build_dist.ps1 runs it on the setup and the update zip).

    python check_zip.py <zip> <config.default.json> [--allow-models] [--allow-progress]

Fails (exit 1) when the zip contains dev files (tests, build scripts, .gitignore), secrets / personal data,
installed or generated folders (models, data, cache, logs, tools, .venv), song study files (songs/, song_jobs/,
song.json, memo.json, *.lrc, audio files mp3 m4a ogg wav flac opus), unsafe entry names, or when
backend/config.json is not byte-for-byte the shipped neutral default config.
"""
import re
import sys
import zipfile

args = [a for a in sys.argv[1:] if not a.startswith("--")]
allow_models = "--allow-models" in sys.argv
allow_progress = "--allow-progress" in sys.argv
zpath, default_cfg = args[0], args[1]

BAD_NAME = [
    (r"(^|/)test_[^/]*\.py$", "test file"),
    (r"(^|/)build_curriculum\.py$", "dev build script"),
    (r"(^|/)(sync_hub_mutations\.json|run_sync_hub_mutations\.ps1)$", "dev tool (sync hub mutation test)"),
    (r"(^|/)\.gitignore$", ".gitignore"),
    (r"(^|/)\.gitattributes$", ".gitattributes"),
    (r"^backend/requirements\.txt$", "dev requirements.txt"),
    (r"(^|/)setup\.ps1$", "dev setup.ps1"),
    (r"(^|/)secrets\.json", "secrets.json"),
    (r"(^|/)(auth\.json|\.env)$", "credentials file"),
    (r"(^|/)lan_devices[^/]*\.json", "paired-phone tokens (lan_devices*.json)"),
    (r"(^|/)remote\.json$", "remote-access settings (remote.json)"),
    (r"^(?!defaults/prefs\.json$)(.*/)?prefs\.json$", "personal settings (prefs.json; only the sanitized defaults/prefs.json may ship)"),
    (r"\.sqlite(-journal|-wal)?$", "database"),
    (r"(^|/)__pycache__/", "__pycache__"),
    (r"\.(pyc|log)$", "pyc/log"),
    (r"^backend/(data|cache|logs|tools|\.venv)/", "installed/generated folder"),
    (r"^(runtime|backup|backups|dist)/", "installed/generated folder"),
    # song study / lyrics memorize: lyrics, audio and per-song records are the user's own files and never ship
    (r"(^|/)songs/", "user songs folder (lyrics/audio)"),
    (r"(^|/)song_jobs/", "song job cache"),
    (r"song\.json$", "song record (lyrics)"),
    (r"memo\.json$", "lyrics-memorize record (memo.json)"),
    (r"\.lrc$", "lyrics file (.lrc)"),
    (r"\.(mp3|m4a|ogg|wav|flac|opus)$", "audio file"),
]
if not allow_models:
    BAD_NAME.append((r"^backend/models/", "models folder"))
if not allow_progress:
    BAD_NAME.append((r"(^|/)progress\.json$", "learning history"))
    BAD_NAME.append((r"(^|/)studylog\.json$", "learning history (studylog.json)"))

bad = []
z = zipfile.ZipFile(zpath)
names = [i.filename for i in z.infolist() if not i.filename.endswith("/")]
# setup zips have one root folder (회화연습/...); update zips start at the app root
roots = set(n.split("/")[0] for n in names)
root = ""
if "manifest.json" not in names and len(roots) == 1:
    root = roots.pop() + "/"
for n in names:
    if n.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", n) or ".." in n.split("/") or "\\" in n:
        bad.append("%s: unsafe entry name" % n)
        continue
    rel = n[len(root):] if n.startswith(root) else n
    for pat, why in BAD_NAME:
        if re.search(pat, rel, re.I):
            bad.append("%s: %s" % (n, why))
            break
cfg_name = root + "backend/config.json"
if cfg_name not in names:
    bad.append("backend/config.json missing")
elif z.read(cfg_name) != open(default_cfg, "rb").read():
    bad.append("backend/config.json is not identical to %s" % default_cfg)
for b in bad:
    print("VIOLATION", b)
print("ZIPCHECK_RESULT %s (%d files in %s)" % ("FAIL" if bad else "OK", len(names), zpath))
sys.exit(1 if bad else 0)
