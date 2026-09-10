#!/usr/bin/env bash
# Self-check for ccswitch. Runs entirely in a temp dir - never touches ~/.claude or ~/.codex.
set -uo pipefail

CC="$(cd "$(dirname "$0")" && pwd)/bin/ccswitch"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export CCSWITCH_HOME="$TMP/state"
export CCSWITCH_CLAUDE_HOME="$TMP/fake-claude"
export CCSWITCH_CODEX_HOME="$TMP/fake-codex"
mkdir -p "$CCSWITCH_CLAUDE_HOME/plugins" "$CCSWITCH_CODEX_HOME"
echo "GLOBAL AGREEMENT" >"$CCSWITCH_CLAUDE_HOME/CLAUDE.md"
echo '{"a":1}' >"$CCSWITCH_CLAUDE_HOME/settings.json"
echo "plugin" >"$CCSWITCH_CLAUDE_HOME/plugins/p.txt"
echo "trust=1" >"$CCSWITCH_CODEX_HOME/config.toml"

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
check "codex config shared"       '[ -L "$CCSWITCH_HOME/profiles/work/codex/config.toml" ]'
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
check "doctor names the profile"  '[[ "$doc" == *"work: settings.json"* ]]'
"$CC" doctor --fix >/dev/null
check "doctor --fix re-links"     '[ -L "$CCSWITCH_HOME/profiles/work/claude/settings.json" ]'
check "shared content restored"   '[ "$(cat "$CCSWITCH_HOME/profiles/work/claude/settings.json")" = "{\"a\":1}" ]'
doc=$("$CC" doctor)
check "doctor clean after fix"    '[[ "$doc" == *"share config correctly"* ]]'

echo "== unuse =="
( cd "$TMP/proj" && "$CC" unuse >/dev/null )
check "marker removed"            '[ ! -f "$TMP/proj/.ccswitch" ]'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
