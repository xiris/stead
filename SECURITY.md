# Security

## Reporting

Open a private security advisory through GitHub's "Report a vulnerability" button on this
repository. I'd rather hear about something that turns out to be fine than not hear about it.

## What this tool claims

`stead` keeps two accounts apart by pointing `CLAUDE_CONFIG_DIR` and `CODEX_HOME` at different
directories. It never reads, writes or copies `.credentials.json`, and it never touches the keychain.
If you find a path where it does, that's the report I most want.

The one place it copies configuration a user wrote is `sync-mcp`, which moves MCP server definitions
between profiles. A server definition can hold a secret, so that copy writes an allowlist of fields
and refuses anything carrying a uri with credentials, a known token prefix, or a long high-entropy
string. It's a strong filter rather than a proof, and a way past it is worth reporting.

## What it doesn't claim

**Profiles separate accounts, not the filesystem.** Any session can read any other profile's
directory. If you need processes that can't read each other's files, this is the wrong tool and you
want separate OS users or a container.

**A `.stead` marker in a cloned repository is attacker-controlled input.** Its contents are validated
the same way profile names are, and an unusable marker refuses rather than falling back to your
default account. The marker also names a profile, so it can leak a client's name if you commit it.
Gitignore it in shared repositories.

**Sharing `sessions` lets profiles message each other.** Message content crosses between accounts,
which is the point, and it's worth knowing before you send a client's code to a session running on a
personal account.
