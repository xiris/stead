# Handoff - 2026-09-12

## Git state

`master` at `2a11c0e`, clean, 6 commits ahead of where the session started (`7b855c1`).
**No git remote exists** - the repo is local only, nothing is pushed anywhere.
Working branch `fix/list-fail-closed` was ff-merged and deleted.

## Green

```
bash -n bin/stead && bash -n test.sh     syntax ok
./test.sh                                   85 passed, 0 failed
/bin/bash ./test.sh                         85 passed, 0 failed  (bash 3.2.57)
```

Every commit red-proofed against its predecessor with `red_proof.py --test ./test.sh --test-path test.sh`.
The `--test-path` flag is required here; without it the script reports "no test file in HEAD^..HEAD".

## What landed

Five defects, all of the same shape: a rule enforced in one code path and missed in a sibling.

1. `44c02de` `list` reported a fail-closed directory as "unbound, uses your default account". Also
   `doctor` never checked the codex side, and `CODEX_SHARED` was missing `plugins` and `skills`.
2. `0daf563` `doctor --fix` deleted profile data whose source did not exist in the real home,
   right after `doctor` called the profile healthy. Fixed by filtering in `each_shared`.
3. `79b524b` A tab in a home path corrupted the tab-separated encoding; after (2) removed the
   guard that accidentally contained it, `rm -rf` could fire against the user's cwd. Also a stray
   file in `profiles/` was treated as a profile and aborted `--fix` mid-run.
4. `e874573` The guard from (3) used `die`, which exits 1, and the shell wrapper reads 1 as
   "unbound, run the real binary" - so it launched a bound client repo on the default account.
   Now exits 2. `shell-init` is exempt from the guard, or the wrapper functions never get defined.
5. `19feaeb` / `2a11c0e` `hooks` and `settings.local.json` joined `CLAUDE_SHARED`; README documents
   that permission approvals cross profiles, and that MCP servers cannot be shared.

## Verified live, not just in tests

- `CLAUDE_CONFIG_DIR` does relocate `.claude.json` into the profile.
- A `claude` run inside a profile leaves `~/.claude.json` byte-identical (mtime and size).
- Profile `personal` is signed in as chris@planner.net.br and answers prompts.
- `~/Projects/Personal/docX` is bound to `personal`; the marker is gitignored there.
- `~/.zshrc` has the PATH line and `eval "$(stead shell-init)"`. Backup at `~/.zshrc.bak.stead`.

## Still open

- **`stead login personal codex`** was never run. The CODEX column in `list` reads `-`.
- **`docX` has an uncommitted ` M .gitignore`** - the one line that ignores `.stead`.
- **`stead sync-mcp <profile>`** is the obvious next feature. MCP servers ride in `.claude.json`
  with the account so they cannot be symlinked, but the `mcpServers` block itself holds no
  credentials, so copying just that key is safe. Refuse entries with a non-empty `env` or
  `headers`. The two servers were copied into `personal` by hand this session.
- Only one account has ever been exercised. Two different accounts live in two terminals is the
  premise, and it is still unproven.

## Parked deliberately

Nothing. All five review findings that were deferred mid-session were closed before landing.

## Read first on resume

`CLAUDE.md` (the four architecture facts), then `bin/stead:37-64` (`resolve`, and why exit 1 and
exit 2 must stay distinct - three of the five defects above were that distinction collapsing).
