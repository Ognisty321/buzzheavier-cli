#!/usr/bin/env bash
#
# buzzheavier-cli - a Bash command-line client for buzzheavier.com
#   https://github.com/Ognisty321/buzzheavier-cli
#
# Dependencies:
#   - bash, curl
#   - jq (optional: formatted tables; without it raw JSON is printed)
#   - base64 or openssl (only for upload notes)
#
# Output contract:
#   - results (download links, tables, JSON) go to stdout
#   - progress, status and error messages go to stderr
#   - exit code: 0 success, 1 failure (network / API error), 2 usage error
#

VERSION="2.0.0"
PROG="${0##*/}"

set -o pipefail

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
# Sets HTTP_STATUS and RESP_BODY; returns curl's exit code.
# Call it directly (not in $(...)), otherwise the globals are lost.
# The token is handed to curl on stdin, so it never shows up in `ps` output.
http_request() {
  local token="$1"; shift
  local out rc
  local -a base=(--globoff --connect-timeout "$CONNECT_TIMEOUT" -A "buzzheavier-cli/${VERSION}")

  HTTP_STATUS=""
  RESP_BODY=""
  if [[ -n "$token" ]]; then
    out=$(curl "${base[@]}" "$@" -w $'\n%{http_code}' --config - \
      <<<"header = \"Authorization: Bearer ${token}\"")
    rc=$?
  else
    out=$(curl "${base[@]}" "$@" -w $'\n%{http_code}')
    rc=$?
  fi
  (( rc == 0 )) || return "$rc"
  HTTP_STATUS="${out##*$'\n'}"
  RESP_BODY="${out%$'\n'*}"
  return 0
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

  local src="$file"
  # Git Bash / Cygwin: hand curl a Windows-style path. The automatic path
  # conversion of MSYS gives up on names containing characters like {} or #.
  case "${OSTYPE:-}" in
    msys* | cygwin*)
      if have cygpath; then
        src="$(cygpath -m -- "$file" 2>/dev/null)" || src="$file"
        [[ -n "$src" ]] || src="$file"
      fi
      ;;
  esac
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
 ${C_CYAN}Browse${C_RST}
   3) List root directory
   4) List a directory
 ${C_CYAN}Manage${C_RST}
   5) Create directory
   6) Rename file or directory
   7) Move file or directory
   8) Set a file note
   9) Delete file or directory
 ${C_CYAN}Account${C_RST}
  10) Account info
  11) Storage locations
  12) Set account ID
  13) Show config
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
      3) ( cmd_ls ) ;;
      4)
        ask "Directory id: " || break
        if [[ -n "$ASK_REPLY" ]]; then ( cmd_ls "$ASK_REPLY" ); else warn "Directory id is required."; fi
        ;;
      5)
        ask "New directory name: " || break; a="$ASK_REPLY"
        ask "Parent directory id [root]: " || break
        ( cmd_mkdir "$a" "$ASK_REPLY" )
        ;;
      6)
        ask "Id of the file or directory: " || break; a="$ASK_REPLY"
        ask "New name: " || break
        ( cmd_rename "$a" "$ASK_REPLY" )
        ;;
      7)
        ask "Id of the file or directory: " || break; a="$ASK_REPLY"
        ask "Id of the new parent directory: " || break
        ( cmd_move "$a" "$ASK_REPLY" )
        ;;
      8)
        ask "File id: " || break; a="$ASK_REPLY"
        ask "Note text: " || break
        ( cmd_note "$a" "$ASK_REPLY" )
        ;;
      9)
        ask "Id of the file or directory to delete: " || break
        ( cmd_delete_dir "$ASK_REPLY" )
        ;;
      10) ( cmd_account ) ;;
      11) ( cmd_locations ) ;;
      12) ( cmd_set_token "" ) ;;
      13) ( cmd_config ) ;;
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

${O_BOLD}EXAMPLES${O_RST}
  ${PROG} upload video.mp4
  ${PROG} upload *.zip -d <dirId>
  ${PROG} upload report.pdf --note "final version" -l <locationId>
  link=\$(${PROG} -q upload backup.tar.gz)
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
