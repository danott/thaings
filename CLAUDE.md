# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

thaings is a macOS integration between Things (task management app) and Claude Code. When a task is added to Things with a specific tag, it gets processed by Claude and the result is sent back to Things.

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
- `bin/receives-things-to-dos` - Receives JSON from Things automation, creates task files
- `bin/responds-to-things-to-dos` - Processes tasks through Claude, updates Things
- `LaunchAgents/com.thaings.daemon.plist` - macOS LaunchAgent that triggers daemon on task directory changes
- `task-env-boilerplate/` - Claude config symlinked into task folders (sandboxed permissions)
- `.claude/` - Claude config for thaings development (this project)

## Task Lifecycle

Tasks use status tags: `waiting` → `working` → `success` or `blocked`

Task state is stored in `~/.thaings/tasks/{id}/task.json`:
```json
{
  "state": { "status": "waiting|working|success|blocked", ... },
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

# Test respond (processes waiting tasks)
./bin/responds-to-things-to-dos
```
