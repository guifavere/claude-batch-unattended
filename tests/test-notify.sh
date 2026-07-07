#!/usr/bin/env bash
# State-logic test suite for the plugin's shell scripts.
#
# No real network: a fake `curl` is prepended to PATH and returns a canned body
# controlled by $CURL_RESP_FILE, so we can drive both delivered ({"ok":true})
# and failed sends and assert the result-aware bookkeeping. Exit = failures.
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
LOG="$C/hooks/notify.log"

# --- fake curl -------------------------------------------------------------
# notify.sh captures stdout as the Telegram response body. Emit whatever
# $CURL_RESP_FILE holds; default to a success body.
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
cat "${CURL_RESP_FILE:-/dev/null}" 2>/dev/null
exit 0
STUB
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"
export CURL_RESP_FILE="$T/curl-resp"
resp_ok()   { printf '{"ok":true,"result":{}}' > "$CURL_RESP_FILE"; }
resp_fail() { printf '{"ok":false,"error_code":401,"description":"Unauthorized"}' > "$CURL_RESP_FILE"; }
resp_ok

# Real-looking (but unused — curl is stubbed) secrets so notify.sh enters the
# send branch. Sourcing this would be a bug; the script must PARSE it.
printf 'TELEGRAM_BOT_TOKEN="123:AAtoken"\nTELEGRAM_CHAT_ID="999"\n' > "$C/.notify.conf"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
lastlog() { tail -n 1 "$LOG" 2>/dev/null; }
reset_state() { rm -f "$C"/.batch-* "$LOG"; }

echo "== 1. no sentinel, no args -> silent no-op, nothing created"
rm -rf "$C/hooks"; rm -f "$C"/.batch-*
bash "$SCRIPT"
check "exit silent" '[ $? -eq 0 ]'
check "no hooks dir created" '[ ! -d "$C/hooks" ]'

echo "== 2. finished + send OK -> sentinel + markers cleared"
reset_state; resp_ok
touch "$C/.batch-active"; sleep 1
echo "resumo: tudo pronto" > "$C/.batch-summary.md"
touch "$C/.batch-attn-last" "$C/.batch-notif-last"
bash "$SCRIPT"
check "finished OK: telegram OK logged" 'lastlog | grep -q "telegram OK (stop)"'
check "finished OK: sentinel removed" '[ ! -f "$C/.batch-active" ]'
check "finished OK: markers cleared" '[ ! -f "$C/.batch-attn-last" ] && [ ! -f "$C/.batch-notif-last" ]'

echo "== 3. finished + send FAILED -> sentinel KEPT (C2 regression)"
reset_state; resp_fail
touch "$C/.batch-active"; sleep 1
echo "resumo" > "$C/.batch-summary.md"
bash "$SCRIPT"
check "finished FAIL: telegram FAILED logged" 'lastlog | grep -q "telegram FAILED (stop)"'
check "finished FAIL: sentinel KEPT for retry" '[ -f "$C/.batch-active" ]'

echo "== 4. ...then send OK on the next stop -> now cleared (retry works)"
resp_ok
bash "$SCRIPT"
check "retry: sentinel cleared after OK" '[ ! -f "$C/.batch-active" ]'

echo "== 5. stale summary + OK -> ATTENTION, sentinel kept, then debounced"
reset_state; resp_ok
echo "resumo velho" > "$C/.batch-summary.md"; sleep 1
touch "$C/.batch-active"
bash "$SCRIPT"
check "stale OK: sentinel kept" '[ -f "$C/.batch-active" ]'
check "stale OK: attn marker dropped" '[ -f "$C/.batch-attn-last" ]'
bash "$SCRIPT"
check "stale OK: 2nd stop debounced" 'lastlog | grep -q "skip stale-stop attention"'

echo "== 6. stale summary + FAILED -> attn marker NOT set (retry preserved)"
reset_state; resp_fail
echo "resumo velho" > "$C/.batch-summary.md"; sleep 1
touch "$C/.batch-active"
bash "$SCRIPT"
check "stale FAIL: telegram FAILED logged" 'lastlog | grep -q "telegram FAILED (stop)"'
check "stale FAIL: attn marker NOT set" '[ ! -f "$C/.batch-attn-last" ]'

echo "== 7. debounce EXPIRED -> ATTENTION fires again"
resp_ok
touch "$C/.batch-attn-last"
touch -t 200001010000 "$C/.batch-attn-last"   # 26 years ago -> outside 30 min
bash "$SCRIPT"
check "expired debounce: telegram OK sent" 'lastlog | grep -q "telegram OK (stop)"'

echo "== 8. --notification + OK -> marker set; 2nd debounced"
reset_state; resp_ok
touch "$C/.batch-active"
echo '{"session_id":"x","message":"Claude needs your permission to use Bash","title":"Claude Code"}' \
  | bash "$SCRIPT" --notification
check "notif OK: marker dropped" '[ -f "$C/.batch-notif-last" ]'
echo '{"message":"again"}' | bash "$SCRIPT" --notification
check "notif OK: 2nd ping debounced" 'lastlog | grep -q "skip notification ping"'

echo "== 9. --notification + FAILED -> marker NOT set (H4 regression)"
reset_state; resp_fail
touch "$C/.batch-active"
echo '{"message":"perm"}' | bash "$SCRIPT" --notification
check "notif FAIL: telegram FAILED logged" 'lastlog | grep -q "telegram FAILED (notification)"'
check "notif FAIL: marker NOT set" '[ ! -f "$C/.batch-notif-last" ]'

echo "== 10. --notification WITHOUT sentinel -> silent no-op"
reset_state
echo '{"message":"x"}' | bash "$SCRIPT" --notification
check "notif no sentinel: no marker" '[ ! -f "$C/.batch-notif-last" ]'
check "notif no sentinel: no log" '[ ! -f "$LOG" ]'

echo "== 11. --start -> sends, touches no state"
reset_state; resp_ok
bash "$SCRIPT" --start "plano X aprovado"
check "start: telegram OK logged" 'lastlog | grep -q "telegram OK (start)"'
check "start: no sentinel/markers created" '[ ! -f "$C/.batch-active" ] && [ ! -f "$C/.batch-blocked" ]'

echo "== 12. BLOCKED + OK -> block marker AND notif debounce set (H1 regression)"
reset_state; resp_ok
touch "$C/.batch-active"
bash "$SCRIPT" "BLOCKED: precisa de decisao sobre schema"
check "blocked: block marker dropped" '[ -f "$C/.batch-blocked" ]'
check "blocked: notif debounce set (suppresses idle double-ping)" '[ -f "$C/.batch-notif-last" ]'
# The idle Notification hook firing right after must now be debounced.
echo '{"message":"idle"}' | bash "$SCRIPT" --notification
check "blocked: following idle ping debounced" 'lastlog | grep -q "skip notification ping"'

echo "== 13. ...then stop -> block marker consumed, stop silent"
bash "$SCRIPT"
check "blocked: stop consumed marker" '[ ! -f "$C/.batch-blocked" ]'
check "blocked: stop silent" 'lastlog | grep -q "skip finished: turn ended on a block"'
check "blocked: sentinel kept" '[ -f "$C/.batch-active" ]'

echo "== 14. UTF-8: mid-char cut invalid raw, valid after iconv -c"
printf 'ça' | tail -c 2 | iconv -f UTF-8 -t UTF-8 > /dev/null 2>&1
check "utf8: raw cut IS invalid (bug is real)" '[ $? -ne 0 ]'
CUT="$(printf 'ça' | tail -c 2 | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null)"
printf '%s' "$CUT" | iconv -f UTF-8 -t UTF-8 > /dev/null 2>&1
check "utf8: iconv -c output valid" '[ $? -eq 0 ]'
B=""; i=0
while [ "$i" -lt 100 ]; do B="${B}aprovação e conclusão çãáéíóú… "; i=$((i + 1)); done
printf '%s' "$B" > "$C/sum-utf8.md"
tail -c 1200 "$C/sum-utf8.md" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null \
  | iconv -f UTF-8 -t UTF-8 > /dev/null 2>&1
check "utf8: 1200-byte excerpt valid after iconv" '[ $? -eq 0 ]'

echo "== 15. log rotation"
reset_state; resp_ok
touch "$C/.batch-active"
mkdir -p "$C/hooks"
head -c 300000 /dev/zero | tr '\0' 'x' > "$LOG"
bash "$SCRIPT" --start "rot"
SZ="$(wc -c < "$LOG")"
check "log rotated under 200KB" '[ "$SZ" -lt 204800 ]'

echo "== 16. --cancel with sentinel -> sends, clears everything"
reset_state; resp_ok
touch "$C/.batch-active" "$C/.batch-blocked" "$C/.batch-attn-last" "$C/.batch-notif-last"
bash "$SCRIPT" --cancel
check "cancel: telegram OK logged" 'lastlog | grep -q "telegram OK (cancel)"'
check "cancel: sentinel + markers cleared" \
  '[ ! -f "$C/.batch-active" ] && [ ! -f "$C/.batch-blocked" ] && [ ! -f "$C/.batch-attn-last" ] && [ ! -f "$C/.batch-notif-last" ]'

echo "== 17. --cancel without sentinel -> logged no-op, nothing sent"
reset_state
bash "$SCRIPT" --cancel
check "cancel idle: logged" 'lastlog | grep -q "cancel: no active batch"'
check "cancel idle: no send attempted" '! grep -q "telegram" "$LOG"'

echo "== 18. conf is PARSED not sourced (C1 regression)"
reset_state; resp_ok
EVIL="$C/.notify-evil.conf"
{
  echo 'TELEGRAM_BOT_TOKEN="123:AAtoken"'
  echo 'TELEGRAM_CHAT_ID="999"'
  echo "\$(touch $T/PWNED)"
  echo "\`touch $T/PWNED2\`"
} > "$EVIL"
# Point the run at the evil conf by swapping it in as the real conf.
cp "$C/.notify.conf" "$C/.notify.conf.bak"
cp "$EVIL" "$C/.notify.conf"
touch "$C/.batch-active"
bash "$SCRIPT" --start "x"
check "conf parse: no code executed from conf" '[ ! -e "$T/PWNED" ] && [ ! -e "$T/PWNED2" ]'
check "conf parse: still delivered" 'lastlog | grep -q "telegram OK (start)"'
cp "$C/.notify.conf.bak" "$C/.notify.conf"

echo "== 19. --notification message with escaped quotes doesn't break send"
reset_state; resp_ok
touch "$C/.batch-active"
printf '{"message":"needs \\"Bash\\" permission","title":"x"}' | bash "$SCRIPT" --notification
check "notif escaped-quote: still delivered" 'lastlog | grep -q "telegram OK (notification)"'

echo "== 20. batch-context.sh (SessionStart)"
reset_state
OUT="$(bash "$CONTEXT")"
check "context: silent without sentinel" '[ -z "$OUT" ]'
touch "$C/.batch-active"
OUT="$(bash "$CONTEXT")"
check "context: reports active batch" 'printf "%s" "$OUT" | grep -q "UNFINISHED BATCH RUN"'
check "context: state in progress" 'printf "%s" "$OUT" | grep -q "in progress"'
# stat order (M1): SINCE must be a real date containing the current year on
# BOTH GNU and BSD, never a format-string literal.
YEAR="$(date +%Y)"
check "context: Active-since has current year (stat portable)" \
  'printf "%s" "$OUT" | grep -q "Active since:.*$YEAR"'
touch "$C/.batch-blocked"
OUT="$(bash "$CONTEXT")"
check "context: reports block" 'printf "%s" "$OUT" | grep -q "manual BLOCK"'

echo
echo "RESULT: $PASS pass, $FAIL fail"
exit "$FAIL"
