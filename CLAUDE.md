# stead

Binds a Claude Code / Codex account to a directory, so a client repo uses the client account and a
personal repo uses mine, with no switching and no logging out.

> The maintainer's global working agreement lives in `~/.claude/CLAUDE.md`, outside this repo.
> You don't need it to contribute. This file holds what is specific to stead.
> This file holds only what's specific to THIS project. Where they conflict, this file wins.

## Stack

- **Runtime:** bash 3.2 (macOS system bash - no bash 4 syntax, no `declare -A`, no `${x^^}`)
- **Package manager:** none. One executable, `bin/stead`. Adding a dependency needs a reason.
- **Tests:** `./test.sh` - plain bash, runs in a temp dir, no framework
- **Lint:** `bash -n` always; `shellcheck` if installed (it currently is not)

The stack's `standards/biome.json` does **not** apply here. It's a shell project.

## Green

```bash
bash -n bin/stead && bash -n test.sh   # syntax
./test.sh                                 # 155 assertions, must print "0 failed"
shellcheck bin/stead test.sh hooks/*      # must be clean; CI runs it too
./hooks/pre-commit                        # all of the above in one gate
```

**Known environment failures:** none. `test.sh` touches nothing outside its `mktemp -d`.

## Architecture

Four facts carry the whole design. Violating any of them breaks the premise.

- **Isolation is native, not ours.** `CLAUDE_CONFIG_DIR` and `CODEX_HOME` give each profile its own
  credentials. We never read, write, or copy a credential store, and never touch the keychain. Every
  competing tool swaps one shared credential slot, which is why none can do per-project.
  The one place we copy config a user wrote is `sync-mcp`, and it is an allowlist that refuses
  anything credential-shaped - see `cmd_sync_mcp`. That refusal is a trust boundary, not a nicety.
- **The env var must be set before the process starts.** `.claude/settings.json`'s `env` block is
  read *after* credentials load, so it cannot select an account. Verified empirically, not assumed.
  This is why a shell wrapper exists at all, and why nothing here can be pure project config.
- **`cmd_run` is the only place the env contract lives.** `login`, and the `shell-init` wrappers all
  route through it. Add a new entry point by calling it, never by exporting the vars again.
- **Auth is isolated; everything else is symlinked back to `~/.claude`.** Config lives in one place
  and profiles see it. The failure mode is an atomic write (temp + rename) replacing a symlink with
  a real file, silently unsharing it - that is exactly what `stead doctor` looks for.
- **Profile names become filesystem paths.** `valid_name` is a trust boundary, and so is the
  content of a `.stead` marker, which is an attacker-writable file in a cloned repo. Both are
  validated. Do not add a code path that skips it.

## Hooks

`git config core.hooksPath hooks` once per clone. `hooks/pre-commit` runs syntax, shellcheck and the
suite under `/bin/bash`, and `pre-push` runs the same gate because a commit can reach a branch
without passing pre-commit. All three failure modes are proven to exit non-zero, not assumed.

`--no-verify` is allowed by the working agreement. Say which check you skipped and why.

## Docs that matter

- `README.md` - install, the commands, and why the alternatives were rejected

## Gotchas

- **Moving `$STEAD_HOME` orphans every login.** Claude Code keys the keychain entry on
  `sha256(config dir)[:8]`, so a profile at a new path has no credential even though its
  `.claude.json` still names the account. Cost an evening's confusion after renaming ccswitch to
  stead. `doctor` reports it now; `needs_login` is the check, and it reports one way only because
  an entry exists before a login succeeds, so presence proves nothing.

- **`cmd | grep -q` under `set -o pipefail` scores a false failure.** grep exits at the first match,
  the writer takes SIGPIPE, the pipeline returns 141. Cost an hour of chasing a bug in `doctor` that
  did not exist. Capture to a variable, then match with `[[ $var == *pat* ]]`.
- **Switching needs a restart.** Env is fixed at process launch, so a running session keeps the
  account it started with. Inherent to the mechanism, not a bug to fix.
- **`.stead` names a profile, so it can leak a client's name.** Gitignore it in shared repos.

## Deploy

None. `bin/stead` goes on `PATH`; `eval "$(stead shell-init)"` goes in `~/.zshrc`.
