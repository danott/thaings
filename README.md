# Thaings

Thaings adds agentic workers to to-dos in Things. It's *AI* augmenting *Things*. *Thaings*. You get it.

## How it works

Select a to-do in Things and run the Thaings shortcut. A background daemon picks it up and tags it `Working` while Claude processes it. When done, the results are appended to the to-do's notes and the tag changes to `Ready`. You decide whether to mark it complete or continue the conversation.

Each to-do gets its own conversation context—Claude can reference previous exchanges in that to-do's history.

## Assumptions

- macOS
- [Homebrew](https://brew.sh)
- [Things](https://culturedcode.com/things/)
- [Claude Code](https://claude.ai/code) installed via Homebrew
- Ruby 3.0+ via [rbenv](https://github.com/rbenv/rbenv) (the daemon expects Ruby at `~/.rbenv/shims/ruby`)
- Apple Shortcuts (comes with macOS)

## Installation

### Quick install

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/danott/thaings/main/install.sh)"
```

This clones the repository to `$HOME/thaings`, sets up a LaunchAgent, and creates a to-do in your Things Inbox that walks you through the remaining setup.

### Manual install

If you prefer a different location:

```bash
git clone https://github.com/danott/thaings.git /path/to/thaings
cd /path/to/thaings
./bin/install
```

Note: The Apple Shortcut expects Thaings at `$HOME/thaings`. If you install elsewhere, you'll need to edit the shortcut to point to your install location.

## Known caveats

1. **Collapse to-dos before calling the shortcut.** Things' "Get Selected Items" returns unpredictable data when a to-do is open for editing.
2. **Don't edit to-dos while Thaings is working.** Things' URL scheme updates are unpredictable when the notes field is focused. Let the to-do rest until it's tagged `Ready`.

## Configuration

Configuration lives in `.env` (created from `.env.example` during installation). All variables are prefixed with `THAINGS_` to avoid conflicts.

### Required

**`THAINGS_THINGS_AUTH_TOKEN`** — Thaings updates to-dos via the Things URL scheme, which requires an auth token. Get yours from Things → Settings → General → Enable Things URLs → Manage.

### Optional

**`THAINGS_SYSTEM_PROMPT_FILE`** — Path to a custom system prompt file. Defaults to `default-system-prompt.md` in the Thaings directory.

**`THAINGS_MAX_TURNS`** — Maximum agentic turns Claude can take per to-do. Defaults to 10.

**`THAINGS_TIMEOUT_SECONDS`** — How long to wait for Claude to respond before timing out. Defaults to 300 (5 minutes).

**`THAINGS_ALLOWED_TOOLS`** — Comma-separated list of tools Claude can use. Defaults to `WebSearch,WebFetch`.

**`THAINGS_CLAUDE_PATH`** — Path to the Claude binary. Defaults to `/opt/homebrew/bin/claude`.

## Testing

### Automated Tests

```bash
ruby test/end_to_end_test.rb
```

### End-to-End Test

1. Ensure the daemon is running: `launchctl list | grep thaings`
2. Create a to-do in Things with a simple prompt (e.g., "What is 2+2?")
3. Run the Thaings shortcut on that to-do
4. Watch `tail -f log/daemon.log` for processing activity
5. Verify the to-do gets the `Ready` tag and Claude's response in notes

See [CLAUDE.md](CLAUDE.md) for more detailed testing instructions.

## License

MIT
