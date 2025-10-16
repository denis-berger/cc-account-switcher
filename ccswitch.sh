#!/usr/bin/env bash

# Multi-Account Switcher for Claude Code
# Simple tool to manage and switch between multiple Claude Code accounts

set -euo pipefail

# Configuration
readonly BACKUP_DIR="$HOME/.claude-switch-backup"
readonly SEQUENCE_FILE="$BACKUP_DIR/sequence.json"

# Container detection
is_running_in_container() {
    # Check for Docker environment file
    if [[ -f /.dockerenv ]]; then
        return 0
    fi
    
    # Check cgroup for container indicators
    if [[ -f /proc/1/cgroup ]] && grep -q 'docker\|lxc\|containerd\|kubepods' /proc/1/cgroup 2>/dev/null; then
        return 0
    fi
    
    # Check mount info for container filesystems
    if [[ -f /proc/self/mountinfo ]] && grep -q 'docker\|overlay' /proc/self/mountinfo 2>/dev/null; then
        return 0
    fi
    
    # Check for common container environment variables
    if [[ -n "${CONTAINER:-}" ]] || [[ -n "${container:-}" ]]; then
        return 0
    fi
    
    return 1
}

# Platform detection
detect_platform() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux) 
            if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

# Get Claude configuration file path with fallback
get_claude_config_path() {
    local primary_config="$HOME/.claude/.claude.json"
    local fallback_config="$HOME/.claude.json"
    
    # Check primary location first
    if [[ -f "$primary_config" ]]; then
        # Verify it has valid oauthAccount structure
        if jq -e '.oauthAccount' "$primary_config" >/dev/null 2>&1; then
            echo "$primary_config"
            return
        fi
    fi
    
    # Fallback to standard location
    echo "$fallback_config"
}

# Basic validation that JSON is valid
validate_json() {
    local file="$1"
    if ! jq . "$file" >/dev/null 2>&1; then
        echo "Error: Invalid JSON in $file"
        return 1
    fi
}

# Email validation function
validate_email() {
    local email="$1"
    # Use robust regex for email validation
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Extract provider information from UUID
extract_provider() {
    local uuid="$1"
    if [[ -z "$uuid" || "$uuid" == "null" ]]; then
        echo "unknown"
        return
    fi

    # Add logic to identify provider based on UUID patterns
    # This is a placeholder - you'll need to adjust based on actual UUID patterns
    if [[ "$uuid" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
        echo "anthropic"  # Standard UUID format, likely Anthropic
    elif [[ "$uuid" =~ ^zai_ ]]; then
        echo "z.ai"       # Z.AI UUID pattern
    else
        echo "unknown"    # Fallback
    fi
}

# Create unique account identifier
create_account_id() {
    local email="$1"
    local uuid="$2"
    local manual_provider="${3:-}"
    local provider
    if [[ -n "$manual_provider" ]]; then
        provider="$manual_provider"
    else
        provider=$(extract_provider "$uuid")
    fi
    echo "${email}@${provider}"
}

# Parse account ID into email and provider
parse_account_id() {
    local account_id="$1"
    if [[ "$account_id" =~ ^(.+)@(.+)$ ]]; then
        echo "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        echo "$account_id" "unknown"
    fi
}

# Account identifier resolution function
resolve_account_identifier() {
    local identifier="$1"
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        echo "$identifier"  # It's a number
    else
        # Parse identifier to extract email and potential provider
        local email provider account_id
        if [[ "$identifier" =~ ^(.+)@(.+)$ ]]; then
            email="${BASH_REMATCH[1]}"
            provider="${BASH_REMATCH[2]}"
            account_id="$identifier"  # Full email@provider format
        else
            email="$identifier"
            account_id=""  # Will be constructed below
        fi

        # Try to find account(s) by email
        local accounts
        accounts=$(jq -r --arg email "$email" '.accounts | to_entries[] | select(.value.email == $email) | "\(.key):\(.value.accountId // .value.email)"' "$SEQUENCE_FILE" 2>/dev/null)

        if [[ -z "$accounts" ]]; then
            echo ""
            return
        fi

        # If no provider specified and multiple accounts exist, show options
        if [[ -z "$account_id" ]]; then
            local count
            count=$(echo "$accounts" | wc -l)
            if [[ $count -gt 1 ]]; then
                echo "Multiple accounts found for email '$email':" >&2
                echo "$accounts" | while IFS=: read -r num acc_id; do
                    local acc_email acc_provider
                    read -r acc_email acc_provider <<< "$(parse_account_id "$acc_id")"
                    echo "  Account $num: ${acc_email} (${acc_provider})" >&2
                done
                echo "Please specify with: --switch-to ${email}[provider] or use account number" >&2
                echo ""
                return
            else
                # Single account, use it
                echo "$accounts" | cut -d: -f1
                return
            fi
        fi

        # Find account matching the full account_id
        local account_num
        account_num=$(echo "$accounts" | grep -F ":$account_id" | cut -d: -f1)
        if [[ -n "$account_num" ]]; then
            echo "$account_num"
        else
            echo ""
        fi
    fi
}

# Safe JSON write with validation
write_json() {
    local file="$1"
    local content="$2"
    local temp_file
    temp_file=$(mktemp "${file}.XXXXXX")
    
    echo "$content" > "$temp_file"
    if ! jq . "$temp_file" >/dev/null 2>&1; then
        rm -f "$temp_file"
        echo "Error: Generated invalid JSON"
        return 1
    fi
    
    mv "$temp_file" "$file"
    chmod 600 "$file"
}

# Check Bash version (4.4+ required)
check_bash_version() {
    local version
    version=$(bash --version | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
    if ! awk -v ver="$version" 'BEGIN { exit (ver >= 4.4 ? 0 : 1) }'; then
        echo "Error: Bash 4.4+ required (found $version)"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    for cmd in jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: Required command '$cmd' not found"
            echo "Install with: apt install $cmd (Linux) or brew install $cmd (macOS)"
            exit 1
        fi
    done
}

# Setup backup directories
setup_directories() {
    mkdir -p "$BACKUP_DIR"/{configs,credentials}
    chmod 700 "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"/{configs,credentials}
}

# Claude Code process detection (Node.js app)
is_claude_running() {
    ps -eo pid,comm,args | awk '$2 == "claude" || $3 == "claude" {exit 0} END {exit 1}'
}

# Wait for Claude Code to close (no timeout - user controlled)
wait_for_claude_close() {
    if ! is_claude_running; then
        return 0
    fi
    
    echo "Claude Code is running. Please close it first."
    echo "Waiting for Claude Code to close..."
    
    while is_claude_running; do
        sleep 1
    done
    
    echo "Claude Code closed. Continuing..."
}

# Get current account info from .claude.json
get_current_account() {
    if [[ ! -f "$(get_claude_config_path)" ]]; then
        echo "none"
        return
    fi
    
    if ! validate_json "$(get_claude_config_path)"; then
        echo "none"
        return
    fi
    
    local email
    email=$(jq -r '.oauthAccount.emailAddress // empty' "$(get_claude_config_path)" 2>/dev/null)
    echo "${email:-none}"
}

# Read credentials based on platform
read_credentials() {
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            if [[ -f "$HOME/.claude/.credentials.json" ]]; then
                cat "$HOME/.claude/.credentials.json"
            else
                echo ""
            fi
            ;;
    esac
}

# Write credentials based on platform
write_credentials() {
    local credentials="$1"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            mkdir -p "$HOME/.claude"
            printf '%s' "$credentials" > "$HOME/.claude/.credentials.json"
            chmod 600 "$HOME/.claude/.credentials.json"
            ;;
    esac
}

# Read account credentials from backup
read_account_credentials() {
    local account_num="$1"
    local account_id="$2"
    local platform
    platform=$(detect_platform)

    case "$platform" in
        macos)
            # Try new format first (with account_id)
            security find-generic-password -s "Claude Code-Account-${account_num}-${account_id}" -w 2>/dev/null || \
            # Fallback to old format (with email only)
            security find-generic-password -s "Claude Code-Account-${account_num}-${account_id%%@*}" -w 2>/dev/null || echo ""
            ;;
        linux|wsl)
            # Try new format first (with account_id)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${account_id}.json"
            if [[ -f "$cred_file" ]]; then
                cat "$cred_file"
            else
                # Fallback to old format (with email only)
                local old_cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${account_id%%@*}.json"
                if [[ -f "$old_cred_file" ]]; then
                    cat "$old_cred_file"
                else
                    echo ""
                fi
            fi
            ;;
    esac
}

# Write account credentials to backup
write_account_credentials() {
    local account_num="$1"
    local email="$2"
    local credentials="$3"
    local platform
    platform=$(detect_platform)
    
    case "$platform" in
        macos)
            security add-generic-password -U -s "Claude Code-Account-${account_num}-${email}" -a "$USER" -w "$credentials" 2>/dev/null
            ;;
        linux|wsl)
            local cred_file="$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${email}.json"
            printf '%s' "$credentials" > "$cred_file"
            chmod 600 "$cred_file"
            ;;
    esac
}

# Read account config from backup
read_account_config() {
    local account_num="$1"
    local account_id="$2"

    # Try new format first (with account_id)
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${account_id}.json"
    if [[ -f "$config_file" ]]; then
        cat "$config_file"
    else
        # Fallback to old format (with email only)
        local old_config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${account_id%%@*}.json"
        if [[ -f "$old_config_file" ]]; then
            cat "$old_config_file"
        else
            echo ""
        fi
    fi
}

# Write account config to backup
write_account_config() {
    local account_num="$1"
    local email="$2"
    local config="$3"
    local config_file="$BACKUP_DIR/configs/.claude-config-${account_num}-${email}.json"
    
    echo "$config" > "$config_file"
    chmod 600 "$config_file"
}

# Initialize sequence.json if it doesn't exist
init_sequence_file() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        local init_content='{
  "activeAccountNumber": null,
  "lastUpdated": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
  "sequence": [],
  "accounts": {}
}'
        write_json "$SEQUENCE_FILE" "$init_content"
    fi
}

# Get next account number
get_next_account_number() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "1"
        return
    fi
    
    local max_num
    max_num=$(jq -r '.accounts | keys | map(tonumber) | max // 0' "$SEQUENCE_FILE")
    echo $((max_num + 1))
}

# Check if account exists by email (returns true if any account with this email exists)
account_exists() {
    local email="$1"
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 1
    fi

    jq -e --arg email "$email" '.accounts[] | select(.email == $email)' "$SEQUENCE_FILE" >/dev/null 2>&1
}

# Check if specific account (email + provider) exists
account_exists_full() {
    local email="$1"
    local uuid="$2"
    local account_id
    account_id=$(create_account_id "$email" "$uuid")

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        return 1
    fi

    jq -e --arg account_id "$account_id" '.accounts[] | select(.accountId == $account_id)' "$SEQUENCE_FILE" >/dev/null 2>&1
}

# Add account
cmd_add_account() {
    setup_directories
    init_sequence_file

    local manual_provider="$1"

    local current_email
    current_email=$(get_current_account)

    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found. Please log in first."
        exit 1
    fi

    # Get account UUID
    local account_uuid
    account_uuid=$(jq -r '.oauthAccount.accountUuid' "$(get_claude_config_path)")

    # Create unique account ID with manual or auto-detected provider
    local account_id
    account_id=$(create_account_id "$current_email" "$account_uuid" "$manual_provider")

    # Check if this specific account (email + provider) already exists
    if account_exists_full "$current_email" "$account_uuid"; then
        local provider
        if [[ -n "$manual_provider" ]]; then
            provider="$manual_provider"
        else
            provider=$(extract_provider "$account_uuid")
        fi
        echo "Account $current_email ($provider) is already managed."
        exit 0
    fi

    local account_num
    account_num=$(get_next_account_number)

    # Backup current credentials and config
    local current_creds current_config
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")

    if [[ -z "$current_creds" ]]; then
        echo "Error: No credentials found for current account"
        exit 1
    fi

    # Store backups using account_id for uniqueness
    write_account_credentials "$account_num" "$account_id" "$current_creds"
    write_account_config "$account_num" "$account_id" "$current_config"

    # Update sequence.json with new account ID format
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg email "$current_email" --arg uuid "$account_uuid" --arg account_id "$account_id" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .accounts[$num] = {
            email: $email,
            uuid: $uuid,
            accountId: $account_id,
            added: $now
        } |
        .sequence += [$num | tonumber] |
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"

    # Display provider info
    local provider
    if [[ -n "$manual_provider" ]]; then
        provider="$manual_provider (manual)"
    else
        provider="$(extract_provider "$account_uuid") (auto-detected)"
    fi
    echo "Added Account $account_num: $current_email ($provider)"
}

# Remove account
cmd_remove_account() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --remove-account <account_number|email[@provider]>"
        exit 1
    fi

    local identifier="$1"
    local account_num

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    # Handle email vs numeric identifier
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        account_num="$identifier"
    else
        # Handle email[@provider] format
        if [[ "$identifier" =~ ^(.+)@(.+)$ ]]; then
            local email="${BASH_REMATCH[1]}"
            local provider="${BASH_REMATCH[2]}"
            # Validate email part
            if ! validate_email "$email"; then
                echo "Error: Invalid email format: $email"
                exit 1
            fi
        else
            # Validate email format
            if ! validate_email "$identifier"; then
                echo "Error: Invalid email format: $identifier"
                exit 1
            fi
        fi

        # Resolve identifier to account number
        account_num=$(resolve_account_identifier "$identifier")
        if [[ -z "$account_num" ]]; then
            echo "Error: No account found with identifier: $identifier"
            exit 1
        fi
    fi

    local account_info
    account_info=$(jq -r --arg num "$account_num" '.accounts[$num] // empty' "$SEQUENCE_FILE")

    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$account_num does not exist"
        exit 1
    fi

    local email account_id
    email=$(echo "$account_info" | jq -r '.email')
    account_id=$(echo "$account_info" | jq -r '.accountId')

    local active_account
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")

    # Parse account ID to show provider
    local acc_email provider
    read -r acc_email provider <<< "$(parse_account_id "$account_id")"

    if [[ "$active_account" == "$account_num" ]]; then
        echo "Warning: Account-$account_num ($email) with provider ($provider) is currently active"
    fi

    echo -n "Are you sure you want to permanently remove Account-$account_num ($email) with provider ($provider)? [y/N] "
    read -r confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cancelled"
        exit 0
    fi

    # Remove backup files using account_id for uniqueness
    local platform
    platform=$(detect_platform)
    case "$platform" in
        macos)
            security delete-generic-password -s "Claude Code-Account-${account_num}-${account_id}" 2>/dev/null || true
            ;;
        linux|wsl)
            rm -f "$BACKUP_DIR/credentials/.claude-credentials-${account_num}-${account_id}.json"
            ;;
    esac
    rm -f "$BACKUP_DIR/configs/.claude-config-${account_num}-${account_id}.json"

    # Update sequence.json
    local updated_sequence
    updated_sequence=$(jq --arg num "$account_num" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        del(.accounts[$num]) |
        .sequence = (.sequence | map(select(. != ($num | tonumber)))) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"

    echo "Account-$account_num ($email) with provider ($provider) has been removed"
}

# First-run setup workflow
first_run_setup() {
    local current_email
    current_email=$(get_current_account)
    
    if [[ "$current_email" == "none" ]]; then
        echo "No active Claude account found. Please log in first."
        return 1
    fi
    
    echo -n "No managed accounts found. Add current account ($current_email) to managed list? [Y/n] "
    read -r response
    
    if [[ "$response" == "n" || "$response" == "N" ]]; then
        echo "Setup cancelled. You can run '$0 --add-account' later."
        return 1
    fi
    
    cmd_add_account
    return 0
}

# List accounts
cmd_list() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "No accounts are managed yet."
        first_run_setup
        exit 0
    fi

    # Get current active account from .claude.json
    local current_email
    current_email=$(get_current_account)

    # Find which account number corresponds to the current email
    local active_account_num=""
    if [[ "$current_email" != "none" ]]; then
        # Method 1: Look for account with matching email and UUID (if available)
        local current_uuid
        current_uuid=$(jq -r '.oauthAccount.accountUuid // empty' "$(get_claude_config_path)" 2>/dev/null)

        if [[ -n "$current_uuid" && "$current_uuid" != "null" ]]; then
            local current_account_id
            current_account_id=$(create_account_id "$current_email" "$current_uuid")
            active_account_num=$(jq -r --arg account_id "$current_account_id" '.accounts | to_entries[] | select(.value.accountId == $account_id) | .key' "$SEQUENCE_FILE" 2>/dev/null)
        fi

        # Method 2: If UUID matching failed, use activeAccountNumber from sequence.json
        if [[ -z "$active_account_num" || "$active_account_num" == "null" ]]; then
            active_account_num=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE" 2>/dev/null)
            # Validate that this account number actually exists and matches the email
            local account_email
            account_email=$(jq -r --arg num "$active_account_num" '.accounts[$num].email' "$SEQUENCE_FILE" 2>/dev/null)
            if [[ "$account_email" != "$current_email" ]]; then
                active_account_num=""
            fi
        fi

        # Method 3: Final fallback - simple email match (might match multiple, use first)
        if [[ -z "$active_account_num" || "$active_account_num" == "null" ]]; then
            active_account_num=$(jq -r --arg email "$current_email" '.accounts | to_entries[] | select(.value.email == $email) | .key' "$SEQUENCE_FILE" 2>/dev/null | head -n1)
        fi
    fi

    echo "Accounts:"
    jq -r --arg active "$active_account_num" '
        .sequence[] as $num |
        .accounts["\($num)"] |
        if .accountId then
            # New format with accountId - take the last part after @
            ( .accountId | split("@") ) as $parts |
            if "\($num)" == $active then
                "* \($num): \(.email) (\($parts[-1])) (active)"
            else
                "  \($num): \(.email) (\($parts[-1]))"
            end
        else
            # Old format without accountId - extract provider from uuid
            if (.uuid | test("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$")) then
                if "\($num)" == $active then
                    "* \($num): \(.email) (anthropic) (active)"
                else
                    "  \($num): \(.email) (anthropic)"
                end
            elif (.uuid | test("^zai_")) then
                if "\($num)" == $active then
                    "* \($num): \(.email) (z.ai) (active)"
                else
                    "  \($num): \(.email) (z.ai)"
                end
            else
                if "\($num)" == $active then
                    "* \($num): \(.email) (unknown) (active)"
                else
                    "  \($num): \(.email) (unknown)"
                end
            end
        end
    ' "$SEQUENCE_FILE"
}

# Switch to next account
cmd_switch() {
    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi
    
    local current_email
    current_email=$(get_current_account)
    
    if [[ "$current_email" == "none" ]]; then
        echo "Error: No active Claude account found"
        exit 1
    fi
    
    # Check if current account is managed
    if ! account_exists "$current_email"; then
        echo "Notice: Active account '$current_email' was not managed."
        cmd_add_account
        local account_num
        account_num=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
        echo "It has been automatically added as Account-$account_num."
        echo "Please run './ccswitch.sh --switch' again to switch to the next account."
        exit 0
    fi
    
    # wait_for_claude_close
    
    local active_account sequence
    active_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    sequence=($(jq -r '.sequence[]' "$SEQUENCE_FILE"))
    
    # Find next account in sequence
    local next_account current_index=0
    for i in "${!sequence[@]}"; do
        if [[ "${sequence[i]}" == "$active_account" ]]; then
            current_index=$i
            break
        fi
    done
    
    next_account="${sequence[$(((current_index + 1) % ${#sequence[@]}))]}"
    
    perform_switch "$next_account"
}

# Switch to specific account
cmd_switch_to() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 --switch-to <account_number|email[@provider]>"
        exit 1
    fi

    local identifier="$1"
    local target_account

    if [[ ! -f "$SEQUENCE_FILE" ]]; then
        echo "Error: No accounts are managed yet"
        exit 1
    fi

    # Handle email vs numeric identifier
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        target_account="$identifier"
    else
        # Handle email[@provider] format
        if [[ "$identifier" =~ ^(.+)@(.+)$ ]]; then
            local email="${BASH_REMATCH[1]}"
            local provider="${BASH_REMATCH[2]}"
            # Validate email part
            if ! validate_email "$email"; then
                echo "Error: Invalid email format: $email"
                exit 1
            fi
        else
            # Validate email format
            if ! validate_email "$identifier"; then
                echo "Error: Invalid email format: $identifier"
                exit 1
            fi
        fi

        # Resolve identifier to account number
        target_account=$(resolve_account_identifier "$identifier")
        if [[ -z "$target_account" ]]; then
            echo "Error: No account found with identifier: $identifier"
            exit 1
        fi
    fi

    local account_info
    account_info=$(jq -r --arg num "$target_account" '.accounts[$num] // empty' "$SEQUENCE_FILE")

    if [[ -z "$account_info" ]]; then
        echo "Error: Account-$target_account does not exist"
        exit 1
    fi

    # wait_for_claude_close
    perform_switch "$target_account"
}

# Perform the actual account switch
perform_switch() {
    local target_account="$1"

    # Get current and target account info
    local current_account target_account_id target_email current_email
    current_account=$(jq -r '.activeAccountNumber' "$SEQUENCE_FILE")
    target_account_id=$(jq -r --arg num "$target_account" '.accounts[$num].accountId // .accounts[$num].email' "$SEQUENCE_FILE")
    target_email=$(jq -r --arg num "$target_account" '.accounts[$num].email' "$SEQUENCE_FILE")
    current_email=$(get_current_account)

    # Step 1: Backup current account
    local current_creds current_config current_account_id
    current_creds=$(read_credentials)
    current_config=$(cat "$(get_claude_config_path)")
    current_account_id=$(jq -r --arg num "$current_account" '.accounts[$num].accountId // .accounts[$num].email' "$SEQUENCE_FILE")

    write_account_credentials "$current_account" "$current_account_id" "$current_creds"
    write_account_config "$current_account" "$current_account_id" "$current_config"

    # Step 2: Retrieve target account
    local target_creds target_config
    target_creds=$(read_account_credentials "$target_account" "$target_account_id")
    target_config=$(read_account_config "$target_account" "$target_account_id")

    if [[ -z "$target_creds" || -z "$target_config" ]]; then
        echo "Error: Missing backup data for Account-$target_account"
        exit 1
    fi

    # Step 3: Activate target account
    write_credentials "$target_creds"

    # Extract oauthAccount from backup and validate
    local oauth_section
    oauth_section=$(echo "$target_config" | jq '.oauthAccount' 2>/dev/null)
    if [[ -z "$oauth_section" || "$oauth_section" == "null" ]]; then
        echo "Error: Invalid oauthAccount in backup"
        exit 1
    fi

    # Merge with current config and validate
    local merged_config
    merged_config=$(jq --argjson oauth "$oauth_section" '.oauthAccount = $oauth' "$(get_claude_config_path)" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to merge config"
        exit 1
    fi

    # Use existing safe write_json function
    write_json "$(get_claude_config_path)" "$merged_config"

    # Step 4: Update state
    local updated_sequence
    updated_sequence=$(jq --arg num "$target_account" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .activeAccountNumber = ($num | tonumber) |
        .lastUpdated = $now
    ' "$SEQUENCE_FILE")

    write_json "$SEQUENCE_FILE" "$updated_sequence"

    # Parse account ID to show provider - handle both old and new formats
    local provider
    # Count the number of @ symbols
    local at_count
    at_count=$(echo "$target_account_id" | grep -o '@' | wc -l)

    if [[ $at_count -gt 1 ]]; then
        # New format with multiple @ - take the last part after @
        provider="$(echo "$target_account_id" | awk -F'@' '{print $NF}')"
    else
        # Old format (single @ = email) - extract from UUID
        local target_uuid
        target_uuid=$(jq -r --arg num "$target_account" '.accounts[$num].uuid' "$SEQUENCE_FILE")
        provider=$(extract_provider "$target_uuid")
    fi

    echo "Switched to Account-$target_account ($target_email) with provider ($provider)"
    # Display updated account list
    cmd_list
    echo ""
    echo "Please restart Claude Code to use the new authentication."
    echo ""

}

# Show usage
show_usage() {
    echo "Multi-Account Switcher for Claude Code"
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  --add-account [provider]                     Add current account to managed accounts, optionally specifying provider"
    echo "  --remove-account <num|email[@provider]>      Remove account by number or email with optional provider"
    echo "  --list                                        List all managed accounts with providers"
    echo "  --switch                                      Rotate to next account in sequence"
    echo "  --switch-to <num|email[@provider]>           Switch to specific account number or email with optional provider"
    echo "  --help                                        Show this help message"
    echo ""
    echo "Provider Support:"
    echo "  The tool supports multiple accounts with the same email from different providers."
    echo "  - Auto-detection: Providers are automatically detected from account UUIDs (anthropic, z.ai, unknown)"
    echo "  - Manual specification: Override auto-detection by providing provider name when adding accounts"
    echo ""
    echo "Provider Examples:"
    echo "  anthropic, z.ai, custom, work, personal, etc."
    echo ""
    echo "Usage Examples:"
    echo "  $0 --add-account                           # Auto-detect provider"
    echo "  $0 --add-account anthropic                 # Force provider as 'anthropic'"
    echo "  $0 --add-account z.ai                      # Force provider as 'z.ai'"
    echo "  $0 --add-account work                      # Use custom provider name 'work'"
    echo "  $0 --list"
    echo "  $0 --switch"
    echo "  $0 --switch-to 2"
    echo "  $0 --switch-to user@example.com"
    echo "  $0 --switch-to user@example.com@anthropic"
    echo "  $0 --switch-to user@example.com@z.ai"
    echo "  $0 --switch-to user@example.com@work"
    echo "  $0 --remove-account user@example.com@z.ai"
}

# Main script logic
main() {
    # Basic checks - allow root execution in containers
    if [[ $EUID -eq 0 ]] && ! is_running_in_container; then
        echo "Error: Do not run this script as root (unless running in a container)"
        exit 1
    fi
    
    check_bash_version
    check_dependencies
    
    case "${1:-}" in
        --add-account)
            shift
            cmd_add_account "$@"
            ;;
        --remove-account)
            shift
            cmd_remove_account "$@"
            ;;
        --list)
            cmd_list
            ;;
        --switch)
            cmd_switch
            ;;
        --switch-to)
            shift
            cmd_switch_to "$@"
            ;;
        --help)
            show_usage
            ;;
        "")
            show_usage
            ;;
        *)
            echo "Error: Unknown command '$1'"
            show_usage
            exit 1
            ;;
    esac
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi