# -*- coding: utf-8 -*-
"""Checks a built package zip before it is published (build_dist.ps1 runs it on the setup and the update zip).

    python check_zip.py <zip> <config.default.json> [--allow-models] [--allow-progress]

Also fails when vendor/install_tools.py, vendor/tools.lock.json, vendor/update_helper.py or stop_app.ps1 are missing, or manifest.json has no
x.y.z version / installer_version, or defaults/prefs.json still has lesson_cursor (the learning position), mic_device or a *_consent choice.

Fails (exit 1) when the zip contains dev files (tests, build scripts, .gitignore), secrets / personal data,
installed or generated folders (models, data, cache, logs, tools, .venv), song study files (songs/, song_jobs/,
song.json, memo.json, *.lrc, audio files mp3 m4a ogg wav flac opus), unsafe entry names, or when
backend/config.json is not byte-for-byte the shipped neutral default config.
"""
import json
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
# the shipped default prefs come from the build PC: personal choices (consents, mic) must never ship
prefs_name = root + "defaults/prefs.json"
if prefs_name in names:
    def _personal_keys(v, path=""):
        out = []
        if isinstance(v, dict):
            for k, x in v.items():
                if k in ("mic_device", "lesson_cursor") or k.endswith("_consent"):
                    out.append(path + k)
                out += _personal_keys(x, path + k + ".")
        elif isinstance(v, list):
            for x in v:
                out += _personal_keys(x, path)
        return out
    try:
        for k in _personal_keys(json.loads(z.read(prefs_name).decode("utf-8"))):
            bad.append("defaults/prefs.json: personal setting %s" % k)
    except ValueError:
        bad.append("defaults/prefs.json is not valid JSON")
# files the installer and updater need (install.ps1 step 1 exits 10 without them, update.ps1 skips the tools refresh)
for need in ("vendor/install_tools.py", "vendor/tools.lock.json", "vendor/update_helper.py", "stop_app.ps1"):
    if root + need not in names:
        bad.append("%s is missing from the package" % need)
if root == "":
    pass  # update zip: same files at the zip root
elif root + "install.ps1" not in names:
    bad.append("install.ps1 is missing from the package")
# manifest.json must carry a version (update.ps1 and install.ps1 both read it) and the installer generation
man_name = root + "manifest.json"
if man_name not in names:
    bad.append("manifest.json missing")
else:
    try:
        man = json.loads(z.read(man_name).decode("utf-8-sig"))
        if not isinstance(man.get("version"), str) or not re.match(r"^\d+\.\d+\.\d+$", man.get("version", "")):
            bad.append("manifest.json: version is missing or not x.y.z")
        if not isinstance(man.get("installer_version"), int):
            bad.append("manifest.json: installer_version is missing")
        if not isinstance(man.get("files"), dict) or not man["files"]:
            bad.append("manifest.json: no files list")
    except ValueError:
        bad.append("manifest.json is not valid JSON")
for b in bad:
    print("VIOLATION", b)
print("ZIPCHECK_RESULT %s (%d files in %s)" % ("FAIL" if bad else "OK", len(names), zpath))
sys.exit(1 if bad else 0)
