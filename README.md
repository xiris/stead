# stead

One account per directory. A client repo runs on the client's Claude account, a personal repo runs
on your own, and you never log out of either. Two terminals can hold two accounts at once.

Claude Code reads `CLAUDE_CONFIG_DIR` and Codex reads `CODEX_HOME`. Point those at different
directories and you get separate credentials with no shared slot to fight over. `stead` walks up
from your working directory looking for a `.stead` file naming a profile, then launches the real
binary with those variables set. A directory without that file behaves exactly as it did before.

## Install

```bash
git clone https://github.com/xiris/stead ~/Projects/stead
export PATH="$HOME/Projects/stead/bin:$PATH"   # in ~/.zshrc
eval "$(stead shell-init)"                     # in ~/.zshrc, after the PATH line
```

## Use

```bash
stead add client-acme        # create a profile. It shares your config and starts signed out
stead login client-acme      # opens claude, run /login, exit
cd ~/work/acme && stead use client-acme

claude                       # runs as the acme account, here and in every subdirectory
```

That's the whole setup, and it's once per account plus once per project. After it, you type
`claude` and `codex` the way you always did. After that you only need `stead` for a new profile or
when something looks wrong.

| Command | |
|---|---|
| `stead add <name>` | create a profile |
| `stead login <name> [claude\|codex]` | sign a profile in |
| `stead use <name>` / `unuse` | bind or unbind the current directory |
| `stead list` | profiles, their accounts, which one is active here |
| `stead which` | the profile governing the current directory |
| `stead run <name> <cmd>...` | run anything inside a profile |
| `stead sync-mcp <name>` | copy your MCP servers into a profile |
| `stead doctor [--fix]` | check that profiles still share config |
| `stead version` | versions and paths, for a bug report |

## What a profile shares

Only auth is separate. `CLAUDE.md`, `settings.json`, `settings.local.json`, `plugins`, `skills`,
`agents`, `commands`, `hooks` and `sessions` are symlinked back to `~/.claude`, so every profile has
your full setup and you maintain it once. On the Codex side it's `config.toml`, `plugins` and
`skills`.

Two of them share more than you might want.

`settings.local.json` is the file Claude Code writes when you pick "don't ask again". Shared, a
permission you approve under the client account is approved under your personal one, and the other
way around. That's the trade for not re-approving everything in every profile. If you'd rather keep
approvals apart, drop it from `CLAUDE_SHARED` in `bin/stead`.

`sessions` is the peer registry, which is how `/agents` and cross-session messaging find other
sessions. Sharing it lets a session in one profile talk to a session in another. It opens no new
read channel, since profiles separate accounts and not the filesystem, but message content does
cross between accounts, so keep those messages task shaped. I don't know yet what a long-lived pair
of sessions does to that.

MCP servers can't be symlinked at all. They live in `.claude.json`, the same file that holds the
account, so sharing it would share the credentials. `stead add` copies them into a new profile
instead and `stead sync-mcp` refreshes an existing one. That copy writes an allowlist of fields,
`type`, `command`, `args` and `url`, and nothing else. Any server carrying something beyond those,
or a url or argv shaped like it holds a credential, is refused by name so you can add it by hand.
The filter errs toward refusing, because a false refusal costs you one manual paste and a false copy
moves a secret between accounts.

## Session names

A session registers itself in the shared registry when it starts, and Claude Code names it after the
directory. In a client repo that publishes the repo's name to your other accounts before `/title`
can rename it. So a bound directory gets a neutral alias instead, `<profile>-<number>`, stable for
that profile and directory. Set `CLAUDE_CODE_SESSION_NAME` yourself to override it.

The record's `cwd` field still holds the real path. Any profile could already read any other
profile's directory, so hiding it in the registry would be theatre.

## What this doesn't do

**Survive moving `~/.stead` on its own.** Claude Code keys a profile's keychain entry on a hash of
its config directory. Move the state directory and every profile gets a new entry while the old one
stays behind, where it shadows the new one: logins are written and never read back, so every session
asks you to sign in again. `stead doctor` detects the move, names the stale keychain entry and gives
you the command to remove it. It won't remove it itself, because nothing here touches the credential
store.

**Switch a running session.** The variables are read when the process launches, so a live session
keeps the account it started with. Restart it.

**Touch your credential store.** Nothing reads or writes `.credentials.json`, and the keychain is
never modified.

**Claim to be tested anywhere but macOS.** Nothing here touches the keychain, and the suite passes
on Linux in CI, so it should work there. I run it on macOS only, so Linux is tested rather than
used.

**Work outside an interactive shell.** The wrapper is a shell function from your `~/.zshrc`. A
`claude` launched by an IDE extension or a cron job may not get it, and would run on your default
account. Check with `whence -w claude`, which should say `function`.

## Prior art

Three tools already existed.

[CCSwitcher](https://github.com/XueshiQiao/CCSwitcher) (Swift) writes the target account's token to
the `Claude Code-credentials` keychain entry and overwrites the `oauthAccount` block in
`~/.claude.json`. [claude-account-switcher](https://github.com/Symbioose/claude-account-switcher)
(Python, MIT) backs each account up under `claude-switcher:{email}` and restores the selected one
into that same active slot. [cc-account-switcher](https://github.com/ming86/cc-account-switcher)
(bash, MIT) keeps credentials in the keychain and OAuth state in `~/.claude-switch-backup/`. Its
owner archived it in February 2026.

They're different implementations of one shape: a single active slot that gets overwritten. That's
what sent me looking for another approach, because one slot means one account for the whole machine
and two terminals can't hold two. They also write to credential storage, which is a bad place to
have a bug.

None of the three mentions `CLAUDE_CONFIG_DIR`, and none binds an account to a directory. They did
show me the command surface people expect, and I kept it. `stead` answers a different question with
it: which account this project uses. None of their code is here.

## Contributing

The test suite is plain bash and runs in a temp directory:

```bash
git config core.hooksPath hooks   # once per clone
./hooks/pre-commit                # syntax, shellcheck, and the suite under bash 3.2
```

That's the same gate CI runs. If you'd rather run the pieces:

```bash
bash -n bin/stead && bash -n test.sh
shellcheck bin/stead test.sh hooks/*
./test.sh            # must print "0 failed"
/bin/bash ./test.sh  # macOS ships bash 3.2, so it has to pass there too
```

Profile names and `.stead` contents both become filesystem paths, so `valid_name` is a trust
boundary and so is the marker. If you add a code path that reaches the filesystem, route it through
those.

## License

MIT.
