# -*- coding: utf-8 -*-
"""A4: write godot/tests/fixtures/reading_golden.json from the PC server's POST /reading/analyze.

The phone's LocalReading (godot/scripts/local/local_reading.gd) is compared against these answers: per-word `lemma`
match rate >= 90% and `level` match rate >= 85% (godot/tests/local_reading_test.gd). The paragraphs live in this file
on purpose: change them here, then run the script again against a running backend.

Run (stdlib only, any Python 3; the backend must already be running, nothing is started or stopped here):
  python -I <worktree>\backend\tools\make_reading_golden.py [--base http://127.0.0.1:18799] [--out <path>]

Exit code 0 = file written. Exit code 1 = the server could not be reached / answered badly (the old file is left alone).
The script only sends POST /reading/analyze requests (no side effects on the server).
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DEFAULT_OUT = os.path.join(ROOT, "godot", "tests", "fixtures", "reading_golden.json")
DEFAULT_BASE = "http://127.0.0.1:18799"

# five English paragraphs written for this test (contractions, names, plurals, -ing/-ed forms, irregular verbs,
# numbers, quotes, line breaks, abbreviations, a URL)
PARAGRAPHS = [
    # 1: everyday story, contractions, names
    "I didn't sleep well last night, so this morning I was walking slowly to the station. "
    "My brother Daniel was already waiting there with two coffees. \"You look tired,\" he said. "
    "\"It's the neighbours' fault,\" I answered. They're painting their house, and the noise started before dawn. "
    "We laughed, caught the 7:45 train, and talked about the holidays we'd planned for next summer.",
    # 2: explanatory text, plurals, participles, hyphens, numbers
    "Bees are surprisingly clever insects. A single colony can contain 50,000 workers, and each one has a job: "
    "some collect nectar, others clean the hive, and a few guard the entrance. When a scout finds a rich field of "
    "flowers, she returns and performs a waggle dance that shows her sisters the direction and the distance. "
    "Scientists studying these well-known dances have learned that the longer the dance lasts, the farther away the food is.",
    # 3: dialogue with line breaks and questions
    "\"Where have you been?\" asked Maria.\n"
    "\"At the library,\" said Tom. \"I borrowed three books about gardening.\"\n"
    "\"Gardening? You've never planted anything in your life!\"\n"
    "\"That's true, but my grandmother left me her old garden, and I'd like to grow tomatoes there. "
    "Do you think it will work?\"\n"
    "Maria smiled. \"Honestly, I don't know. Let's try together this weekend.\"",
    # 4: news style, abbreviations, URL, percentages
    "The city council announced on Monday that public transport fares will rise by 4% next year. "
    "Mayor Johnson said the money would be used to buy 120 new electric buses and to repair older stations. "
    "Dr. Smith, who studies urban planning at the University of Leeds, believes cheaper tickets would bring more "
    "passengers. Residents can read the full proposal at https://example.com/council/fares or send questions to "
    "help@example.com before the vote on March 3rd.",
    # 5: descriptive, irregular verbs, comparatives
    "The old lighthouse stood on the highest rock, looking over a restless grey sea. Every evening the keeper climbed "
    "the narrow stairs, lit the lamp, and watched the ships passing by. He had grown quieter with the years, but his "
    "eyes were sharper than anyone's in the village. Storms came and went, boats were lost and found, and the light "
    "kept burning brighter and steadier than the stars above it.",
]


def post_analyze(base, text, timeout):
    body = json.dumps({"lang": "en", "text": text}).encode("utf-8")
    req = urllib.request.Request(base.rstrip("/") + "/reading/analyze", data=body,
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def check(resp, text):
    """the answer must have the API.md shape and its tokens must give back the paragraph exactly"""
    if not isinstance(resp, dict) or not all(k in resp for k in ("tokens", "sentences", "words")):
        raise ValueError("answer has no tokens/sentences/words")
    if "".join(t["t"] for t in resp["tokens"]) != text:
        raise ValueError("tokens do not join back to the paragraph")
    if not any(t.get("w") for t in resp["tokens"]):
        raise ValueError("answer has no word tokens")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", default=DEFAULT_BASE, help="backend base URL (default %s)" % DEFAULT_BASE)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--timeout", type=float, default=60.0)
    args = ap.parse_args(argv)
    entries = []
    try:
        for text in PARAGRAPHS:
            resp = post_analyze(args.base, text, args.timeout)
            check(resp, text)
            entries.append({"text": text, "response": resp})
    except (urllib.error.URLError, OSError, ValueError) as e:
        print("ERROR: could not get /reading/analyze answers from %s: %s" % (args.base, e), file=sys.stderr)
        return 1
    golden = {"v": 1, "source": "POST /reading/analyze (PC backend)", "generator": "backend/tools/make_reading_golden.py",
              "lang": "en", "entries": entries}
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(golden, f, ensure_ascii=False, indent=1)
        f.write("\n")
    nw = sum(1 for e in entries for t in e["response"]["tokens"] if t["w"])
    print("wrote", args.out)
    print("paragraphs", len(entries), "word tokens", nw)
    return 0


if __name__ == "__main__":
    sys.exit(main())
