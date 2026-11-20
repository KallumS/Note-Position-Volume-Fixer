"""Turns a Claude Code session record (.jsonl) into a readable Markdown chat.
Keeps: the user's messages (and answers to questions), Claude's replies, and one line per tool step.
Leaves out: Claude's private reasoning, tool output, system messages, and anything matching an email address."""
import json, re, sys
from datetime import datetime

src, out = sys.argv[1], sys.argv[2]
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
SCRATCH = re.compile(r"/tmp/claude-0/[^\s`'\"]*")
SESSION = re.compile(r"/root/\.claude/[^\s`'\"]*")

def clean(s):
    s = EMAIL.sub("[email removed]", s)
    s = SCRATCH.sub("<scratch>", s)
    s = SESSION.sub("<session files>", s)
    return s.rstrip()

def when(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).strftime("%-d %b %Y, %H:%M UTC")
    except Exception:
        return ""

def step(name, inp):
    d = inp.get("description")
    if name == "Bash": return f"Ran a command: {d or inp.get('command','')[:80]}"
    if name == "Write": return f"Wrote `{inp.get('file_path','').replace('/home/user/Note-Position-Volume-Fixer/','')}`"
    if name == "Edit": return f"Edited `{inp.get('file_path','').replace('/home/user/Note-Position-Volume-Fixer/','')}`"
    if name == "Read": return f"Read `{inp.get('file_path','').replace('/home/user/Note-Position-Volume-Fixer/','')}`"
    if name == "WebSearch": return f"Searched the web: \"{inp.get('query','')}\""
    if name == "WebFetch": return f"Fetched {inp.get('url','')}"
    if name == "AskUserQuestion": return "Asked you a question (below)"
    if name == "TaskCreate": return f"Planned: {inp.get('subject','')}"
    if name == "TaskUpdate": return f"Task {inp.get('taskId','')} → {inp.get('status','')}"
    if name == "SendUserFile": return "Sent you files: " + ", ".join(inp.get("files", []))
    if name == "ToolSearch": return f"Loaded tools: {inp.get('query','')}"
    short = name.replace("mcp__github__", "GitHub: ").replace("mcp__claude-code-remote__", "Session: ")
    return short + (": " + d if d else "")

lines = ["# The chat that built Note Position & Volume Fixer", "",
         "13-20 November 2026, between you and Claude (Claude Code, in the cloud).",
         "Made from the session's own record when the chat was about to be cleared.", "",
         "Kept: every message from you, every reply from Claude, and one line for each step Claude took "
         "(tucked under *Steps*). Left out: Claude's private reasoning, what each step printed, system "
         "messages, and your email address. Paths in Claude's scratch folder are shown as `<scratch>`.", "",
         "What came of it is in the repository: the [README](../../README.md), the "
         "[decisions](../decisions/README.md) and the [session logs](../sessions/).", ""]

pending = []  # tool step lines waiting to be written
asked = {}    # tool_use id -> questions

def flush():
    global pending
    if pending:
        lines.append(f"<details><summary>Steps ({len(pending)})</summary>")
        lines.append("")
        for p in pending: lines.append("- " + clean(p))
        lines.append("")
        lines.append("</details>")
        lines.append("")
        pending = []

speaker = None
for raw in open(src, encoding="utf-8"):
    d = json.loads(raw)
    t = d.get("type")
    if t == "attachment":
        a = d.get("attachment") or {}
        if a.get("type") == "queued_command" and a.get("prompt"):
            flush()
            lines += [f"### You, while Claude was working ({when(d.get('timestamp',''))})", "", clean(a["prompt"]), ""]
            speaker = "you"
        continue
    if t not in ("user", "assistant"): continue
    m = d.get("message") or {}
    content = m.get("content")
    if t == "user":
        if isinstance(content, str):
            if content.startswith("<task-notification>"):
                flush()
                lines += ["*(A background check finished: a GitHub build was done.)*", ""]
                continue
            if d.get("isMeta") and content.startswith("[Image"):
                pending.append("Looked at a screenshot of the page")
                continue
            flush()
            lines += [f"## You ({when(d.get('timestamp',''))})", "", clean(content), ""]
            speaker = "you"
            continue
        for c in content or []:
            if c.get("type") == "text" and "interrupted" in c.get("text", "").lower():
                flush(); lines += ["*(You stopped Claude here and sent your message again with more detail.)*", ""]
            if c.get("type") == "tool_result" and c.get("tool_use_id") in asked:
                res = c.get("content")
                text = res if isinstance(res, str) else " ".join(x.get("text", "") for x in res or [] if isinstance(x, dict))
                ans = re.findall(r'"([^"]+)"="([^"]+)"', text)
                flush()
                lines += ["**Your answer:** " + (clean(ans[0][1]) if ans else clean(text)), ""]
        continue
    for c in content or []:
        ct = c.get("type")
        if ct == "text" and c.get("text", "").strip():
            flush()
            if speaker != "claude":
                lines += ["### Claude", ""]
                speaker = "claude"
            lines += [clean(c["text"]), ""]
        elif ct == "tool_use":
            name, inp = c.get("name", ""), c.get("input") or {}
            if name == "AskUserQuestion":
                flush()
                asked[c.get("id")] = True
                for q in inp.get("questions", []):
                    lines += ["**Claude asked:** " + clean(q.get("question", "")), ""]
                    for o in q.get("options", []):
                        lines.append(f"- *{clean(o.get('label',''))}*: {clean(o.get('description',''))}")
                    lines.append("")
            else:
                pending.append(step(name, inp))
flush()
text = "\n".join(lines) + "\n"
assert not EMAIL.search(text.replace("noreply@anthropic.com", "")), "an email address slipped through"
open(out, "w", encoding="utf-8").write(text)
print(out, len(text), "characters")
