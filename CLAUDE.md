# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

thaings is a macOS integration between Things (task management app) and Claude Code. When the user runs the Thaings shortcut on a to-do, it gets sent to Claude for processing, and the result is appended back to the to-do's notes.

## Architecture

```
Things App
    ↓ (Automation sends JSON via stdin)
receives-things-to-dos
    ↓ (Creates message in to-dos/{id}/messages/{timestamp}.json)
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

To-do state is stored in the filesystem:
```
to-dos/
  _queue/               # Marker files - presence means work is needed
    {id}
  {id}/
    messages/
      {timestamp}.json  # Raw data from Things (Title, Notes, Tags, etc.)
    processed           # Timestamp of last processed message
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

- `log/daemon.log` - Main daemon activity
- `log/receive.log` - Incoming to-do receipts
- `log/daemon.stdout.log` / `daemon.stderr.log` - LaunchAgent output

## Ruby Style

**Formatting:** Format all Ruby code with [Syntax Tree](https://github.com/ruby-syntax-tree/syntax_tree). Run `stree format <file>` or `stree write <file>` to format files.

- Use `hash.fetch('key')` instead of `hash['key']` — missing values should cause explicit failures, not silent nils
- Use `hash.fetch('key', default)` when a default is appropriate
- Never reference instance variables (`@var`) outside of `initialize` — use `attr_reader` and call the method instead
- Assign instance variables only in `initialize`, then interact through the reader methods

## Testing

### Automated Tests

Run the test suite with:
```bash
ruby test/end_to_end_test.rb
```

Tests use Minitest and run in isolated temp directories. They test the core components (receiving, queueing, state transitions) with stubbed dependencies - no actual Claude calls or Things updates.

### Manual Component Testing

Test individual scripts directly:
```bash
# Test receive (pipe JSON to stdin)
echo '{"Type":"To-Do","ID":"test123","Title":"Test to-do"}' | ./bin/receives-things-to-dos

# Test respond (processes queued to-dos)
./bin/responds-to-things-to-dos
```

### Real-World End-to-End Test

1. **Verify the daemon is running:**
   ```bash
   launchctl list | grep thaings
   ```

2. **Create a test to-do in Things** with a simple title like "What is 2+2?"

3. **Run the Thaings shortcut** on that to-do (via the Services menu or keyboard shortcut)

4. **Watch the logs:**
   ```bash
   tail -f log/daemon.log
   ```

   You should see: `triggered` → `received` → `processing` → `done`

5. **Check the to-do in Things** - it should have:
   - The `Working` tag (briefly), then `Ready` tag
   - Claude's response appended to the notes

6. **Verify queue state:**
   ```bash
   # Should be empty after processing
   ls to-dos/_queue/

   # Message files persist
   ls to-dos/<to-do-id>/messages/
   ```
