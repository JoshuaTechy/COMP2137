#!/bin/bash

# Assignment 2 - COMP2137 - Joshua Naccarato
#
# Brings this server in line with the required configuration:
# -192.168.16.21/24 on the 192.168.16 interface (mgmt interface untouched)
# -/etc/hosts maps server1 to 192.168.16.21, old address removed
# -apache2 and squid installed and running as default config
# -user accounts with home dirs in /home, bash shell, rsa + ed25519 keys
#  added to their own authorized_keys
# -dennis additionally has sudo and an extra provided public key
#
# Safe to re-run: each section checks current state before changing anything.

set -u

# Exit early if not run as root

[[ "$EUID" -eq 0 ]] || { echo "ERROR: this script must be run as root (try: sudo $0)"; exit 1; }

# Network configuration

DESIRED_ADDR="192.168.16.21/24"
DESIRED_ADDR_RE="192\.168\.16\.21/24"
OLD_ADDR_PATTERN="192\.168\.16\.[0-9]+/24"

# Finds the netplan file with the old 192.168.16.x address and updates
# it to 192.168.16.21/24, applying the change and confirming.
configure_network() {
    echo "----- Network configuration -----"

    NETPLAN_FILE=$(find /etc/netplan -maxdepth 1 -type f -name "*.yaml" \
        -exec grep -lE "$OLD_ADDR_PATTERN" {} + 2>/dev/null | head -n1)
    [[ -n "$NETPLAN_FILE" ]] || { echo "ERROR: no netplan file found defining a 192.168.16.x address"; return 1; }

    grep -qE "addresses: \[$DESIRED_ADDR_RE\]" "$NETPLAN_FILE" || \
        grep -qE "^[[:space:]]*-[[:space:]]*$DESIRED_ADDR_RE" "$NETPLAN_FILE" && \
        { echo "OK: address already set to $DESIRED_ADDR"; return 0; }

    cp "$NETPLAN_FILE" "${NETPLAN_FILE}.bak"

    if grep -qE "addresses: \[${OLD_ADDR_PATTERN}\]" "$NETPLAN_FILE"; then
        sed -i -E "s#addresses: \[${OLD_ADDR_PATTERN}\]#addresses: [$DESIRED_ADDR]#" "$NETPLAN_FILE"
    else
        sed -i -E "s#^([[:space:]]*-[[:space:]]*)${OLD_ADDR_PATTERN}#\1${DESIRED_ADDR}#" "$NETPLAN_FILE"
    fi

    echo "Applying netplan config..."
    netplan apply && echo "OK: netplan applied" || {
        echo "ERROR: netplan apply failed, restoring backup"
        cp "${NETPLAN_FILE}.bak" "$NETPLAN_FILE"
        netplan apply
        return 1
    }

    sleep 3
    ip -4 addr show | grep -q "$DESIRED_ADDR" && echo "OK: interface now has $DESIRED_ADDR" || \
        { echo "ERROR: no interface shows $DESIRED_ADDR, check manually"; return 1; }
}

# /etc/hosts configuration

HOSTS_FILE="/etc/hosts"
DESIRED_IP="192.168.16.21"
THIS_HOSTNAME=$(hostname)

# Makes sure /etc/hosts maps this server's hostname to 192.168.16.21,
# removing any old address entry for the same hostname first.

configure_hosts() {
    echo "== /etc/hosts configuration =="

    grep -qxE "${DESIRED_IP}[[:space:]]+${THIS_HOSTNAME}" "$HOSTS_FILE" && \
        { echo "OK: $THIS_HOSTNAME already maps to $DESIRED_IP"; return 0; }

    cp "$HOSTS_FILE" "${HOSTS_FILE}.bak"
    sed -i -E "/^[0-9.]+[[:space:]]+${THIS_HOSTNAME}([[:space:]]|$)/d" "$HOSTS_FILE"
    echo "$DESIRED_IP $THIS_HOSTNAME" >> "$HOSTS_FILE"

    grep -qxE "${DESIRED_IP}[[:space:]]+${THIS_HOSTNAME}" "$HOSTS_FILE" && \
        echo "OK: $THIS_HOSTNAME now maps to $DESIRED_IP" || \
        { echo "ERROR: couldn't verify the new /etc/hosts entry"; return 1; }
}

# Software installation

# Installs a package if missing, then make sure its service is
# enabled on boot and currently running. Used for both apache2 and squid.

ensure_package_running() {
    local package_name="$1"
    local service_name="$2"

    dpkg -s "$package_name" >/dev/null 2>&1 && echo "OK: $package_name already installed" || {
        echo "Installing $package_name..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$package_name"
    }

    systemctl enable --quiet "$service_name" 2>/dev/null
    systemctl is-active --quiet "$service_name" && echo "OK: $service_name running" || {
        echo "Starting $service_name..."
        systemctl start "$service_name"
    }
}

# Installs and starts apache2 and squid with their default configuration.
configure_software() {
    echo "----- Software installation -----"
    ensure_package_running "apache2" "apache2"
    ensure_package_running "squid" "squid"
}


# User accounts

regular_users=(aubrey captain snibbles brownie scooter sandy perrier cindy tiger yoda)
DENNIS_EXTRA_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4rT3vTt99Ox5kndS4HmgTrKBT8SKzhK4rhGkEVGlCI student@generic-vm"

# Creates the user account's if doesn't exist (with a home dir under
# /home and bash as the shell), or fixes the shell if it's already wrong.
ensure_account_exists() {
    local username="$1"
    local home_dir="/home/$username"

    id "$username" &>/dev/null || useradd -m -d "$home_dir" -s /bin/bash "$username"

    local shell
    shell=$(getent passwd "$username" | cut -d: -f7)
    [[ "$shell" == "/bin/bash" ]] || usermod -s /bin/bash "$username"
}

# Sets up the user's .ssh directory and generates an rsa and an ed25519
# keypair for them, skipping generation if the keys already exist.
ensure_keys_exist() {
    local username="$1"
    local ssh_dir="/home/$username/.ssh"

    mkdir -p "$ssh_dir"
    chown "$username:$username" "$ssh_dir"
    chmod 700 "$ssh_dir"

    [[ -f "$ssh_dir/id_rsa" && -f "$ssh_dir/id_rsa.pub" ]] || \
        sudo -u "$username" ssh-keygen -t rsa -f "$ssh_dir/id_rsa" -N "" -q

    [[ -f "$ssh_dir/id_ed25519" && -f "$ssh_dir/id_ed25519.pub" ]] || \
        sudo -u "$username" ssh-keygen -t ed25519 -f "$ssh_dir/id_ed25519" -N "" -q
}

# Adds the user's own rsa and ed25519 public keys to their
# authorized_keys file, without duplicating entries on re-runs.
ensure_authorized_keys() {
    local username="$1"
    local ssh_dir="/home/$username/.ssh"
    local auth_file="$ssh_dir/authorized_keys"

    touch "$auth_file"

    local rsa_pub ed25519_pub
    rsa_pub=$(cat "$ssh_dir/id_rsa.pub" 2>/dev/null)
    ed25519_pub=$(cat "$ssh_dir/id_ed25519.pub" 2>/dev/null)

    grep -qF "$rsa_pub" "$auth_file" 2>/dev/null || echo "$rsa_pub" >> "$auth_file"
    grep -qF "$ed25519_pub" "$auth_file" 2>/dev/null || echo "$ed25519_pub" >> "$auth_file"

    chown -R "$username:$username" "$ssh_dir"
    chmod 600 "$auth_file"
}

# Gives dennis sudo group membership and adds the extra provided public
# key to his authorized_keys, on top of his own generated keys.
ensure_dennis_extras() {
    local username="dennis"
    local auth_file="/home/$username/.ssh/authorized_keys"

    groups "$username" | grep -qw "sudo" || usermod -aG sudo "$username"
    grep -qF "$DENNIS_EXTRA_KEY" "$auth_file" 2>/dev/null || echo "$DENNIS_EXTRA_KEY" >> "$auth_file"
}

# Runs the full account + key setup for one username.
process_user() {
    local username="$1"
    echo "Processing user: $username"
    ensure_account_exists "$username"
    ensure_keys_exist "$username"
    ensure_authorized_keys "$username"
}

# Processes every required account, then applies dennis's extra sudo
# access and provided key on top of the standard setup.
configure_users() {
    echo "----- User accounts -----"

    for username in "${regular_users[@]}"; do
        process_user "$username"
    done

    process_user "dennis"
    ensure_dennis_extras
}

# Run everything

configure_network
configure_hosts
configure_software
configure_users

echo "Done."


