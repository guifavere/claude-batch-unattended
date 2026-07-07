#!/usr/bin/env bash
# State-logic test suite for the plugin's shell scripts. No network: the conf
# has empty Telegram vars, so curl is never reached while all sentinel/marker
# bookkeeping still runs. Exit code = number of failures.
#
# Assertions are single-quoted strings eval'd inside check() — expansion is
# deliberately deferred, which trips shellcheck's static analysis:
# shellcheck disable=SC2016,SC2034,SC2329
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/notify.sh"
CONTEXT="$ROOT/scripts/batch-context.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export CLAUDE_PROJECT_DIR="$T"
C="$T/.claude"
mkdir -p "$C"
printf 'TELEGRAM_BOT_TOKEN=""\nTELEGRAM_CHAT_ID=""\n' > "$C/.notify.conf"
LOG="$C/hooks/notify.log"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
lastlog() { tail -n 1 "$LOG" 2>/dev/null; }

echo "== 1. no sentinel, no args -> silent no-op, nothing created"
rm -rf "$C/hooks"
bash "$SCRIPT"
check "exit silent" '[ $? -eq 0 ]'
check "no hooks dir created" '[ ! -d "$C/hooks" ]'

echo "== 2. sentinel + NEWER summary -> finished, sentinel+markers cleared"
touch "$C/.batch-active"
sleep 1
echo "resumo: tudo pronto" > "$C/.batch-summary.md"
touch "$C/.batch-attn-last" "$C/.batch-notif-last"
bash "$SCRIPT"
check "finished: sentinel removed" '[ ! -f "$C/.batch-active" ]'
check "finished: markers cleared" '[ ! -f "$C/.batch-attn-last" ] && [ ! -f "$C/.batch-notif-last" ]'
check "finished: send path reached" 'grep -q "telegram vars missing" "$LOG"'

echo "== 3. sentinel NEWER than summary -> ATTENTION, sentinel kept, debounced"
rm -f "$LOG"
echo "resumo velho" > "$C/.batch-summary.md"
sleep 1
touch "$C/.batch-active"
bash "$SCRIPT"
check "stale: sentinel kept" '[ -f "$C/.batch-active" ]'
check "stale: attn marker dropped" '[ -f "$C/.batch-attn-last" ]'
bash "$SCRIPT"
check "stale: 2nd stop debounced" 'lastlog | grep -q "skip stale-stop attention"'

echo "== 4. --notification with sentinel + stdin JSON, then debounced"
rm -f "$C/.batch-notif-last" "$LOG"
echo '{"session_id":"x","message":"Claude needs your permission to use Bash","title":"Claude Code"}' \
  | bash "$SCRIPT" --notification
check "notif: marker dropped" '[ -f "$C/.batch-notif-last" ]'
echo '{"message":"again"}' | bash "$SCRIPT" --notification
check "notif: 2nd ping debounced" 'lastlog | grep -q "skip notification ping"'

echo "== 5. --notification WITHOUT sentinel -> silent no-op"
rm -f "$C/.batch-active" "$C/.batch-notif-last" "$LOG"
echo '{"message":"x"}' | bash "$SCRIPT" --notification
check "notif no sentinel: no marker" '[ ! -f "$C/.batch-notif-last" ]'
check "notif no sentinel: no log" '[ ! -f "$LOG" ]'

echo "== 6. --start -> sends, touches no state"
rm -f "$LOG"
bash "$SCRIPT" --start "plano X aprovado"
check "start: send path reached" 'grep -q "telegram vars missing" "$LOG"'
check "start: no sentinel/markers created" '[ ! -f "$C/.batch-active" ] && [ ! -f "$C/.batch-blocked" ]'

echo "== 7. BLOCKED then stop -> marker consumed, stop silent"
touch "$C/.batch-active"
rm -f "$LOG"
bash "$SCRIPT" "BLOCKED: precisa de decisao sobre schema"
check "blocked: marker dropped" '[ -f "$C/.batch-blocked" ]'
bash "$SCRIPT"
check "blocked: stop consumed marker" '[ ! -f "$C/.batch-blocked" ]'
check "blocked: stop silent" 'lastlog | grep -q "skip finished: turn ended on a block"'
check "blocked: sentinel kept" '[ -f "$C/.batch-active" ]'

echo "== 8. UTF-8: mid-char cut is invalid raw, valid after iconv -c"
# 'ça' is ç(2 bytes)+a; tail -c 2 keeps ç's 2nd byte + 'a' -> broken UTF-8.
printf 'ça' | tail -c 2 | iconv -f UTF-8 -t UTF-8 > /dev/null 2>&1
check "utf8: raw cut IS invalid (bug is real)" '[ $? -ne 0 ]'
CUT="$(printf 'ça' | tail -c 2 | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)"
printf '%s' "$CUT" | iconv -f UTF-8 -t UTF-8 > /dev/null 2>&1
check "utf8: iconv -c output valid" '[ $? -eq 0 ]'
# End-to-end: a big accented summary excerpt survives the same pipeline.
B=""
i=0
while [ "$i" -lt 100 ]; do B="${B}aprovação e conclusão çãáéíóú… "; i=$((i + 1)); done
printf '%s' "$B" > "$C/sum-utf8.md"
tail -c 1200 "$C/sum-utf8.md" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null \
  | iconv -f UTF-8 -t UTF-8 > /dev/null 2>&1
check "utf8: 1200-byte excerpt valid after iconv" '[ $? -eq 0 ]'

echo "== 9. log rotation"
touch "$C/.batch-active"
rm -f "$C/.batch-blocked" "$C/.batch-attn-last"
mkdir -p "$C/hooks"
head -c 300000 /dev/zero | tr '\0' 'x' > "$LOG"
bash "$SCRIPT" --start "rot"
SZ="$(wc -c < "$LOG")"
check "log rotated under 200KB" '[ "$SZ" -lt 204800 ]'

echo "== 10. --cancel with sentinel -> sends, clears everything"
touch "$C/.batch-active" "$C/.batch-blocked" "$C/.batch-attn-last" "$C/.batch-notif-last"
rm -f "$LOG"
bash "$SCRIPT" --cancel
check "cancel: send path reached" 'grep -q "telegram vars missing" "$LOG"'
check "cancel: sentinel + markers cleared" \
  '[ ! -f "$C/.batch-active" ] && [ ! -f "$C/.batch-blocked" ] && [ ! -f "$C/.batch-attn-last" ] && [ ! -f "$C/.batch-notif-last" ]'

echo "== 11. --cancel without sentinel -> logged no-op, nothing sent"
rm -f "$LOG"
bash "$SCRIPT" --cancel
check "cancel idle: logged" 'lastlog | grep -q "cancel: no active batch"'
check "cancel idle: no send attempted" '! grep -q "telegram" "$LOG"'

echo "== 12. batch-context.sh (SessionStart)"
rm -f "$C/.batch-active" "$C/.batch-blocked"
OUT="$(bash "$CONTEXT")"
check "context: silent without sentinel" '[ -z "$OUT" ]'
touch "$C/.batch-active"
OUT="$(bash "$CONTEXT")"
check "context: reports active batch" 'printf "%s" "$OUT" | grep -q "UNFINISHED BATCH RUN"'
check "context: state in progress" 'printf "%s" "$OUT" | grep -q "in progress"'
touch "$C/.batch-blocked"
OUT="$(bash "$CONTEXT")"
check "context: reports block" 'printf "%s" "$OUT" | grep -q "manual BLOCK"'
rm -f "$C/.batch-active" "$C/.batch-blocked"

echo
echo "RESULT: $PASS pass, $FAIL fail"
exit "$FAIL"
