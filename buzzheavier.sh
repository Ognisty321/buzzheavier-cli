#!/usr/bin/env bash
#
# buzzheavier-cli - a Bash command-line client for buzzheavier.com
#   https://github.com/Ognisty321/buzzheavier-cli
#
# Dependencies:
#   - bash, curl
#   - jq (optional: formatted tables; without it raw JSON is printed)
#   - base64 or openssl (only for upload notes)
#   - grep, sed, tr (only for downloads)
#   - python3 + curl_cffi (optional, recommended for downloads: requests look
#     like a real browser, so the site's browser check blocks them far less)
#
# Output contract:
#   - results (download links, tables, JSON) go to stdout
#   - progress, status and error messages go to stderr
#   - exit code: 0 success, 1 failure (network / API error), 2 usage error
#

VERSION="2.2.0"
PROG="${0##*/}"

set -o pipefail
# Bash 5.2+ gives "&" a meaning in ${var//pattern/replacement}; keep it literal.
shopt -u patsub_replacement 2>/dev/null || true

########################################
# Configuration & global state
########################################
API_BASE="${BUZZHEAVIER_API_BASE:-https://buzzheavier.com/api}"
UPLOAD_BASE="${BUZZHEAVIER_UPLOAD_BASE:-https://w.buzzheavier.com}"
DOWNLOAD_BASE="${BUZZHEAVIER_DOWNLOAD_BASE:-https://buzzheavier.com}"
API_BASE="${API_BASE%/}"
UPLOAD_BASE="${UPLOAD_BASE%/}"
DOWNLOAD_BASE="${DOWNLOAD_BASE%/}"

CONNECT_TIMEOUT=20   # seconds, every request
API_TIMEOUT=60       # seconds, API calls only (uploads have no time limit)
MAX_NAME_LEN=500
MAX_NOTE_LEN=500
CURL_COMMON=(--globoff --connect-timeout "$CONNECT_TIMEOUT" -A "buzzheavier-cli/${VERSION}")

LEGACY_CONFIG_FILE="${HOME}/.config/buzzheavier-cli/config"
CONFIG_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/buzzheavier-cli/config"
# Keep using a pre-existing config from the old default location.
if [[ ! -f "$CONFIG_FILE" && -f "$LEGACY_CONFIG_FILE" ]]; then
  CONFIG_FILE="$LEGACY_CONFIG_FILE"
fi

ACCOUNT_ID=""        # from env or config file (see load_token)
TOKEN_SOURCE="none"  # env | config | none
TOKEN=""             # token used by the current command (see resolve_token)
HTTP_STATUS=""       # set by http_request
RESP_BODY=""         # set by http_request

OPT_JSON=0
OPT_QUIET=0
OPT_YES=0
OPT_NO_COLOR=0
JQ_HINT_SHOWN=0

########################################
# UI helpers
########################################
have() { command -v "$1" >/dev/null 2>&1; }

# C_* colour stderr messages, O_* colour stdout output. Empty when not a TTY.
C_RST="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_DIM="" C_BOLD=""
O_RST="" O_BOLD="" O_BLUE="" O_DIM="" O_CYAN=""
SYM_OK="OK" SYM_ARROW="->" SYM_DOTS="..."

setup_ui() {
  local color=1
  if (( OPT_NO_COLOR )) || [[ -n "${NO_COLOR:-}" || "${TERM:-}" == "dumb" ]]; then
    color=0
  fi
  if (( color )) && [[ -t 2 ]]; then
    C_RST=$'\033[0m' C_RED=$'\033[1;31m' C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m' C_CYAN=$'\033[36m' C_DIM=$'\033[2m' C_BOLD=$'\033[1m'
  fi
  if (( color )) && [[ -t 1 ]]; then
    O_RST=$'\033[0m' O_BOLD=$'\033[1m' O_BLUE=$'\033[1;34m'
    O_DIM=$'\033[2m' O_CYAN=$'\033[36m'
  fi
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*)
      SYM_OK="✔" SYM_ARROW="→" SYM_DOTS="…"
      ;;
  esac
}

step() { (( OPT_QUIET )) || printf '%s %s\n' "${C_CYAN}${SYM_ARROW}${C_RST}" "$*" >&2; }
ok()   { (( OPT_QUIET )) || printf '%s %s\n' "${C_GREEN}${SYM_OK}${C_RST}" "$*" >&2; }
hint() { (( OPT_QUIET )) || printf '%s\n' "${C_DIM}$*${C_RST}" >&2; }
warn() { printf '%s %s\n' "${C_YELLOW}warning:${C_RST}" "$*" >&2; }
err()  { printf '%s %s\n' "${C_RED}error:${C_RST}" "$*" >&2; }

die() { err "$*"; exit 1; }

# die_usage <synopsis>   e.g. die_usage "rename <id> <newName>"
die_usage() {
  err "Wrong arguments."
  printf 'Usage: %s %s\n' "$PROG" "$1" >&2
  printf "Run '%s help' for the full command list.\n" "$PROG" >&2
  exit 2
}

# Ask before destructive actions. Skipped with -y and when stdin is not a
# terminal (so existing scripts keep working unattended).
confirm() {
  (( OPT_YES )) && return 0
  [[ -t 0 ]] || return 0
  local reply
  printf '%s [y/N] ' "$1" >&2
  read -r reply || return 1
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]]
}

human_size() {
  local b="${1:-0}" rem=0 i=0
  local -a units=(B KB MB GB TB)
  while (( b >= 1024 && i < 4 )); do
    rem=$(( b % 1024 ))
    b=$(( b / 1024 ))
    i=$(( i + 1 ))
  done
  if (( i == 0 )); then
    printf '%d B' "$b"
  else
    printf '%d.%d %s' "$b" $(( rem * 10 / 1024 )) "${units[i]}"
  fi
}

########################################
# Encoding helpers
########################################

# Percent-encode every byte outside the RFC 3986 "unreserved" set.
# Pure Bash, so it behaves the same everywhere (UTF-8 names included).
urlencode() {
  local LC_ALL=C
  local s="$1" out="" c hex i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *)
        printf -v hex '%02X' "'$c"
        out+="%${hex: -2}"
        ;;
    esac
  done
  printf '%s' "$out"
}

# JSON string escaping (enough for names and notes)
json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  printf '%s' "$s"
}

base64_encode() {
  if have base64; then
    # Some implementations wrap long output; strip the line breaks.
    printf '%s' "$1" | base64 | tr -d '\r\n'
  elif have openssl; then
    printf '%s' "$1" | openssl base64 -A
  else
    return 1
  fi
}

########################################
# Output helpers
########################################
print_json() {
  local body="${1-$RESP_BODY}"
  [[ -n "$body" ]] || return 0
  if have jq; then
    printf '%s\n' "$body" | jq . 2>/dev/null || printf '%s\n' "$body"
  else
    printf '%s\n' "$body"
  fi
}

jq_hint() {
  (( JQ_HINT_SHOWN )) && return 0
  JQ_HINT_SHOWN=1
  hint "Tip: install 'jq' to get formatted tables instead of raw JSON."
}

# `.data.id` of the last response (falls back to the first "id" without jq)
extract_id() {
  if have jq; then
    printf '%s\n' "$RESP_BODY" | jq -r '.data.id // empty' 2>/dev/null
    return 0
  fi
  printf '%s\n' "$RESP_BODY" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

# Error text of the last response, if the API sent one
api_error_message() {
  local msg=""
  if have jq; then
    msg=$(printf '%s\n' "$RESP_BODY" | jq -r '(.error // .message // empty) | tostring' 2>/dev/null)
  fi
  if [[ -z "$msg" ]]; then
    msg=$(printf '%s\n' "$RESP_BODY" \
      | sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  fi
  printf '%s' "$msg"
}

# print_table <header>   TSV rows on stdin, TSV header as argument ("" = none).
# The last column is left unpadded so wide (non-ASCII) names cannot break it.
print_table() {
  local header="$1" line cell out i last n=0
  local -a rows=() w=() f=()
  [[ -n "$header" ]] && rows+=("$header")
  while IFS= read -r line; do
    [[ -n "$line" ]] && rows+=("$line")
  done
  for line in "${rows[@]}"; do
    IFS=$'\t' read -ra f <<<"$line"
    for (( i = 0; i < ${#f[@]}; i++ )); do
      (( ${#f[i]} > ${w[i]:-0} )) && w[i]=${#f[i]}
    done
  done
  for line in "${rows[@]}"; do
    IFS=$'\t' read -ra f <<<"$line"
    out=""
    last=$(( ${#f[@]} - 1 ))
    for (( i = 0; i <= last; i++ )); do
      if (( i == last )); then
        out+="${f[i]}"
      else
        printf -v cell '%-*s' "${w[i]}" "${f[i]}"
        out+="${cell}  "
      fi
    done
    if [[ -n "$header" ]] && (( n == 0 )); then
      printf '%s%s%s\n' "$O_BOLD" "$out" "$O_RST"
    elif [[ "${f[0]}" == "dir" ]]; then
      printf '%s%s%s\n' "$O_BLUE" "$out" "$O_RST"
    else
      printf '%s\n' "$out"
    fi
    n=$(( n + 1 ))
  done
}

########################################
# Token handling
########################################
valid_token() { [[ "$1" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; }

load_token() {
  ACCOUNT_ID=""
  TOKEN_SOURCE="none"
  if [[ -n "${BUZZHEAVIER_ACCOUNT_ID:-}" ]]; then
    ACCOUNT_ID="$BUZZHEAVIER_ACCOUNT_ID"
    TOKEN_SOURCE="env"
    return 0
  fi
  [[ -f "$CONFIG_FILE" ]] || return 0

  # Parse ACCOUNT_ID=... by hand; never `source` the file.
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ "$line" == ACCOUNT_ID=* ]] || continue
    line="${line#ACCOUNT_ID=}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#\"}"; line="${line%\"}"
    line="${line#\'}"; line="${line%\'}"
    if [[ -n "$line" ]]; then
      ACCOUNT_ID="$line"
      TOKEN_SOURCE="config"
    fi
    break
  done < "$CONFIG_FILE"
}

# resolve_token [explicit]   Sets TOKEN (explicit > env > config) or exits.
# Must not be called inside $(...), or the exit would be swallowed.
resolve_token() {
  TOKEN="${1:-$ACCOUNT_ID}"
  if [[ -z "$TOKEN" ]]; then
    err "This command needs your account ID, and none is configured."
    printf 'Save it once with:  %s set-token\n' "$PROG" >&2
    printf 'or set the BUZZHEAVIER_ACCOUNT_ID environment variable.\n' >&2
    exit 1
  fi
  valid_token "$TOKEN" || die "The account ID contains unexpected characters (spaces, quotes ...)."
}

cmd_set_token() {
  local tok="${1:-}"
  if [[ -z "$tok" ]]; then
    # No argument: read it without echoing, keeping it out of shell history.
    if [[ -t 0 ]]; then
      read -rsp "Account ID (input hidden): " tok || true
      printf '\n' >&2
    else
      IFS= read -r tok || true
    fi
  fi
  tok="${tok%$'\r'}"
  [[ -n "$tok" ]] || die "No account ID given."
  valid_token "$tok" || die "That does not look like an account ID (unexpected characters)."

  local dir="${CONFIG_FILE%/*}"
  ( umask 077 && mkdir -p "$dir" && printf 'ACCOUNT_ID=%s\n' "$tok" > "$CONFIG_FILE" ) \
    || die "Could not write $CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  ok "Account ID saved to $CONFIG_FILE"
  if [[ -n "${BUZZHEAVIER_ACCOUNT_ID:-}" ]]; then
    warn "BUZZHEAVIER_ACCOUNT_ID is set and takes precedence over the saved value."
  fi
  hint "Check it with: $PROG account"
}

cmd_unset_token() {
  if [[ -f "$CONFIG_FILE" ]]; then
    rm -f "$CONFIG_FILE" || die "Could not remove $CONFIG_FILE"
    ok "Removed $CONFIG_FILE"
  else
    hint "Nothing to remove (no config file at $CONFIG_FILE)."
  fi
}

mask_token() {
  local t="$1"
  if (( ${#t} <= 8 )); then
    printf '****'
  else
    printf '%s%s%s' "${t:0:2}" "$SYM_DOTS" "${t: -4}"
  fi
}

cmd_config() {
  local src="not set" tok="-" jq_state="not installed (raw JSON output)"
  case "$TOKEN_SOURCE" in
    env)    src="BUZZHEAVIER_ACCOUNT_ID environment variable" ;;
    config) src="config file" ;;
  esac
  [[ -n "$ACCOUNT_ID" ]] && tok="$(mask_token "$ACCOUNT_ID") (${#ACCOUNT_ID} characters)"
  have jq && jq_state="installed"
  printf '%-14s %s\n' \
    "Version:"     "$VERSION" \
    "Config file:" "$CONFIG_FILE" \
    "Account ID:"  "$tok" \
    "Source:"      "$src" \
    "API:"         "$API_BASE" \
    "Upload:"      "$UPLOAD_BASE" \
    "Download:"    "$DOWNLOAD_BASE" \
    "jq:"          "$jq_state"
}

########################################
# HTTP layer
########################################
status_ok() { [[ "$1" =~ ^2[0-9][0-9]$ ]]; }

# http_request <token|""> <curl args...>
# Sets HTTP_STATUS and RESP_BODY; returns curl's exit code (HTTP_STATUS is
# set even when curl itself fails, e.g. with --fail).
# Call it directly (not in $(...)), otherwise the globals are lost.
# The token is handed to curl on stdin, so it never shows up in `ps` output.
http_request() {
  local token="$1"; shift
  local out rc

  HTTP_STATUS=""
  RESP_BODY=""
  if [[ -n "$token" ]]; then
    out=$(curl "${CURL_COMMON[@]}" "$@" -w $'\n%{http_code}' --config - \
      <<<"header = \"Authorization: Bearer ${token}\"")
    rc=$?
  else
    out=$(curl "${CURL_COMMON[@]}" "$@" -w $'\n%{http_code}')
    rc=$?
  fi
  HTTP_STATUS="${out##*$'\n'}"
  (( rc == 0 )) || return "$rc"
  RESP_BODY="${out%$'\n'*}"
  return 0
}

# Git Bash / Cygwin: hand curl a Windows-style path. The automatic path
# conversion of MSYS gives up on names containing characters like {} or #.
native_path() {
  local p="$1" converted
  case "${OSTYPE:-}" in
    msys* | cygwin*)
      if have cygpath && converted="$(cygpath -m -- "$p" 2>/dev/null)" && [[ -n "$converted" ]]; then
        p="$converted"
      fi
      ;;
  esac
  printf '%s' "$p"
}

# Turn a non-2xx answer into an error message + non-zero return.
require_ok() {
  status_ok "$HTTP_STATUS" && return 0
  local msg
  msg="$(api_error_message)"
  (( OPT_JSON )) && print_json
  err "${1:-Request failed}: HTTP ${HTTP_STATUS}${msg:+ - $msg}"
  case "$HTTP_STATUS" in
    401 | 403) hint "Is your account ID correct? Check with: $PROG config" ;;
  esac
  return 1
}

# api <METHOD> <path> <token|""> [json-payload]
api() {
  local method="$1" path="$2" token="$3"
  local -a args=(-sS --max-time "$API_TIMEOUT" -X "$method" -H "Accept: application/json")
  if (( $# >= 4 )); then
    args+=(-H "Content-Type: application/json" --data-binary "$4")
  fi
  if ! http_request "$token" "${args[@]}" "${API_BASE}${path}"; then
    err "Could not reach ${API_BASE} (see the curl message above)."
    return 1
  fi
  require_ok
}

########################################
# Uploads
########################################

# do_upload <file> <name|""> <parentId|""> <locationId|""> <note|""> <token|"">
# Prints the download link (or raw JSON with --json) on stdout.
do_upload() {
  local file="$1" name="$2" parent="$3" loc="$4" note="$5" token="$6"

  [[ -e "$file" ]] || { err "No such file: $file"; return 1; }
  [[ -f "$file" ]] || { err "Not a regular file: $file"; return 1; }
  [[ -r "$file" ]] || { err "File is not readable: $file"; return 1; }
  [[ -n "$name" ]] || name="${file##*/}"
  [[ "$name" != */* ]] || { err "File name must not contain '/': $name"; return 1; }
  (( ${#name} <= MAX_NAME_LEN )) \
    || { err "File name is too long (${#name} > ${MAX_NAME_LEN} characters): $name"; return 1; }

  local url="${UPLOAD_BASE}/" query=""
  [[ -n "$parent" ]] && url+="$(urlencode "$parent")/"
  url+="$(urlencode "$name")"
  [[ -n "$loc" ]] && query+="&locationId=$(urlencode "$loc")"
  if [[ -n "$note" ]]; then
    (( ${#note} <= MAX_NOTE_LEN )) \
      || { err "Note is too long (${#note} > ${MAX_NOTE_LEN} characters)."; return 1; }
    local encoded
    encoded="$(base64_encode "$note")" \
      || { err "Neither 'base64' nor 'openssl' found; cannot encode the note."; return 1; }
    query+="&note=$(urlencode "$encoded")"
  fi
  [[ -n "$query" ]] && url+="?${query:1}"

  local src
  src="$(native_path "$file")"
  # curl treats "-T -" and "-T ." as stdin; make bare names unambiguous.
  [[ "$src" == */* ]] || src="./$src"

  local size
  size="$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')"
  step "Uploading ${name} ($(human_size "${size:-0}"))${parent:+ to directory ${parent}}"

  local -a args=(-T "$src")
  if (( OPT_QUIET )) || [[ ! -t 2 ]]; then
    args+=(-sS)
  else
    args+=(-#)   # progress bar on stderr
  fi

  if ! http_request "$token" "${args[@]}" "$url"; then
    err "Upload failed: ${name} (see the curl message above)."
    return 1
  fi
  if ! require_ok "Upload failed: ${name}"; then
    # The server refuses some characters in names (for example '#').
    if [[ "$HTTP_STATUS" == 400 ]]; then
      hint "If the server does not accept this file name, pick another one with: -n <name>"
    fi
    return 1
  fi

  if (( OPT_JSON )); then
    print_json
    return 0
  fi
  local id
  id="$(extract_id)"
  if [[ -n "$id" ]]; then
    ok "Uploaded ${name}"
    printf '%s/%s\n' "$DOWNLOAD_BASE" "$id"
  else
    warn "Upload finished, but the response contains no file id:"
    print_json
  fi
}

# upload <file>... [-d dirId] [-n name] [-l locationId] [--note text]
cmd_upload() {
  local synopsis="upload <file>... [-d <dirId>] [-n <name>] [-l <locationId>] [--note <text>]"
  local parent="" name="" loc="" note="" file
  local -a files=()

  while (( $# )); do
    case "$1" in
      -d | --dir | --parent) (( $# >= 2 )) || die_usage "$synopsis"; parent="$2"; shift 2 ;;
      -n | --name)           (( $# >= 2 )) || die_usage "$synopsis"; name="$2";   shift 2 ;;
      -l | --location)       (( $# >= 2 )) || die_usage "$synopsis"; loc="$2";    shift 2 ;;
      -N | --note)           (( $# >= 2 )) || die_usage "$synopsis"; note="$2";   shift 2 ;;
      --dir=*)      parent="${1#*=}"; shift ;;
      --name=*)     name="${1#*=}";   shift ;;
      --location=*) loc="${1#*=}";    shift ;;
      --note=*)     note="${1#*=}";   shift ;;
      --) shift; while (( $# )); do files+=("$1"); shift; done ;;
      -?*) err "Unknown option for upload: $1"; die_usage "$synopsis" ;;
      *) files+=("$1"); shift ;;
    esac
  done

  (( ${#files[@]} >= 1 )) || die_usage "$synopsis"
  if [[ -n "$name" ]] && (( ${#files[@]} > 1 )); then
    die "--name can only be used when uploading a single file."
  fi

  # Only uploads into a directory are authenticated; plain uploads are anonymous.
  TOKEN=""
  [[ -n "$parent" ]] && resolve_token ""

  local failed=0 total=${#files[@]}
  for file in "${files[@]}"; do
    do_upload "$file" "$name" "$parent" "$loc" "$note" "$TOKEN" || failed=$(( failed + 1 ))
  done
  if (( total > 1 )); then
    if (( failed )); then
      warn "$(( total - failed )) of ${total} files uploaded, ${failed} failed."
    else
      ok "All ${total} files uploaded."
    fi
  fi
  (( failed == 0 ))
}

# --- legacy upload commands (kept for backwards compatibility) ---
cmd_upload_anon() {
  (( $# >= 1 )) || die_usage "upload-anon <filePath> [fileName]"
  do_upload "$1" "${2:-}" "" "" "" ""
}

cmd_upload_auth() {
  (( $# >= 2 )) || die_usage "upload-auth <filePath> <parentId> [fileName] [account_id]"
  resolve_token "${4:-}"
  do_upload "$1" "${3:-}" "$2" "" "" "$TOKEN"
}

cmd_upload_loc() {
  (( $# >= 3 )) || die_usage "upload-loc <filePath> <fileName> <locationId>"
  do_upload "$1" "$2" "" "$3" "" ""
}

cmd_upload_note() {
  (( $# >= 3 )) || die_usage "upload-note <filePath> <fileName> <noteString>"
  do_upload "$1" "$2" "" "" "$3" ""
}

cmd_bulk_upload() {
  (( $# >= 2 )) || die_usage "bulk-upload <parentId> <file1> [file2] ..."
  local parent="$1"; shift
  cmd_upload --dir "$parent" -- "$@"
}

########################################
# Downloads
########################################
# BuzzHeavier has no download API. The file page carries the file name and a
# short-lived link; requesting that link the way the page does (as an htmx
# request) answers with an HX-Redirect header pointing at the real file.
# A direct file link copied in a browser skips both steps.
#
# All download requests go through dl_fetch. When Python with curl_cffi is
# available it sends them with a real browser's TLS/HTTP2 fingerprint (the site
# often answers plain curl with a browser check); otherwise plain curl is used.
# BUZZHEAVIER_DOWNLOADER=auto|cffi|curl picks the transport,
# BUZZHEAVIER_IMPERSONATE the browser curl_cffi pretends to be.

DOWNLOADER="${BUZZHEAVIER_DOWNLOADER:-auto}"
IMPERSONATE="${BUZZHEAVIER_IMPERSONATE:-chrome}"
DL_BACKEND=""   # cffi | curl, decided once by pick_backend
CFFI_PY=""      # Python interpreter that has curl_cffi
DL_COOKIES=""   # cookie jar shared by the requests of one run (cffi only)

# The curl_cffi side of dl_fetch. Same options as dl_fetch, plus --cookies,
# --impersonate and --connect-timeout. Prints like curl -w '\n%{http_code}'
# (nothing extra with "--out -") and exits with curl-style codes.
read -r -d '' CFFI_HELPER <<'PYEOF'
import sys
sys.path[:] = [p for p in sys.path if p not in ("", ".")]  # never import from the cwd
import json, os, time
try:
    from curl_cffi import requests
except Exception as e:
    sys.stderr.write("curl_cffi: cannot be loaded (%s)\n" % e)
    sys.exit(2)

head = include = location = resume = progress = fail = False
out = cookie_file = url = max_time = None
connect_timeout = 20.0
impersonate = "chrome"
headers = {}
it = iter(sys.argv[1:])
for a in it:
    if a == "--head": head = True
    elif a == "--include": include = True
    elif a == "--location": location = True
    elif a == "--resume": resume = True
    elif a == "--progress": progress = True
    elif a == "--fail": fail = True
    elif a == "--out": out = next(it)
    elif a == "--header":
        k, _, v = next(it).partition(":")
        headers[k.strip()] = v.strip()
    elif a == "--max-time": max_time = float(next(it))
    elif a == "--connect-timeout": connect_timeout = float(next(it))
    elif a == "--cookies": cookie_file = next(it)
    elif a == "--impersonate": impersonate = next(it)
    else: url = a

to_file = out not in (None, "-")
status = 0
session = requests.Session(impersonate=impersonate)

if cookie_file and os.path.exists(cookie_file):
    try:
        with open(cookie_file, encoding="utf-8") as f:
            for name, value, domain, path in json.load(f):
                session.cookies.set(name, value, domain=domain, path=path)
    except Exception:
        pass

def finish(code):
    if out != "-":
        sys.stdout.buffer.write(b"\n%03d" % status)  # 000 = no answer, as in curl
    sys.stdout.flush()
    if cookie_file:
        try:
            jar = [[c.name, c.value, c.domain, c.path] for c in session.cookies.jar]
            with open(cookie_file, "w", encoding="utf-8") as f:
                json.dump(jar, f)
        except Exception:
            pass
    sys.exit(code)

def fail_with(e):
    code = getattr(e, "code", None)
    try:
        code = int(code)
    except (TypeError, ValueError):
        code = 28 if isinstance(e, requests.exceptions.Timeout) else 7
    sys.stderr.write("curl_cffi: %s\n" % e)
    finish(code or 7)

offset = 0
if resume and to_file and os.path.exists(out):
    offset = os.path.getsize(out)
    if offset:
        headers["Range"] = "bytes=%d-" % offset

# Whole-request limit for page/API calls; downloads only give up when stalled.
timeout = max_time if max_time else (connect_timeout, 120)
try:
    r = session.request("HEAD" if head else "GET", url, headers=headers,
                        allow_redirects=location, timeout=timeout, stream=True)
except Exception as e:
    fail_with(e)
status = r.status_code

if fail and status >= 400:
    r.close()
    finish(22)

w = sys.stdout.buffer
try:
    if include or head:
        lines = ["HTTP/1.1 %d %s" % (status, r.reason or "")]
        lines += ["%s: %s" % kv for kv in r.headers.multi_items()]
        w.write(("\r\n".join(lines) + "\r\n\r\n").encode("utf-8", "replace"))
    if head:
        r.close()
        finish(0)
    if not to_file:
        for chunk in r.iter_content(chunk_size=65536):
            w.write(chunk)
        finish(0)

    if status != 206:
        offset = 0  # the server sent the whole file
    total = int(r.headers.get("content-length") or 0)
    total = total + offset if total else 0
    done, last = offset, 0.0
    def bar(final=False):
        if total:
            pct = min(done * 100.0 / total, 100.0)
            hashes = "#" * int(pct * 0.6)
            sys.stderr.write("\r%-60s %5.1f%%" % (hashes, pct))
        else:
            sys.stderr.write("\r%d bytes" % done)
        if final:
            sys.stderr.write("\n")
        sys.stderr.flush()
    with open(out, "ab" if offset else "wb") as f:
        for chunk in r.iter_content(chunk_size=65536):
            f.write(chunk)
            done += len(chunk)
            if progress and time.time() - last > 0.2:
                last = time.time()
                bar()
    if progress:
        bar(final=True)
except Exception as e:
    if progress:
        sys.stderr.write("\n")
    fail_with(e)
finish(0)
PYEOF

# Decide once per run whether downloads use curl_cffi or plain curl.
pick_backend() {
  [[ -n "$DL_BACKEND" ]] && return 0
  local c probe='import sys; sys.path[:] = [p for p in sys.path if p not in ("", ".")]; import curl_cffi'
  case "$DOWNLOADER" in
    curl) DL_BACKEND="curl"; return 0 ;;
    auto | cffi | curl_cffi) ;;
    *)
      err "BUZZHEAVIER_DOWNLOADER must be auto, cffi or curl (got: ${DOWNLOADER})"
      return 1
      ;;
  esac
  for c in python3 python py; do
    if have "$c" && "$c" -c "$probe" >/dev/null 2>&1; then
      CFFI_PY="$c"
      DL_BACKEND="cffi"
      DL_COOKIES="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/buzzheavier-cookies.$$")"
      trap '[[ -n "$DL_COOKIES" ]] && rm -f "$DL_COOKIES"' EXIT
      return 0
    fi
  done
  if [[ "$DOWNLOADER" != auto ]]; then
    err "curl_cffi is not available (BUZZHEAVIER_DOWNLOADER=${DOWNLOADER})."
    hint "Install it with: pip install curl_cffi"
    return 1
  fi
  DL_BACKEND="curl"
  hint "curl_cffi not found, downloading with plain curl (pip install curl_cffi to look like a browser)."
}

# dl_fetch [--head] [--include] [--location] [--fail] [--resume] [--progress]
#          [--max-time <s>] [--header <h>]... [--out <file|->] <url>
# Like http_request: sets HTTP_STATUS (and RESP_BODY without --out) and
# returns the transport's exit code. With "--out -" the body goes to stdout.
dl_fetch() {
  pick_backend || return 1
  local -a cargs=() pargs=()
  local out="" url="" progress=0 rc
  while (( $# )); do
    case "$1" in
      --head)     cargs+=(-I);     pargs+=(--head) ;;
      --include)  cargs+=(-i);     pargs+=(--include) ;;
      --location) cargs+=(-L);     pargs+=(--location) ;;
      --fail)     cargs+=(--fail); pargs+=(--fail) ;;
      --resume)   cargs+=(-C -);   pargs+=(--resume) ;;
      --progress) progress=1;      pargs+=(--progress) ;;
      --max-time) cargs+=(--max-time "$2"); pargs+=(--max-time "$2"); shift ;;
      --header)   cargs+=(-H "$2");         pargs+=(--header "$2"); shift ;;
      --out)      out="$2"; shift ;;
      *)          url="$1" ;;
    esac
    shift
  done
  if (( progress )); then cargs+=(-#); else cargs+=(-sS); fi

  HTTP_STATUS=""
  RESP_BODY=""
  if [[ "$DL_BACKEND" == curl ]]; then
    if [[ "$out" == "-" ]]; then
      curl "${CURL_COMMON[@]}" "${cargs[@]}" "$url"
      return
    fi
    [[ -n "$out" ]] && cargs+=(-o "$(native_path "$out")")
    http_request "" "${cargs[@]}" "$url"
    return
  fi

  pargs+=(--impersonate "$IMPERSONATE" --connect-timeout "$CONNECT_TIMEOUT"
          --cookies "$(native_path "$DL_COOKIES")")
  if [[ "$out" == "-" ]]; then
    "$CFFI_PY" -c "$CFFI_HELPER" "${pargs[@]}" --out - "$url"
    return
  fi
  [[ -n "$out" ]] && pargs+=(--out "$(native_path "$out")")
  local res
  res=$("$CFFI_PY" -c "$CFFI_HELPER" "${pargs[@]}" "$url")
  rc=$?
  HTTP_STATUS="${res##*$'\n'}"
  [[ "$HTTP_STATUS" =~ ^[0-9]+$ ]] || HTTP_STATUS="000"
  (( rc == 0 )) || return "$rc"
  RESP_BODY="${res%$'\n'*}"
  return 0
}

DL_ORIGIN=""
DL_ID=""

# parse_link <link|id>   Sets DL_ORIGIN and DL_ID; returns 1 if it is neither.
parse_link() {
  local s="$1" rest
  DL_ORIGIN="$DOWNLOAD_BASE"
  DL_ID=""
  # "buzzheavier.com/abc123" without a scheme
  if [[ "$s" != *://* && "$s" == *.*/* ]]; then
    s="https://$s"
  fi
  case "$s" in
    http://* | https://*)
      rest="${s#*://}"
      [[ "$rest" == */* ]] || return 1
      DL_ORIGIN="${s%%://*}://${rest%%/*}"
      s="${rest#*/}"
      ;;
  esac
  s="${s%%[?#]*}"
  s="${s%%/*}"
  [[ "$s" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  DL_ID="$s"
}

# Decode the HTML entities that can show up in a page title.
html_unescape() {
  local s="$1" code char re='&#([0-9]+);' dq='"' sq="'"
  s="${s//&lt;/<}"
  s="${s//&gt;/>}"
  s="${s//&quot;/$dq}"
  s="${s//&apos;/$sq}"
  while [[ "$s" =~ $re ]]; do
    code="${BASH_REMATCH[1]}"
    char="_"
    if (( ${#code} <= 3 && 10#$code >= 32 && 10#$code < 127 )); then
      printf -v char '%b' "\\0$(printf '%03o' "$(( 10#$code ))")"
    fi
    s="${s//&#${code};/$char}"
  done
  s="${s//&amp;/&}"
  printf '%s' "$s"
}

# Make a server-supplied name safe to use as a local file name: no path
# separators, no control characters, never "." or "..".
safe_filename() {
  local n="$1" bad='[<>:"|?*]'
  n="$(printf '%s' "$n" | tr -d '\000-\037\177')"
  n="${n//\//_}"
  n="${n//\\/_}"
  case "${OSTYPE:-}" in
    msys* | cygwin*) n="${n//$bad/_}" ;;   # not allowed in Windows file names
  esac
  n="${n#"${n%%[![:space:]]*}"}"
  n="${n%"${n##*[![:space:]]}"}"
  [[ "$n" == "." || "$n" == ".." ]] && n=""
  printf '%s' "$n"
}

# File name from the Content-Disposition header of a response.
header_filename() {
  local headers value
  headers="$(printf '%s\n' "$1" | tr -d '\r')"
  value="$(printf '%s\n' "$headers" \
    | sed -n "s/^[Cc]ontent-[Dd]isposition:.*filename\*=[Uu][Tt][Ff]-8''\([^;]*\).*/\1/p" | tail -n 1)"
  if [[ -n "$value" ]]; then
    printf '%b' "${value//%/\\x}"   # percent-decoding
    return 0
  fi
  printf '%s\n' "$headers" \
    | sed -n 's/^[Cc]ontent-[Dd]isposition:.*filename="\([^"]*\)".*/\1/p' | tail -n 1
}

# What the two ways of locating a file hand to do_download:
DL_NAME=""      # file name, already safe to use locally
DL_SIZE=""      # human-readable size, may be empty
DL_PAGE_URL=""  # file page (empty for direct links)
DL_LINK=""      # the page's download link, still to be resolved
DL_DIRECT=""    # URL of the file itself

# probe_direct_link <url> <id>
# A direct file link, e.g. from "Copy download link" on the file page.
probe_direct_link() {
  local bytes
  DL_DIRECT="$1"
  DL_ID="$2"
  DL_PAGE_URL=""
  DL_LINK=""
  DL_SIZE=""
  if ! dl_fetch --head --max-time "$API_TIMEOUT" "$DL_DIRECT"; then
    err "Could not reach the download server (see the message above)."
    return 1
  fi
  if ! status_ok "$HTTP_STATUS"; then
    err "The direct link was refused (HTTP ${HTTP_STATUS})."
    hint "Direct links expire - copy a fresh one from the file page."
    return 1
  fi
  DL_NAME="$(safe_filename "$(header_filename "$RESP_BODY")")"
  [[ -n "$DL_NAME" ]] || DL_NAME="$DL_ID"
  bytes="$(printf '%s\n' "$RESP_BODY" | tr -d '\r' \
    | sed -n 's/^[Cc]ontent-[Ll]ength:[[:space:]]*\([0-9][0-9]*\)$/\1/p' | tail -n 1)"
  [[ -n "$bytes" ]] && DL_SIZE="$(human_size "$bytes")"
  return 0
}

# read_file_page <link|id> <alt 0|1>
# Reads name, size and the download link from the public file page.
read_file_page() {
  local target="$1" alt="$2" origin
  DL_DIRECT=""
  parse_link "$target" || { err "Not a BuzzHeavier link or file id: $target"; return 1; }
  origin="$DL_ORIGIN"
  DL_PAGE_URL="${origin}/${DL_ID}"

  if ! dl_fetch --max-time "$API_TIMEOUT" "$DL_PAGE_URL"; then
    err "Could not reach ${origin} (see the message above)."
    return 1
  fi
  if ! status_ok "$HTTP_STATUS"; then
    if [[ "$HTTP_STATUS" == 404 ]]; then
      err "File not found (removed or expired?): ${DL_PAGE_URL}"
    elif [[ "$RESP_BODY" == *"Just a moment"* ]]; then
      err "The site answered with a browser check (HTTP ${HTTP_STATUS}) instead of the file page."
      hint "Open ${DL_PAGE_URL} in a browser, use \"Copy download link\" there"
      hint "and pass that link to this command instead."
    else
      err "Could not open ${DL_PAGE_URL}: HTTP ${HTTP_STATUS}"
    fi
    return 1
  fi

  DL_NAME="$(printf '%s\n' "$RESP_BODY" | sed -n 's/.*<title>\(.*\)<\/title>.*/\1/p' | head -n 1)"
  DL_NAME="$(safe_filename "$(html_unescape "$DL_NAME")")"
  [[ -n "$DL_NAME" ]] || DL_NAME="$DL_ID"
  DL_SIZE="$(printf '%s\n' "$RESP_BODY" | sed -n 's/.*class="size">\([^<]*\)<.*/\1/p' | head -n 1)"
  DL_LINK="$(printf '%s\n' "$RESP_BODY" | grep -o 'hx-get="[^"]*/download[^"]*"' | grep -v 'alt=true' | head -n 1)"
  DL_LINK="${DL_LINK#hx-get=\"}"
  DL_LINK="${DL_LINK%\"}"
  DL_LINK="${DL_LINK//&amp;/&}"
  if [[ -z "$DL_LINK" ]]; then
    err "No download link found on ${DL_PAGE_URL}"
    hint "Only links to single files can be downloaded (not directories)."
    return 1
  fi
  case "$DL_LINK" in
    http://* | https://*) ;;
    /*) DL_LINK="${origin}${DL_LINK}" ;;
    *)  DL_LINK="${origin}/${DL_LINK}" ;;
  esac
  if (( alt )); then
    if [[ "$DL_LINK" == *\?* ]]; then DL_LINK+="&alt=true"; else DL_LINK+="?alt=true"; fi
  fi
  return 0
}

# Ask for the real file URL the way the page does; sets DL_DIRECT.
request_direct_url() {
  if ! dl_fetch --include --max-time "$API_TIMEOUT" \
      --header "HX-Request: true" --header "Referer: ${DL_PAGE_URL}" "$DL_LINK"; then
    err "Could not reach ${DL_ORIGIN} (see the message above)."
    return 1
  fi
  DL_DIRECT="$(printf '%s\n' "$RESP_BODY" | tr -d '\r' \
    | sed -n 's/^[Hh][Xx]-[Rr][Ee][Dd][Ii][Rr][Ee][Cc][Tt]:[[:space:]]*//p' | head -n 1)"
  [[ "$DL_DIRECT" == /* ]] && DL_DIRECT="${DL_ORIGIN}${DL_DIRECT}"
  if [[ ! "$DL_DIRECT" =~ ^https?:// || "$DL_DIRECT" == "$DL_PAGE_URL" \
      || "$DL_DIRECT" == "${DL_PAGE_URL}/" ]]; then
    err "The site did not hand out a download link for ${DL_NAME} (HTTP ${HTTP_STATUS})."
    hint "It may be busy, or the site has changed. Try again, or try --alt."
    return 1
  fi
  return 0
}

# do_download <link|id> <output|""> <force 0|1> <alt 0|1>
# Prints the path of the saved file on stdout (nothing when writing to stdout).
do_download() {
  local target="$1" out="$2" force="$3" alt="$4"
  local name size direct dest part rc bytes
  local direct_re='^https?://[^/]+/d/([A-Za-z0-9_-]+)([?#].*)?$'

  # 1. Find the file: its name, size and where to get it from.
  if [[ "$target" =~ $direct_re ]]; then
    probe_direct_link "$target" "${BASH_REMATCH[1]}" || return 1
  else
    read_file_page "$target" "$alt" || return 1
  fi
  name="$DL_NAME"
  size="$DL_SIZE"

  # 2. Where to save it. Decided before anything large is transferred.
  if [[ "$out" == "-" ]]; then
    dest="-"
  elif [[ -z "$out" ]]; then
    dest="$name"
  elif [[ -d "$out" || "$out" == */ ]]; then
    mkdir -p "$out" || { err "Could not create directory: $out"; return 1; }
    dest="${out%/}/${name}"
  else
    dest="$out"
  fi
  if [[ "$dest" != "-" ]]; then
    part="${dest}.part"
    if [[ -d "$dest" ]]; then
      err "A directory with that name is in the way: $dest"
      return 1
    fi
    if [[ -e "$dest" ]] && (( ! force )); then
      err "File already exists: $dest"
      hint "Use --force to overwrite it, or -o <path> to save it somewhere else."
      return 1
    fi
    (( force )) && rm -f "$part"
  fi

  # 3. A link from the file page still has to be turned into the file URL.
  if [[ -z "$DL_DIRECT" ]]; then
    request_direct_url || return 1
  fi
  direct="$DL_DIRECT"

  # 4. Transfer.
  step "Downloading ${name}${size:+ (${size})}"
  local -a args=(--fail --location)
  if ! (( OPT_QUIET )) && [[ -t 2 ]]; then
    args+=(--progress)   # progress bar on stderr
  fi

  if [[ "$dest" == "-" ]]; then
    if ! dl_fetch "${args[@]}" --out - "$direct"; then
      err "Download failed: ${name}"
      return 1
    fi
    ok "Downloaded ${name}"
    return 0
  fi

  if [[ -s "$part" ]]; then
    bytes="$(wc -c < "$part" 2>/dev/null | tr -d '[:space:]')"
    hint "Resuming, $(human_size "${bytes:-0}") already downloaded."
  fi
  dl_fetch "${args[@]}" --resume --out "$part" "$direct"
  rc=$?
  # 416 on a resume means the partial file was already complete.
  if ! { (( rc == 0 )) && status_ok "$HTTP_STATUS"; } \
      && ! [[ "$HTTP_STATUS" == 416 && -s "$part" ]]; then
    [[ "$HTTP_STATUS" == 000 ]] && HTTP_STATUS=""
    err "Download failed: ${name}${HTTP_STATUS:+ (HTTP ${HTTP_STATUS})}"
    if [[ -s "$part" ]]; then
      hint "Partial data kept in ${part} - run the same command again to resume."
    else
      rm -f "$part"
    fi
    return 1
  fi

  mv -f -- "$part" "$dest" || { err "Could not save $dest"; return 1; }
  bytes="$(wc -c < "$dest" 2>/dev/null | tr -d '[:space:]')"
  ok "Saved ${dest} ($(human_size "${bytes:-0}"))"
  printf '%s\n' "$dest"
}

# download <link|id>... [-o <file|dir>] [-f] [--alt]
cmd_download() {
  local synopsis="download <link|id>... [-o <file|dir>] [-f] [--alt]"
  local out="" force=0 alt=0 target
  local -a targets=()

  while (( $# )); do
    case "$1" in
      -o | --output) (( $# >= 2 )) || die_usage "$synopsis"; out="$2"; shift 2 ;;
      --output=*)    out="${1#*=}"; shift ;;
      -f | --force)  force=1; shift ;;
      --alt)         alt=1; shift ;;
      -?*) err "Unknown option for download: $1"; die_usage "$synopsis" ;;
      *) targets+=("$1"); shift ;;
    esac
  done

  (( ${#targets[@]} >= 1 )) || die_usage "$synopsis"
  if (( ${#targets[@]} > 1 )) && [[ -n "$out" && ! -d "$out" && "$out" != */ ]]; then
    die "With several links, -o must name a directory."
  fi

  local failed=0 total=${#targets[@]}
  for target in "${targets[@]}"; do
    do_download "$target" "$out" "$force" "$alt" || failed=$(( failed + 1 ))
  done
  if (( total > 1 )); then
    if (( failed )); then
      warn "$(( total - failed )) of ${total} files downloaded, ${failed} failed."
    else
      ok "All ${total} files downloaded."
    fi
  fi
  (( failed == 0 ))
}

########################################
# Public / account
########################################
cmd_locations() {
  api GET "/locations" "" || return 1
  if (( OPT_JSON )); then print_json; return 0; fi
  if ! have jq; then jq_hint; print_json; return 0; fi

  local rows
  if rows=$(printf '%s\n' "$RESP_BODY" \
      | jq -r '.data[] | [(.id // "-" | tostring), (.name // "" | tostring)] | @tsv' 2>/dev/null) \
      && [[ -n "$rows" ]]; then
    print_table $'ID\tNAME' <<<"$rows"
  else
    print_json
  fi
}

cmd_account() {
  resolve_token "${1:-}"
  api GET "/account" "$TOKEN" || return 1
  if (( OPT_JSON )); then print_json; return 0; fi
  if ! have jq; then jq_hint; print_json; return 0; fi

  local rows
  if rows=$(printf '%s\n' "$RESP_BODY" | jq -r '
        (.data // .)
        | if type != "object" then error("unexpected shape") else . end
        | to_entries[]
        | select((.value | type) != "object" and (.value | type) != "array")
        | ["\(.key):", (.value | if . == null then "-" else tostring end)] | @tsv' 2>/dev/null) \
      && [[ -n "$rows" ]]; then
    print_table "" <<<"$rows"
  else
    print_json
  fi
}

########################################
# File manager
########################################

# Formatted directory listing from RESP_BODY; falls back to JSON when the
# response does not look like a listing.
render_listing() {
  local rows title
  if ! rows=$(printf '%s\n' "$RESP_BODY" | jq -r '
      def isdir: (.isDirectory // .directory // .isDir // false) == true;
      def hs:
        if type != "number" then "-"
        elif . < 1024 then "\(.) B"
        else
          [., 0]
          | until(.[0] < 1024 or .[1] >= 4; [.[0] / 1024, .[1] + 1])
          | "\((.[0] * 10 | floor) / 10) \(["B", "KB", "MB", "GB", "TB"][.[1]])"
        end;
      (.data // .) as $d
      | (if ($d | type) == "array" then $d else $d.children end) as $items
      | if ($items | type) != "array" then error("unexpected shape") else $items end
      | sort_by([(isdir | not), (.name // "" | tostring | ascii_downcase)])
      | .[]
      | [ (if isdir then "dir" else "file" end),
          (.id // "-" | tostring),
          (if isdir then "-" else (.size | hs) end),
          (if isdir then "-" else (.downloads // "-" | tostring) end),
          (.createdAt // "-" | tostring | .[0:10]),
          ((.name // "" | tostring) + (if isdir then "/" else "" end)) ]
      | @tsv' 2>/dev/null); then
    print_json
    return 0
  fi

  title=$(printf '%s\n' "$RESP_BODY" | jq -r '
      .data | select(type == "object")
      | "\(.name // "(unnamed)")  [id: \(.id // "?")]"' 2>/dev/null)
  [[ -n "$title" ]] && hint "Directory: $title"

  if [[ -z "$rows" ]]; then
    hint "(empty directory)"
    return 0
  fi
  print_table $'TYPE\tID\tSIZE\tDL\tCREATED\tNAME' <<<"$rows"

  local cursor
  cursor=$(printf '%s\n' "$RESP_BODY" | jq -r '.data.nextCursor? // empty' 2>/dev/null)
  if [[ -n "$cursor" ]]; then
    warn "More entries exist: the API returned only the first page of this directory."
  fi
  return 0
}

# ls [directoryId] [account_id]
cmd_ls() {
  local id="${1:-}"
  resolve_token "${2:-}"
  local path="/fs"
  [[ -n "$id" ]] && path="/fs/$(urlencode "$id")"
  api GET "$path" "$TOKEN" || return 1
  if (( OPT_JSON )); then print_json; return 0; fi
  if ! have jq; then jq_hint; print_json; return 0; fi
  render_listing
}

# mkdir <name> [parentId] [account_id]    (no parentId = root directory)
cmd_mkdir() {
  (( $# >= 1 )) && [[ -n "$1" ]] || die_usage "mkdir <name> [parentId]"
  local name="$1" parent="${2:-}"
  resolve_token "${3:-}"

  if [[ -z "$parent" ]]; then
    # The API wants an explicit parent, so look up the root directory id first.
    api GET "/fs" "$TOKEN" || return 1
    have jq && parent="$(extract_id)"
    if [[ -z "$parent" ]]; then
      err "Could not determine the root directory id automatically."
      hint "Pass it explicitly: $PROG mkdir <name> <parentId>   (see: $PROG ls)"
      return 1
    fi
  fi

  api POST "/fs/$(urlencode "$parent")" "$TOKEN" "{\"name\":\"$(json_escape "$name")\"}" || return 1
  if (( OPT_JSON )); then print_json; return 0; fi
  ok "Created directory '${name}' in ${parent}"
  local id
  id="$(extract_id)"
  [[ -n "$id" ]] && printf '%s\n' "$id"
  return 0
}

# rename <id> <newName> [account_id]
cmd_rename() {
  (( $# >= 2 )) && [[ -n "$1" && -n "$2" ]] || die_usage "rename <id> <newName>"
  resolve_token "${3:-}"
  api PATCH "/fs/$(urlencode "$1")" "$TOKEN" "{\"name\":\"$(json_escape "$2")\"}" || return 1
  (( OPT_JSON )) && print_json
  ok "Renamed $1 ${SYM_ARROW} $2"
}

# mv <id> <newParentId> [account_id]
# The API docs say PUT for move and note, but the server only accepts PATCH.
cmd_move() {
  (( $# >= 2 )) && [[ -n "$1" && -n "$2" ]] || die_usage "mv <id> <newParentId>"
  resolve_token "${3:-}"
  api PATCH "/fs/$(urlencode "$1")" "$TOKEN" "{\"parentId\":\"$(json_escape "$2")\"}" || return 1
  (( OPT_JSON )) && print_json
  ok "Moved $1 ${SYM_ARROW} directory $2"
}

# note <fileId> <text> [account_id]
cmd_note() {
  (( $# >= 2 )) && [[ -n "$1" ]] || die_usage "note <fileId> <text>"
  resolve_token "${3:-}"
  api PATCH "/fs/$(urlencode "$1")" "$TOKEN" "{\"note\":\"$(json_escape "$2")\"}" || return 1
  (( OPT_JSON )) && print_json
  ok "Note updated for $1"
}

# delete_dirs <id>...   (uses TOKEN)
delete_dirs() {
  local id failed=0 question
  if (( $# == 1 )); then
    question="Delete $1? (a directory is deleted with everything inside it)"
  else
    question="Delete $# items? (directories are deleted with everything inside them)"
  fi
  if ! confirm "$question"; then
    hint "Aborted, nothing was deleted."
    return 1
  fi

  for id in "$@"; do
    if api DELETE "/fs/$(urlencode "$id")" "$TOKEN"; then
      (( OPT_JSON )) && print_json
      ok "Deleted $id"
    else
      failed=$(( failed + 1 ))
    fi
  done
  (( failed == 0 ))
}

# rm <id>...   (the API deletes files as well as directories)
cmd_rm() {
  (( $# >= 1 )) || die_usage "rm <id>..."
  resolve_token ""
  delete_dirs "$@"
}

# delete-dir <directoryId> [account_id]   (legacy form with optional token)
cmd_delete_dir() {
  (( $# >= 1 )) && [[ -n "$1" ]] || die_usage "delete-dir <directoryId> [account_id]"
  resolve_token "${2:-}"
  delete_dirs "$1"
}

########################################
# Interactive menu
########################################
ASK_REPLY=""

# ask <prompt>   Reads a line into ASK_REPLY; returns 1 on EOF.
ask() {
  ASK_REPLY=""
  read -rp "$1" ASK_REPLY || return 1
  ASK_REPLY="${ASK_REPLY%$'\r'}"
  return 0
}

# ask_path <prompt>   Like ask, but strips drag-and-drop quotes and expands ~
ask_path() {
  ask "$1" || return 1
  ASK_REPLY="${ASK_REPLY#\"}"; ASK_REPLY="${ASK_REPLY%\"}"
  ASK_REPLY="${ASK_REPLY#\'}"; ASK_REPLY="${ASK_REPLY%\'}"
  # shellcheck disable=SC2088  # a literal ~ typed by the user, expanded by hand
  case "$ASK_REPLY" in
    "~") ASK_REPLY="$HOME" ;;
    "~/"*) ASK_REPLY="${HOME}/${ASK_REPLY:2}" ;;
  esac
  return 0
}

interactive_menu() {
  local choice a acct
  local -a list=()

  while true; do
    load_token
    acct="not set"
    [[ -n "$ACCOUNT_ID" ]] && acct="$(mask_token "$ACCOUNT_ID")"
    cat >&2 <<EOF

${C_BOLD}Buzzheavier CLI${C_RST} ${C_DIM}v${VERSION} - account ID: ${acct}${C_RST}

 ${C_CYAN}Upload${C_RST}
   1) Upload a file (anonymous)
   2) Upload file(s) into a directory
 ${C_CYAN}Download${C_RST}
   3) Download a file from a link
 ${C_CYAN}Browse${C_RST}
   4) List root directory
   5) List a directory
 ${C_CYAN}Manage${C_RST}
   6) Create directory
   7) Rename file or directory
   8) Move file or directory
   9) Set a file note
  10) Delete file or directory
 ${C_CYAN}Account${C_RST}
  11) Account info
  12) Storage locations
  13) Set account ID
  14) Show config
   q) Quit

EOF
    ask "Choose an option: " || { printf '\n' >&2; break; }
    choice="$ASK_REPLY"

    # Every action runs in a subshell: an error ends the action, not the menu.
    case "$choice" in
      1)
        ask_path "File path: " || break; a="$ASK_REPLY"
        ask "Name to store it under [same as the file]: " || break
        ( cmd_upload_anon "$a" "$ASK_REPLY" )
        ;;
      2)
        ask "Target directory id: " || break; a="$ASK_REPLY"
        list=()
        hint "Enter one file path per line; an empty line starts the upload."
        while ask_path "  file: " && [[ -n "$ASK_REPLY" ]]; do
          list+=("$ASK_REPLY")
        done
        if [[ -z "$a" ]] || (( ${#list[@]} == 0 )); then
          warn "Directory id and at least one file are required."
        else
          ( cmd_upload --dir "$a" -- "${list[@]}" )
        fi
        ;;
      3)
        ask "Link or file id: " || break; a="$ASK_REPLY"
        ask_path "Save to (file or directory) [current directory]: " || break
        if [[ -z "$a" ]]; then
          warn "A link or file id is required."
        elif [[ -n "$ASK_REPLY" ]]; then
          ( cmd_download "$a" -o "$ASK_REPLY" )
        else
          ( cmd_download "$a" )
        fi
        ;;
      4) ( cmd_ls ) ;;
      5)
        ask "Directory id: " || break
        if [[ -n "$ASK_REPLY" ]]; then ( cmd_ls "$ASK_REPLY" ); else warn "Directory id is required."; fi
        ;;
      6)
        ask "New directory name: " || break; a="$ASK_REPLY"
        ask "Parent directory id [root]: " || break
        ( cmd_mkdir "$a" "$ASK_REPLY" )
        ;;
      7)
        ask "Id of the file or directory: " || break; a="$ASK_REPLY"
        ask "New name: " || break
        ( cmd_rename "$a" "$ASK_REPLY" )
        ;;
      8)
        ask "Id of the file or directory: " || break; a="$ASK_REPLY"
        ask "Id of the new parent directory: " || break
        ( cmd_move "$a" "$ASK_REPLY" )
        ;;
      9)
        ask "File id: " || break; a="$ASK_REPLY"
        ask "Note text: " || break
        ( cmd_note "$a" "$ASK_REPLY" )
        ;;
      10)
        ask "Id of the file or directory to delete: " || break
        ( cmd_delete_dir "$ASK_REPLY" )
        ;;
      11) ( cmd_account ) ;;
      12) ( cmd_locations ) ;;
      13) ( cmd_set_token "" ) ;;
      14) ( cmd_config ) ;;
      q | Q | quit | exit) break ;;
      "") ;;
      *) warn "Unknown option: $choice" ;;
    esac
  done
  hint "Bye."
  return 0
}

########################################
# Help
########################################
usage() {
  cat <<EOF
${O_BOLD}buzzheavier-cli ${VERSION}${O_RST} - command-line client for buzzheavier.com

${O_BOLD}USAGE${O_RST}
  ${PROG} [options] <command> [arguments]

${O_BOLD}UPLOAD${O_RST}
  ${O_CYAN}upload${O_RST} <file>... [-d <dirId>] [-n <name>] [-l <locationId>] [--note <text>]
      Upload one or more files and print their download links.
        -d, --dir <dirId>         upload into your directory (needs account ID);
                                  without it the upload is anonymous
        -n, --name <name>         store under another name (single file only)
        -l, --location <id>       storage location (see: ${PROG} locations)
        -N, --note <text>         note shown under the download link

${O_BOLD}DOWNLOAD${O_RST}
  ${O_CYAN}download${O_RST} <link|id>... [-o <file|dir>] [-f] [--alt]
      Download files from BuzzHeavier links and print where they were saved.
        -o, --output <path>       file name, or a directory to save into;
                                  "-" writes the file to stdout
        -f, --force               overwrite an existing file
            --alt                 use the alternative download server
      Run the same command again to resume an interrupted download.
      Direct links ("Copy download link" on a file page) work as well.

${O_BOLD}FILE MANAGER${O_RST} ${O_DIM}(needs account ID)${O_RST}
  ${O_CYAN}ls${O_RST} [dirId]                    List the root or the given directory
  ${O_CYAN}mkdir${O_RST} <name> [parentId]       Create a directory (default parent: root)
  ${O_CYAN}rename${O_RST} <id> <newName>         Rename a file or directory
  ${O_CYAN}mv${O_RST} <id> <newParentId>         Move a file or directory
  ${O_CYAN}note${O_RST} <fileId> <text>          Set or replace the note of a file
  ${O_CYAN}rm${O_RST} <id>...                    Delete files or directories (with their contents)

${O_BOLD}ACCOUNT & SETUP${O_RST}
  ${O_CYAN}account${O_RST}                       Show account information
  ${O_CYAN}locations${O_RST}                     List storage locations (no account needed)
  ${O_CYAN}set-token${O_RST} [account_id]        Save your account ID (prompts when omitted)
  ${O_CYAN}unset-token${O_RST}                   Remove the saved account ID
  ${O_CYAN}config${O_RST}                        Show configuration (account ID is masked)
  ${O_CYAN}interactive${O_RST}                   Menu-driven mode
  ${O_CYAN}help${O_RST}, ${O_CYAN}version${O_RST}

${O_BOLD}OPTIONS${O_RST}
      --json        Print the raw API response instead of formatted output
  -q, --quiet       No progress or status messages (errors are still shown)
  -y, --yes         Do not ask for confirmation before deleting
      --no-color    Disable colours (also: NO_COLOR=1)
  -h, --help        Show this help
  -V, --version     Show the version
      --            Treat everything after it as arguments, not options

${O_BOLD}ENVIRONMENT${O_RST}
  BUZZHEAVIER_ACCOUNT_ID      account ID (overrides the config file)
  BUZZHEAVIER_API_BASE        default: https://buzzheavier.com/api
  BUZZHEAVIER_UPLOAD_BASE     default: https://w.buzzheavier.com
  BUZZHEAVIER_DOWNLOAD_BASE   default: https://buzzheavier.com
  BUZZHEAVIER_DOWNLOADER      auto (default: curl_cffi if installed, else curl) | cffi | curl
  BUZZHEAVIER_IMPERSONATE     browser curl_cffi imitates, default: chrome

${O_BOLD}EXAMPLES${O_RST}
  ${PROG} upload video.mp4
  ${PROG} upload *.zip -d <dirId>
  ${PROG} upload report.pdf --note "final version" -l <locationId>
  link=\$(${PROG} -q upload backup.tar.gz)
  ${PROG} download https://buzzheavier.com/<id> -o ~/Downloads/
  ${PROG} ls --json | jq '.data.children[].name'

${O_BOLD}LEGACY COMMAND NAMES${O_RST} ${O_DIM}(still supported)${O_RST}
  upload-anon, upload-auth, upload-loc, upload-note, bulk-upload, get-root,
  get-dir, create-dir, rename-dir, rename-file, move, move-dir, move-file,
  add-note-file, delete-dir, bulk-delete
  Commands that need the account ID still accept it as a trailing argument.
EOF
}

########################################
# Main
########################################
main() {
  local -a args=() rest=()
  local want_help=0 want_version=0 cmd="" a seen_ddash=0

  # Global options may appear anywhere before a literal `--`.
  while (( $# )); do
    case "$1" in
      --json)         OPT_JSON=1 ;;
      -q | --quiet)   OPT_QUIET=1 ;;
      -y | --yes)     OPT_YES=1 ;;
      --no-color)     OPT_NO_COLOR=1 ;;
      -h | --help)    want_help=1 ;;
      -V | --version) want_version=1 ;;
      --) args+=("$@"); break ;;
      *) args+=("$1") ;;
    esac
    shift
  done

  setup_ui

  if (( want_version )); then
    printf 'buzzheavier-cli %s\n' "$VERSION"
    return 0
  fi
  if (( want_help )); then
    usage
    return 0
  fi
  if (( ${#args[@]} == 0 )) || [[ "${args[0]}" == "--" ]]; then
    usage >&2
    return 2
  fi

  cmd="${args[0]}"
  for a in "${args[@]:1}"; do
    # `upload` parses `--` itself; for other commands just drop the first one.
    if [[ "$a" == "--" && "$cmd" != "upload" ]] && (( ! seen_ddash )); then
      seen_ddash=1
      continue
    fi
    rest+=("$a")
  done

  case "$cmd" in
    help | version | config | set-token | unset-token) ;;
    *) have curl || die "'curl' is required but was not found in PATH." ;;
  esac

  load_token

  case "$cmd" in
    help)        usage ;;
    version)     printf 'buzzheavier-cli %s\n' "$VERSION" ;;

    # Setup
    set-token)   cmd_set_token "${rest[0]:-}" ;;
    unset-token) cmd_unset_token ;;
    config)      cmd_config ;;
    interactive) interactive_menu ;;

    # Uploads
    upload)      cmd_upload "${rest[@]}" ;;
    upload-anon) cmd_upload_anon "${rest[@]}" ;;
    upload-auth) cmd_upload_auth "${rest[@]}" ;;
    upload-loc)  cmd_upload_loc "${rest[@]}" ;;
    upload-note) cmd_upload_note "${rest[@]}" ;;
    bulk-upload) cmd_bulk_upload "${rest[@]}" ;;

    # Downloads
    download | dl | get) cmd_download "${rest[@]}" ;;

    # Public / account
    locations)        cmd_locations ;;
    account | whoami) cmd_account "${rest[0]:-}" ;;

    # File manager
    ls)       cmd_ls "${rest[0]:-}" "${rest[1]:-}" ;;
    get-root) cmd_ls "" "${rest[0]:-}" ;;
    get-dir)
      [[ -n "${rest[0]:-}" ]] || die_usage "get-dir <directoryId> [account_id]"
      cmd_ls "${rest[0]}" "${rest[1]:-}"
      ;;
    mkdir)      cmd_mkdir "${rest[@]}" ;;
    create-dir)
      (( ${#rest[@]} >= 2 )) || die_usage "create-dir <name> <parentId> [account_id]"
      cmd_mkdir "${rest[@]}"
      ;;
    rename | rename-dir | rename-file) cmd_rename "${rest[@]}" ;;
    mv | move | move-dir | move-file)  cmd_move "${rest[@]}" ;;
    note | add-note-file)              cmd_note "${rest[@]}" ;;
    rm | bulk-delete)                  cmd_rm "${rest[@]}" ;;
    delete-dir)                        cmd_delete_dir "${rest[@]}" ;;

    *)
      err "Unknown command: $cmd"
      printf "Run '%s help' to see the available commands.\n" "$PROG" >&2
      return 2
      ;;
  esac
}

main "$@"
exit $?
