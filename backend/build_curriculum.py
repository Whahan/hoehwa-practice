import json, re, sys

def sections(lines, level):
    """Split lines into (title, body_lines) by heading of given level."""
    prefix = "#" * level + " "
    out, cur, body = [], None, []
    for ln in lines:
        if ln.startswith(prefix):
            if cur is not None:
                out.append((cur, body))
            cur, body = ln[len(prefix):].strip(), []
        elif cur is not None:
            body.append(ln)
    if cur is not None:
        out.append((cur, body))
    return out

def tables(body):
    """Return list of tables: each {header:[...], rows:[[...]]}."""
    res, cur = [], None
    for ln in body:
        s = ln.strip()
        if s.startswith("|"):
            cells = [c.strip() for c in s.strip("|").split("|")]
            if cur is None:
                cur = {"header": cells, "rows": []}
            elif all(re.fullmatch(r":?-{2,}:?", c) for c in cells):
                continue
            else:
                cur["rows"].append(cells)
        else:
            if cur is not None:
                res.append(cur)
                cur = None
    if cur is not None:
        res.append(cur)
    return res

def blocks(body):
    """Body into simple blocks: para, list, table, code, h4(bold-only line)."""
    out, i = [], 0
    while i < len(body):
        s = body[i].rstrip()
        if not s.strip():
            i += 1; continue
        if s.startswith("```"):
            j = i + 1; code = []
            while j < len(body) and not body[j].startswith("```"):
                code.append(body[j].rstrip("\n")); j += 1
            out.append({"t": "code", "v": "\n".join(code).strip("\n")}); i = j + 1; continue
        if s.lstrip().startswith("|"):
            j = i; tb = []
            while j < len(body) and body[j].strip().startswith("|"):
                tb.append(body[j]); j += 1
            out.append({"t": "table", **tables(tb)[0]}); i = j; continue
        if re.match(r"^\s*(- |\d+\. )", s):
            j = i; items = []
            ordered = bool(re.match(r"^\s*\d+\. ", s))
            while j < len(body) and re.match(r"^\s*(- |\d+\. )", body[j]):
                items.append(re.sub(r"^\s*(- |\d+\. )", "", body[j]).strip()); j += 1
            out.append({"t": "ol" if ordered else "ul", "v": items}); i = j; continue
        if s.startswith("### ") or s.startswith("#### "):
            out.append({"t": "h", "v": s.lstrip("#").strip()}); i += 1; continue
        out.append({"t": "p", "v": s.strip()}); i += 1
    return out

def parse_month(title, body):
    m = re.match(r"(\d+)개월차 \((\d{4}-\d{2})\) — (.+)", title)
    month = {"n": int(m.group(1)), "ym": m.group(2), "title": m.group(3).strip(),
             "goal": "", "content": [], "weeks": [], "missions": [], "checks": [], "extra": []}
    mode = None
    for ln in body:
        s = ln.strip()
        if not s:
            continue
        g = re.match(r"\*\*이달 목표\*\*\s*[:：]\s*(.+)", s)
        if g:
            month["goal"] = g.group(1); mode = None; continue
        if s.startswith("**핵심 학습 내용**"):
            mode = "content"; continue
        if s.startswith("**주차별 포커스**"):
            mode = "weeks"; continue
        if s.startswith("**이달 말하기 미션**"):
            mode = "missions"; continue
        if s.startswith("**월말 체크리스트**"):
            mode = "checks"; continue
        if s.startswith("|"):
            cells = [c.strip() for c in s.strip("|").split("|")]
            if re.match(r"\d+주차", cells[0]) and len(cells) >= 3:
                month["weeks"].append({"w": cells[0], "topic": cells[1], "act": cells[2]})
            continue
        if s.startswith("- [ ]"):
            month["checks"].append(s[5:].strip()); continue
        if mode == "missions" and re.match(r"\d+\. ", s):
            month["missions"].append(re.sub(r"^\d+\. ", "", s)); continue
        if mode == "content" and s.startswith("- "):
            item = s[2:]
            k = re.match(r"([^:：]{1,14})[:：]\s*(.+)", item)
            if k:
                month["content"].append({"k": k.group(1).strip(), "v": k.group(2).strip()})
            else:
                month["content"].append({"k": "", "v": item})
            continue
        month["extra"].append(s.lstrip("- ").strip())
    return month

def parse(path, lang):
    lines = open(path, encoding="utf-8").read().splitlines()
    top = dict(sections(lines, 2))
    data = {"lang": lang}
    # months
    data["months"] = [parse_month(t, b) for t, b in sections(top["월별 상세"], 3)
                      if re.match(r"\d+개월차", t)]
    # roadmap
    data["roadmap"] = tables(top["전체 로드맵"])[0]
    # other sections as blocks with subsections
    def sec(name):
        body = top[name]
        subs = sections(body, 3)
        intro = []
        for ln in body:
            if ln.startswith("### "):
                break
            intro.append(ln)
        return {"intro": blocks(intro), "subs": [{"title": t, "blocks": blocks(b)} for t, b in subs]}
    data["goal"] = sec("전제와 목표")
    data["routine"] = sec("하루·주간 루틴")
    data["resources"] = sec("추천 자료")
    data["speaking"] = sec("말하기 실력을 올리는 핵심 방법")
    data["eval"] = sec("분기 평가")
    data["stuck"] = sec("자주 막히는 지점과 대처")
    data["roadmapExtra"] = sec("전체 로드맵")
    return data

if __name__ == "__main__":
    root = sys.argv[1]
    out = {"en": parse(root + "/영어/커리큘럼.md", "en"),
           "ja": parse(root + "/일본어/커리큘럼.md", "ja")}
    for k, v in out.items():
        ms = v["months"]
        print(k, len(ms), [ (m["n"], len(m["content"]), len(m["weeks"]), len(m["missions"]), len(m["checks"]), len(m["extra"])) for m in ms], file=sys.stderr)
    json.dump(out, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
