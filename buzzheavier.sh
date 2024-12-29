#!/usr/bin/env bash
#
# buzzheavier.sh: An extended CLI script to interact with Buzzheavier.io
#
# Dependencies:
#   - curl
#   - jq         (optional, for pretty JSON; remove/replace if not available)
#   - base64     (or openssl for base64 fallback)
#   - bash 4+    (for arrays in bulk operations)
#

########################################
# Configuration & Global Variables
########################################
API_BASE="https://buzzheavier.com/api"
FILE_UPLOAD_BASE="https://w.buzzheavier.com"

CONFIG_FILE="${HOME}/.config/buzzheavier-cli/config"

# If a user calls a command that requires token-based auth,
# and they haven't provided a token, we will try to load from $CONFIG_FILE.
ACCOUNT_ID=""  # Will be loaded from config, if present.

########################################
# Helper: usage instructions
########################################
function usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [arguments...]

Commands:

  #--------------------#
  # Config Management  #
  #--------------------#

  set-token <token>
    Saves <token> to config so you don't have to provide it every time.

  #--------------------------#
  # Interactive Mode         #
  #--------------------------#

  interactive
    Launch an interactive menu-driven mode.

  #----------------------------#
  # File Upload Endpoints      #
  #----------------------------#

  upload-anon <filePath> <fileName>
    Upload <filePath> anonymously as <fileName>.

  upload-auth <filePath> <parentId> <fileName> [token]
    Upload <filePath> to a user directory (parentId). Token can be given or read from config.

  upload-loc <filePath> <fileName> <locationId>
    Upload <filePath> to a specific locationId.

  upload-note <filePath> <fileName> <noteString>
    Upload <filePath> with a text note (up to 500 chars). Script base64-encodes the note.

  bulk-upload <parentId> <file1> [file2] [file3] ...
    Upload multiple files to user directory <parentId> in one command.

  #--------------------#
  # Public / Account   #
  #--------------------#

  locations
    Get file storage locations (public).

  account [token]
    Retrieve authenticated account info. Token can be passed or read from config.

  #----------------------#
  # File Manager         #
  #----------------------#

  get-root [token]
    Lists the contents of the root directory.

  get-dir <directoryId> [token]
    Lists the contents of <directoryId>.

  create-dir <name> <parentId> [token]
    Create a new directory named <name> under <parentId>.

  rename-dir <directoryId> <newName> [token]
    Rename directory <directoryId> to <newName>.

  move-dir <directoryId> <newParentId> [token]
    Move directory <directoryId> under <newParentId>.

  rename-file <fileId> <newName> [token]
    Rename file <fileId> to <newName>.

  move-file <fileId> <newParentId> [token]
    Move file <fileId> under <newParentId>.

  add-note-file <fileId> <noteString> [token]
    Add/change note on <fileId>.

  delete-dir <directoryId> [token]
    Delete directory <directoryId> (including subdirectories).

  bulk-delete <dirId1> [dirId2] [dirId3] ...
    Delete multiple directories in one go.

Examples:
  $(basename "$0") set-token "YOUR_ACCOUNT_ID"
  $(basename "$0") interactive

  $(basename "$0") upload-anon ./myvideo.mp4 myvideo.mp4
  $(basename "$0") upload-auth ./myvideo.mp4 parent123 myvideo.mp4
  $(basename "$0") upload-note ./myvideo.mp4 myvideo.mp4 "Hello from Buzzheavier!"
  $(basename "$0") bulk-upload parent123 ./file1.mp4 ./file2.mp4
  $(basename "$0") locations
  $(basename "$0") account
  $(basename "$0") get-root

EOF
}

########################################
# Load token from config if it exists
########################################
function load_token_from_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null
  fi
}

########################################
# Set token command
########################################
function set_token() {
  local newToken="$1"

  if [[ -z "$newToken" ]]; then
    echo "Error: You must provide a token."
    exit 1
  fi

  mkdir -p "$(dirname "$CONFIG_FILE")"
  echo "ACCOUNT_ID=\"$newToken\"" > "$CONFIG_FILE"
  echo "Token saved to $CONFIG_FILE"
}

########################################
# Helper to get token
########################################
function get_token_argument_or_config() {
  local passedToken="$1"
  if [[ -n "$passedToken" ]]; then
    echo "$passedToken"
  else
    if [[ -z "$ACCOUNT_ID" ]]; then
      echo "Error: No token provided and none found in $CONFIG_FILE. Please run:"
      echo "  $(basename "$0") set-token <your_token>"
      exit 1
    fi
    echo "$ACCOUNT_ID"
  fi
}

########################################
# Enhanced Upload (Progress Bar)
########################################
function enhanced_curl_put() {
  # Usage: enhanced_curl_put <filePath> <URL> [<headers...>]
  # This wrapper uses a more verbose progress bar for uploading.
  local filePath="$1"
  local url="$2"
  shift 2
  local headers=("$@")

  curl --progress-bar -o - -T "$filePath" "${headers[@]}" "$url" | cat
}

########################################
# File Upload Functions
########################################

# 1) Anonymous file upload
function upload_anon() {
  local filePath="$1"
  local fileName="$2"

  if [[ ! -f "$filePath" ]]; then
    echo "Error: file does not exist: $filePath"
    exit 1
  fi

  echo "Uploading $filePath anonymously as $fileName ..."
  enhanced_curl_put "$filePath" \
    "${FILE_UPLOAD_BASE}/${fileName}"
  echo ""
}

# 2) Authenticated file upload
function upload_auth() {
  local filePath="$1"
  local parentId="$2"
  local fileName="$3"
  local tokenArg="$4"

  if [[ ! -f "$filePath" ]]; then
    echo "Error: file does not exist: $filePath"
    exit 1
  fi
  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  echo "Uploading $filePath to user directory $parentId as $fileName ..."
  enhanced_curl_put "$filePath" \
    "${FILE_UPLOAD_BASE}/${parentId}/${fileName}" \
    -H "Authorization: Bearer $token"
  echo ""
}

# 3) Upload a file to a specific location
function upload_loc() {
  local filePath="$1"
  local fileName="$2"
  local locationId="$3"

  if [[ ! -f "$filePath" ]]; then
    echo "Error: file does not exist: $filePath"
    exit 1
  fi

  echo "Uploading $filePath to location $locationId as $fileName ..."
  enhanced_curl_put "$filePath" \
    "${FILE_UPLOAD_BASE}/${fileName}?locationId=${locationId}"
  echo ""
}

# 4) Upload a file with note
function upload_note() {
  local filePath="$1"
  local fileName="$2"
  local noteString="$3"

  if [[ ! -f "$filePath" ]]; then
    echo "Error: file does not exist: $filePath"
    exit 1
  fi

  local encodedNote
  if command -v base64 >/dev/null 2>&1; then
    encodedNote="$(echo -n "$noteString" | base64)"
  else
    encodedNote="$(openssl base64 -A <<< "$noteString")"
  fi

  echo "Uploading $filePath with note ..."
  enhanced_curl_put "$filePath" \
    "${FILE_UPLOAD_BASE}/${fileName}?note=${encodedNote}"
  echo ""
}

# Bulk upload multiple files into a user directory
function bulk_upload() {
  local parentId="$1"
  shift
  if [[ $# -lt 1 ]]; then
    echo "Usage: bulk-upload <parentId> <file1> [file2] ..."
    exit 1
  fi

  # We'll attempt to use the token from config. No separate token argument here,
  # but you can easily add [token] if needed.
  local token
  token="$(get_token_argument_or_config "")"

  # For each file, we’ll keep the same file name (basename).
  for filePath in "$@"; do
    if [[ ! -f "$filePath" ]]; then
      echo "Warning: $filePath does not exist, skipping..."
      continue
    fi
    local fileName
    fileName="$(basename "$filePath")"
    echo "Bulk uploading $fileName to directory $parentId..."
    enhanced_curl_put "$filePath" \
      "${FILE_UPLOAD_BASE}/${parentId}/${fileName}" \
      -H "Authorization: Bearer $token"
    echo ""
  done
}

########################################
# Public / Account Info
########################################

# 5) Get file storage locations
function get_locations() {
  echo "Fetching file storage locations..."
  curl -s "${API_BASE}/locations" | jq .
}

# 6) Get account information
function get_account() {
  local tokenArg="$1"
  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  echo "Fetching account info..."
  curl -s \
    -H "Authorization: Bearer $token" \
    "${API_BASE}/account" \
  | jq .
}

########################################
# File Manager
########################################

# 7) Get root directory
function get_root() {
  local tokenArg="$1"
  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  echo "Listing root directory contents..."
  curl -s \
    -H "Authorization: Bearer $token" \
    "${API_BASE}/fs" \
  | jq .
}

# 8) Get directory
function get_directory() {
  local directoryId="$1"
  local tokenArg="$2"
  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  echo "Listing directory $directoryId..."
  curl -s \
    -H "Authorization: Bearer $token" \
    "${API_BASE}/fs/${directoryId}" \
  | jq .
}

# 9) Create directory
function create_directory() {
  local name="$1"
  local parentId="$2"
  local tokenArg="$3"
  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  echo "Creating directory '$name' under parentId='$parentId'..."
  curl -s \
    -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${name}\", \"parentId\": \"${parentId}\"}" \
    "${API_BASE}/fs" \
  | jq .
}

# 10) Rename directory
function rename_directory() {
  local directoryId="$1"
  local newName="$2"
  local tokenArg="$3"
  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  echo "Renaming directory $directoryId to $newName..."
  curl -s \
    -X PATCH \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${newName}\"}" \
    "${API_BASE}/fs/${directoryId}" \
  | jq .
}

# 11) Move directory
function move_directory() {
  local directoryId="$1"
  local newParentId="$2"
  local tokenArg="$3"
  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  echo "Moving directory $directoryId to $newParentId..."
  curl -s \
    -X PUT \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"parentId\": \"${newParentId}\"}" \
    "${API_BASE}/fs/${directoryId}" \
  | jq .
}

# 12) Rename file
function rename_file() {
  local fileId="$1"
  local newName="$2"
  local tokenArg="$3"
  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  echo "Renaming file $fileId to $newName..."
  curl -s \
    -X PATCH \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${newName}\"}" \
    "${API_BASE}/fs/${fileId}" \
  | jq .
}

# 13) Move file
function move_file() {
  local fileId="$1"
  local newParentId="$2"
  local tokenArg="$3"
  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  echo "Moving file $fileId to $newParentId..."
  curl -s \
    -X PUT \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"parentId\": \"${newParentId}\"}" \
    "${API_BASE}/fs/${fileId}" \
  | jq .
}

# 14) Add / change note for a file
function add_note_file() {
  local fileId="$1"
  local noteString="$2"
  local tokenArg="$3"
  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  echo "Updating note for file $fileId..."
  curl -s \
    -X PUT \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"note\": \"${noteString}\"}" \
    "${API_BASE}/fs/${fileId}" \
  | jq .
}

# 15) Delete directory
function delete_directory() {
  local directoryId="$1"
  local tokenArg="$2"
  local token
  token="$(get_token_argument_or_config "$tokenArg")"

  echo "Deleting directory $directoryId..."
  curl -s \
    -X DELETE \
    -H "Authorization: Bearer $token" \
    "${API_BASE}/fs/${directoryId}" \
  | jq .
}

# Bulk delete multiple directories
function bulk_delete_directories() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: bulk-delete <dirId1> [dirId2] [dirId3] ..."
    exit 1
  fi

  local token
  token="$(get_token_argument_or_config "")"

  for dirId in "$@"; do
    echo "Deleting directory: $dirId"
    curl -s \
      -X DELETE \
      -H "Authorization: Bearer $token" \
      "${API_BASE}/fs/${dirId}" \
    | jq .
  done
}

########################################
# Interactive Menu
########################################
function interactive_menu() {
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
    echo "11) Quit"
    echo "======================================================"
    read -rp "Choose an option (1-11): " choice

    case "$choice" in
      1)
        echo -n "Enter new token: "
        read -r newTok
        set_token "$newTok"
        ;;
      2)
        get_account
        ;;
      3)
        echo -n "Enter file path: "
        read -r anonPath
        echo -n "Enter file name as stored: "
        read -r anonName
        upload_anon "$anonPath" "$anonName"
        ;;
      4)
        echo -n "Enter file path: "
        read -r authPath
        echo -n "Enter parentId: "
        read -r pId
        echo -n "Enter file name as stored: "
        read -r fName
        upload_auth "$authPath" "$pId" "$fName"
        ;;
      5)
        echo -n "Enter parentId for bulk upload: "
        read -r bParent
        echo -n "Enter paths for files to upload (space-separated): "
        read -ra fileArray
        bulk_upload "$bParent" "${fileArray[@]}"
        ;;
      6)
        get_root
        ;;
      7)
        echo -n "Enter new directory name: "
        read -r newDirName
        echo -n "Enter parentId: "
        read -r cParent
        create_directory "$newDirName" "$cParent"
        ;;
      8)
        echo -n "Enter directoryId to delete: "
        read -r dId
        delete_directory "$dId"
        ;;
      9)
        echo -n "Enter directoryIds to bulk-delete (space-separated): "
        read -ra dirArray
        bulk_delete_directories "${dirArray[@]}"
        ;;
      10)
        get_locations
        ;;
      11)
        echo "Exiting Interactive Mode."
        break
        ;;
      *)
        echo "Invalid choice."
        ;;
    esac
  done
}

########################################
# Main
########################################

# 1) Load token from config if available
load_token_from_config

# 2) Handle user command
if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
  # Config
  set-token)
    # usage: set-token <token>
    set_token "$@"
    ;;
  
  # Interactive Mode
  interactive)
    interactive_menu
    ;;

  # File Upload Endpoints
  upload-anon)
    # usage: upload-anon <filePath> <fileName>
    upload_anon "$@"
    ;;
  upload-auth)
    # usage: upload-auth <filePath> <parentId> <fileName> [token]
    upload_auth "$@"
    ;;
  upload-loc)
    # usage: upload-loc <filePath> <fileName> <locationId>
    upload_loc "$@"
    ;;
  upload-note)
    # usage: upload-note <filePath> <fileName> <noteString>
    upload_note "$@"
    ;;
  bulk-upload)
    # usage: bulk-upload <parentId> <file1> [file2] ...
    bulk_upload "$@"
    ;;

  # Public / Account
  locations)
    # usage: locations
    get_locations
    ;;
  account)
    # usage: account [token]
    get_account "$@"
    ;;

  # File Manager
  get-root)
    # usage: get-root [token]
    get_root "$@"
    ;;
  get-dir)
    # usage: get-dir <directoryId> [token]
    get_directory "$@"
    ;;
  create-dir)
    # usage: create-dir <name> <parentId> [token]
    create_directory "$@"
    ;;
  rename-dir)
    # usage: rename-dir <directoryId> <newName> [token]
    rename_directory "$@"
    ;;
  move-dir)
    # usage: move-dir <directoryId> <newParentId> [token]
    move_directory "$@"
    ;;
  rename-file)
    # usage: rename-file <fileId> <newName> [token]
    rename_file "$@"
    ;;
  move-file)
    # usage: move-file <fileId> <newParentId> [token]
    move_file "$@"
    ;;
  add-note-file)
    # usage: add-note-file <fileId> <noteString> [token]
    add_note_file "$@"
    ;;
  delete-dir)
    # usage: delete-dir <directoryId> [token]
    delete_directory "$@"
    ;;
  bulk-delete)
    # usage: bulk-delete <dirId1> [dirId2] [dirId3] ...
    bulk_delete_directories "$@"
    ;;

  *)
    echo "Unknown command: $COMMAND"
    usage
    exit 1
    ;;
esac

exit 0
