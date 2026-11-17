course_src\tools  -  content tools for the 72-week English course (v2.0)
=====================================================================
Python 3, standard library only, no network.  Not shipped with the app (course_src\ is outside backend\ and godot\).
Run with:  D:\Ai\언어\app\backend\.venv\Scripts\python.exe -X utf8 <script> ...   (add -I for an isolated interpreter)

Tools
-----
check_course.py   linter (design docs\v200_design.md 9.2). Exit 0 = pass, 1 = fail.
                  First line of a failure `CHECK_FAIL <CODE>`, last line `CHECK_FAIL weeks=.. violations=N codes=..`;
                  pass: last line `CHECK_OK weeks=.. violations=0`. Output = ids, codes, single tokens (never manuscript text).
    --in <dir>            manuscript folder (skeleton.json, policy.json, weeks\w001.json ...)
    --weeks a-b           only these weeks are checked (their files must exist); all other loaded weeks only feed the lexicon
    --strict              warnings (unknown keys, plain-style Korean endings, missing policy.json, unverifiable Tatoeba ...) fail
    --skeleton            check skeleton.json (72 weeks, counts, id_ranges, assignment table, pattern `needs`)  [K0]
    --lexicon-from skeleton   words come from the assignment table of skeleton.json (and week files must match it exactly)
    --tatoeba-db <path>   tatoeba.sqlite (read only) or a small {"id": "text"} .json (tests)
    --grammar [--grammar-backend <grammar.py>]   LanguageTool via backend\grammar.py; without it `GRAMMAR_SKIPPED` (not verified)
    --count-items         prints `ITEMS weeks=.. word=.. pattern=.. sentence=.. dialogue_line=.. total=N`
    --review <tsv>        checks R1_X*.tsv (columns id type verdict issue fix): every item once, verdict OK/M/C
                          -> `REVIEW_OK rows=N C=.. M=..` (with --strict C must be 0)
  Codes: SCHEMA ORDER UNKNOWN_TOKEN NUM_SAY KO_HANGUL KO_HANJA DUP_EN DUP_KO SAME_KO_OPTIONS BLOCKED PERSONAL COUNT CANON
         TATOEBA GRAMMAR.

build_course.py   lint (strict) then write godot\data\course\ files: --in <dir> --out <dir> [--weeks a-b] [--check]
                  Nothing is written when the lint fails. Manifest = {"v":1,"lang":"en","weeks":[a,b],"count":N,
                  "files":[{"path","bytes","sha256","records"}]} (PackLoader format, no time stamp: builds are byte-identical).
                  en_speak_prompts.json is grouped by month: {"month":n,"w":w,"prompts":[{id,kind,en,ko,say,expect_any,o}]}.
numbers_en.py     words(n) price_say time_say ordinal_say phone_say percent_say decimal_say say_sentence needs_say say_matches
sample_sheet.py   --in <dir> --n 300 --seed S --out sheet.csv [--weeks a-b]   stratified sample for the human review
tatoeba_fit.py    --in <dir> [--weeks a-b] [--db <sqlite>] [--show N] [--json out]   candidates per week (cum / new)
make_fixtures.py  rewrites fixtures\ (good_mini and 14 bad_<name> folders); `--check` compares (test_check_course runs it)
Tests: python -X utf8 -m unittest discover -s course_src\tools -p "test_*.py" -v

Rules the linter applies (token rules are the ones the app's LexiconGuard must use too)
----------------------------------------------------------------------------------------
Tokenizer: NFKC, lower case, U+2019 -> ', tokens = runs of letters/digits with an optional inner '  (hyphens and all other
  punctuation split: thirty-five -> thirty five, I'm stays one token).  Text source: `say` if the item has one, else `en`.
o = w*10 + d (week, day).  Item o = its `d` (sentence without `d`: the earliest day that fits, never later than D7).
  word o = w*10 + d;  a form (`forms[].f`) of a word has o = max(word o, o of the pattern named in `pat`);
  `alt` spellings count at the word's o;  tokens of a multi-word entry (chunk) count at the chunk's o.
ORDER: a token of an item has min(o of its lexicon entries) > item o; passive word in a sentence with scope "all" (R5);
  declared `words` that are later than the item.  UNKNOWN_TOKEN: token not in the lexicon at all.
NUM_SAY: digits, symbols ($ % & @ # + =), abbreviations (Mr. Dr. a.m. ...), acronyms (ABC, except policy acronym_ok / OK)
  need a `say` without digits/symbols that matches numbers_en readings ("$5.99" -> "five ninety-nine").
Day rule: new words and patterns are taught on D1..D4 (`d` 1..4); sentences/lines may use D1..D7.
Counts per week (policy.json "limits" overrides any key; defaults = design): sentences >= 36, per pattern >= 6, per active
  word >= 2, active 10-30 (weeks 1-4: 20-28, weeks 16/32/48/60/68: 10-16), passive 8-16 (weeks 1-4: 0-16), patterns 3-5
  (weeks 1-4: 1-2, synthesis weeks 0-3), exactly 1 dialogue (weeks 1-7: 2-4 lines, 8+: 6-10), speak_prompts = 3 in weeks
  divisible by 4, else 0, Tatoeba share <= 25 % per week and overall.

Manuscript formats (what the tools read; K0 / A1-A4 must write exactly this)
----------------------------------------------------------------------------
weeks\w0NN.json   {"v":1,"w":N,"title_ko":..,"can_do":[..],"scene":{..},
   "words":[{id w0001, en, pos, ko (<=12 chars, one meaning), ko2?, ipa, say, tags[], role active|passive, d 1..4,
             forms[{f,pat}], alt[], syn[ids], ca bool, src "own"}],
   "patterns":[{id p_xxx, tpl "I like ___.", slots[], title_ko, grammar_ko[2..4 lines, each <= 90 chars], d 1..4, examples[]?}],
   "sentences":[{id s0001, en, ko, say, words[ids]?, pat, d 1..7, scope all|listen, accept[], src own|tatoeba, tid}],
   "dialogues":[{id d0001, title_ko, scene, user "B", d?, lines[{s A|B, en, ko, say, d?, hint_ko?, accept?}]}],
   "speak_prompts":[{id sp0401, kind read|answer|intro|question, en, ko, say?, expect_any[]}],
   "notes":[{id n0001, kind spelling|vocab|culture|fact|sound, text_ko, ca+us (spelling), fact_date (fact)}]}
  Keys starting with "_" are free notes. `o` may be given but must equal w*10+d.
skeleton.json     the layout of design 10.2 as K0 wrote it (older object layout is still accepted):
   top level: v, lang, meta, id_ranges, stages, situations, canada_notes[{id,w,..}], sound_items, patterns, words, weeks
   words      = the assignment table [{id, lemma, pos, role, w, d}] (weeks 1-16; also accepted under the name `assign`)
   patterns   = [{id p_xxx, w, d 1..4, tpl, title_ko, grammar_ko[2..4 lines], needs[lemmas]}]  (bodies of the week lists)
   weeks[]    = {w,n,k,stage,legacy_stage,release,title_ko,can_do[],scene{id,title_ko,canada[ids of canada_notes]},situations,
                 themes,review,counts{active,passive,patterns},patterns[ids],days[{d,kind,active,words[],patterns[]}],
                 ladder{},check{items,pass,month},minutes{},words{new[],passive[]},dialogue}
   id_ranges  = {"words":{"assigned":[lo,hi],"A1":[lo,hi]..},"sentences":{"A1":[..]},"dialogues":{..},"authors":{"A1":[1,4]..}}
   Checked: 72 weeks, n/k/stage/legacy_stage, counts against the table and against words.new/passive and days[].words,
   unknown or unlisted pattern ids, duplicate lemma/id, needs <= pattern day, canada note ids, id ranges (no overlap,
   inside w0001-w0699 / s0001-s0999 / d0001-d0999), totals (active 1714-1894, passive 892-1012; weeks 1-16 370-410 / 110-130).
   Weeks with review:true skip the per-day word split.
policy.json       K0 layout: blocked {category:[words]} (or a list), blocked_prefix [..], context_allowed [{word, from_w}]
   (blocked before that week), allow {word:[weeks]}, allowed_names {given:[{name,from_w}], surnames:{from_w,names[]},
   places/streets/orgs/..}, personal.email_domains, stage0.max_words_per_sentence {"1":4,..}, limits {..} (overrides counts),
   canon_pairs [{ca,us}], acronym_ok [..], allowed_postal_codes [..], tatoeba_db (fixtures only).
   A proper noun (pos propn) in a week file must be listed in allowed_names (or names/places/allowed_propn) and not be used
   before its from_w, unless it is tagged place/calendar/country/language/org/brand/holiday.  With --lexicon-from skeleton
   the table has no proper nouns: week files may add them (pos propn, id inside the author's word range).
   Phone numbers 555-01xx, e-mail @example.com/.ca (or personal.email_domains); URLs, street addresses (not listed in
   allowed_names), postal codes are flagged.  Built-in Canadian spelling pairs: colour/color favourite/favorite
   centre/center neighbour flavour honour labour behaviour theatre metre grey/gray (US form in text or as headword ->
   CANON; a Canadian headword needs the US form in `alt`).

LanguageTool (--grammar): backend\grammar.py is loaded from the file (default <repo>ackend\grammar.py) and pointed at
   --lt-dir, else COURSE_LT_DIR, else <repo>ackend	ools\languagetool, else the main checkout's copy next to the worktree
   (..ppackend	ools\languagetool). Language en-CA (so colour is not flagged). The Java server is started by that
   module on a free port of its own and stopped by PID (grammar.stop); the note line shows pid and port.
