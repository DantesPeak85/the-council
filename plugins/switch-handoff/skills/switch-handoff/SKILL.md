---
name: switch-handoff
description: Write a handoff before switching Claude accounts, and load it after the switch, so the new session picks up exactly where the old one stopped. Use whenever Tom says he is switching accounts, moving to his other Claude account, hitting the usage limit, closing this session for a fresh one, or asks to "write a handoff", "hand off", "prepare for the switch", "load the handoff", "pick up from the handoff", "continue from the last session", or "I just switched". Two modes, write (outgoing session) and load (incoming session). If the mode isn't stated, infer it: a session with work in its context is outgoing, and a fresh session with nothing done yet is incoming.
---

# Switch handoff

Tom works across two Claude accounts on the same machine. When he switches, the new session starts
with no conversation context. Anything only the old session knew (the live state, half-done work,
what's waiting on him, the gotchas it learned the hard way) is lost unless it's written down. The
handoff file carries that across.

Things that do **not** reliably carry across an account switch, so the handoff has to cover them:
- conversation context, running background tasks, subagents, Monitors and `/loop`s (they die with the session);
- **claude.ai artifacts, cloud routines/scheduled agents, connectors** (they belong to an account; the
  other account may not open them). Copy anything essential from an artifact into the handoff;
- memory, if the two accounts use different config dirs. Write the handoff so it stands alone.

Files on disk, git, `gh` and the shell are machine-level and do carry across.

Modes: **write** (outgoing) and **load** (incoming). `/switch-handoff write` or `/switch-handoff load`.

---

## Where handoffs live

`<main checkout>/docs/superpowers/handoffs/YYYY-MM-DD-<topic>-handoff.md`

Always write into the **main checkout**, never into a worktree, even when this session works inside one.
A previous handoff was written only inside `.claude/worktrees/*`, and the main checkout never saw it.
Find the main checkout with:

```bash
git rev-parse --path-format=absolute --git-common-dir   # parent of this path = main checkout
```

If the project isn't a git repo, use `<cwd>/docs/superpowers/handoffs/`. `<topic>` is a short slug for
the workstream (e.g. `lba-master`). If a handoff for the same topic already exists today, add a
suffix (`-b`) and mark it as superseding the earlier one.

---

## Write mode (before the switch)

1. **Find the previous handoff** for this topic (same search as load step 1). The new one is a delta
   on it: keep what's still true, update what changed, and say `supersedes <file>` in the title line.
   Carry unchanged sections forward in full. Don't write "see previous". The incoming session should
   need one file.

2. **Gather evidence; don't write from memory.** Run the commands that settle each state claim and
   write down what they return. Typical: `git status`, `git log --oneline -15`, `git worktree list`,
   branch heads, `gh pr list` and the state of the relevant PRs, ledger/progress files, live-version
   checks the project already uses (read-only ones only). Stamp the state table with when it was
   verified. A claim you couldn't verify goes in as **UNVERIFIED**, so the next session knows to check it.

3. **Inventory what will die with this session**: background tasks, subagents still running, Monitors,
   scheduled wakeups, plus account-bound items (artifact URLs, routines, connector sessions). For each,
   say what it was doing and how to restart or replace it.

4. **Write the file** with the template below. Leave out sections that would be empty, but keep
   §4 (waiting on Tom) and §8 (first actions) even if short. Be concrete: exact SHAs, branch names,
   paths, commands, URLs. Write "the suite is green at 220 files / 3128 tests on abc123", not
   "tests pass". The reader has nothing else to go on.

5. **Sanity-read it as the incoming session would**: could a fresh Claude with only this file and the
   repo take the next action without asking Tom anything he already answered? Fill any gap.

6. **Report to Tom** in a few lines: the file path, the 3–5 headline items, what's waiting on him, and
   the line to type in the new session:
   `/switch-handoff load` (or just "load the handoff").

Don't commit the handoff unless the project already commits them or Tom asks. It's on disk, and
that's enough for the switch.

### Template

```markdown
# <Topic> handoff: YYYY-MM-DD (outgoing: "<session title>"; supersedes <previous file or "none">)

Read this first. Then read: <memory files, specs, ledgers the next session needs, with paths>.
<Standing communication rules, e.g. language, who decides what.>

## 0. Your role
<What this session is (master / worker / solo), what it owns, what it may and may not do without Tom.>
House rules that held this session:
- <rule, with the reason when it's non-obvious (e.g. "PC crashed from memory exhaustion 2026-10-08")>

## 1. Current state (verified <date time + TZ>)
| Thing | Live / current | Source (branch @ SHA, PR) | Rollback |
|---|---|---|---|
<then bullets: config flags, worktrees and which one is safe to use, things NOT to touch>

## 2. What changed since the last handoff (newest first)
1. **<change>** (<SHA / PR>): what, why, Tom's call if it was his, verification status.

## 3. In flight right now
- **<task>**: where it stopped, exact branch @ SHA / file, what's done, what's left, the next command.
  Interrupted processes: what was running and how to restart it.

## 4. Waiting on Tom (bring these as one list)
1. <decision or QA ask>, with your recommendation and what happens on yes / no.

## 5. Open work (not started or partial)
- <item>: enough context to start it cold.

## 6. Other sessions and workers
- **<name>**: what they own, where their ledger is, their state, anything they must do.

## 7. Account-bound and session-bound items
- <artifact URL / routine / connector / background task>: what it is, whether the other account can
  reach it, and the essential content copied here if not.

## 8. Gotchas learned
- <trap>: symptom → what to do.

## 9. First actions for the incoming session
1. Re-verify §1 (commands: ...).
2. <the next concrete step>.
```

---

## Load mode (after the switch)

1. **Find the newest handoff.** Search the main checkout **and every worktree**, because older
   handoffs may sit only in a worktree:

   ```bash
   main="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
   { ls "$main"/docs/superpowers/handoffs/*handoff*.md
     git -C "$main" worktree list --porcelain | sed -n 's/^worktree //p' | while read -r w; do
       ls "$w"/docs/superpowers/handoffs/*handoff*.md; done; } 2>/dev/null \
     | awk -F/ '{print $NF "\t" $0}' | sort -r | head -10
   ```

   Pick the newest date. Among same-date files, prefer the one that says it supersedes the other.
   If the topic is ambiguous (several workstreams handed off the same day), show Tom the candidates
   and ask which one. If the newest copy is only in a worktree, say so. The same filename often
   appears in several worktrees. If `md5sum` shows the copies differ, use the newest-modified one and
   tell Tom which you picked.

2. **Read the whole file**, then the files its "Read this first" line names.

3. **Re-verify §1 before trusting it.** The handoff is a claim written by another session. Re-run the
   cheap, read-only checks (commits and branches exist at the stated SHAs, PR states, worktree list,
   whatever live-version check §9 names) and diff reality against the file. Don't deploy, write to
   production, or restart paid jobs as part of verification. Those wait for Tom.

4. **Check what the account switch broke**: for each item in §7, test whether this account can reach
   it (open the artifact, list routines and scheduled tasks). Anything unreachable goes on the list for Tom.

5. **Brief Tom on one screen**:
   - which handoff you loaded (path, date, outgoing session);
   - your role, in one line;
   - state: verified ✓ / discrepancies ✗ (what the file said vs what's true);
   - what didn't survive the switch;
   - **waiting on Tom**: §4, as one numbered list;
   - your proposed first action. Then wait for his go (plan → review → act).

Don't start in-flight work before that go, even if §9 sounds unambiguous. Tom may have changed his
mind between sessions.
