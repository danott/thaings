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

## Installation

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/danott/thaings/main/install.sh)"
```

This installer will setup a LaunchAgent and create a to-do in your Things Inbox that walks you through the remaining setup.

## License

MIT
