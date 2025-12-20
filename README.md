# BuzzHeavier CLI

A **Bash** command-line interface (CLI) for interacting with the [BuzzHeavier](https://buzzheavier.com) API.

- Anonymous uploads (no auth)
- Authenticated uploads + file manager (requires your **Account ID** as Bearer token)
- Bulk operations
- Interactive menu mode
- `jq` is optional (pretty JSON if installed, raw output otherwise)

---

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Configuration](#configuration)
  - [Set token](#set-token)
  - [Environment variables](#environment-variables)
- [Usage](#usage)
- [Commands Reference](#commands-reference)
  - [Config / Help / Interactive](#config--help--interactive)
  - [Uploads](#uploads)
  - [Bulk Operations](#bulk-operations)
  - [Public / Account](#public--account)
  - [File Manager](#file-manager)
  - [Aliases / Convenience Commands](#aliases--convenience-commands)
- [Interactive Mode](#interactive-mode)
- [Dependencies](#dependencies)
- [License](#license)

---

## Features

1. **Store your token (Account ID)** in `~/.config/buzzheavier-cli/config`.
2. **Anonymous uploads** – no token needed.
3. **Authenticated uploads** – upload into a specific user directory (parentId).
4. **File manager operations** – list, create, rename, move, set note, delete directories.
5. **Bulk operations**
   - Bulk upload multiple files
   - Bulk delete multiple directories
6. **Interactive mode** – menu-driven common operations.
7. **Better UX**
   - Optional `jq` (pretty-print if present)
   - Shows HTTP status codes
   - Safer config parsing (no `source`)

---

## Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/Ognisty321/buzzheavier-cli.git
   cd buzzheavier-cli
   ```

2. **Make the script executable**

   ```bash
   chmod +x buzzheavier.sh
   ```

3. **(Optional) Install `jq`** for pretty-printing JSON

   ```bash
   # Ubuntu/Debian
   sudo apt-get install jq
   ```

---

## Configuration

### Set token

Authenticated endpoints use your **Account ID** as a Bearer token.

```bash
./buzzheavier.sh set-token "YOUR_ACCOUNT_ID"
```

This writes to:

```text
~/.config/buzzheavier-cli/config
```

Format:

```text
ACCOUNT_ID=YOUR_ACCOUNT_ID
```

Other useful config commands:

```bash
./buzzheavier.sh config       # show config status (does not print full token)
./buzzheavier.sh unset-token  # remove config file
```

### Environment variables

You can override defaults using environment variables:

* `BUZZHEAVIER_ACCOUNT_ID` – token (Account ID)
* `BUZZHEAVIER_API_BASE` – default: `https://buzzheavier.com/api`
* `BUZZHEAVIER_UPLOAD_BASE` – default: `https://w.buzzheavier.com`
* `BUZZHEAVIER_DOWNLOAD_BASE` – default: `https://buzzheavier.com`

Example:

```bash
export BUZZHEAVIER_ACCOUNT_ID="YOUR_ACCOUNT_ID"
./buzzheavier.sh account
```

---

## Usage

```bash
./buzzheavier.sh <command> [arguments...]
```

See built-in help:

```bash
./buzzheavier.sh help
# or
./buzzheavier.sh -h
```

Example invocations:

```bash
# Anonymous upload (no token)
./buzzheavier.sh upload-anon ./myvideo.mp4 myvideo.mp4

# Authenticated upload to a parent directory
./buzzheavier.sh upload-auth ./myvideo.mp4 parent123 myvideo.mp4

# Upload with a note (note is base64 encoded and URL-safe)
./buzzheavier.sh upload-note ./myvideo.mp4 myvideo.mp4 "hello from buzzheavier"

# List root directory (auth)
./buzzheavier.sh get-root

# List a directory (auth)
./buzzheavier.sh get-dir directory123

# Or use ls alias:
./buzzheavier.sh ls
./buzzheavier.sh ls directory123
```

---

## Commands Reference

### Config / Help / Interactive

| Command                  | Description                                       |
| ------------------------ | ------------------------------------------------- |
| `help` / `-h` / `--help` | Show help + command list                          |
| `set-token <account_id>` | Save Account ID token to config                   |
| `unset-token`            | Remove saved token/config                         |
| `config`                 | Print config status (token source + masked token) |
| `interactive`            | Launch menu-driven interactive mode               |

### Uploads

| Command                                                     | Description                               |
| ----------------------------------------------------------- | ----------------------------------------- |
| `upload-anon <filePath> <fileName>`                         | Anonymous upload as `<fileName>`          |
| `upload-auth <filePath> <parentId> <fileName> [account_id]` | Auth upload into directory `<parentId>`   |
| `upload-loc <filePath> <fileName> <locationId>`             | Upload to a specific storage location     |
| `upload-note <filePath> <fileName> <noteString>`            | Upload with a note (base64 + URL-encoded) |

### Bulk Operations

| Command                                      | Description                                  |
| -------------------------------------------- | -------------------------------------------- |
| `bulk-upload <parentId> <file1> [file2] ...` | Bulk upload multiple files into `<parentId>` |
| `bulk-delete <dirId1> [dirId2] ...`          | Bulk delete directories                      |

### Public / Account

| Command                | Description                               |
| ---------------------- | ----------------------------------------- |
| `locations`            | List storage locations (no auth required) |
| `account [account_id]` | Get account info (auth)                   |

### File Manager

| Command                                             | Description                                  |
| --------------------------------------------------- | -------------------------------------------- |
| `get-root [account_id]`                             | List root directory (auth)                   |
| `get-dir <directoryId> [account_id]`                | List directory contents (auth)               |
| `create-dir <name> <parentId> [account_id]`         | Create directory `<name>` under `<parentId>` |
| `rename-dir <directoryId> <newName> [account_id]`   | Rename a directory                           |
| `move-dir <directoryId> <newParentId> [account_id]` | Move a directory                             |
| `rename-file <fileId> <newName> [account_id]`       | Rename a file                                |
| `move-file <fileId> <newParentId> [account_id]`     | Move a file                                  |
| `add-note-file <fileId> <noteString> [account_id]`  | Add/change a file note                       |
| `delete-dir <directoryId> [account_id]`             | Delete a directory (and subdirectories)      |

### Aliases / Convenience Commands

These are shortcuts over the same underlying API endpoints:

| Command                                | Description                      |
| -------------------------------------- | -------------------------------- |
| `ls [directoryId] [account_id]`        | Alias for `get-root` / `get-dir` |
| `rename <id> <newName> [account_id]`   | Generic rename for file/dir IDs  |
| `move <id> <newParentId> [account_id]` | Generic move for file/dir IDs    |

---

## Interactive Mode

Run:

```bash
./buzzheavier.sh interactive
```

Menu:

```
========== Buzzheavier CLI Interactive Menu ==========
 1) Set Token
 2) Show Account Info
 3) Upload File (Anon)
 4) Upload File (Auth)
 5) Bulk Upload (Auth)
 6) List Root Directory
 7) Create Directory
 8) Delete Directory
 9) Bulk Delete Directories
10) Get Storage Locations
11) Show Config
12) Quit
======================================================
Choose an option (1-12):
```

---

## Dependencies

* Bash 4.0+
* `curl`
* `jq` *(optional)* for pretty JSON
* `base64` **or** `openssl` (needed for note encoding)

Linux/macOS should have most of these available. On Windows, use **WSL** or **Git Bash**.

---

## License

MIT License – you are free to fork and modify.
