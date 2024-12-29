# Buzzheavier CLI

A **Bash** command-line interface (CLI) for interacting with [Buzzheavier](https://buzzheavier.com) API.

---

## Table of Contents

- [Features](#features)  
- [Installation](#installation)  
- [Configuration](#configuration)  
- [Usage](#usage)  
- [Commands Reference](#commands-reference)  
  - [Config / Interactive](#config--interactive)  
  - [Uploads](#uploads)  
  - [Bulk Operations](#bulk-operations)  
  - [Public / Account](#public--account)  
  - [File Manager](#file-manager)  
- [Interactive Mode](#interactive-mode)  
- [Dependencies](#dependencies)  
- [License](#license)  

---

## Features

1. **Set and store your token** securely in `~/.config/buzzheavier-cli/config`.
2. **Anonymous file uploads** – no token needed.
3. **Authenticated uploads** – upload to user directories or specific locations using your token.
4. **File manager operations** – create, rename, move directories/files, retrieve directories, etc.
5. **Bulk operations**:
   - **Bulk Upload** multiple files at once.
   - **Bulk Delete** multiple directories.
6. **Interactive Mode** – quickly perform actions via a simple menu-driven interface.

---

## Installation

1. **Clone this repository**:
   ```bash
   git clone https://github.com/Ognisty321/buzzheavier-cli.git
   cd buzzheavier-cli
   ```

2. **Make the script executable**:
   ```bash
   chmod +x buzzheavier.sh
   ```

3. **(Optional) Install `jq`** for pretty-printing JSON responses:
   ```bash
   # On Ubuntu/Debian-based systems:
   sudo apt-get install jq
   ```
   (If `jq` is unavailable, the script will still work; JSON will just be printed raw.)

---

## Configuration

Before using authenticated endpoints (like `upload-auth`, `account`, `get-root`, etc.), you must **set your token**:

```bash
./buzzheavier.sh set-token "YOUR_ACCOUNT_ID"
```

This saves your token in `~/.config/buzzheavier-cli/config`:
```bash
ACCOUNT_ID="YOUR_ACCOUNT_ID"
```

Henceforth, any command that requires authentication will automatically load that token unless you explicitly provide one as an argument.

---

## Usage

```bash
./buzzheavier.sh <command> [arguments...]
```

Example invocations:

```bash
# 1. Anonymous upload
./buzzheavier.sh upload-anon ./myvideo.mp4 myvideo.mp4

# 2. Authenticated upload
./buzzheavier.sh upload-auth ./myvideo.mp4 parent123 myvideo.mp4

# 3. Bulk upload multiple files
./buzzheavier.sh bulk-upload parent123 file1.mp4 file2.jpg file3.pdf

# 4. Interactive menu
./buzzheavier.sh interactive
```

---

## Commands Reference

### Config / Interactive

| Command                     | Description                                                                                       |
|-----------------------------|---------------------------------------------------------------------------------------------------|
| **`set-token <token>`**     | Saves your Buzzheavier token in `~/.config/buzzheavier-cli/config`.                              |
| **`interactive`**           | Launches a menu-driven interface that lets you choose common operations.                         |

### Uploads

| Command                                                       | Description                                                                    |
|---------------------------------------------------------------|--------------------------------------------------------------------------------|
| **`upload-anon <filePath> <fileName>`**                      | Upload a file **anonymously** as `<fileName>`.                                 |
| **`upload-auth <filePath> <parentId> <fileName> [token]`**   | Upload a file into user directory `<parentId>`, using a token.                |
| **`upload-loc <filePath> <fileName> <locationId>`**          | Upload a file to a **specific storage location**.                              |
| **`upload-note <filePath> <fileName> <noteString>`**         | Upload a file with a **text note** (converted to Base64).                      |

### Bulk Operations

| Command                                                  | Description                                                      |
|----------------------------------------------------------|------------------------------------------------------------------|
| **`bulk-upload <parentId> <file1> [file2] ...`**         | **Bulk upload** multiple files to user directory `<parentId>`.   |
| **`bulk-delete <dirId1> [dirId2] ...`**                  | **Bulk delete** multiple directories (no file-deletion endpoint).|

### Public / Account

| Command                      | Description                                                                      |
|-----------------------------|----------------------------------------------------------------------------------|
| **`locations`**             | Retrieve a list of **storage locations** (no auth required).                     |
| **`account [token]`**       | Get **account info** for the currently authenticated user.                        |

### File Manager

| Command                                                    | Description                                                                          |
|------------------------------------------------------------|--------------------------------------------------------------------------------------|
| **`get-root [token]`**                                    | List **root directory**.                                                             |
| **`get-dir <directoryId> [token]`**                       | List contents of a **directory**.                                                    |
| **`create-dir <name> <parentId> [token]`**                | Create a new directory `<name>` under `<parentId>`.                                  |
| **`rename-dir <directoryId> <newName> [token]`**          | Rename directory `<directoryId>` to `<newName>`.                                     |
| **`move-dir <directoryId> <newParentId> [token]`**        | Move directory `<directoryId>` to `<newParentId>`.                                   |
| **`rename-file <fileId> <newName> [token]`**              | Rename file `<fileId>` to `<newName>`.                                               |
| **`move-file <fileId> <newParentId> [token]`**            | Move file `<fileId>` to `<newParentId>`.                                             |
| **`add-note-file <fileId> <noteString> [token]`**         | Add or change the **note** on file `<fileId>`.                                       |
| **`delete-dir <directoryId> [token]`**                    | Delete directory `<directoryId>` (and all subdirectories).                           |

---

## Interactive Mode

You can run:
```bash
./buzzheavier.sh interactive
```

This will present a **menu** in your terminal:

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
11) Quit
======================================================
Choose an option (1-11):
```

Select actions by entering a number. This is a great way to explore the API **without** memorizing commands.

---

## Dependencies

- **Bash** 4.0+  
- **curl** (for making requests)  
- **jq** (optional, for nicely formatted JSON output)  
- **base64** or **openssl** (for note-encoding in `upload-note`)  

On most Linux or macOS systems, these tools are readily available or easily installed. On Windows, consider **Git Bash** or **WSL**.

---

## License

[MIT License](LICENSE) – You are free to **fork** and **modify**.  
