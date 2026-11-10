#!/usr/bin/env bash
#
# Test suite for buzzheavier.sh. Runs every command against a local mock of
# the API (tests/mock_server.py) - nothing is sent to buzzheavier.com.
#
# Usage: tests/run.sh          (needs bash, curl and python3)
#
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/../buzzheavier.sh"

PYTHON=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 7))' 2>/dev/null; then
    PYTHON="$candidate"
    break
  fi
done
[[ -n "$PYTHON" ]] || { echo "python3 is required to run the tests" >&2; exit 1; }

WORK="$(mktemp -d)"
LOG="$WORK/requests.log"
: > "$LOG"
"$PYTHON" "$HERE/mock_server.py" "$WORK/port" "$LOG" &
SERVER_PID=$!
cleanup() {
  kill "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

for _ in $(seq 1 50); do
  [[ -s "$WORK/port" ]] && break
  sleep 0.1
done
[[ -s "$WORK/port" ]] || { echo "mock server did not start" >&2; exit 1; }
BASE="http://127.0.0.1:$(cat "$WORK/port")"

export HOME="$WORK/home"
mkdir -p "$HOME"
unset XDG_CONFIG_HOME BUZZHEAVIER_ACCOUNT_ID NO_COLOR
export BUZZHEAVIER_API_BASE="$BASE/api"
export BUZZHEAVIER_UPLOAD_BASE="$BASE"
export BUZZHEAVIER_DOWNLOAD_BASE="https://dl.example.test"
TOKEN="testtoken123"

PASS=0
FAIL=0
OUT="" ERR="" RC=0

# run <args...>   Runs the CLI (stdin closed), captures stdout / stderr / exit code.
run() {
  OUT="$("$CLI" "$@" 2>"$WORK/stderr" </dev/null)"
  RC=$?
  ERR="$(cat "$WORK/stderr")"
}

pass() { PASS=$(( PASS + 1 )); }
fail() {
  FAIL=$(( FAIL + 1 ))
  printf 'FAIL: %s\n' "$1"
  printf '      rc=%s\n      stdout: %s\n      stderr: %s\n' "$RC" "$OUT" "$ERR"
}
check()       { if [[ "$2" == "$3" ]]; then pass; else fail "$1 (expected '$3', got '$2')"; fi; }
contains()    { if [[ "$2" == *"$3"* ]]; then pass; else fail "$1 (missing '$3')"; fi; }
not_contains() { if [[ "$2" != *"$3"* ]]; then pass; else fail "$1 (unexpected '$3')"; fi; }

last_req() { tail -n 1 "$LOG"; }
req_field() { last_req | cut -f "$1"; }
req_count() { wc -l < "$LOG" | tr -d '[:space:]'; }

have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

# ---- fixtures
FILES="$WORK/files"
mkdir -p "$FILES"
printf 'hello world\n' > "$FILES/plain.txt"
printf 'second\n' > "$FILES/second.txt"
printf 'tricky\n' > "$FILES/my file [a]{b} 100%.txt"
printf 'hash\n' > "$FILES/bad #name.txt"
printf 'utf8\n' > "$FILES/zażółć gęślą.txt"
: > "$FILES/empty.bin"

echo "== basics"
run version;      check "version exit code" "$RC" 0; contains "version output" "$OUT" "buzzheavier-cli 2."
run --version;    check "--version exit code" "$RC" 0
run help;         check "help exit code" "$RC" 0; contains "help lists upload" "$OUT" "upload"
run upload -h;    check "-h after a command shows help" "$RC" 0
run;              check "no arguments is a usage error" "$RC" 2; check "usage goes to stderr" "$OUT" ""
run nonsense;     check "unknown command exit code" "$RC" 2; contains "unknown command message" "$ERR" "Unknown command"
run rename onlyone; check "missing argument is a usage error" "$RC" 2

echo "== locations"
run locations --json
check "locations exit code" "$RC" 0
contains "locations --json prints the response" "$OUT" '"loc000000001"'
not_contains "status messages stay off stdout" "$OUT" "HTTP"
run locations
check "locations (formatted) exit code" "$RC" 0
contains "locations lists names" "$OUT" "Western Europe"

echo "== anonymous upload"
run upload "$FILES/plain.txt"
check "upload exit code" "$RC" 0
contains "stdout is only the download link" "$OUT" "https://dl.example.test/up"
check "stdout is a single line" "$(printf '%s\n' "$OUT" | wc -l | tr -d '[:space:]')" 1
check "upload uses PUT" "$(req_field 1)" "PUT"
check "upload path" "$(req_field 2)" "/plain.txt"
check "anonymous upload sends no token" "$(req_field 3)" "-"
check "whole file was sent" "$(req_field 4)" 12

run upload "$FILES/my file [a]{b} 100%.txt"
check "special characters: exit code" "$RC" 0
check "special characters are percent-encoded" "$(req_field 2)" "/my%20file%20%5Ba%5D%7Bb%7D%20100%25.txt"
check "special characters: whole file was sent" "$(req_field 4)" 7

run upload "$FILES/bad #name.txt"
check "name rejected by the server: exit code" "$RC" 1
check "'#' is encoded, not treated as a fragment" "$(req_field 2)" "/bad%20%23name.txt"
contains "server message is shown" "$ERR" "the Name field is invalid"
contains "a way out is suggested" "$ERR" "-n <name>"

run upload "$FILES/zażółć gęślą.txt"
check "UTF-8 name: exit code" "$RC" 0
check "UTF-8 name is encoded bytewise" "$(req_field 2)" "/za%C5%BC%C3%B3%C5%82%C4%87%20g%C4%99%C5%9Bl%C4%85.txt"

run upload "$FILES/empty.bin"
check "empty file uploads" "$RC" 0

run upload "$FILES/plain.txt" --name "renamed copy.txt"
check "--name exit code" "$RC" 0
check "--name is used in the URL" "$(req_field 2)" "/renamed%20copy.txt"

run upload "$FILES/plain.txt" --json
check "upload --json exit code" "$RC" 0
contains "upload --json prints the response" "$OUT" '"code"'

run -q upload "$FILES/plain.txt"
check "-q upload exit code" "$RC" 0
check "-q prints nothing on stderr" "$ERR" ""

before="$(req_count)"
run upload "$FILES/does-not-exist.txt"
check "missing file fails" "$RC" 1
check "missing file sends nothing" "$(req_count)" "$before"
run upload "$FILES/plain.txt" "$FILES/second.txt" --name x
check "--name with several files is rejected" "$RC" 1
run upload
check "upload without files is a usage error" "$RC" 2

echo "== upload options"
run upload "$FILES/plain.txt" --note 'héllo + "note" / ok?'
check "note upload exit code" "$RC" 0
check "note survives base64 + URL encoding" "$(req_field 5)" 'note=héllo + "note" / ok?'
run upload "$FILES/plain.txt" -l loc000000001
check "location upload exit code" "$RC" 0
check "locationId is passed" "$(req_field 2)" "/plain.txt?locationId=loc000000001"

echo "== authenticated upload"
before="$(req_count)"
run upload "$FILES/plain.txt" -d dir000000001
check "upload into a directory needs a token" "$RC" 1
check "no request without a token" "$(req_count)" "$before"
contains "missing token is explained" "$ERR" "set-token"

export BUZZHEAVIER_ACCOUNT_ID="$TOKEN"
run upload "$FILES/plain.txt" -d dir000000001
check "auth upload exit code" "$RC" 0
check "auth upload path" "$(req_field 2)" "/dir000000001/plain.txt"
check "auth upload sends the bearer token" "$(req_field 3)" "Bearer $TOKEN"

run upload "$FILES/plain.txt" "$FILES/missing.txt" "$FILES/second.txt" -d dir000000001
check "partial failure returns 1" "$RC" 1
check "the good files are still uploaded" "$(printf '%s\n' "$OUT" | grep -c 'dl.example.test')" 2
contains "partial failure is summarised" "$ERR" "2 of 3"

BUZZHEAVIER_ACCOUNT_ID="wrongtoken" run upload "$FILES/plain.txt" -d dir000000001
check "rejected token fails" "$RC" 1
contains "HTTP status is reported" "$ERR" "HTTP 401"
contains "API error text is reported" "$ERR" "Unauthorized"
check "nothing on stdout after a failed upload" "$OUT" ""

echo "== file manager"
run ls --json
check "ls --json exit code" "$RC" 0
contains "ls --json prints the response" "$OUT" '"children"'
check "ls hits /api/fs" "$(req_field 2)" "/api/fs"
run ls dir000000001 --json
check "ls <id> hits /api/fs/<id>" "$(req_field 2)" "/api/fs/dir000000001"
run ls missing
check "ls on a missing directory fails" "$RC" 1
contains "404 is reported" "$ERR" "HTTP 404"

run mkdir 'a "quoted" \ name' dir000000001
check "mkdir exit code" "$RC" 0
check "mkdir uses POST" "$(req_field 1)" "POST"
check "mkdir path" "$(req_field 2)" "/api/fs/dir000000001"
check "mkdir body is valid, escaped JSON" "$(req_field 5)" '{"name":"a \"quoted\" \\ name"}'
check "mkdir prints the new directory id" "$OUT" "newdir000001"

run rename file00000001 "new name.bin"
check "rename exit code" "$RC" 0
check "rename uses PATCH" "$(req_field 1)" "PATCH"
check "rename body" "$(req_field 5)" '{"name":"new name.bin"}'

run mv file00000001 dir000000001
check "mv exit code" "$RC" 0
check "mv uses PATCH" "$(req_field 1)" "PATCH"
check "mv body" "$(req_field 5)" '{"parentId":"dir000000001"}'

run note file00000001 "a note"
check "note exit code" "$RC" 0
check "note uses PATCH" "$(req_field 1)" "PATCH"
check "note body" "$(req_field 5)" '{"note":"a note"}'

before="$(req_count)"
run rm -y dirA dirB
check "rm exit code" "$RC" 0
check "rm deletes every directory" "$(( $(req_count) - before ))" 2
check "rm uses DELETE" "$(req_field 1)" "DELETE"
check "rm path" "$(req_field 2)" "/api/fs/dirB"
run rm -y dirA missing
check "rm reports partial failure" "$RC" 1

run account --json
check "account exit code" "$RC" 0
contains "account --json prints the response" "$OUT" '"email"'

echo "== legacy command names"
run upload-anon "$FILES/plain.txt" legacy.txt
check "upload-anon exit code" "$RC" 0
check "upload-anon path" "$(req_field 2)" "/legacy.txt"
run upload-anon "$FILES/plain.txt"
check "upload-anon without a name uses the file name" "$(req_field 2)" "/plain.txt"
run upload-auth "$FILES/plain.txt" dir000000001 stored.txt
check "upload-auth exit code" "$RC" 0
check "upload-auth path" "$(req_field 2)" "/dir000000001/stored.txt"
BUZZHEAVIER_ACCOUNT_ID="" run upload-auth "$FILES/plain.txt" dir000000001 stored.txt "$TOKEN"
check "upload-auth with a trailing account id" "$RC" 0
check "trailing account id is used" "$(req_field 3)" "Bearer $TOKEN"
run upload-loc "$FILES/plain.txt" loc.txt loc000000002
check "upload-loc path" "$(req_field 2)" "/loc.txt?locationId=loc000000002"
run upload-note "$FILES/plain.txt" note.txt "legacy note"
check "upload-note note" "$(req_field 5)" "note=legacy note"
before="$(req_count)"
run bulk-upload dir000000001 "$FILES/plain.txt" "$FILES/second.txt"
check "bulk-upload exit code" "$RC" 0
check "bulk-upload sends every file" "$(( $(req_count) - before ))" 2
run get-root --json;                 check "get-root" "$(req_field 2)" "/api/fs"
run get-dir dir000000001 --json;     check "get-dir" "$(req_field 2)" "/api/fs/dir000000001"
run create-dir newdir dir000000001;  check "create-dir" "$(req_field 5)" '{"name":"newdir"}'
run create-dir newdir;               check "create-dir still requires a parent" "$RC" 2
run rename-dir d1 n1;                check "rename-dir" "$(req_field 1)" "PATCH"
run move-file f1 d1;                 check "move-file exit code" "$RC" 0; check "move-file" "$(req_field 5)" '{"parentId":"d1"}'
run add-note-file f1 "n";            check "add-note-file exit code" "$RC" 0; check "add-note-file" "$(req_field 5)" '{"note":"n"}'
run delete-dir d1;                   check "delete-dir" "$(req_field 1)" "DELETE"
run bulk-delete d1 d2;               check "bulk-delete" "$(req_field 2)" "/api/fs/d2"
unset BUZZHEAVIER_ACCOUNT_ID

echo "== configuration"
before="$(req_count)"
run account
check "account without a token fails" "$RC" 1
check "account without a token sends nothing" "$(req_count)" "$before"

run set-token "$TOKEN"
check "set-token exit code" "$RC" 0
check "config file content" "$(cat "$HOME/.config/buzzheavier-cli/config")" "ACCOUNT_ID=$TOKEN"
run config
check "config exit code" "$RC" 0
not_contains "config never prints the full token" "$OUT$ERR" "$TOKEN"
contains "config shows the source" "$OUT" "config file"
run account --json
check "saved token is used" "$RC" 0
check "saved token is sent" "$(req_field 3)" "Bearer $TOKEN"

printf '  ACCOUNT_ID="%s"  \r\n' "$TOKEN" > "$HOME/.config/buzzheavier-cli/config"
run account --json
check "config with quotes, spaces and CRLF is parsed" "$RC" 0

OUT="$(printf '%s\n' "$TOKEN" | "$CLI" set-token 2>"$WORK/stderr")"; RC=$?; ERR="$(cat "$WORK/stderr")"
check "set-token reads the id from stdin" "$RC" 0
check "stdin token is stored" "$(cat "$HOME/.config/buzzheavier-cli/config")" "ACCOUNT_ID=$TOKEN"
run set-token 'bad token"'
check "set-token rejects odd characters" "$RC" 1

run unset-token
check "unset-token exit code" "$RC" 0
if [[ ! -e "$HOME/.config/buzzheavier-cli/config" ]]; then pass; else fail "config file is removed"; fi

echo "== interactive mode"
OUT="$(printf '11\nq\n' | "$CLI" interactive 2>"$WORK/stderr")"; RC=$?; ERR="$(cat "$WORK/stderr")"
check "interactive exit code" "$RC" 0
contains "interactive runs the chosen action" "$OUT" "loc000000001"
OUT="$(printf '10\n4\nmissing\n11\n' | "$CLI" interactive 2>"$WORK/stderr")"; RC=$?; ERR="$(cat "$WORK/stderr")"
check "interactive ends on EOF" "$RC" 0
contains "a failing action does not end the menu" "$OUT" "loc000000001"

if (( have_jq )); then
  echo "== formatted output (jq)"
  export BUZZHEAVIER_ACCOUNT_ID="$TOKEN"
  run ls
  check "ls exit code" "$RC" 0
  contains "ls has a header" "$OUT" "NAME"
  contains "ls marks directories" "$OUT" "Movies/"
  contains "ls shows sizes" "$OUT" "1.5 KB"
  contains "ls shows downloads and date" "$OUT" "7   2025-12-31"
  contains "ls header has the new columns" "$OUT" "CREATED"
  contains "ls shows big sizes" "$OUT" "5 GB"
  contains "ls keeps UTF-8 names" "$OUT" "alpha zażółć.txt"
  check "ls sorts directories first" "$(printf '%s\n' "$OUT" | sed -n 2p | cut -c1-3)" "dir"
  contains "ls names the directory" "$ERR" "Root"
  run ls empty0000000
  check "empty directory exit code" "$RC" 0
  contains "empty directory is reported" "$ERR" "empty"
  run account
  contains "account shows fields" "$OUT" "user@example.test"
  not_contains "account hides nested objects" "$OUT" "settings"
  run locations
  contains "locations table header" "$OUT" "ID"
  run mkdir fromroot
  check "mkdir without a parent uses the root" "$(req_field 2)" "/api/fs/root0000root"
  unset BUZZHEAVIER_ACCOUNT_ID
else
  echo "== formatted output (jq): SKIPPED, jq is not installed"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
