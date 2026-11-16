#!/usr/bin/env bash
#
# Proxmox Installer
# Author: Atyro Labs
# Version: 1.0
# Debian 12 (Bookworm) -> Proxmox VE 8
# Debian 13 (Trixie)   -> Proxmox VE 9
#
# Installs Proxmox VE on an existing Debian host using official repositories.
# The official Proxmox ISO installer remains the recommended method for new hosts.
#

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

NAME="Proxmox Installer"
VERSION="1.0"
AUTHOR="Atyro Labs"
LOG_FILE="/var/log/proxmox-installer.log"
BACKUP_DIR=""
REPO_FILE="/etc/apt/sources.list.d/atyro-proxmox.sources"
KEYRING="/usr/share/keyrings/proxmox-archive-keyring.gpg"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; RESET='\033[0m'

mkdir -p /var/log
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

info()    { printf "${CYAN}[INFO]${RESET} %s\n" "$*"; }
success() { printf "${GREEN}[SUCCESS]${RESET} %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARNING]${RESET} %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
die()     { error "$*"; exit 1; }

on_error() {
    local rc=$?
    error "Unexpected failure at line ${BASH_LINENO[0]:-unknown} (exit ${rc})."
    error "Review the log: ${LOG_FILE}"
    exit "$rc"
}
trap on_error ERR

banner() {
    printf '\n'
    printf '%s\n' '============================================================'
    printf '  %s | v%s\n' "$NAME" "$VERSION"
    printf '  Author: %s\n' "$AUTHOR"
    printf '%s\n' '============================================================'
    printf '\n'
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ask_yes_no() {
    local prompt="$1" answer
    [[ -t 0 ]] || die "Interactive terminal required for confirmation: ${prompt}"
    read -r -p "$prompt [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

valid_fqdn() {
    python3 - "$1" <<'PY'
import re, sys
name = sys.argv[1].rstrip(".")
if len(name) > 253 or "." not in name:
    raise SystemExit(1)
labels = name.split(".")
if any(not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", x) for x in labels):
    raise SystemExit(1)
PY
}

banner

# 1. Host and operating-system checks
[[ "$EUID" -eq 0 ]] || die "Run as root: sudo bash proxmox-installer.sh"
[[ -r /etc/os-release ]] || die "Cannot identify the operating system."
require_command apt-get
require_command dpkg
require_command dpkg-query
require_command systemctl
require_command ip
require_command awk
require_command grep
require_command sed
require_command python3
require_command getent

source /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "Only Debian 12 and Debian 13 are supported."

case "${VERSION_ID:-}" in
    12)
        CODENAME="bookworm"
        PVE_MAJOR="8"
        KEY_URL="https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg"
        ;;
    13)
        CODENAME="trixie"
        PVE_MAJOR="9"
        KEY_URL="https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"
        ;;
    *)
        die "Unsupported Debian version: ${VERSION_ID:-unknown}. Supported: Debian 12 and 13."
        ;;
esac

ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "amd64" ]] || die "This installer currently supports amd64 only (detected: $ARCH)."

if systemd-detect-virt --container >/dev/null 2>&1; then
    die "Container environment detected. Install Proxmox VE on a supported physical host or a properly configured virtualization host, not inside an ordinary container."
fi

[[ -d /run/systemd/system ]] || die "A running systemd environment is required."
info "Detected: Debian ${VERSION_ID} (${CODENAME}), architecture ${ARCH}"
info "Target: Proxmox VE ${PVE_MAJOR}"

# 2. Protect existing Proxmox/cluster installations
for pkg in proxmox-ve pve-manager corosync; do
    if dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null | grep -qx installed; then
        die "Existing Proxmox-related package detected: ${pkg}. This script is for a fresh installation only."
    fi
done

[[ ! -e /etc/pve/corosync.conf ]] || die "Existing cluster configuration found at /etc/pve/corosync.conf."
[[ ! -e /var/lib/pve-cluster/config.db ]] || die "Existing PVE cluster database found. Refusing to overwrite it."

# 3. Detect management IPv4 and validate it
DEFAULT_ROUTE="$(ip -4 route get 1.1.1.1 2>/dev/null | head -n1 || true)"
IP_ADDRESS="$(awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' <<<"$DEFAULT_ROUTE")"

if [[ -z "$IP_ADDRESS" ]]; then
    warn "Could not automatically detect the outbound management IPv4 address."
    read -r -p "Enter an IPv4 address already configured on this host: " IP_ADDRESS
fi

python3 - "$IP_ADDRESS" <<'PY'
import ipaddress, sys
try:
    ipaddress.IPv4Address(sys.argv[1])
except Exception:
    raise SystemExit("Invalid IPv4 address.")
PY

ip -o -4 addr show | awk '{split($4,a,"/"); print a[1]}' | grep -Fxq "$IP_ADDRESS" ||
    die "The selected address ${IP_ADDRESS} is not assigned to this host."

# 4. Hostname input and validation
CURRENT_FQDN="$(hostname -f 2>/dev/null || true)"
DEFAULT_FQDN="$CURRENT_FQDN"
if [[ -z "$DEFAULT_FQDN" || "$DEFAULT_FQDN" == "localhost" || "$DEFAULT_FQDN" != *.* ]]; then
    DEFAULT_FQDN="pve.home.arpa"
fi

read -r -p "Enter this node's FQDN [${DEFAULT_FQDN}]: " FQDN
FQDN="${FQDN:-$DEFAULT_FQDN}"
FQDN="${FQDN,,}"
valid_fqdn "$FQDN" || die "Invalid FQDN. Example: pve.example.com or pve.home.arpa."

SHORT_HOSTNAME="${FQDN%%.*}"
[[ "$SHORT_HOSTNAME" != "localhost" ]] || die "The hostname cannot be localhost."

# Check basic network/DNS reachability before changing system configuration.
info "Checking access to official Proxmox repository..."
getent ahosts enterprise.proxmox.com >/dev/null || die "DNS lookup failed for enterprise.proxmox.com."
getent ahosts download.proxmox.com >/dev/null || die "DNS lookup failed for download.proxmox.com."

printf '\n'
info "Installation configuration:"
printf '  Debian       : %s (%s)\n' "$VERSION_ID" "$CODENAME"
printf '  Proxmox VE   : %s\n' "$PVE_MAJOR"
printf '  Hostname     : %s\n' "$SHORT_HOSTNAME"
printf '  FQDN         : %s\n' "$FQDN"
printf '  Management IP: %s\n' "$IP_ADDRESS"
printf '\n'
warn "Use a static management IP. This installer does not rewrite network interfaces or firewall rules."
warn "A full Debian upgrade and Proxmox package installation will be performed."
warn "Back up important data and ensure out-of-band/console access before continuing."
ask_yes_no "Continue with Proxmox VE ${PVE_MAJOR} installation?" || die "Installation cancelled by user."

# 5. Backup important configuration before editing
BACKUP_DIR="/root/proxmox-installer-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
for path in /etc/hosts /etc/hostname /etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/preferences /etc/apt/preferences.d; do
    if [[ -e "$path" ]]; then
        cp -a "$path" "$BACKUP_DIR/"
    fi
done
success "Configuration backup created: $BACKUP_DIR"

# 6. Configure hostname and hosts mapping without changing network settings
# Debian/Proxmox use the short node hostname; /etc/hosts maps both names to
# the management IP. Check the "files" NSS source directly so an unrelated
# public DNS record cannot cause a false failure.
hostnamectl set-hostname "$SHORT_HOSTNAME"

python3 - "$IP_ADDRESS" "$FQDN" "$SHORT_HOSTNAME" <<'PY'
from pathlib import Path
import ipaddress
import sys

ip, fqdn, short = sys.argv[1:]
ipaddress.IPv4Address(ip)
path = Path("/etc/hosts")
# Recover hosts files previously written with literal "\\n"/"\\t" text
# by an earlier buggy installer build.
raw_text = path.read_text() if path.exists() else ""
raw_text = raw_text.replace(r"\\n", "\\n").replace(r"\\t", "\\t")
lines = raw_text.splitlines()
out = []
seen_v4 = False
seen_v6 = False

for line in lines:
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        out.append(line)
        continue

    fields = stripped.split()
    if len(fields) < 2:
        out.append(line)
        continue

    address, *names = fields
    # Remove only aliases belonging to this node. Preserve unrelated hosts.
    names = [name for name in names if name not in (fqdn, short)]

    if address == "127.0.0.1":
        if "localhost" in names:
            seen_v4 = True
        if not names:
            names = ["localhost"]
        out.append("\t".join([address, *names]))
    elif address == "::1":
        if "localhost" in names:
            seen_v6 = True
        if not names:
            names = ["localhost"]
        out.append("\t".join([address, *names]))
    elif names:
        out.append("\t".join([address, *names]))

if not seen_v4:
    out.insert(0, "127.0.0.1 localhost")
if not seen_v6:
    out.append("::1 localhost")

# Put the node mapping at the end; both names resolve to the selected IP.
out.append(f"{ip}\t{fqdn} {short}")
path.write_text("\n".join(out) + "\n")
PY

# Keep the system hostname short, as expected by common Proxmox node setups.
hostname "$SHORT_HOSTNAME"

# Ensure /etc/hosts is checked before DNS/systemd-resolved.
python3 <<'PY'
from pathlib import Path
import re
path = Path("/etc/nsswitch.conf")
if path.exists():
    lines = path.read_text().splitlines()
    output = []
    found = False
    for line in lines:
        match = re.match(r"^(\\s*hosts\\s*:\\s*)(.*)$", line)
        if match and not line.lstrip().startswith("#"):
            tokens = [x for x in match.group(2).split() if x != "files"]
            tokens.insert(0, "files")
            output.append(match.group(1) + " ".join(tokens))
            found = True
        else:
            output.append(line)
    if not found:
        output.append("hosts: files dns")
    path.write_text("\\n".join(output) + "\\n")
PY

# Verify the literal hosts-file record and resolve IPv4 specifically.
# This avoids depending on getent's optional -s service-selection syntax.
python3 - "$IP_ADDRESS" "$FQDN" "$SHORT_HOSTNAME" <<'PY'
from pathlib import Path
import ipaddress
import sys

ip, fqdn, short = sys.argv[1:]
matches = []
for raw in Path("/etc/hosts").read_text().splitlines():
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    fields = line.split()
    try:
        address = str(ipaddress.ip_address(fields[0]))
    except (ValueError, IndexError):
        continue
    aliases = fields[1:]
    if fqdn in aliases and short in aliases and address == ip:
        matches.append(raw)

if not matches:
    raise SystemExit(
        f"Missing /etc/hosts mapping: {ip} {fqdn} {short}. "
        "Inspect /etc/hosts and check for a read-only or managed hosts file."
    )
PY

HOSTS_LOOKUP="$(getent ahostsv4 "$FQDN" 2>/dev/null || true)"
if ! awk -v ip="$IP_ADDRESS" '$1 == ip { found=1 } END { exit !found }' <<<"$HOSTS_LOOKUP"; then
    error "FQDN IPv4 resolution failed. Expected ${IP_ADDRESS} ${FQDN}."
    grep -F "$FQDN" /etc/hosts || true
    die "FQDN resolution verification failed."
fi

SHORT_LOOKUP="$(getent ahostsv4 "$SHORT_HOSTNAME" 2>/dev/null || true)"
if ! awk -v ip="$IP_ADDRESS" '$1 == ip { found=1 } END { exit !found }' <<<"$SHORT_LOOKUP"; then
    error "Short hostname IPv4 resolution failed. Expected ${IP_ADDRESS} ${SHORT_HOSTNAME}."
    grep -F "$SHORT_HOSTNAME" /etc/hosts || true
    die "Short hostname resolution verification failed."
fi

[[ "$(hostname -s)" == "$SHORT_HOSTNAME" ]] || die "System short hostname did not apply correctly."
success "Hostname and /etc/hosts verified: ${FQDN} -> ${IP_ADDRESS}"
# 7. Disable only conflicting Proxmox repository entries; preserve unrelated sources.
info "Checking for old/enterprise Proxmox repository entries..."
python3 <<'PY'
from pathlib import Path
import re

source_dirs = [Path("/etc/apt/sources.list.d")]
legacy = Path("/etc/apt/sources.list")
paths = ([legacy] if legacy.exists() else [])
for d in source_dirs:
    if d.exists():
        paths.extend(p for p in d.iterdir() if p.is_file() and p.name != "atyro-proxmox.sources")

pattern = re.compile(r"(enterprise\.proxmox\.com|download\.proxmox\.com/debian/pve)", re.I)

for path in paths:
    try:
        text = path.read_text()
    except (OSError, UnicodeDecodeError):
        continue

    changed = False
    if path.suffix == ".sources":
        paragraphs = re.split(r"(\n\s*\n)", text)
        for i in range(0, len(paragraphs), 2):
            block = paragraphs[i]
            if pattern.search(block) and not re.search(r"(?im)^\s*Enabled:\s*no\s*$", block):
                if re.search(r"(?im)^\s*Enabled\s*:", block):
                    block = re.sub(r"(?im)^\s*Enabled\s*:\s*.*$", "Enabled: no", block)
                else:
                    block = block.rstrip() + "\nEnabled: no\n"
                paragraphs[i] = block
                changed = True
        new_text = "".join(paragraphs)
    else:
        new_lines = []
        for line in text.splitlines():
            if pattern.search(line) and not line.lstrip().startswith("#"):
                new_lines.append("# Disabled by Proxmox Installer: " + line)
                changed = True
            else:
                new_lines.append(line)
        new_text = "\n".join(new_lines) + ("\n" if text.endswith("\n") or new_lines else "")

    if changed:
        path.write_text(new_text)
        print(f"[DISABLED CONFLICTING PVE SOURCE] {path}")
PY

# 8. Install download and signing utilities
info "Installing prerequisite packages..."
apt-get update
apt-get install -y --no-install-recommends ca-certificates wget gnupg debian-archive-keyring

# 9. Fetch and validate the official Proxmox signing key
info "Fetching official Proxmox signing key..."
install -d -m 0755 /usr/share/keyrings
TMP_KEY="$(mktemp)"
trap 'rm -f "${TMP_KEY:-}"; on_error' ERR
wget --https-only --timeout=30 --tries=3 -q "$KEY_URL" -O "$TMP_KEY"
[[ -s "$TMP_KEY" ]] || die "Downloaded Proxmox key is empty."
gpg --batch --show-keys "$TMP_KEY" >/dev/null 2>&1 || die "Downloaded Proxmox signing key is invalid."
install -m 0644 "$TMP_KEY" "$KEYRING"
rm -f "$TMP_KEY"
trap on_error ERR
success "Official Proxmox signing key installed."

# 10. Configure the matching no-subscription PVE repository
cat > "$REPO_FILE" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${CODENAME}
Components: pve-no-subscription
Signed-By: ${KEYRING}
EOF
chmod 0644 "$REPO_FILE"
success "Proxmox VE ${PVE_MAJOR} repository configured for ${CODENAME}."

# 11. Update APT and verify package availability
info "Refreshing APT package indexes..."
apt-get update

CANDIDATE="$(apt-cache policy proxmox-ve | awk '/Candidate:/ {print $2; exit}')"
[[ -n "$CANDIDATE" && "$CANDIDATE" != "(none)" ]] ||
    die "No proxmox-ve candidate found. Check APT output and repository connectivity."
success "Proxmox VE package candidate: ${CANDIDATE}"

# 12. Upgrade Debian before installing Proxmox
warn "Running apt-get full-upgrade. This may update the kernel and core system packages."
apt-get full-upgrade -y

# 13. Install Proxmox VE and required supporting services
info "Preconfiguring Postfix to avoid interactive package prompts..."
if command -v debconf-set-selections >/dev/null 2>&1; then
    printf '%s\n' \
        "postfix postfix/main_mailer_type select Local only" \
        "postfix postfix/mailname string ${FQDN}" |
        debconf-set-selections
fi

info "Installing Proxmox VE ${PVE_MAJOR} and supporting packages..."
apt-get install -y proxmox-ve postfix open-iscsi chrony curl

# 14. Verify installed packages and refresh initramfs/boot entries
for pkg in proxmox-ve pve-manager pve-cluster; do
    dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null | grep -qx installed ||
        die "Required package is not installed: ${pkg}"
done

info "Refreshing initramfs..."
if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u -k all
fi
if command -v update-grub >/dev/null 2>&1; then
    update-grub
fi
if command -v proxmox-boot-tool >/dev/null 2>&1; then
    proxmox-boot-tool refresh
fi

# 15. Start services in dependency order
info "Enabling and starting Proxmox services..."
systemctl enable pve-cluster pvedaemon pvestatd pveproxy chrony open-iscsi

if ! systemctl restart pve-cluster; then
    journalctl -u pve-cluster --no-pager -n 80 || true
    die "pve-cluster failed to start. See the service log above."
fi

for service in pvedaemon pvestatd pveproxy; do
    if ! systemctl restart "$service"; then
        journalctl -u "$service" --no-pager -n 60 || true
        die "${service} failed to start."
    fi
done

systemctl restart chrony
systemctl start open-iscsi || warn "open-iscsi did not start; check whether your host requires iSCSI."

# 16. Final checks
[[ "$(hostname -s)" == "$SHORT_HOSTNAME" ]] || die "Short hostname verification failed."
getent ahostsv4 "$FQDN" | awk -v ip="$IP_ADDRESS" '$1 == ip { found=1 } END { exit !found }' || die "FQDN IPv4 resolution check failed."

for service in pve-cluster pvedaemon pvestatd pveproxy; do
    systemctl is-active --quiet "$service" || {
        systemctl status "$service" --no-pager -l || true
        die "Required service is not active: ${service}"
    }
    success "${service} is active."
done

if ! curl -kfsS --connect-timeout 5 https://127.0.0.1:8006/api2/json/version >/dev/null; then
    warn "The local HTTPS API check did not succeed yet. Check pveproxy logs and port 8006."
else
    success "Proxmox HTTPS API is responding on port 8006."
fi

PVE_VERSION="$(pveversion 2>/dev/null | head -n1 || true)"

printf '\n'
printf '%s\n' '============================================================'
printf '  %s installation finished\n' "$NAME"
printf '%s\n' '============================================================'
printf '  Author       : %s\n' "$AUTHOR"
printf '  Installer    : %s\n' "$VERSION"
printf '  Debian       : %s (%s)\n' "$VERSION_ID" "$CODENAME"
printf '  Proxmox      : %s\n' "${PVE_VERSION:-installed}"
printf '  Hostname     : %s\n' "$FQDN"
printf '  Management IP: %s\n' "$IP_ADDRESS"
printf '  Web UI       : https://%s:8006\n' "$IP_ADDRESS"
printf '  Backup       : %s\n' "$BACKUP_DIR"
printf '  Log          : %s\n' "$LOG_FILE"
printf '%s\n' '============================================================'
warn "A reboot is required/recommended to boot the installed Proxmox kernel."
if ask_yes_no "Reboot this server now?"; then
    info "Rebooting..."
    systemctl reboot
else
    warn "Reboot skipped. Schedule a maintenance reboot before creating VMs or containers."
fi
