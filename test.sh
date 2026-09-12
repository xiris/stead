#!/usr/bin/env bash
# Self-check for ccswitch. Runs entirely in a temp dir - never touches ~/.claude or ~/.codex.
set -uo pipefail

CC="$(cd "$(dirname "$0")" && pwd)/bin/ccswitch"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export CCSWITCH_HOME="$TMP/state"
export CCSWITCH_CLAUDE_HOME="$TMP/fake-claude"
export CCSWITCH_CODEX_HOME="$TMP/fake-codex"
export CCSWITCH_CLAUDE_JSON="$TMP/fake-claude.json"
mkdir -p "$CCSWITCH_CLAUDE_HOME/plugins" "$CCSWITCH_CODEX_HOME/skills" "$CCSWITCH_CODEX_HOME/plugins"
echo "GLOBAL AGREEMENT" >"$CCSWITCH_CLAUDE_HOME/CLAUDE.md"
echo '{"a":1}' >"$CCSWITCH_CLAUDE_HOME/settings.json"
echo "plugin" >"$CCSWITCH_CLAUDE_HOME/plugins/p.txt"
echo "trust=1" >"$CCSWITCH_CODEX_HOME/config.toml"
mkdir -p "$CCSWITCH_CLAUDE_HOME/hooks"
echo "#!/bin/sh" >"$CCSWITCH_CLAUDE_HOME/hooks/gate.sh"
echo '{"permissions":{"allow":["Bash(ls:*)"]}}' >"$CCSWITCH_CLAUDE_HOME/settings.local.json"
echo "codex skill" >"$CCSWITCH_CODEX_HOME/skills/s.txt"
cat >"$CCSWITCH_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"real@example.com"},
 "mcpServers":{"plain-http":{"type":"http","url":"https://example.test/mcp"},
               "plain-stdio":{"type":"stdio","command":"/bin/echo","args":[],"env":{}},
               "has-secret":{"type":"stdio","command":"/bin/echo","env":{"API_KEY":"sk-live-xxx"}},
               "has-headers":{"type":"http","url":"https://x.test","headers":{"Authorization":"Bearer t"}}}}
JSON

pass=0 fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check()   { if eval "$2"; then ok "$1"; else no "$1"; fi; }
rejects() { if "$CC" "$@" >/dev/null 2>&1; then no "rejects: $*"; else ok "rejects: $*"; fi; }

echo "== name validation (profile names become filesystem paths) =="
rejects add ../evil
rejects add ..
rejects add .
rejects add "a b"
rejects add 'x;rm -rf /'
rejects add ''
rejects use nonexistent-profile

echo "== add =="
"$CC" add work >/dev/null
check "profile dirs created"      '[ -d "$CCSWITCH_HOME/profiles/work/claude" ] && [ -d "$CCSWITCH_HOME/profiles/work/codex" ]'
check "CLAUDE.md shared"          '[ -L "$CCSWITCH_HOME/profiles/work/claude/CLAUDE.md" ]'
check "shared content readable"   '[ "$(cat "$CCSWITCH_HOME/profiles/work/claude/CLAUDE.md")" = "GLOBAL AGREEMENT" ]'
check "plugins dir shared"        '[ -L "$CCSWITCH_HOME/profiles/work/claude/plugins" ]'
check "hooks dir shared"          '[ -L "$CCSWITCH_HOME/profiles/work/claude/hooks" ]'
check "hook script readable"      '[ -f "$CCSWITCH_HOME/profiles/work/claude/hooks/gate.sh" ]'
check "local permissions shared"  '[ -L "$CCSWITCH_HOME/profiles/work/claude/settings.local.json" ]'
check "codex config shared"       '[ -L "$CCSWITCH_HOME/profiles/work/codex/config.toml" ]'
check "codex skills shared"       '[ -L "$CCSWITCH_HOME/profiles/work/codex/skills" ]'
check "codex plugins shared"      '[ -L "$CCSWITCH_HOME/profiles/work/codex/plugins" ]'
check "auth NOT shared"           '[ ! -e "$CCSWITCH_HOME/profiles/work/claude/.credentials.json" ]'
check "duplicate add refused"     '! "$CC" add work >/dev/null 2>&1'

echo "== bind / resolve =="
mkdir -p "$TMP/proj/deep/nested" "$TMP/elsewhere"
( cd "$TMP/proj" && "$CC" use work >/dev/null )
check "marker written"            '[ "$(cat "$TMP/proj/.ccswitch")" = "work" ]'
check "which in project"          '[ "$(cd "$TMP/proj" && "$CC" which)" = "work" ]'
check "which walks up from deep"  '[ "$(cd "$TMP/proj/deep/nested" && "$CC" which)" = "work" ]'
check "unbound dir exits nonzero" '! ( cd "$TMP/elsewhere" && "$CC" which --quiet >/dev/null 2>&1 )'

echo "== marker content is untrusted input, and a bad marker must FAIL CLOSED =="
# Exit 2 (refuse) vs exit 1 (unbound, use default) is the load-bearing distinction: collapsing them
# runs a client repo on the personal account silently.
rc_of() { ( cd "$1" && "$CC" which >/dev/null 2>&1 ); echo $?; }
for bad in "../../../etc" "" "-n" "--fix" "a b" "x;id" "/etc/passwd" ".." "client acme";
do
	printf '%s\n' "$bad" >"$TMP/proj/.ccswitch"
	check "bad marker '$bad' exits 2 (refuse)" '[ "$(rc_of "$TMP/proj")" = "2" ]'
done
printf 'no-such-profile\n' >"$TMP/proj/.ccswitch"
check "valid name, missing profile exits 2" '[ "$(rc_of "$TMP/proj")" = "2" ]'
rm -f "$TMP/proj/.ccswitch"
check "no marker at all exits 1"  '[ "$(rc_of "$TMP/proj")" = "1" ]'
printf '  work  \n' >"$TMP/proj/.ccswitch"
check "whitespace tolerated"      '[ "$(cd "$TMP/proj" && "$CC" which)" = "work" ]'
printf 'work\r\n' >"$TMP/proj/.ccswitch"
check "CRLF marker tolerated"     '[ "$(cd "$TMP/proj" && "$CC" which)" = "work" ]'
printf 'work\nignored-second-line\n' >"$TMP/proj/.ccswitch"
check "only first line is read"   '[ "$(cd "$TMP/proj" && "$CC" which)" = "work" ]'
printf 'work' >"$TMP/proj/.ccswitch"
check "no trailing newline is ok" '[ "$(cd "$TMP/proj" && "$CC" which)" = "work" ]'
printf 'work\n' >"$TMP/proj/.ccswitch"
check "bound dir exits 0"         '[ "$(rc_of "$TMP/proj")" = "0" ]'

echo "== run exports the isolation contract =="
got=$("$CC" run work sh -c 'echo "$CLAUDE_CONFIG_DIR|$CODEX_HOME|$CCSWITCH_PROFILE"')
check "CLAUDE_CONFIG_DIR set"     '[ "${got%%|*}" = "$CCSWITCH_HOME/profiles/work/claude" ]'
check "CODEX_HOME set"            '[ "$(echo "$got" | cut -d"|" -f2)" = "$CCSWITCH_HOME/profiles/work/codex" ]'
check "profile name exported"     '[ "$(echo "$got" | cut -d"|" -f3)" = "work" ]'
check "run refuses unknown"       '! "$CC" run ghost sh -c true >/dev/null 2>&1'

echo "== two profiles are actually independent =="
"$CC" add client >/dev/null
a=$("$CC" run work   sh -c 'echo $CLAUDE_CONFIG_DIR')
b=$("$CC" run client sh -c 'echo $CLAUDE_CONFIG_DIR')
check "distinct config dirs"      '[ "$a" != "$b" ]'

echo "== shell wrapper =="
cat >"$TMP/bin-claude" <<'EOF'
#!/bin/sh
echo "claude ran with CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-none}"
EOF
chmod +x "$TMP/bin-claude"
mkdir -p "$TMP/shim" "$TMP/shim-noswitch"
cp "$TMP/bin-claude" "$TMP/shim/claude"; cp "$TMP/bin-claude" "$TMP/shim/codex"
cp "$TMP/bin-claude" "$TMP/shim-noswitch/claude"
ln -sf "$CC" "$TMP/shim/ccswitch"
out_bound=$(cd "$TMP/proj"      && PATH="$TMP/shim:$PATH" bash -c 'eval "$(ccswitch shell-init)"; claude')
out_free=$(cd  "$TMP/elsewhere" && PATH="$TMP/shim:$PATH" bash -c 'eval "$(ccswitch shell-init)"; claude')
check "bound dir gets profile"    '[ "$out_bound" = "claude ran with CLAUDE_CONFIG_DIR=$CCSWITCH_HOME/profiles/work/claude" ]'
check "unbound dir passes through" '[ "$out_free" = "claude ran with CLAUDE_CONFIG_DIR=none" ]'

# The wrapper must refuse rather than silently fall back to the default account.
echo "../../etc" >"$TMP/proj/.ccswitch"
out_bad=$(cd "$TMP/proj" && PATH="$TMP/shim:$PATH" bash -c 'eval "$(ccswitch shell-init)"; claude' 2>/dev/null)
rc_bad=$(cd "$TMP/proj" && PATH="$TMP/shim:$PATH" bash -c 'eval "$(ccswitch shell-init)"; claude' >/dev/null 2>&1; echo $?)
check "wrapper refuses bad marker" '[ "$rc_bad" = "2" ]'
check "wrapper ran NOTHING on bad marker" '[ -z "$out_bad" ]'
err_bad=$(cd "$TMP/proj" && PATH="$TMP/shim:$PATH" bash -c 'eval "$(ccswitch shell-init)"; claude' 2>&1 >/dev/null)
check "wrapper explains why"      '[[ "$err_bad" == *"refusing to guess an account"* ]]'

# ...but a missing/broken ccswitch must never block the real binary.
out_noswitch=$(cd "$TMP/proj" && PATH="$TMP/shim-noswitch:$PATH" bash -c 'claude' 2>/dev/null)
check "no ccswitch on PATH still runs claude" '[ "$out_noswitch" = "claude ran with CLAUDE_CONFIG_DIR=none" ]'
printf 'work\n' >"$TMP/proj/.ccswitch"

echo "== doctor detects an atomic write that clobbered a symlink =="
# Capture before grepping: `cmd | grep -q` SIGPIPEs the writer, and pipefail scores that a failure.
doc=$("$CC" doctor)
check "clean profiles report ok"  '[[ "$doc" == *"share config correctly"* ]]'
rm "$CCSWITCH_HOME/profiles/work/claude/settings.json"
echo '{"clobbered":1}' >"$CCSWITCH_HOME/profiles/work/claude/settings.json"
doc=$("$CC" doctor)
check "doctor spots real file"    '[[ "$doc" == *"no longer shared"* ]]'
check "doctor names the profile"  '[[ "$doc" == *"work: claude/settings.json"* ]]'
"$CC" doctor --fix >/dev/null
check "doctor --fix re-links"     '[ -L "$CCSWITCH_HOME/profiles/work/claude/settings.json" ]'
check "shared content restored"   '[ "$(cat "$CCSWITCH_HOME/profiles/work/claude/settings.json")" = "{\"a\":1}" ]'
doc=$("$CC" doctor)
check "doctor clean after fix"    '[[ "$doc" == *"share config correctly"* ]]'

echo "== doctor covers the codex side too, not just claude ==" 
# The lists are consumed from one definition; a doctor that walked only CLAUDE_SHARED reported a
# clobbered codex/config.toml as healthy while --fix silently repaired it.
rm "$CCSWITCH_HOME/profiles/work/codex/config.toml"
echo 'clobbered=1' >"$CCSWITCH_HOME/profiles/work/codex/config.toml"
doc=$("$CC" doctor)
check "doctor spots codex file"   '[[ "$doc" == *"work: codex/config.toml"* ]]'
"$CC" doctor --fix >/dev/null
check "doctor --fix relinks codex" '[ -L "$CCSWITCH_HOME/profiles/work/codex/config.toml" ]'
check "codex content restored"    '[ "$(cat "$CCSWITCH_HOME/profiles/work/codex/config.toml")" = "trust=1" ]'

echo "== doctor --fix must not delete what it has no shared copy of ==" 
# The fake claude home has no 'agents' dir, so nothing was ever linked there. Real content at that
# path is the user's only copy. A --fix loop that walks entries with no source rm -rf's it and
# link_shared cannot restore it - silent, unrecoverable, right after doctor said "healthy".
mkdir -p "$CCSWITCH_HOME/profiles/work/claude/agents"
echo "my only copy" >"$CCSWITCH_HOME/profiles/work/claude/agents/mine.md"
check "unshared path reported healthy" '[[ "$("$CC" doctor)" == *"share config correctly"* ]]'
rm "$CCSWITCH_HOME/profiles/work/claude/settings.json"   # an UNRELATED break sends the user to --fix
echo '{"clobbered":2}' >"$CCSWITCH_HOME/profiles/work/claude/settings.json"
"$CC" doctor --fix >/dev/null
check "unrelated --fix spared the data" '[ "$(cat "$CCSWITCH_HOME/profiles/work/claude/agents/mine.md" 2>/dev/null)" = "my only copy" ]'
check "--fix still repaired the break"  '[ -L "$CCSWITCH_HOME/profiles/work/claude/settings.json" ]'
rm -rf "$CCSWITCH_HOME/profiles/work/claude/agents"

echo "== list must not call a fail-closed directory 'unbound' =="
# rc=2 (refuse) reported as "uses your default account" is the exact lie the tool exists to prevent.
printf 'work\n' >"$TMP/proj/.ccswitch"
out=$(cd "$TMP/proj" && "$CC" list 2>/dev/null)
check "bound dir marked active"   '[[ "$out" == *"<- active here"* ]]'
out=$(cd "$TMP/elsewhere" && "$CC" list 2>/dev/null)
check "unbound dir says unbound"  '[[ "$out" == *"unbound - claude and codex use your default account"* ]]'
printf '../../etc\n' >"$TMP/proj/.ccswitch"
out=$(cd "$TMP/proj" && "$CC" list 2>/dev/null)
check "bad marker NOT called unbound" '[[ "$out" != *"use your default account"* ]]'
check "bad marker says refuse"    '[[ "$out" == *"refuse to run here"* ]]'
printf 'work\n' >"$TMP/proj/.ccswitch"

echo "== use warns when the marker would be committed =="
# .ccswitch names a profile, which can be a client's name.
git -C "$TMP/proj" init -q 2>/dev/null
out=$(cd "$TMP/proj" && "$CC" use work)
check "warns when not ignored"    '[[ "$out" == *"not gitignored"* ]]'
echo ".ccswitch" >"$TMP/proj/.gitignore"
out=$(cd "$TMP/proj" && "$CC" use work)
check "silent when ignored"       '[[ "$out" != *"not gitignored"* ]]'

echo "== a tab or newline in a home path is refused at startup =="
# The tab-separated encoding would split one entry in two and hand the rm -rf loop a RELATIVE dst,
# which resolves against the user's cwd - a delete outside $PROFILES entirely. Fail closed instead.
tabhome="$TMP/cl$(printf '\t')aude"
mkdir -p "$tabhome"
rc=0; out=$(CCSWITCH_CLAUDE_HOME="$tabhome" "$CC" doctor 2>&1) || rc=$?
check "tab in home exits 2"       '[ "$rc" -eq 2 ]'
check "tab refusal explains why"  '[[ "$out" == *"tab or newline"* ]]'
rc=0; out=$(CCSWITCH_HOME="$TMP/st$(printf '\t')ate" "$CC" list 2>&1) || rc=$?
check "tab in CCSWITCH_HOME too"  '[ "$rc" -eq 2 ]'
rc=0; CCSWITCH_CLAUDE_HOME="$tabhome" "$CC" which >/dev/null 2>&1 || rc=$?
check "which exits 2, not 1"      '[ "$rc" -eq 2 ]'
# Exit 1 here would mean "unbound" to the wrapper, which would then run the DEFAULT account in a
# repo explicitly bound to a client profile. That is the failure the whole tool exists to prevent.
printf 'work\n' >"$TMP/proj/.ccswitch"
out_tab=$(cd "$TMP/proj" && CCSWITCH_CLAUDE_HOME="$tabhome" PATH="$TMP/shim:$PATH" \
	bash -c 'eval "$(ccswitch shell-init)" 2>/dev/null; claude' 2>/dev/null)
check "tab home never runs claude" '[ -z "$out_tab" ]'
rc_tab=$(cd "$TMP/proj" && CCSWITCH_CLAUDE_HOME="$tabhome" PATH="$TMP/shim:$PATH" \
	bash -c 'eval "$(ccswitch shell-init)" 2>/dev/null; claude' >/dev/null 2>&1; echo $?)
check "tab home wrapper refuses"  '[ "$rc_tab" = "2" ]'

echo "== doctor --fix must converge, not claim a repair it did not make =="
# Skipping a profile's missing claude/ half silently let --fix print success forever.
rm -rf "$CCSWITCH_HOME/profiles/work/codex"
check "half-deleted profile is broken" '[[ "$("$CC" doctor)" == *"not shared"* ]]'
"$CC" doctor --fix >/dev/null
check "doctor --fix converges"     '[[ "$("$CC" doctor)" == *"share config correctly"* ]]'
check "codex half rebuilt"         '[ -L "$CCSWITCH_HOME/profiles/work/codex/config.toml" ]'

echo "== a profile name that fails valid_name is not listed =="
mkdir -p "$CCSWITCH_HOME/profiles/bad;name"
lst=$("$CC" list)
check "invalid name not listed"    '[[ "$lst" != *"bad;name"* ]]'
check "doctor ignores it too"      '[[ "$("$CC" doctor)" != *"bad;name"* ]]'
rm -rf "$CCSWITCH_HOME/profiles/bad;name"

echo "== a stray file in profiles/ is not a profile =="
# `ls -1` called it one, then link_shared died on `ln: .../README/claude/...: Not a directory` and
# every profile sorting after it went unrepaired.
touch "$CCSWITCH_HOME/profiles/README"
mkdir -p "$CCSWITCH_HOME/profiles/halfbuilt"          # a dir with no claude/ or codex/ half
rm "$CCSWITCH_HOME/profiles/work/claude/settings.json"
echo '{"clobbered":3}' >"$CCSWITCH_HOME/profiles/work/claude/settings.json"
rc=0; out=$("$CC" doctor 2>&1) || rc=$?
check "doctor survives stray"     '[ "$rc" -eq 0 ]'
check "stray not called a profile" '[[ "$out" != *"README"* ]]'
lst=$("$CC" list)
check "stray absent from list"    '[[ "$lst" != *README* ]]'
rc=0; "$CC" doctor --fix >/dev/null 2>&1 || rc=$?
check "--fix survives stray"      '[ "$rc" -eq 0 ]'
check "--fix still repaired work" '[ -L "$CCSWITCH_HOME/profiles/work/claude/settings.json" ]'
rm -rf "$CCSWITCH_HOME/profiles/README" "$CCSWITCH_HOME/profiles/halfbuilt"

echo "== sync-mcp copies config and refuses anything that may hold a token ==" 
# MCP servers cannot be symlinked - they live in .claude.json next to oauthAccount.
mcp_of() { python3 -c 'import json,sys
try: print(" ".join(sorted(json.load(open(sys.argv[1])).get("mcpServers",{}))))
except Exception: print("")' "$CCSWITCH_HOME/profiles/$1/claude/.claude.json"; }
"$CC" add synced >/dev/null
check "add copies safe servers"   '[ "$(mcp_of synced)" = "plain-http plain-stdio" ]'
check "env block NOT copied"      '[[ "$(mcp_of synced)" != *has-secret* ]]'
check "headers block NOT copied"  '[[ "$(mcp_of synced)" != *has-headers* ]]'
secret_leaked=$(grep -c 'sk-live-xxx' "$CCSWITCH_HOME/profiles/synced/claude/.claude.json" 2>/dev/null || true)
check "no secret written to disk" '[ "$secret_leaked" = "0" ]'
out=$("$CC" sync-mcp synced)
check "sync-mcp is idempotent"    '[ "$(mcp_of synced)" = "plain-http plain-stdio" ]'
check "sync-mcp reports refusals" '[[ "$out" == *"may hold a secret"* ]]'

# It must never clobber a server the profile already defines, nor the profile's own account.
python3 - <<'PY'
import json, os
p = os.environ["CCSWITCH_HOME"] + "/profiles/synced/claude/.claude.json"
d = json.load(open(p))
d["oauthAccount"] = {"emailAddress": "profile@example.com"}
d["mcpServers"]["plain-http"] = {"type": "http", "url": "https://PROFILE-OWN/mcp"}
json.dump(d, open(p, "w"))
PY
"$CC" sync-mcp synced >/dev/null
own=$(python3 -c 'import json,os;d=json.load(open(os.environ["CCSWITCH_HOME"]+"/profiles/synced/claude/.claude.json"));print(d["mcpServers"]["plain-http"]["url"], d["oauthAccount"]["emailAddress"])')
check "does not clobber own entry" '[[ "$own" == *"PROFILE-OWN"* ]]'
check "does not touch the account" '[[ "$own" == *"profile@example.com"* ]]'
check "sync-mcp refuses unknown"  '! "$CC" sync-mcp ghost >/dev/null 2>&1'
rm -rf "$CCSWITCH_HOME/profiles/synced"

echo "== unuse =="
( cd "$TMP/proj" && "$CC" unuse >/dev/null )
check "marker removed"            '[ ! -f "$TMP/proj/.ccswitch" ]'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
