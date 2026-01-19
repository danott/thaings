# Thaings

Thaings adds agentic workers to to-dos in Things. It’s *AI* augmenting *Things*. *Thaings*. You get it.

## How it works

Select a to-do in Things and run the Thaings shortcut. The to-do gets
tagged `Working` while Claude processes it. When done, the results are
appended to the to-do's notes and the tag changes to `Ready`. You decide
whether to mark it complete or continue the conversation.

## Requirements

- macOS
- [Things](https://culturedcode.com/things/)
- [Claude Code](https://claude.ai/code)
- Ruby 3.0+ (via [rbenv](https://github.com/rbenv/rbenv))

## Installation

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/danott/thaings/main/install.sh)"
```

This installer will setup a LaunchAgent and create a to-do in your Things Inbox that walks you through the remaining setup.

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
