# Multi-Account Switcher for Claude Code

A simple tool to manage and switch between multiple Claude Code accounts on macOS, Linux, and WSL.

## Features

- **Multi-account management**: Add, remove, and list Claude Code accounts
- **Multi-provider support**: Manage multiple accounts with the same email from different providers (Anthropic, Z.AI, custom)
- **Quick switching**: Switch between accounts with simple commands
- **Cross-platform**: Works on macOS, Linux, and WSL
- **Secure storage**: Uses system keychain (macOS) or protected files (Linux/WSL)
- **Settings preservation**: Only switches authentication - your themes, settings, and preferences remain unchanged

## Installation

Download the script directly:

```bash
curl -O https://raw.githubusercontent.com/ming86/cc-account-switcher/main/ccswitch.sh
chmod +x ccswitch.sh
```

## Usage

### Basic Commands

```bash
# Add current account to managed accounts (auto-detect provider)
./ccswitch.sh --add-account

# Add current account with manual provider specification
./ccswitch.sh --add-account anthropic
./ccswitch.sh --add-account work

# List all managed accounts with provider information
./ccswitch.sh --list

# Switch to next account in sequence
./ccswitch.sh --switch

# Switch to specific account by number, email, or email@provider
./ccswitch.sh --switch-to 2
./ccswitch.sh --switch-to user2@example.com
./ccswitch.sh --switch-to user@example.com@anthropic
./ccswitch.sh --switch-to user@example.com@z.ai

# Remove an account
./ccswitch.sh --remove-account user2@example.com
./ccswitch.sh --remove-account user@example.com@work

# Show help
./ccswitch.sh --help
```

### Provider Support

The tool supports multiple accounts with the same email from different providers using the `email@provider` format:

- **Auto-detection**: Providers are automatically detected from account UUIDs
  - `anthropic`: Standard Anthropic UUID format
  - `z.ai`: Z.AI accounts starting with `zai_`
  - `unknown`: Unrecognized UUID patterns

- **Manual specification**: Override auto-detection by providing provider name
  ```bash
  # Auto-detect provider (default)
  ./ccswitch.sh --add-account

  # Specify provider manually
  ./ccswitch.sh --add-account anthropic
  ./ccswitch.sh --add-account z.ai
  ./ccswitch.sh --add-account work
  ./ccswitch.sh --add-account personal
  ```

- **Account identification**: Use `email@provider` format for unambiguous access
  ```bash
  ./ccswitch.sh --switch-to user@example.com@anthropic
  ./ccswitch.sh --switch-to user@example.com@z.ai
  ./ccswitch.sh --remove-account user@example.com@work
  ```

### First Time Setup

1. **Log into Claude Code** with your first account (make sure you're actively logged in)
2. Run `./ccswitch.sh --add-account` to add it to managed accounts
3. **Log out** and log into Claude Code with your second account
4. Run `./ccswitch.sh --add-account` again
5. Now you can switch between accounts with `./ccswitch.sh --switch`
6. **Important**: After each switch, restart Claude Code to use the new authentication

> **What gets switched:** Only your authentication credentials and provider information change. Your themes, settings, preferences, and chat history remain exactly the same.

## Requirements

- Bash 4.4+
- `jq` (JSON processor)

### Installing Dependencies

**macOS:**

```bash
brew install jq
```

**Ubuntu/Debian:**

```bash
sudo apt install jq
```

## How It Works

The switcher stores account authentication data separately:

- **macOS**: Credentials in Keychain, OAuth info in `~/.claude-switch-backup/`
- **Linux/WSL**: Both credentials and OAuth info in `~/.claude-switch-backup/` with restricted permissions

When switching accounts, it:

1. Backs up the current account's authentication data
2. Restores the target account's authentication data
3. Updates Claude Code's authentication files

## Troubleshooting

### If a switch fails

- Check that you have accounts added: `./ccswitch.sh --list`
- Verify Claude Code is closed before switching
- Try switching back to your original account

### If you can't add an account

- Make sure you're logged into Claude Code first
- Check that you have `jq` installed
- Verify you have write permissions to your home directory

### If Claude Code doesn't recognize the new account

- Make sure you restarted Claude Code after switching
- Check the current account: `./ccswitch.sh --list` (look for "(active)")

## Cleanup/Uninstall

To stop using this tool and remove all data:

1. Note your current active account: `./ccswitch.sh --list`
2. Remove the backup directory: `rm -rf ~/.claude-switch-backup`
3. Delete the script: `rm ccswitch.sh`

Your current Claude Code login will remain active.

## Security Notes

- Credentials stored in macOS Keychain or files with 600 permissions
- Authentication files are stored with restricted permissions (600)
- The tool requires Claude Code to be closed during account switches

## License

MIT License - see LICENSE file for details
