#!/bin/bash

# 🐧 WSL2 Podman Network Fix
# On WSL2 the stock Microsoft kernel lacks some nf_tables features that
# netavark (Podman's network backend) relies on, so creating or starting
# containers on a custom network fails with "netavark: nftables error".
# This module switches netavark to the iptables firewall driver, backed by
# iptables-legacy, for both rootless and rootful Podman.

# Load required libraries
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/colors.sh"
source "$LIB_DIR/prompt-utils.sh"
source "$LIB_DIR/os-detect.sh"

WSL2_PODMAN_ROOTLESS_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/containers/containers.conf"
WSL2_PODMAN_ROOTFUL_CONF="/etc/containers/containers.conf"

# Run a command as root (directly when already root, via sudo otherwise)
_wsl2_as_root() {
    if is_root; then
        "$@"
    else
        sudo "$@"
    fi
}

# True when Podman uses netavark (the only backend affected by the bug)
_wsl2_podman_uses_netavark() {
    local backend
    backend=$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null)
    # Older Podman versions don't expose the field: assume netavark,
    # which has been the default backend since Podman 4.0
    [ -z "$backend" ] || [ "$backend" = "netavark" ]
}

# True when iptables currently resolves to the legacy (non nf_tables) backend
_wsl2_iptables_is_legacy() {
    local iptables_bin

    # iptables often lives in /usr/sbin, which may be missing from a user PATH
    iptables_bin=$(command -v iptables 2>/dev/null || true)
    for candidate in /usr/sbin/iptables /sbin/iptables; do
        [ -n "$iptables_bin" ] && break
        [ -x "$candidate" ] && iptables_bin=$candidate
    done

    [ -n "$iptables_bin" ] && "$iptables_bin" --version 2>/dev/null | grep -q "legacy"
}

# Print the firewall_driver value configured in a containers.conf (empty if unset)
_wsl2_get_firewall_driver() {
    local conf_file=$1

    [ -r "$conf_file" ] || return 0
    awk '
        /^[[:space:]]*\[/ { in_network = ($0 ~ /^[[:space:]]*\[network\][[:space:]]*$/) }
        in_network && /^[[:space:]]*firewall_driver[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/["[:space:]]/, "")
            print
            exit
        }
    ' "$conf_file"
}

# True when nothing needs to change
_wsl2_podman_fix_already_applied() {
    _wsl2_iptables_is_legacy && \
        [ "$(_wsl2_get_firewall_driver "$WSL2_PODMAN_ROOTLESS_CONF")" = "iptables" ] && \
        [ "$(_wsl2_get_firewall_driver "$WSL2_PODMAN_ROOTFUL_CONF")" = "iptables" ]
}

# Install the iptables package (provides both iptables-nft and iptables-legacy)
_wsl2_install_iptables() {
    local install_cmd

    if command -v iptables-legacy &> /dev/null || [ -x /usr/sbin/iptables-legacy ]; then
        print_success "iptables-legacy already installed"
        return 0
    fi

    install_cmd=$(get_install_command)
    if [ -z "$install_cmd" ]; then
        print_error "Unsupported package manager: install iptables manually"
        return 1
    fi

    print_step "Installing iptables..."
    case "$PACKAGE_MANAGER" in
        apt)
            sudo apt-get update -qq || true
            $install_cmd iptables || return 1
            ;;
        dnf|yum)
            # On Fedora/RHEL the legacy binaries ship in a separate package
            $install_cmd iptables-legacy || $install_cmd iptables || return 1
            ;;
        *)
            $install_cmd iptables || return 1
            ;;
    esac

    if command -v iptables-legacy &> /dev/null || [ -x /usr/sbin/iptables-legacy ]; then
        print_success "iptables installed"
        return 0
    fi

    print_error "iptables-legacy not available after installation"
    return 1
}

# Point the iptables/ip6tables alternatives to the legacy backend
_wsl2_switch_to_iptables_legacy() {
    local alt_cmd=""
    local legacy_dir=""

    if command -v update-alternatives &> /dev/null; then
        alt_cmd="update-alternatives"
    elif command -v alternatives &> /dev/null; then
        alt_cmd="alternatives"
    else
        print_error "Neither update-alternatives nor alternatives found"
        return 1
    fi

    for dir in /usr/sbin /sbin /usr/bin; do
        if [ -x "$dir/iptables-legacy" ]; then
            legacy_dir=$dir
            break
        fi
    done

    if [ -z "$legacy_dir" ]; then
        print_error "iptables-legacy binary not found"
        return 1
    fi

    print_step "Switching iptables to the legacy backend..."
    if ! _wsl2_as_root "$alt_cmd" --set iptables "$legacy_dir/iptables-legacy" > /dev/null; then
        print_error "Failed to switch iptables to iptables-legacy"
        return 1
    fi

    # ip6tables is best effort: some distros don't register it as an alternative
    if [ -x "$legacy_dir/ip6tables-legacy" ]; then
        _wsl2_as_root "$alt_cmd" --set ip6tables "$legacy_dir/ip6tables-legacy" > /dev/null 2>&1 || \
            print_warning "Could not switch ip6tables to ip6tables-legacy (IPv6 networking may still fail)"
    fi

    print_success "iptables now uses the legacy backend"
}

# Set firewall_driver = "iptables" in the [network] section of a containers.conf
# Usage: _wsl2_set_firewall_driver <conf_file> <as_root: true|false>
_wsl2_set_firewall_driver() {
    local conf_file=$1
    local as_root=$2
    local tmp_file

    if [ "$(_wsl2_get_firewall_driver "$conf_file")" = "iptables" ]; then
        print_success "firewall_driver already set in $conf_file"
        return 0
    fi

    tmp_file=$(mktemp) || return 1

    if [ -f "$conf_file" ]; then
        # Replace an existing firewall_driver in [network], add it to an
        # existing [network] section, or append a new [network] section
        awk '
            function flush_missing() {
                if (in_network && !done) { print "firewall_driver = \"iptables\""; done = 1 }
            }
            /^[[:space:]]*\[/ {
                flush_missing()
                in_network = ($0 ~ /^[[:space:]]*\[network\][[:space:]]*$/)
                if (in_network) seen_network = 1
                print
                next
            }
            in_network && /^[[:space:]]*#?[[:space:]]*firewall_driver[[:space:]]*=/ {
                if (!done) { print "firewall_driver = \"iptables\""; done = 1 }
                next
            }
            { print }
            END {
                flush_missing()
                if (!seen_network) { print ""; print "[network]"; print "firewall_driver = \"iptables\"" }
            }
        ' "$conf_file" > "$tmp_file"

        # Keep a timestamped backup of the original file
        if [ "$as_root" = true ]; then
            _wsl2_as_root cp -p "$conf_file" "$conf_file.backup.$(date +%Y%m%d_%H%M%S)" || { rm -f "$tmp_file"; return 1; }
        else
            cp -p "$conf_file" "$conf_file.backup.$(date +%Y%m%d_%H%M%S)" || { rm -f "$tmp_file"; return 1; }
        fi
    else
        printf '[network]\nfirewall_driver = "iptables"\n' > "$tmp_file"
    fi

    if [ "$as_root" = true ]; then
        _wsl2_as_root mkdir -p "$(dirname "$conf_file")" && \
            _wsl2_as_root install -m 0644 "$tmp_file" "$conf_file"
    else
        mkdir -p "$(dirname "$conf_file")" && \
            install -m 0644 "$tmp_file" "$conf_file"
    fi
    local rc=$?
    rm -f "$tmp_file"

    if [ $rc -ne 0 ]; then
        print_error "Failed to update $conf_file"
        return 1
    fi

    print_success "firewall_driver = \"iptables\" set in $conf_file"
}

# Remove unused Podman networks so they are recreated with the new driver
_wsl2_cleanup_podman_networks() {
    print_step "Cleaning up unused Podman networks..."

    if podman network prune -f > /dev/null 2>&1; then
        print_success "Rootless Podman networks cleaned"
    else
        print_warning "Could not prune rootless Podman networks"
    fi

    if _wsl2_as_root podman network prune -f > /dev/null 2>&1; then
        print_success "Rootful Podman networks cleaned"
    else
        print_warning "Could not prune rootful Podman networks"
    fi

    # Re-apply firewall rules for containers that are still running
    podman network reload --all > /dev/null 2>&1 || true
}

# Apply the WSL2 Podman network fix
# Returns 0 when the fix is applied (or not needed), 1 on failure or if declined
apply_wsl2_podman_fix() {
    if ! is_wsl2; then
        return 0
    fi

    if ! command -v podman &> /dev/null; then
        return 0
    fi

    if ! _wsl2_podman_uses_netavark; then
        print_info "Podman network backend is not netavark, WSL2 fix not needed"
        return 0
    fi

    if _wsl2_podman_fix_already_applied; then
        print_success "WSL2 Podman network fix already applied"
        return 0
    fi

    echo ""
    print_warning "WSL2 detected: Podman networking needs iptables-legacy"
    echo ""
    echo "The WSL2 kernel does not fully support nftables, so netavark fails"
    echo "to create container networks. The fix will (requires sudo):"
    echo "  - install iptables and switch it to the legacy backend"
    echo "  - set firewall_driver = \"iptables\" in:"
    echo "      $WSL2_PODMAN_ROOTLESS_CONF"
    echo "      $WSL2_PODMAN_ROOTFUL_CONF"
    echo "  - remove unused Podman networks"
    echo ""

    if ! ask_yes_no "Apply the WSL2 Podman network fix?" "y"; then
        print_warning "Skipping WSL2 fix: containers may fail to start"
        return 1
    fi

    _wsl2_install_iptables || return 1
    _wsl2_switch_to_iptables_legacy || return 1
    _wsl2_set_firewall_driver "$WSL2_PODMAN_ROOTLESS_CONF" false || return 1
    _wsl2_set_firewall_driver "$WSL2_PODMAN_ROOTFUL_CONF" true || return 1
    _wsl2_cleanup_podman_networks

    print_success "WSL2 Podman network fix applied"
    echo ""
}
