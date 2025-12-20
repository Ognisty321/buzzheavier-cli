#!/usr/bin/env bash
#
# Buzzheavier CLI (improved)
#   A Bash CLI for interacting with buzzheavier.com programmatically.
#
# Dependencies:
#   - bash 4+
#   - curl
#   - jq (optional)
#   - base64 or openssl (for upload-note)
#

########################################
# Configuration & Global Variables
########################################
API_BASE="${BUZZHEAVIER_API_BASE:-https://buzzheavier.com/api}"
UPLOAD_BASE="${BUZZHEAVIER_UPLOAD_BASE:-https://w.buzzheavier.com}"
DOWNLOAD_BASE="${BUZZHEAVIER_DOWNLOAD_BASE:-https://buzzheavier.com}"

CONFIG_FILE="${HOME}/.config/buzzheavier-cli/config"

ACCOUNT_ID=""     # Loaded from config (or env)
HTTP_STATUS=""    # Set by curl wrappers

########################################
# Helpers
########################################
have() { command -v "$1" >/dev/null 2>&1; }

log() { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
err() { printf 'Error: %s\n' "$*" >&2; }

die() { err "$*"; exit 1; }

# Best-effort JSON pretty printer
pretty_json() {
  local body="$1"
  if have jq; then
    # jq will error on non-JSON; fall back to raw
    printf '%s\n' "$body" | jq . 2>/dev/null || printf '%s\n' "$body"
  else
    printf '%s\n' "$body"
  fi
}

# Extract `.data.id` from typical upload responses (fallback if jq missing)
extract_upload_id() {
  local body="$1"
  if have jq; then
    printf '%s\n' "$body" | jq -r '.data.id // empty' 2>/dev/null
    return 0
  fi
  # Fallback: naive regex for "id":"..."; take the first match
  printf '%s\n' "$body" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n 1
}

# Minimal JSON string escaping (enough for names/notes)
json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# URL-encode a string (used for query params like note=...)
urlencode() {
  local s="$1"
  if have python3; then
    python3 - "$s" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
    return 0
  fi
  if have jq; then
    printf '%s' "$s" | jq -sRr @uri
    return 0
  fi
  if have perl; then
    perl -MURI::Escape -e 'print uri_escape($ARGV[0]);' "$s"
    return 0
  fi

  # Fallback: enough for base64 strings and common ASCII
  local out="$s"
  out=${out//%/%25}
  out=${out// /%20}
  out=${out//+/%2B}
  out=${out//\//%2F}
  out=${out//=/%3D}
  out=${out//$'\n'/%0A}
  out=${out//$'\r'/%0D}
  printf '%s' "$out"
}

########################################
# Usage
########################################
usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [arguments...]

Config:
  set-token <account_id>
  unset-token
  config              Show config status (does not print the full token)

Interactive:
  interactive

Uploads:
  upload-anon <filePath> <fileName>
  upload-auth <filePath> <parentId> <fileName> [account_id]
  upload-loc  <filePath> <fileName> <locationId>
  upload-note <filePath> <fileName> <noteString>
  bulk-upload <parentId> <file1> [file2] ...

Public / Account:
  locations
  account [account_id]

File Manager:
  get-root [account_id]
  get-dir <directoryId> [account_id]
  create-dir <name> <parentId> [account_id]
  rename-dir <directoryId> <newName> [account_id]
  move-dir <directoryId> <newParentId> [account_id]
  rename-file <fileId> <newName> [account_id]
  move-file <fileId> <newParentId> [account_id]
  add-note-file <fileId> <noteString> [account_id]
  delete-dir <directoryId> [account_id]
  bulk-delete <dirId1> [dirId2] ...

Convenience aliases (same underlying API endpoints):
  ls [directoryId] [account_id]        Alias for get-root/get-dir
  rename <id> <newName> [account_id]   Alias for rename-dir/rename-file
  move   <id> <newParentId> [account_id] Alias for move-dir/move-file
  help | -h | --help

Environment overrides:
  BUZZHEAVIER_ACCOUNT_ID   (takes precedence over config file)
  BUZZHEAVIER_API_BASE     (default: https://buzzheavier.com/api)
  BUZZHEAVIER_UPLOAD_BASE  (default: https://w.buzzheavier.com)
  BUZZHEAVIER_DOWNLOAD_BASE (default: https://buzzheavier.com)

EOF
}

########################################
# Token handling
########################################
load_token_from_config() {
  # Env var wins
  if [[ -n "${BUZZHEAVIER_ACCOUNT_ID:-}" ]]; then
    ACCOUNT_ID="${BUZZHEAVIER_ACCOUNT_ID}"
    return 0
  fi

  [[ -f "$CONFIG_FILE" ]] || return 0

  # Parse ACCOUNT_ID=... without sourcing (avoid executing arbitrary code)
  local line
  line=$(grep -E '^[[:space:]]*ACCOUNT_ID=' "$CONFIG_FILE" 2>/dev/null | head -n 1 || true)
  [[ -n "$line" ]] || return 0

  line=${line#ACCOUNT_ID=}
  # Trim surrounding quotes if present
  line=${line#\"}; line=${line%\"}
  line=${line#\'}; line=${line%\'}
  ACCOUNT_ID="$line"
}

set_token() {
  local newToken="${1:-}"
  [[ -n "$newToken" ]] || die "You must provide an account id. Example: $(basename "$0") set-token YOUR_ACCOUNT_ID"

  mkdir -p "$(dirname "$CONFIG_FILE")"
  # Write as plain text for safe parsing
  printf 'ACCOUNT_ID=%s\n' "$newToken" > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
  log "Account ID saved to $CONFIG_FILE"
}

unset_token() {
  if [[ -f "$CONFIG_FILE" ]]; then
    rm -f "$CONFIG_FILE"
    log "Removed $CONFIG_FILE"
  else
    log "No config file found at $CONFIG_FILE"
  fi
}

get_token_argument_or_config() {
  local passed="${1:-}"
  if [[ -n "$passed" ]]; then
    printf '%s' "$passed"
    return 0
  fi
  if [[ -z "$ACCOUNT_ID" ]]; then
    die "No account id provided and none found in $CONFIG_FILE. Run: $(basename "$0") set-token YOUR_ACCOUNT_ID"
  fi
  printf '%s' "$ACCOUNT_ID"
}

show_config() {
  log "Config file: $CONFIG_FILE"
  if [[ -n "${BUZZHEAVIER_ACCOUNT_ID:-}" ]]; then
    log "Token source: BUZZHEAVIER_ACCOUNT_ID env var"
    log "Account ID: (hidden) length=${#BUZZHEAVIER_ACCOUNT_ID}"
    return 0
  fi

  if [[ -z "$ACCOUNT_ID" ]]; then
    log "Account ID: not set"
    return 0
  fi

  # Mask token display
  local tail="${ACCOUNT_ID: -4}"
  local head="${ACCOUNT_ID:0:2}"
  log "Token source: config file"
  log "Account ID: ${head}…${tail} (length=${#ACCOUNT_ID})"
}

########################################
# curl wrappers (capture body + HTTP status)
########################################
curl_capture() {
  # Usage: curl_capture <curl args...>
  # Sets global HTTP_STATUS, prints body to stdout.
  local out rc
  out=$(curl "$@" -w $'\n%{http_code}')
  rc=$?
  if [[ $rc -ne 0 ]]; then
    HTTP_STATUS=""
    return $rc
  fi
  HTTP_STATUS="${out##*$'\n'}"
  printf '%s' "${out%$'\n'*}"
  return 0
}

api_call() {
  # Usage: api_call <METHOD> <URL> [curl args...]
  local method="$1"; shift
  local url="$1"; shift
  curl_capture -sS -X "$method" "$@" "$url"
}

upload_call() {
  # Usage: upload_call <filePath> <URL> [curl args...]
  local filePath="$1"; shift
  local url="$1"; shift
  curl_capture --progress-bar -sS -T "$filePath" "$@" "$url"
}

status_ok() {
  [[ "$1" =~ ^2[0-9][0-9]$ ]]
}

########################################
# Uploads
########################################
upload_anon() {
  local filePath="${1:-}"
  local fileName="${2:-}"
  [[ -n "$filePath" && -n "$fileName" ]] || die "Usage: upload-anon <filePath> <fileName>"
  [[ -f "$filePath" ]] || die "File does not exist: $filePath"
  (( ${#fileName} <= 500 )) || die "fileName is too long (${#fileName} > 500)"

  log "Uploading (anon): $filePath -> $fileName"
  local body
  if ! body=$(upload_call "$filePath" "${UPLOAD_BASE}/${fileName}"); then
    die "Upload failed (curl error)."
  fi

  log "HTTP: $HTTP_STATUS"
  pretty_json "$body"

  local id
  id=$(extract_upload_id "$body")
  if [[ -n "$id" ]]; then
    log "Download link: ${DOWNLOAD_BASE}/${id}"
  fi
}

upload_auth() {
  local filePath="${1:-}"
  local parentId="${2:-}"
  local fileName="${3:-}"
  local tokenArg="${4:-}"
  [[ -n "$filePath" && -n "$parentId" && -n "$fileName" ]] || die "Usage: upload-auth <filePath> <parentId> <fileName> [account_id]"
  [[ -f "$filePath" ]] || die "File does not exist: $filePath"
  (( ${#fileName} <= 500 )) || die "fileName is too long (${#fileName} > 500)"

  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  log "Uploading (auth): $filePath -> ${parentId}/${fileName}"
  local body
  if ! body=$(upload_call "$filePath" "${UPLOAD_BASE}/${parentId}/${fileName}" -H "Authorization: Bearer $token"); then
    die "Upload failed (curl error)."
  fi

  log "HTTP: $HTTP_STATUS"
  pretty_json "$body"

  local id
  id=$(extract_upload_id "$body")
  if [[ -n "$id" ]]; then
    log "Download link: ${DOWNLOAD_BASE}/${id}"
  fi
}

upload_loc() {
  local filePath="${1:-}"
  local fileName="${2:-}"
  local locationId="${3:-}"
  [[ -n "$filePath" && -n "$fileName" && -n "$locationId" ]] || die "Usage: upload-loc <filePath> <fileName> <locationId>"
  [[ -f "$filePath" ]] || die "File does not exist: $filePath"
  (( ${#fileName} <= 500 )) || die "fileName is too long (${#fileName} > 500)"

  log "Uploading (location=${locationId}): $filePath -> $fileName"
  local body
  if ! body=$(upload_call "$filePath" "${UPLOAD_BASE}/${fileName}?locationId=$(urlencode "$locationId")"); then
    die "Upload failed (curl error)."
  fi

  log "HTTP: $HTTP_STATUS"
  pretty_json "$body"

  local id
  id=$(extract_upload_id "$body")
  if [[ -n "$id" ]]; then
    log "Download link: ${DOWNLOAD_BASE}/${id}"
  fi
}

upload_note() {
  local filePath="${1:-}"
  local fileName="${2:-}"
  local noteString="${3:-}"
  [[ -n "$filePath" && -n "$fileName" && -n "$noteString" ]] || die "Usage: upload-note <filePath> <fileName> <noteString>"
  [[ -f "$filePath" ]] || die "File does not exist: $filePath"
  (( ${#fileName} <= 500 )) || die "fileName is too long (${#fileName} > 500)"
  (( ${#noteString} <= 500 )) || die "noteString is too long (${#noteString} > 500)"

  local encodedNote
  if have base64; then
    # Cross-platform: remove newlines because some base64 implementations wrap output
    encodedNote=$(printf '%s' "$noteString" | base64 | tr -d '\n')
  elif have openssl; then
    encodedNote=$(printf '%s' "$noteString" | openssl base64 -A)
  else
    die "Neither base64 nor openssl found; cannot encode note."
  fi

  # Important: base64 commonly includes +/= which should be URL-encoded in query strings
  local encodedNoteUrl
  encodedNoteUrl=$(urlencode "$encodedNote")

  log "Uploading (with note): $filePath -> $fileName"
  local body
  if ! body=$(upload_call "$filePath" "${UPLOAD_BASE}/${fileName}?note=${encodedNoteUrl}"); then
    die "Upload failed (curl error)."
  fi

  log "HTTP: $HTTP_STATUS"
  pretty_json "$body"

  local id
  id=$(extract_upload_id "$body")
  if [[ -n "$id" ]]; then
    log "Download link: ${DOWNLOAD_BASE}/${id}"
  fi
}

bulk_upload() {
  local parentId="${1:-}"
  shift || true
  [[ -n "$parentId" ]] || die "Usage: bulk-upload <parentId> <file1> [file2] ..."
  [[ $# -ge 1 ]] || die "Usage: bulk-upload <parentId> <file1> [file2] ..."

  local token
  token="$(get_token_argument_or_config "")"

  for filePath in "$@"; do
    if [[ ! -f "$filePath" ]]; then
      warn "Skipping (not a file): $filePath"
      continue
    fi
    local fileName
    fileName="$(basename "$filePath")"
    (( ${#fileName} <= 500 )) || { warn "Skipping (fileName too long): $fileName"; continue; }

    log "Bulk uploading: $fileName -> ${parentId}/${fileName}"
    local body
    if ! body=$(upload_call "$filePath" "${UPLOAD_BASE}/${parentId}/${fileName}" -H "Authorization: Bearer $token"); then
      warn "Upload failed (curl error) for: $fileName"
      continue
    fi

    log "HTTP: $HTTP_STATUS"
    pretty_json "$body"

    local id
    id=$(extract_upload_id "$body")
    if [[ -n "$id" ]]; then
      log "Download link: ${DOWNLOAD_BASE}/${id}"
    fi
    log ""
  done
}

########################################
# Public / Account
########################################
get_locations() {
  log "Fetching storage locations..."
  local body
  if ! body=$(api_call GET "${API_BASE}/locations"); then
    die "Request failed (curl error)."
  fi
  log "HTTP: $HTTP_STATUS"
  pretty_json "$body"
}

get_account() {
  local tokenArg="${1:-}"
  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  log "Fetching account info..."
  local body
  if ! body=$(api_call GET "${API_BASE}/account" -H "Authorization: Bearer $token"); then
    die "Request failed (curl error)."
  fi
  log "HTTP: $HTTP_STATUS"
  pretty_json "$body"
}

########################################
# File Manager
########################################
get_root() {
  local tokenArg="${1:-}"
  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  log "Listing root directory..."
  local body
  if ! body=$(api_call GET "${API_BASE}/fs" -H "Authorization: Bearer $token"); then
    die "Request failed (curl error)."
  fi
  log "HTTP: $HTTP_STATUS"
  pretty_json "$body"
}

get_directory() {
  local directoryId="${1:-}"
  local tokenArg="${2:-}"
  [[ -n "$directoryId" ]] || die "Usage: get-dir <directoryId> [account_id]"

  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  log "Listing directory: $directoryId"
  local body
  if ! body=$(api_call GET "${API_BASE}/fs/${directoryId}" -H "Authorization: Bearer $token"); then
    die "Request failed (curl error)."
  fi
  log "HTTP: $HTTP_STATUS"
  pretty_json "$body"
}

create_directory() {
  local name="${1:-}"
  local parentId="${2:-}"
  local tokenArg="${3:-}"
  [[ -n "$name" && -n "$parentId" ]] || die "Usage: create-dir <name> <parentId> [account_id]"

  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  # Official docs: POST /api/fs/{parentDirectoryId} with JSON { "name": "..." }
  local payload
  payload="{\"name\":\"$(json_escape "$name")\"}"

  log "Creating directory '$name' under parentId='$parentId'..."
  local body
  if ! body=$(api_call POST "${API_BASE}/fs/${parentId}" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$payload"); then
    die "Request failed (curl error)."
  fi
  log "HTTP: $HTTP_STATUS"
  pretty_json "$body"
}

rename_item() {
  local id="${1:-}"
  local newName="${2:-}"
  local tokenArg="${3:-}"
  [[ -n "$id" && -n "$newName" ]] || die "Usage: rename <id> <newName> [account_id]"

  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  local payload
  payload="{\"name\":\"$(json_escape "$newName")\"}"

  log "Renaming item $id -> $newName"
  local body
  if ! body=$(api_call PATCH "${API_BASE}/fs/${id}" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$payload"); then
    die "Request failed (curl error)."
  fi
  log "HTTP: $HTTP_STATUS"
  pretty_json "$body"
}

move_item() {
  local id="${1:-}"
  local newParentId="${2:-}"
  local tokenArg="${3:-}"
  [[ -n "$id" && -n "$newParentId" ]] || die "Usage: move <id> <newParentId> [account_id]"

  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  local payload
  payload="{\"parentId\":\"$(json_escape "$newParentId")\"}"

  log "Moving item $id -> parent $newParentId"
  local body
  if ! body=$(api_call PUT "${API_BASE}/fs/${id}" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$payload"); then
    die "Request failed (curl error)."
  fi
  log "HTTP: $HTTP_STATUS"
  pretty_json "$body"
}

add_note_file() {
  local fileId="${1:-}"
  local noteString="${2:-}"
  local tokenArg="${3:-}"
  [[ -n "$fileId" && -n "$noteString" ]] || die "Usage: add-note-file <fileId> <noteString> [account_id]"

  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  local payload
  payload="{\"note\":\"$(json_escape "$noteString")\"}"

  log "Updating note for file $fileId..."
  local body
  if ! body=$(api_call PUT "${API_BASE}/fs/${fileId}" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$payload"); then
    die "Request failed (curl error)."
  fi
  log "HTTP: $HTTP_STATUS"
  pretty_json "$body"
}

delete_directory() {
  local directoryId="${1:-}"
  local tokenArg="${2:-}"
  [[ -n "$directoryId" ]] || die "Usage: delete-dir <directoryId> [account_id]"

  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  log "Deleting directory: $directoryId"
  local body
  if ! body=$(api_call DELETE "${API_BASE}/fs/${directoryId}" -H "Authorization: Bearer $token"); then
    die "Request failed (curl error)."
  fi
  log "HTTP: $HTTP_STATUS"
  pretty_json "$body"
}

bulk_delete_directories() {
  [[ $# -ge 1 ]] || die "Usage: bulk-delete <dirId1> [dirId2] ..."

  local token
  token="$(get_token_argument_or_config "")"

  for dirId in "$@"; do
    log "Deleting directory: $dirId"
    local body
    if ! body=$(api_call DELETE "${API_BASE}/fs/${dirId}" -H "Authorization: Bearer $token"); then
      warn "Request failed (curl error) for: $dirId"
      continue
    fi
    log "HTTP: $HTTP_STATUS"
    pretty_json "$body"
  done
}

# Convenience alias: ls [id]
ls_cmd() {
  local maybeId="${1:-}"
  local tokenArg="${2:-}"

  if [[ -z "$maybeId" ]]; then
    get_root "$tokenArg"
  else
    get_directory "$maybeId" "$tokenArg"
  fi
}

########################################
# Interactive Menu (kept mostly the same)
########################################
interactive_menu() {
  while true; do
    echo
    echo "========== Buzzheavier CLI Interactive Menu =========="
    echo " 1) Set Token"
    echo " 2) Show Account Info"
    echo " 3) Upload File (Anon)"
    echo " 4) Upload File (Auth)"
    echo " 5) Bulk Upload (Auth)"
    echo " 6) List Root Directory"
    echo " 7) Create Directory"
    echo " 8) Delete Directory"
    echo " 9) Bulk Delete Directories"
    echo "10) Get Storage Locations"
    echo "11) Show Config"
    echo "12) Quit"
    echo "======================================================"
    read -rp "Choose an option (1-12): " choice

    case "$choice" in
      1)
        read -rsp "Enter new account id: " newTok
        echo
        set_token "$newTok"
        load_token_from_config
        ;;
      2)
        get_account
        ;;
      3)
        read -rp "Enter file path: " anonPath
        read -rp "Enter file name as stored: " anonName
        upload_anon "$anonPath" "$anonName"
        ;;
      4)
        read -rp "Enter file path: " authPath
        read -rp "Enter parentId: " pId
        read -rp "Enter file name as stored: " fName
        upload_auth "$authPath" "$pId" "$fName"
        ;;
      5)
        read -rp "Enter parentId for bulk upload: " bParent
        echo "Enter paths for files to upload (space-separated): "
        read -ra fileArray
        bulk_upload "$bParent" "${fileArray[@]}"
        ;;
      6)
        get_root
        ;;
      7)
        read -rp "Enter new directory name: " newDirName
        read -rp "Enter parentId: " cParent
        create_directory "$newDirName" "$cParent"
        ;;
      8)
        read -rp "Enter directoryId to delete: " dId
        delete_directory "$dId"
        ;;
      9)
        echo "Enter directoryIds to bulk-delete (space-separated): "
        read -ra dirArray
        bulk_delete_directories "${dirArray[@]}"
        ;;
      10)
        get_locations
        ;;
      11)
        show_config
        ;;
      12)
        log "Exiting Interactive Mode."
        break
        ;;
      *)
        warn "Invalid choice."
        ;;
    esac
  done
}

########################################
# Main
########################################
load_token_from_config

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

COMMAND="$1"
shift || true

case "$COMMAND" in
  help|-h|--help)
    usage
    ;;

  # Config
  set-token)
    set_token "${1:-}"
    ;;
  unset-token)
    unset_token
    ;;
  config)
    show_config
    ;;

  # Interactive Mode
  interactive)
    interactive_menu
    ;;

  # Uploads
  upload-anon)
    upload_anon "$@"
    ;;
  upload-auth)
    upload_auth "$@"
    ;;
  upload-loc)
    upload_loc "$@"
    ;;
  upload-note)
    upload_note "$@"
    ;;
  bulk-upload)
    bulk_upload "$@"
    ;;

  # Public / Account
  locations)
    get_locations
    ;;
  account)
    get_account "$@"
    ;;

  # File Manager (original names)
  get-root)
    get_root "$@"
    ;;
  get-dir)
    get_directory "$@"
    ;;
  create-dir)
    create_directory "$@"
    ;;
  rename-dir)
    rename_item "$@"
    ;;
  move-dir)
    move_item "$@"
    ;;
  rename-file)
    rename_item "$@"
    ;;
  move-file)
    move_item "$@"
    ;;
  add-note-file)
    add_note_file "$@"
    ;;
  delete-dir)
    delete_directory "$@"
    ;;
  bulk-delete)
    bulk_delete_directories "$@"
    ;;

  # Convenience aliases
  ls)
    ls_cmd "$@"
    ;;
  rename)
    rename_item "$@"
    ;;
  move)
    move_item "$@"
    ;;

  *)
    err "Unknown command: $COMMAND"
    usage
    exit 1
    ;;
esac
