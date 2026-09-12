# ccswitch

Bind a Claude Code or Codex account to a directory. Client repo uses the client's account, work repo
uses work's, personal uses mine. No logging out, no switching, and two accounts can be live in two
terminals at the same time.

## Install

```bash
git clone <this repo> ~/Projects/Personal/ccswitch
export PATH="$HOME/Projects/Personal/ccswitch/bin:$PATH"   # in ~/.zshrc
eval "$(ccswitch shell-init)"                              # in ~/.zshrc, after the PATH line
```

## Use

```bash
ccswitch add client-acme        # create a profile (shares your config, starts signed out)
ccswitch login client-acme      # opens claude, run /login, exit
cd ~/work/acme && ccswitch use client-acme

claude                          # now runs as the acme account, here and in every subdirectory
```

Directories with no `.ccswitch` marker use your default account exactly as before. Nothing changes
until you opt a directory in.

| Command | |
|---|---|
| `ccswitch add <name>` | create a profile |
| `ccswitch login <name> [claude\|codex]` | sign a profile in |
| `ccswitch use <name>` / `unuse` | bind / unbind the current directory |
| `ccswitch list` | profiles, their accounts, which is active here |
| `ccswitch which` | the profile governing the current directory |
| `ccswitch run <name> <cmd>...` | run anything inside a profile |
| `ccswitch doctor [--fix]` | check that profiles still share config, and flag risky MCP entries |
| `ccswitch sync-mcp <name>` | copy your MCP servers into a profile |

## How it works

Claude Code reads `CLAUDE_CONFIG_DIR` and Codex reads `CODEX_HOME`. Point them at different
directories and you get fully separate credentials, with no shared slot to fight over. `ccswitch`
walks up from `$PWD` for a `.ccswitch` file naming a profile, then launches the real binary with
those variables set.

Only auth is separated. `CLAUDE.md`, `settings.json`, `settings.local.json`, `plugins`, `skills`,
`agents`, `commands` and `hooks` are symlinked back to `~/.claude`, so every profile has your full
setup and you maintain it once. On the Codex side it is `config.toml`, `plugins` and `skills`.

Sessions are shared too, which is what lets `ListAgents` and `SendMessage` reach a session running
under a different profile. Claude Code discovers peers by reading `sessions/` inside the config dir,
so an unshared one makes two accounts invisible to each other even though the socket they would talk
over is already global. Sharing it opens no new read channel - profiles isolate accounts, not the
filesystem - but it does let message *content* cross between accounts, so keep messages task-shaped.
A session's default name is derived from its directory, which would publish a client repo's name to
every other profile at startup - before `/title` could rename it. So a bound directory gets a
neutral alias instead, `<profile>-<number>`, stable for that profile and directory and carrying
nothing about either. Set `CLAUDE_CODE_SESSION_NAME` yourself to override it, or `/title` to rename
a running session. The record's `cwd` field is untouched: this fixes the address book, not the
record, and that path was already readable from any profile.

Sharing cuts both ways on one file. `settings.local.json` is what Claude Code writes when you pick
"don't ask again", so a permission you approve under the client account is approved under your
personal one too, and the reverse. That is the intended trade - unshared, every profile re-prompts
for everything you have already allowed. If you want approvals isolated per client, drop
`settings.local.json` from `CLAUDE_SHARED` in `bin/ccswitch`.

One thing cannot be symlinked: **user-scoped MCP servers**. They live in `.claude.json`, the same
file that holds the account, so sharing it would share the credentials and defeat the whole design.
`ccswitch add` copies them into a new profile instead, and `ccswitch sync-mcp <name>` refreshes an
existing one. It writes an allowlist of fields - `type`, `command`, `args`, `url` - and nothing
else. A server carrying anything beyond those, or a url or argv shaped like it holds a credential,
is refused and named so you can add it by hand. Unrecognised means refused, never copied: a wrong
refusal costs one `claude mcp add`, a wrong copy puts a client's token in a personal profile.
Restart a session to pick up new servers.

## What this does not do

**Switch a running session.** The variables are read at process launch, so a live session keeps the
account it started with. Restart it.

**Touch your credential store.** Nothing reads, writes or copies `.credentials.json`, and the
keychain is never modified. That is the difference from every alternative below.

The one exception worth knowing: `sync-mcp` copies MCP server *definitions* between profiles, and a
server definition can contain a secret - a database URI with a password in it, an API key in an
argument. It copies an allowlist of fields and refuses any entry carrying a uri with credentials, a
known token prefix, or a long high-entropy string, naming what it refused. Treat that as a strong
filter, not a proof: if a server's definition holds something sensitive, add it by hand.

## Why not the existing tools

[CCSwitcher](https://github.com/XueshiQiao/CCSwitcher),
[claude-account-switcher](https://github.com/Symbioose/claude-account-switcher) and
[cc-account-switcher](https://github.com/ming86/cc-account-switcher) all overwrite the single
`Claude Code-credentials` keychain entry and the `oauthAccount` block in `~/.claude.json`.

That makes per-project impossible by construction. There is one slot, so there is one active
account for the whole machine, and two terminals cannot hold two accounts. They also mutate
credential storage, which is a bad place to have a bug. `cc-account-switcher` was archived in
February 2026.

They solve "which account am I on". This solves "which account does this project use".
