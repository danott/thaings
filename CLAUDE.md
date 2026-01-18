# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

thaings is a macOS integration between Things (task management app) and Claude Code. When the user runs the Thaings shortcut on a to-do, it gets sent to Claude for processing, and the result is appended back to the to-do's notes.

## Architecture

```
Things App
    ↓ (Automation sends JSON via stdin)
receives-things-to-dos
    ↓ (Creates to-do in ~/.thaings/to-dos/{id}/to-do.json)
LaunchAgent watches to-dos/
    ↓ (Triggers on filesystem change)
responds-to-things-to-dos
    ↓ (Runs `claude --continue --print -p <prompt>`)
Claude Code
    ↓ (Returns result)
responds-to-things-to-dos
    ↓ (Updates Things via things:/// URL scheme)
Things App
```

**Key components:**
- `bin/install` - Sets up Thaings: creates onboarding to-do and loads the daemon
- `bin/receives-things-to-dos` - Receives JSON from Things automation, creates to-do files
- `bin/responds-to-things-to-dos` - Processes to-dos through Claude, updates Things
- `LaunchAgents/com.thaings.daemon.plist` - macOS LaunchAgent that triggers daemon on to-do directory changes
- `to-do-instructions.txt` - System prompt for to-do-processing Claude sessions (passed via `--append-system-prompt-file`)
- `.claude/` - Claude config for thaings development (this project)

## To-Do Lifecycle

To-dos use two tags to indicate whose turn it is:
- `Working` - Agent's turn (pending/working)
- `Ready` - Human's turn (ready for review)

To-do state is stored in `~/.thaings/to-dos/{id}/to-do.json`:
```json
{
  "state": { "status": "pending|working|review", ... },
  "props": [{ "received_at": "...", "data": { "Title": "...", "Notes": "..." } }]
}
```

## LaunchAgent Management

```bash
# Load the daemon
launchctl load ~/Library/LaunchAgents/com.thaings.daemon.plist

# Unload the daemon
launchctl unload ~/Library/LaunchAgents/com.thaings.daemon.plist

# Check if loaded
launchctl list | grep thaings
```

## Logs

- `~/.thaings/log/daemon.log` - Main daemon activity
- `~/.thaings/log/receive.log` - Incoming to-do receipts
- `~/.thaings/log/daemon.stdout.log` / `daemon.stderr.log` - LaunchAgent output
- `~/.thaings/to-dos/{id}/to-do.log` - Per-to-do processing log

## Testing

Run scripts directly for testing:
```bash
# Test receive (pipe JSON to stdin)
echo '{"Type":"To-Do","ID":"test123","Title":"Test to-do"}' | ./bin/receives-things-to-dos

# Test respond (processes pending to-dos)
./bin/responds-to-things-to-dos
```
