#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034
# SC2016: every assertion is a single-quoted expression that `check` evaluates later. Expanding it
#         at definition time would compare the values from before the command under test ran.
# SC2034: the variables those assertions read are invisible to shellcheck for the same reason.
# Self-check for stead. Runs entirely in a temp dir - never touches ~/.claude or ~/.codex.
set -uo pipefail

CC="$(cd "$(dirname "$0")" && pwd)/bin/stead"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export STEAD_HOME="$TMP/state"
export STEAD_CLAUDE_HOME="$TMP/fake-claude"
export STEAD_CODEX_HOME="$TMP/fake-codex"
export STEAD_CLAUDE_JSON="$TMP/fake-claude.json"
mkdir -p "$STEAD_CLAUDE_HOME/plugins" "$STEAD_CODEX_HOME/skills" "$STEAD_CODEX_HOME/plugins" "$STEAD_CLAUDE_HOME/sessions"
echo "GLOBAL AGREEMENT" >"$STEAD_CLAUDE_HOME/CLAUDE.md"
echo '{"a":1}' >"$STEAD_CLAUDE_HOME/settings.json"
echo "plugin" >"$STEAD_CLAUDE_HOME/plugins/p.txt"
echo "trust=1" >"$STEAD_CODEX_HOME/config.toml"
mkdir -p "$STEAD_CLAUDE_HOME/hooks"
echo "#!/bin/sh" >"$STEAD_CLAUDE_HOME/hooks/gate.sh"
echo '{"permissions":{"allow":["Bash(ls:*)"]}}' >"$STEAD_CLAUDE_HOME/settings.local.json"
echo "codex skill" >"$STEAD_CODEX_HOME/skills/s.txt"
cat >"$STEAD_CLAUDE_JSON" <<'JSON'
{"oauthAccount":{"emailAddress":"real@example.com"},
 "mcpServers":{"plain-http":{"type":"http","url":"https://example.test/mcp"},
               "plain-stdio":{"type":"stdio","command":"/bin/echo","args":[],"env":{}},
               "has-secret":{"type":"stdio","command":"/bin/echo","env":{"API_KEY":"sk-live-env"}},
               "has-headers":{"type":"http","url":"https://x.test","headers":{"Authorization":"Bearer sk-live-hdr"}},
               "url-key":{"type":"http","url":"https://x.test/mcp?api_key=sk-live-url"},
               "url-userinfo":{"type":"http","url":"https://user:sk-live-userinfo@x.test/mcp"},
               "args-key":{"type":"stdio","command":"npx","args":["-y","@p/s","--api-key=sk-live-args"]},
               "case-env":{"type":"stdio","command":"/bin/echo","Env":{"K":"sk-live-case"}},
               "nested-oauth":{"type":"http","url":"https://y.test/mcp","oauth":{"clientId":"sk-live-oauth"}},
               "not-an-object":"npx -y @p/s"}}
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
check "profile dirs created"      '[ -d "$STEAD_HOME/profiles/work/claude" ] && [ -d "$STEAD_HOME/profiles/work/codex" ]'
check "CLAUDE.md shared"          '[ -L "$STEAD_HOME/profiles/work/claude/CLAUDE.md" ]'
check "shared content readable"   '[ "$(cat "$STEAD_HOME/profiles/work/claude/CLAUDE.md")" = "GLOBAL AGREEMENT" ]'
check "plugins dir shared"        '[ -L "$STEAD_HOME/profiles/work/claude/plugins" ]'
check "hooks dir shared"          '[ -L "$STEAD_HOME/profiles/work/claude/hooks" ]'
check "hook script readable"      '[ -f "$STEAD_HOME/profiles/work/claude/hooks/gate.sh" ]'
check "local permissions shared"  '[ -L "$STEAD_HOME/profiles/work/claude/settings.local.json" ]'
check "session registry shared"   '[ -L "$STEAD_HOME/profiles/work/claude/sessions" ]'
# The point of sharing it: one registry, so a session in a profile is discoverable from outside it.
echo '{"pid":424242,"name":"probe"}' >"$STEAD_HOME/profiles/work/claude/sessions/probe.json"
check "peers land in one registry" '[ -f "$STEAD_CLAUDE_HOME/sessions/probe.json" ]'
rm -f "$STEAD_CLAUDE_HOME/sessions/probe.json"
check "codex config shared"       '[ -L "$STEAD_HOME/profiles/work/codex/config.toml" ]'
check "codex skills shared"       '[ -L "$STEAD_HOME/profiles/work/codex/skills" ]'
check "codex plugins shared"      '[ -L "$STEAD_HOME/profiles/work/codex/plugins" ]'
check "auth NOT shared"           '[ ! -e "$STEAD_HOME/profiles/work/claude/.credentials.json" ]'
check "duplicate add refused"     '! "$CC" add work >/dev/null 2>&1'

echo "== bind / resolve =="
mkdir -p "$TMP/proj/deep/nested" "$TMP/elsewhere"
( cd "$TMP/proj" && "$CC" use work >/dev/null )
check "marker written"            '[ "$(cat "$TMP/proj/.stead")" = "work" ]'
check "which in project"          '[ "$(cd "$TMP/proj" && "$CC" which)" = "work" ]'
check "which walks up from deep"  '[ "$(cd "$TMP/proj/deep/nested" && "$CC" which)" = "work" ]'
check "unbound dir exits nonzero" '! ( cd "$TMP/elsewhere" && "$CC" which --quiet >/dev/null 2>&1 )'

echo "== marker content is untrusted input, and a bad marker must FAIL CLOSED =="
# Exit 2 (refuse) vs exit 1 (unbound, use default) is the load-bearing distinction: collapsing them
# runs a client repo on the personal account silently.
rc_of() { ( cd "$1" && "$CC" which >/dev/null 2>&1 ); echo $?; }
for bad in "../../../etc" "" "-n" "--fix" "a b" "x;id" "/etc/passwd" ".." "client acme";
do
	printf '%s\n' "$bad" >"$TMP/proj/.stead"
	check "bad marker '$bad' exits 2 (refuse)" '[ "$(rc_of "$TMP/proj")" = "2" ]'
done
printf 'no-such-profile\n' >"$TMP/proj/.stead"
check "valid name, missing profile exits 2" '[ "$(rc_of "$TMP/proj")" = "2" ]'
rm -f "$TMP/proj/.stead"
check "no marker at all exits 1"  '[ "$(rc_of "$TMP/proj")" = "1" ]'
printf '  work  \n' >"$TMP/proj/.stead"
check "whitespace tolerated"      '[ "$(cd "$TMP/proj" && "$CC" which)" = "work" ]'
printf 'work\r\n' >"$TMP/proj/.stead"
check "CRLF marker tolerated"     '[ "$(cd "$TMP/proj" && "$CC" which)" = "work" ]'
printf 'work\nignored-second-line\n' >"$TMP/proj/.stead"
check "only first line is read"   '[ "$(cd "$TMP/proj" && "$CC" which)" = "work" ]'
printf 'work' >"$TMP/proj/.stead"
check "no trailing newline is ok" '[ "$(cd "$TMP/proj" && "$CC" which)" = "work" ]'
printf 'work\n' >"$TMP/proj/.stead"
check "bound dir exits 0"         '[ "$(rc_of "$TMP/proj")" = "0" ]'

echo "== run exports the isolation contract =="
got=$("$CC" run work sh -c 'echo "$CLAUDE_CONFIG_DIR|$CODEX_HOME|$STEAD_PROFILE"')
check "CLAUDE_CONFIG_DIR set"     '[ "${got%%|*}" = "$STEAD_HOME/profiles/work/claude" ]'
check "CODEX_HOME set"            '[ "$(echo "$got" | cut -d"|" -f2)" = "$STEAD_HOME/profiles/work/codex" ]'
check "profile name exported"     '[ "$(echo "$got" | cut -d"|" -f3)" = "work" ]'
check "run refuses unknown"       '! "$CC" run ghost sh -c true >/dev/null 2>&1'

# A bound session must not publish its directory name into the shared peer registry.
mkdir -p "$TMP/acme-secret-client"
alias1=$(cd "$TMP/acme-secret-client" && "$CC" run work sh -c 'printf %s "$CLAUDE_CODE_SESSION_NAME"')
check "session alias is set"      '[ -n "$alias1" ]'
check "alias starts with profile" '[[ "$alias1" == work-* ]]'
check "alias hides the directory" '[[ "$alias1" != *acme* ]]'
alias2=$(cd "$TMP/acme-secret-client" && "$CC" run work sh -c 'printf %s "$CLAUDE_CODE_SESSION_NAME"')
check "alias is stable per dir"   '[ "$alias1" = "$alias2" ]'
alias3=$(cd "$TMP/elsewhere" && "$CC" run work sh -c 'printf %s "$CLAUDE_CODE_SESSION_NAME"')
check "alias differs per dir"     '[ "$alias1" != "$alias3" ]'
alias4=$(cd "$TMP/acme-secret-client" && CLAUDE_CODE_SESSION_NAME=chosen "$CC" run work sh -c 'printf %s "$CLAUDE_CODE_SESSION_NAME"')
check "explicit name wins"        '[ "$alias4" = "chosen" ]'

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
ln -sf "$CC" "$TMP/shim/stead"
out_bound=$(cd "$TMP/proj"      && PATH="$TMP/shim:$PATH" bash -c 'eval "$(stead shell-init)"; claude')
out_free=$(cd  "$TMP/elsewhere" && PATH="$TMP/shim:$PATH" bash -c 'eval "$(stead shell-init)"; claude')
check "bound dir gets profile"    '[ "$out_bound" = "claude ran with CLAUDE_CONFIG_DIR=$STEAD_HOME/profiles/work/claude" ]'
check "unbound dir passes through" '[ "$out_free" = "claude ran with CLAUDE_CONFIG_DIR=none" ]'

# The wrapper must refuse rather than silently fall back to the default account.
echo "../../etc" >"$TMP/proj/.stead"
out_bad=$(cd "$TMP/proj" && PATH="$TMP/shim:$PATH" bash -c 'eval "$(stead shell-init)"; claude' 2>/dev/null)
rc_bad=$(cd "$TMP/proj" && PATH="$TMP/shim:$PATH" bash -c 'eval "$(stead shell-init)"; claude' >/dev/null 2>&1; echo $?)
check "wrapper refuses bad marker" '[ "$rc_bad" = "2" ]'
check "wrapper ran NOTHING on bad marker" '[ -z "$out_bad" ]'
err_bad=$(cd "$TMP/proj" && PATH="$TMP/shim:$PATH" bash -c 'eval "$(stead shell-init)"; claude' 2>&1 >/dev/null)
check "wrapper explains why"      '[[ "$err_bad" == *"refusing to guess an account"* ]]'

# ...but a missing/broken stead must never block the real binary.
out_noswitch=$(cd "$TMP/proj" && PATH="$TMP/shim-noswitch:$PATH" bash -c 'claude' 2>/dev/null)
check "no stead on PATH still runs claude" '[ "$out_noswitch" = "claude ran with CLAUDE_CONFIG_DIR=none" ]'
printf 'work\n' >"$TMP/proj/.stead"

echo "== doctor detects an atomic write that clobbered a symlink =="
# Capture before grepping: `cmd | grep -q` SIGPIPEs the writer, and pipefail scores that a failure.
doc=$("$CC" doctor)
check "clean profiles report ok"  '[[ "$doc" == *"share config correctly"* ]]'
rm "$STEAD_HOME/profiles/work/claude/settings.json"
echo '{"clobbered":1}' >"$STEAD_HOME/profiles/work/claude/settings.json"
doc=$("$CC" doctor)
check "doctor spots real file"    '[[ "$doc" == *"no longer shared"* ]]'
check "doctor names the profile"  '[[ "$doc" == *"work: claude/settings.json"* ]]'
"$CC" doctor --fix >/dev/null
check "doctor --fix re-links"     '[ -L "$STEAD_HOME/profiles/work/claude/settings.json" ]'
check "shared content restored"   '[ "$(cat "$STEAD_HOME/profiles/work/claude/settings.json")" = "{\"a\":1}" ]'
doc=$("$CC" doctor)
check "doctor clean after fix"    '[[ "$doc" == *"share config correctly"* ]]'

echo "== doctor covers the codex side too, not just claude ==" 
# The lists are consumed from one definition; a doctor that walked only CLAUDE_SHARED reported a
# clobbered codex/config.toml as healthy while --fix silently repaired it.
rm "$STEAD_HOME/profiles/work/codex/config.toml"
echo 'clobbered=1' >"$STEAD_HOME/profiles/work/codex/config.toml"
doc=$("$CC" doctor)
check "doctor spots codex file"   '[[ "$doc" == *"work: codex/config.toml"* ]]'
"$CC" doctor --fix >/dev/null
check "doctor --fix relinks codex" '[ -L "$STEAD_HOME/profiles/work/codex/config.toml" ]'
check "codex content restored"    '[ "$(cat "$STEAD_HOME/profiles/work/codex/config.toml")" = "trust=1" ]'

echo "== doctor --fix must not delete what it has no shared copy of ==" 
# The fake claude home has no 'agents' dir, so nothing was ever linked there. Real content at that
# path is the user's only copy. A --fix loop that walks entries with no source rm -rf's it and
# link_shared cannot restore it - silent, unrecoverable, right after doctor said "healthy".
mkdir -p "$STEAD_HOME/profiles/work/claude/agents"
echo "my only copy" >"$STEAD_HOME/profiles/work/claude/agents/mine.md"
check "unshared path reported healthy" '[[ "$("$CC" doctor)" == *"share config correctly"* ]]'
rm "$STEAD_HOME/profiles/work/claude/settings.json"   # an UNRELATED break sends the user to --fix
echo '{"clobbered":2}' >"$STEAD_HOME/profiles/work/claude/settings.json"
"$CC" doctor --fix >/dev/null
check "unrelated --fix spared the data" '[ "$(cat "$STEAD_HOME/profiles/work/claude/agents/mine.md" 2>/dev/null)" = "my only copy" ]'
check "--fix still repaired the break"  '[ -L "$STEAD_HOME/profiles/work/claude/settings.json" ]'
rm -rf "$STEAD_HOME/profiles/work/claude/agents"

echo "== list must not call a fail-closed directory 'unbound' =="
# rc=2 (refuse) reported as "uses your default account" is the exact lie the tool exists to prevent.
printf 'work\n' >"$TMP/proj/.stead"
out=$(cd "$TMP/proj" && "$CC" list 2>/dev/null)
check "bound dir marked active"   '[[ "$out" == *"<- active here"* ]]'
out=$(cd "$TMP/elsewhere" && "$CC" list 2>/dev/null)
check "unbound dir says unbound"  '[[ "$out" == *"unbound - claude and codex use your default account"* ]]'
printf '../../etc\n' >"$TMP/proj/.stead"
out=$(cd "$TMP/proj" && "$CC" list 2>/dev/null)
check "bad marker NOT called unbound" '[[ "$out" != *"use your default account"* ]]'
check "bad marker says refuse"    '[[ "$out" == *"refuse to run here"* ]]'
printf 'work\n' >"$TMP/proj/.stead"

echo "== use warns when the marker would be committed =="
# .stead names a profile, which can be a client's name.
git -C "$TMP/proj" init -q 2>/dev/null
out=$(cd "$TMP/proj" && "$CC" use work)
check "warns when not ignored"    '[[ "$out" == *"not gitignored"* ]]'
echo ".stead" >"$TMP/proj/.gitignore"
out=$(cd "$TMP/proj" && "$CC" use work)
check "silent when ignored"       '[[ "$out" != *"not gitignored"* ]]'

echo "== doctor --fix must migrate a profile directory, not delete it ==" 
# sessions is the first shared entry holding LIVE runtime state. rm -rf there deregisters a running
# session and destroys an IPC key Claude Code writes only at startup - and doctor PRINTS --fix as
# the remedy, so the tool would be instructing the user to break their own sessions.
rm -rf "$STEAD_HOME/profiles/work/claude/sessions"
mkdir -p "$STEAD_HOME/profiles/work/claude/sessions"
echo '{"pid":99999}' >"$STEAD_HOME/profiles/work/claude/sessions/99999.json"
echo 'secret-ipc-key' >"$STEAD_HOME/profiles/work/claude/sessions/99999.aaaa.key"
echo 'shared-wins' >"$STEAD_CLAUDE_HOME/sessions/collide.json"
echo 'profile-loses' >"$STEAD_HOME/profiles/work/claude/sessions/collide.json"
"$CC" doctor --fix >/dev/null 2>&1 || true
check "live record survived --fix"  '[ -f "$STEAD_CLAUDE_HOME/sessions/99999.json" ]'
check "ipc key survived --fix"      '[ -f "$STEAD_CLAUDE_HOME/sessions/99999.aaaa.key" ]'
check "sessions relinked after"     '[ -L "$STEAD_HOME/profiles/work/claude/sessions" ]'
check "shared copy wins collision"  '[ "$(cat "$STEAD_CLAUDE_HOME/sessions/collide.json")" = "shared-wins" ]'
rm -f "$STEAD_CLAUDE_HOME/sessions/99999.json" "$STEAD_CLAUDE_HOME/sessions/99999.aaaa.key" "$STEAD_CLAUDE_HOME/sessions/collide.json"
# A real FILE replacing a shared one is still discarded: that is the clobber doctor exists to fix.
rm -f "$STEAD_HOME/profiles/work/claude/settings.json"
echo '{"clobbered":9}' >"$STEAD_HOME/profiles/work/claude/settings.json"
"$CC" doctor --fix >/dev/null 2>&1 || true
check "clobbered file still wins shared" '[ "$(cat "$STEAD_HOME/profiles/work/claude/settings.json")" = "{\"a\":1}" ]'

echo "== an on-demand source is created, not silently skipped =="
# If ~/.claude/sessions does not exist, each_shared filters the entry out, every profile keeps its
# own registry, peers stay invisible - and doctor calls it healthy forever.
rm -rf "$STEAD_CLAUDE_HOME/sessions"
"$CC" add ondemand >/dev/null 2>&1
check "source dir created"         '[ -d "$STEAD_CLAUDE_HOME/sessions" ]'
check "sessions linked anyway"     '[ -L "$STEAD_HOME/profiles/ondemand/claude/sessions" ]'
check "source dir is private"      '[ "$(stat -f %Sp "$STEAD_CLAUDE_HOME/sessions")" = "drwx------" ]'
rm -rf "$STEAD_HOME/profiles/ondemand"

echo "== a tab or newline in a home path is refused at startup =="
# The tab-separated encoding would split one entry in two and hand the rm -rf loop a RELATIVE dst,
# which resolves against the user's cwd - a delete outside $PROFILES entirely. Fail closed instead.
tabhome="$TMP/cl$(printf '\t')aude"
mkdir -p "$tabhome"
rc=0; out=$(STEAD_CLAUDE_HOME="$tabhome" "$CC" doctor 2>&1) || rc=$?
check "tab in home exits 2"       '[ "$rc" -eq 2 ]'
check "tab refusal explains why"  '[[ "$out" == *"tab or newline"* ]]'
rc=0; out=$(STEAD_HOME="$TMP/st$(printf '\t')ate" "$CC" list 2>&1) || rc=$?
check "tab in STEAD_HOME too"  '[ "$rc" -eq 2 ]'
rc=0; STEAD_CLAUDE_HOME="$tabhome" "$CC" which >/dev/null 2>&1 || rc=$?
check "which exits 2, not 1"      '[ "$rc" -eq 2 ]'
# Exit 1 here would mean "unbound" to the wrapper, which would then run the DEFAULT account in a
# repo explicitly bound to a client profile. That is the failure the whole tool exists to prevent.
printf 'work\n' >"$TMP/proj/.stead"
out_tab=$(cd "$TMP/proj" && STEAD_CLAUDE_HOME="$tabhome" PATH="$TMP/shim:$PATH" \
	bash -c 'eval "$(stead shell-init)" 2>/dev/null; claude' 2>/dev/null)
check "tab home never runs claude" '[ -z "$out_tab" ]'
rc_tab=$(cd "$TMP/proj" && STEAD_CLAUDE_HOME="$tabhome" PATH="$TMP/shim:$PATH" \
	bash -c 'eval "$(stead shell-init)" 2>/dev/null; claude' >/dev/null 2>&1; echo $?)
check "tab home wrapper refuses"  '[ "$rc_tab" = "2" ]'

echo "== doctor --fix must converge, not claim a repair it did not make =="
# Skipping a profile's missing claude/ half silently let --fix print success forever.
rm -rf "$STEAD_HOME/profiles/work/codex"
check "half-deleted profile is broken" '[[ "$("$CC" doctor)" == *"not shared"* ]]'
"$CC" doctor --fix >/dev/null
check "doctor --fix converges"     '[[ "$("$CC" doctor)" == *"share config correctly"* ]]'
check "codex half rebuilt"         '[ -L "$STEAD_HOME/profiles/work/codex/config.toml" ]'

echo "== a profile name that fails valid_name is not listed =="
mkdir -p "$STEAD_HOME/profiles/bad;name"
lst=$("$CC" list)
check "invalid name not listed"    '[[ "$lst" != *"bad;name"* ]]'
check "doctor ignores it too"      '[[ "$("$CC" doctor)" != *"bad;name"* ]]'
rm -rf "$STEAD_HOME/profiles/bad;name"

echo "== a stray file in profiles/ is not a profile =="
# `ls -1` called it one, then link_shared died on `ln: .../README/claude/...: Not a directory` and
# every profile sorting after it went unrepaired.
touch "$STEAD_HOME/profiles/README"
mkdir -p "$STEAD_HOME/profiles/halfbuilt"          # a dir with no claude/ or codex/ half
rm "$STEAD_HOME/profiles/work/claude/settings.json"
echo '{"clobbered":3}' >"$STEAD_HOME/profiles/work/claude/settings.json"
rc=0; out=$("$CC" doctor 2>&1) || rc=$?
check "doctor survives stray"     '[ "$rc" -eq 0 ]'
check "stray not called a profile" '[[ "$out" != *"README"* ]]'
lst=$("$CC" list)
check "stray absent from list"    '[[ "$lst" != *README* ]]'
rc=0; "$CC" doctor --fix >/dev/null 2>&1 || rc=$?
check "--fix survives stray"      '[ "$rc" -eq 0 ]'
check "--fix still repaired work" '[ -L "$STEAD_HOME/profiles/work/claude/settings.json" ]'
rm -rf "$STEAD_HOME/profiles/README" "$STEAD_HOME/profiles/halfbuilt"

echo "== sync-mcp copies config and refuses anything that may hold a token ==" 
# MCP servers cannot be symlinked - they live in .claude.json next to oauthAccount.
mcp_of() { python3 -c 'import json,sys
try: print(" ".join(sorted(json.load(open(sys.argv[1])).get("mcpServers",{}))))
except Exception: print("")' "$STEAD_HOME/profiles/$1/claude/.claude.json"; }
"$CC" add synced >/dev/null
check "add copies safe servers"   '[ "$(mcp_of synced)" = "plain-http plain-stdio" ]'
# Every refused shape, one assertion each. url-key and args-key are the two that a denylist of
# env/headers waves through, and the tool then reports them as clean.
for bad in has-secret has-headers url-key url-userinfo args-key case-env nested-oauth not-an-object; do
	check "refused: $bad"         '[[ "$(mcp_of synced)" != *"'"$bad"'"* ]]'
done
# The real test of the premise: NO credential string reaches the profile, by any route.
leaked=$(grep -o 'sk-live-[a-z]*' "$STEAD_HOME/profiles/synced/claude/.claude.json" 2>/dev/null | sort -u | tr '\n' ' ')
check "no secret written to disk" '[ -z "$leaked" ]'
# Only allowlisted keys are ever written, so a field we do not understand cannot ride along.
keys=$(python3 -c 'import json,os;d=json.load(open(os.environ["STEAD_HOME"]+"/profiles/synced/claude/.claude.json"));print(" ".join(sorted({k for c in d["mcpServers"].values() for k in c})))')
check "only allowlisted keys kept" '[[ "$keys" =~ ^(args|command|type|url|\ )+$ ]]'
out=$("$CC" sync-mcp synced)
check "sync-mcp is idempotent"    '[ "$(mcp_of synced)" = "plain-http plain-stdio" ]'
check "sync-mcp names the reason" '[[ "$out" == *"field(s) I will not copy blind: env"* ]]'
check "sync-mcp says what to do"  '[[ "$out" == *"add them by hand"* ]]'

# It must never clobber a server the profile already defines, nor the profile's own account.
python3 - <<'PY'
import json, os
p = os.environ["STEAD_HOME"] + "/profiles/synced/claude/.claude.json"
d = json.load(open(p))
d["oauthAccount"] = {"emailAddress": "profile@example.com"}
d["mcpServers"]["plain-http"] = {"type": "http", "url": "https://PROFILE-OWN/mcp"}
json.dump(d, open(p, "w"))
PY
"$CC" sync-mcp synced >/dev/null
own=$(python3 -c 'import json,os;d=json.load(open(os.environ["STEAD_HOME"]+"/profiles/synced/claude/.claude.json"));print(d["mcpServers"]["plain-http"]["url"], d["oauthAccount"]["emailAddress"])')
check "does not clobber own entry" '[[ "$own" == *"PROFILE-OWN"* ]]'
check "does not touch the account" '[[ "$own" == *"profile@example.com"* ]]'
check "sync-mcp refuses unknown"  '! "$CC" sync-mcp ghost >/dev/null 2>&1'

# An unparseable destination must be left ALONE. Falling back to {} rewrites the file and destroys
# the oauthAccount still sitting in it, which is recoverable by hand until we overwrite it.
printf '{"oauthAccount":{"emailAddress":"stranded@example.com"},"mcpServ' \
	>"$STEAD_HOME/profiles/synced/claude/.claude.json"
rc=0; "$CC" sync-mcp synced >/dev/null 2>&1 || rc=$?
salvage=$(grep -c 'stranded@example.com' "$STEAD_HOME/profiles/synced/claude/.claude.json" || true)
check "truncated dst not clobbered" '[ "$salvage" = "1" ]'
check "truncated dst exits 0"     '[ "$rc" -eq 0 ]'

# add must survive mcp config it cannot parse - there is no `stead remove` to recover with.
cat >"$STEAD_CLAUDE_JSON" <<'JSON'
{"mcpServers":{"legacy":"npx -y @some/mcp"}}
JSON
rc=0; out=$("$CC" add survivor 2>&1) || rc=$?
check "add survives bad mcp config" '[ "$rc" -eq 0 ]'
check "add still printed its help"  '[[ "$out" == *"bind the current directory"* ]]'
check "add still linked shared"     '[ -L "$STEAD_HOME/profiles/survivor/claude/CLAUDE.md" ]'
rm -rf "$STEAD_HOME/profiles/survivor"
rm -rf "$STEAD_HOME/profiles/synced"

echo "== the guard is shape-based, and reads EVERY string in an entry ==" 
# A denylist of field names missed url/args. A denylist of credential words then missed a DSN in
# args, which is how postgres-mcp, mysql-mcp and redis-mcp are all documented to be invoked.
cat >"$TMP/leaks.json" <<'JSON'
{"mcpServers":{
 "pg-uri":{"type":"stdio","command":"uvx","args":["postgres-mcp","postgresql://app:LEAKPG@db.internal:5432/prod"]},
 "redis-uri":{"type":"stdio","command":"npx","args":["-y","@redis/mcp","redis://default:LEAKREDIS@cache:6379"]},
 "zapier":{"type":"http","url":"https://mcp.zapier.com/api/mcp/s/LEAKZAPIERaBcDeF0123456789xy/sse"},
 "smithery":{"type":"stdio","command":"npx","args":["-y","@smithery/cli","--key","LEAKSMITHERYf81d4fae7dec11d0a7"]},
 "jwt":{"type":"http","url":"https://x.test/mcp/eyJhbGciOiJIUzI1NiLEAKJWTInR5cCI6IkpXVCJ9"},
 "ghp":{"type":"stdio","command":"srv","args":["ghp_16C7eLEAKPAT292c6912E7710c838347Ae17"]},
 "query-nonword":{"type":"http","url":"https://x.test/mcp?k=LEAKQUERY9f86d081884c7d659a"},
 "matrix":{"type":"http","url":"https://x.test/mcp;k=LEAKMATRIX9f86d081884c7d65"},
 "filesystem":{"type":"stdio","command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/Users/x/Projects"],"env":{}},
 "sentry":{"type":"http","url":"https://mcp.sentry.dev/mcp"},
 "ghdocker":{"type":"stdio","command":"docker","args":["run","-i","--rm","ghcr.io/github/github-mcp-server"],"env":{}}}}
JSON
STEAD_CLAUDE_JSON="$TMP/leaks.json" "$CC" add shapes >/dev/null 2>&1
got=$(mcp_of shapes)
# Overcorrection is a real cost, so the legit set is asserted exactly, not just "some copied".
check "real servers still copied"  '[ "$got" = "filesystem ghdocker sentry" ]'
for bad in pg-uri redis-uri zapier smithery jwt ghp query-nonword matrix; do
	check "refused: $bad"         '[[ "$got" != *"'"$bad"'"* ]]'
done
# query-nonword and matrix have no credential WORD in them: they exercise the parameter rule alone,
# which had no independent coverage - deleting that rule left the suite green.
leaked=$(grep -oE 'LEAK[A-Z]+' "$STEAD_HOME/profiles/shapes/claude/.claude.json" 2>/dev/null | sort -u | tr '\n' ' ')
check "no secret reaches disk"     '[ -z "$leaked" ]'
rm -rf "$STEAD_HOME/profiles/shapes"

echo "== doctor reports what an older, looser guard already put in a profile =="
# sync-mcp refuses a bad SOURCE entry, but a profile synced by a looser version keeps what it got
# and nothing else looks inside .claude.json. Same guard, so the two cannot drift apart.
python3 - <<'PY'
import json, os
p = os.environ["STEAD_HOME"] + "/profiles/work/claude/.claude.json"
try: d = json.load(open(p))
except Exception: d = {}
d.setdefault("mcpServers", {})["stale"] = {"type": "stdio", "command": "uvx",
    "args": ["postgres-mcp", "postgresql://app:LEGACYLEAK@db.internal:5432/prod"]}
json.dump(d, open(p, "w"))
PY
doc=$("$CC" doctor)
check "doctor flags the stale entry" '[[ "$doc" == *"work: mcp server stale"* ]]'
check "doctor names the reason"     '[[ "$doc" == *"embedded username and password"* ]]'
check "not called share-correct"    '[[ "$doc" != *"share config correctly"* ]]'
check "tells the user what to do"   '[[ "$doc" == *"claude mcp add"* ]]'
# It must NOT be folded into --fix: relinking cannot remove it, and claiming otherwise is the
# fabricated-repair bug this file already fixed once.
"$CC" doctor --fix >/dev/null 2>&1 || true
still=$(python3 -c 'import json,os;print("stale" in json.load(open(os.environ["STEAD_HOME"]+"/profiles/work/claude/.claude.json")).get("mcpServers",{}))')
check "--fix does not touch mcp"    '[ "$still" = "True" ]'
check "doctor still flags after fix" '[[ "$("$CC" doctor)" == *"mcp server stale"* ]]'
python3 -c 'import json,os;p=os.environ["STEAD_HOME"]+"/profiles/work/claude/.claude.json";d=json.load(open(p));d["mcpServers"].pop("stale");json.dump(d,open(p,"w"))'
check "doctor clean once removed"   '[[ "$("$CC" doctor)" == *"share config correctly"* ]]'

echo "== add survives python3 itself failing =="
# The || warn safety net had no coverage: every malformed source was handled INSIDE python, so it
# exited 0 and the branch never ran.
mkdir -p "$TMP/pyfail"
printf '#!/bin/sh\nexit 3\n' >"$TMP/pyfail/python3"; chmod +x "$TMP/pyfail/python3"
rc=0; out=$(PATH="$TMP/pyfail:$PATH" "$CC" add pfail 2>&1) || rc=$?
check "add survives python3 dying" '[ "$rc" -eq 0 ]'
check "add warns sync failed"      '[[ "$out" == *"mcp sync failed"* ]]'
check "add still built the profile" '[ -L "$STEAD_HOME/profiles/pfail/claude/CLAUDE.md" ]'
rm -rf "$STEAD_HOME/profiles/pfail"

echo "== unuse =="
( cd "$TMP/proj" && "$CC" unuse >/dev/null )
check "marker removed"            '[ ! -f "$TMP/proj/.stead" ]'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
