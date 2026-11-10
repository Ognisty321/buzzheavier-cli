# BuzzHeavier CLI

A **Bash** command-line client for the [BuzzHeavier](https://buzzheavier.com) API.

- Upload files anonymously or into your account, one or many at a time
- Browse and manage your files: list, create, rename, move, annotate, delete
- Prints just the download link on stdout, so it is easy to use in scripts
- Formatted tables when `jq` is installed, raw JSON with `--json`
- Interactive menu mode

```console
$ ./buzzheavier.sh upload video.mp4
→ Uploading video.mp4 (148.2 MB)
######################################################################## 100.0%
✔ Uploaded video.mp4
https://buzzheavier.com/abc123def456
```

---

## Table of Contents

- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Commands](#commands)
  - [Upload](#upload)
  - [File manager](#file-manager)
  - [Account and setup](#account-and-setup)
  - [Global options](#global-options)
- [Scripting](#scripting)
- [Interactive mode](#interactive-mode)
- [Legacy command names](#legacy-command-names)
- [Dependencies](#dependencies)
- [Development](#development)
- [License](#license)

---

## Installation

```bash
git clone https://github.com/Ognisty321/buzzheavier-cli.git
cd buzzheavier-cli
chmod +x buzzheavier.sh
```

Optionally put it on your `PATH`:

```bash
sudo install -m 755 buzzheavier.sh /usr/local/bin/buzzheavier
```

Optionally install `jq` to get formatted tables (`sudo apt-get install jq`, `brew install jq`, `winget install jqlang.jq`).

---

## Configuration

Commands that work with your account use your **Account ID** as a Bearer token. Anonymous uploads and `locations` need no setup at all.

Save it once:

```bash
./buzzheavier.sh set-token
```

The command prompts for the ID without echoing it, so it stays out of your shell history. You can also pass it as an argument (`set-token YOUR_ACCOUNT_ID`) or pipe it in.

It is stored in `~/.config/buzzheavier-cli/config` (or under `$XDG_CONFIG_HOME`) with permissions `600`:

```text
ACCOUNT_ID=YOUR_ACCOUNT_ID
```

Related commands:

```bash
./buzzheavier.sh config       # show where the ID comes from (masked) and which endpoints are used
./buzzheavier.sh account      # check that the ID works
./buzzheavier.sh unset-token  # remove the saved ID
```

### Environment variables

| Variable                    | Purpose                                         |
| --------------------------- | ----------------------------------------------- |
| `BUZZHEAVIER_ACCOUNT_ID`    | Account ID; takes precedence over the config file |
| `BUZZHEAVIER_API_BASE`      | default: `https://buzzheavier.com/api`          |
| `BUZZHEAVIER_UPLOAD_BASE`   | default: `https://w.buzzheavier.com`            |
| `BUZZHEAVIER_DOWNLOAD_BASE` | default: `https://buzzheavier.com`              |
| `NO_COLOR`                  | set to any value to disable colours             |

---

## Usage

```bash
./buzzheavier.sh [options] <command> [arguments]
./buzzheavier.sh help
```

Quick tour:

```bash
# Anonymous upload - prints the download link
./buzzheavier.sh upload video.mp4

# Several files into one of your directories
./buzzheavier.sh upload *.zip -d <dirId>

# Different name, a note and a specific storage location
./buzzheavier.sh upload report.pdf -n "Report 2025.pdf" --note "final version" -l <locationId>

# Browse and manage
./buzzheavier.sh ls
./buzzheavier.sh ls <dirId>
./buzzheavier.sh mkdir "Holiday photos"
./buzzheavier.sh rename <id> "new name.mp4"
./buzzheavier.sh mv <id> <newParentId>
./buzzheavier.sh rm <id>
```

---

## Commands

### Upload

```text
upload <file>... [-d <dirId>] [-n <name>] [-l <locationId>] [--note <text>]
```

| Option                  | Description                                                                 |
| ----------------------- | --------------------------------------------------------------------------- |
| `-d`, `--dir <dirId>`   | Upload into one of your directories (needs the account ID). Without it the upload is anonymous. |
| `-n`, `--name <name>`   | Store the file under another name (single file only). Default: the file's own name. |
| `-l`, `--location <id>` | Storage location, see `locations`.                                          |
| `-N`, `--note <text>`   | Note shown under the download link (max 500 characters).                    |

File names are URL-encoded automatically, so spaces and non-ASCII characters work. BuzzHeavier itself refuses a few characters in names (for example `#`); in that case choose another name with `-n`. When several files are given, a failed one does not stop the others; the exit code is non-zero if any of them failed.

### File manager

All of these need the account ID.

| Command                   | Description                                                        |
| ------------------------- | ------------------------------------------------------------------ |
| `ls [dirId]`              | List the root directory or the given directory                     |
| `mkdir <name> [parentId]` | Create a directory and print its ID. Without `parentId` it is created in the root directory (this lookup needs `jq`). |
| `rename <id> <newName>`   | Rename a file or directory                                         |
| `mv <id> <newParentId>`   | Move a file or directory                                           |
| `note <fileId> <text>`    | Set or replace the note of a file                                  |
| `rm <id>...`              | Delete files or directories; a directory is deleted **with everything inside it** |

`rm` asks for confirmation when run in a terminal. Pass `-y` to skip the question. When input is not a terminal (scripts, pipes) it does not ask.

With `jq` installed, `ls` prints a table:

```console
$ ./buzzheavier.sh ls
Directory: root  [id: r00t1d2x3y4z]
TYPE  ID            SIZE      DL  CREATED     NAME
dir   d1r2e3x4a5m6  -         -   2026-11-10  Backups/
file  f1l2e3x4a5m6  112.3 KB  4   2025-12-31  notes.txt
```

> The official API reference lists `PUT` for moving items and setting notes, but the server only accepts `PATCH` for them (`PUT` answers `405 Method Not Allowed`). This CLI uses `PATCH`.

### Account and setup

| Command                  | Description                                          |
| ------------------------ | ---------------------------------------------------- |
| `account`                | Show account information                             |
| `locations`              | List storage locations (no account needed)           |
| `set-token [account_id]` | Save the account ID (prompts when omitted)           |
| `unset-token`            | Remove the saved account ID                          |
| `config`                 | Show the configuration; the account ID is masked     |
| `interactive`            | Menu-driven mode                                     |
| `help`, `version`        | Help and version                                     |

### Global options

| Option            | Description                                                    |
| ----------------- | -------------------------------------------------------------- |
| `--json`          | Print the raw API response instead of formatted output         |
| `-q`, `--quiet`   | No progress or status messages (errors are still shown)        |
| `-y`, `--yes`     | Do not ask for confirmation before deleting                    |
| `--no-color`      | Disable colours                                                |
| `-h`, `--help`    | Show help                                                      |
| `-V`, `--version` | Show the version                                               |
| `--`              | Treat everything after it as arguments, e.g. a file called `-q` |

Options can be placed before or after the command.

---

## Scripting

The CLI is built to be used from scripts:

- **stdout** carries only the result: download links, tables, IDs or JSON.
- **stderr** carries progress, status and error messages.
- **Exit code** is `0` on success, `1` on failure (network error or an error response from the API) and `2` for wrong usage.

```bash
# Capture the link of an upload
link=$(./buzzheavier.sh -q upload backup.tar.gz) || echo "upload failed" >&2

# Create a directory and upload into it
dir=$(./buzzheavier.sh mkdir "Backups $(date +%F)")
./buzzheavier.sh upload *.tar.gz -d "$dir"

# Work with the raw API response
./buzzheavier.sh ls --json | jq -r '.data.children[].name'
```

The account ID is passed to `curl` on standard input rather than as a command-line argument, so it is not visible to other users in the process list.

---

## Interactive mode

```bash
./buzzheavier.sh interactive
```

```text
Buzzheavier CLI v2.0.0 - account ID: ab…wxyz

 Upload
   1) Upload a file (anonymous)
   2) Upload file(s) into a directory
 Browse
   3) List root directory
   4) List a directory
 Manage
   5) Create directory
   6) Rename file or directory
   7) Move file or directory
   8) Set a file note
   9) Delete directory
 Account
  10) Account info
  11) Storage locations
  12) Set account ID
  13) Show config
   q) Quit

Choose an option:
```

---

## Legacy command names

The command names of version 1 keep working, with the same arguments:

| Legacy command                                              | Now                          |
| ----------------------------------------------------------- | ---------------------------- |
| `upload-anon <filePath> [fileName]`                         | `upload <file> [-n <name>]`  |
| `upload-auth <filePath> <parentId> [fileName] [account_id]` | `upload <file> -d <dirId>`   |
| `upload-loc <filePath> <fileName> <locationId>`             | `upload <file> -l <id>`      |
| `upload-note <filePath> <fileName> <noteString>`            | `upload <file> --note <text>` |
| `bulk-upload <parentId> <file1> [file2] ...`                | `upload <file>... -d <dirId>` |
| `get-root [account_id]`, `get-dir <directoryId> [account_id]` | `ls [dirId]`               |
| `create-dir <name> <parentId> [account_id]`                 | `mkdir <name> [parentId]`    |
| `rename-dir`, `rename-file <id> <newName> [account_id]`     | `rename <id> <newName>`      |
| `move`, `move-dir`, `move-file <id> <newParentId> [account_id]` | `mv <id> <newParentId>`  |
| `add-note-file <fileId> <noteString> [account_id]`          | `note <fileId> <text>`       |
| `delete-dir <directoryId> [account_id]`                     | `rm <id>`                    |
| `bulk-delete <dirId1> [dirId2] ...`                         | `rm <id>...`                 |

Differences from version 1 that scripts may notice:

- Status messages (`Uploading ...`) now go to stderr, and uploads print only the download link on stdout. Use `--json` to get the API response as before.
- Failed requests now return a non-zero exit code.
- Moving items and setting notes (`move-*`, `add-note-file`) now work; version 1 sent `PUT`, which the server rejects.
- `delete-dir` and `bulk-delete` ask for confirmation when run in a terminal (`-y` skips it).

---

## Dependencies

- Bash and `curl`
- `jq` *(optional)* - formatted tables and `mkdir` without a parent ID
- `base64` **or** `openssl` - only for upload notes

Tested with Bash 5 on Linux and on Windows (Git Bash and WSL). The script avoids Bash 4+ only features, so the Bash 3.2 that ships with macOS should work too.

---

## Development

The test suite runs every command against a small local mock of the API, so nothing is sent to buzzheavier.com:

```bash
bash tests/run.sh    # needs python3
```

---

## License

MIT License – you are free to fork and modify.
