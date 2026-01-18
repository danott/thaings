# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

thaings is a macOS integration between Things (task management app) and Claude Code. When the user runs the Thaings shortcut on a to-do, it gets sent to Claude for processing, and the result is appended back to the to-do's notes.

## Architecture

```
Things App
    ↓ (Automation sends JSON via stdin)
receives-things-to-dos
    ↓ (Creates task in ~/.thaings/tasks/{id}/task.json)
LaunchAgent watches tasks/
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
- `bin/install` - Sets up Thaings: creates onboarding todo and loads the daemon
- `bin/receives-things-to-dos` - Receives JSON from Things automation, creates task files
- `bin/responds-to-things-to-dos` - Processes tasks through Claude, updates Things
- `LaunchAgents/com.thaings.daemon.plist` - macOS LaunchAgent that triggers daemon on task directory changes
- `task-instructions.txt` - System prompt for task-processing Claude sessions (passed via `--append-system-prompt-file`)
- `.claude/` - Claude config for thaings development (this project)

## Task Lifecycle

Tasks use two tags to indicate whose turn it is:
- `Working` - Agent's turn (pending/working)
- `Ready` - Human's turn (ready for review)

Task state is stored in `~/.thaings/tasks/{id}/task.json`:
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
- `~/.thaings/log/receive.log` - Incoming task receipts
- `~/.thaings/log/daemon.stdout.log` / `daemon.stderr.log` - LaunchAgent output
- `~/.thaings/tasks/{id}/task.log` - Per-task processing log

## Testing

Run scripts directly for testing:
```bash
# Test receive (pipe JSON to stdin)
echo '{"Type":"To-Do","ID":"test123","Title":"Test task"}' | ./bin/receives-things-to-dos

# Test respond (processes pending tasks)
./bin/responds-to-things-to-dos
```
