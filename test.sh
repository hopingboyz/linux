#!/usr/bin/env bash
#
# Atyro Proxmox VE Installer
# Version: 3.1.1
# Debian 12 = Proxmox VE 8
# Debian 13 = Proxmox VE 9
#

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none
umask 022

VERSION="3.1.1"
LOG_FILE="/var/log/atyro-proxmox-installer.log"
KEYRING="/usr/share/keyrings/proxmox-archive-keyring.gpg"
REPO_FILE="/etc/apt/sources.list.d/pve-install.sources"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'

mkdir -p /var/log
touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[WARNING]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }

trap 'rc=$?; error "Failed at line ${LINENO} (exit ${rc}). Log: ${LOG_FILE}"; exit "$rc"' ERR

echo
echo "============================================"
echo "       ATYRO PROXMOX VE INSTALLER"
echo "              Version $VERSION"
echo "============================================"
echo

# --------------------------------------------------
# 1. Root + OS check (NO gpg/wget in pre-check)
# --------------------------------------------------

[[ "$EUID" -eq 0 ]] || die "Run this installer as root."
[[ -f /etc/os-release ]] || die "OS detection failed."

# Only truly-always-present tools here. gpg/wget installed later.
for c in systemctl apt-get python3 ip hostnamectl dpkg; do
    command -v "$c" >/dev/null || die "Required command missing: $c"
done

source /etc/os-release
[[ "$ID" == "debian" ]] || die "Only Debian is supported."

case "$VERSION_ID" in
    12) CODENAME="bookworm"; PVE_VERSION="8"
        KEY_URL="https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg" ;;
    13) CODENAME="trixie";   PVE_VERSION="9"
        KEY_URL="https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg" ;;
    *)  die "Unsupported Debian version: $VERSION_ID" ;;
esac

ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "amd64" ]] || die "Only amd64 is supported."
info "Detected Debian $VERSION_ID ($CODENAME), PVE $PVE_VERSION"

# --------------------------------------------------
# 2. EARLY: install gpg/wget/ca-certificates
#    (before any pre-check that needs them)
# --------------------------------------------------

info "Installing base utilities early (gnupg, wget, ca-certificates)..."
apt-get update || die "apt-get update failed (early)."
apt-get install -y --no-install-recommends \
    ca-certificates gnupg wget lsb-release apt-transport-https \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    || die "Early base utilities install failed."

command -v gpg  >/dev/null || die "gpg still missing after install."
command -v wget >/dev/null || die "wget still missing after install."
success "Base utilities ready."

# --------------------------------------------------
# 3. Existing Proxmox protection
# --------------------------------------------------

for pkg in proxmox-ve pve-manager corosync; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        die "Existing Proxmox package detected: $pkg. Refusing."
    fi
done
[[ -f /etc/pve/corosync.conf ]] && die "Existing cluster config detected. Refusing."
[[ -s /var/lib/pve-cluster/config.db ]] && warn "Existing config.db preserved."

# --------------------------------------------------
# 4. Hostname config
# --------------------------------------------------

read -r -p "Enter Proxmox hostname [pve]: " HOSTNAME_INPUT
HOSTNAME_INPUT="${HOSTNAME_INPUT:-pve}"
[[ ${#HOSTNAME_INPUT} -le 253 ]] || die "Hostname too long."
[[ "$HOSTNAME_INPUT" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] \
    || die "Invalid hostname format."

SHORT_HOSTNAME="${HOSTNAME_INPUT%%.*}"
if [[ "$HOSTNAME_INPUT" == *.* ]]; then FQDN="$HOSTNAME_INPUT"; else FQDN="${SHORT_HOSTNAME}.localdomain"; fi
info "Hostname: $SHORT_HOSTNAME"; info "FQDN: $FQDN"

# --------------------------------------------------
# 5. Management IPv4 (NO fe80::)
# --------------------------------------------------

IP_ADDRESS="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
[[ -z "$IP_ADDRESS" ]] && IP_ADDRESS="$(ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]; exit}' || true)"
if [[ -z "$IP_ADDRESS" ]]; then
    warn "Auto IPv4 detection failed."
    read -r -p "Enter static management IPv4: " IP_ADDRESS
fi
python3 - "$IP_ADDRESS" <<'PY'
import ipaddress, sys
ipaddress.IPv4Address(sys.argv[1])
PY
ip -o -4 addr show | awk '{split($4,a,"/"); print a[1]}' | grep -Fxq "$IP_ADDRESS" \
    || die "Selected IP is not assigned to this machine."
info "Management IP: $IP_ADDRESS"

read -r -p "Continue with this configuration? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Installation cancelled."

# --------------------------------------------------
# 6. Backup
# --------------------------------------------------

BACKUP_DIR="/root/atyro-pve-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -a /etc/hosts    "$BACKUP_DIR/hosts"
cp -a /etc/hostname "$BACKUP_DIR/hostname"
[[ -f /etc/apt/sources.list ]] && cp -a /etc/apt/sources.list "$BACKUP_DIR/sources.list"
[[ -d /etc/apt/sources.list.d ]] && cp -a /etc/apt/sources.list.d "$BACKUP_DIR/sources.list.d"
success "Backup: $BACKUP_DIR"

# --------------------------------------------------
# 7. Hostname + /etc/hosts (IPv4, cloud-init aware)
# --------------------------------------------------

hostnamectl set-hostname "$SHORT_HOSTNAME"

if command -v cloud-init >/dev/null 2>&1 || [[ -d /etc/cloud ]]; then
    mkdir -p /etc/cloud/cloud.cfg.d
    cat > /etc/cloud/cloud.cfg.d/99-disable-manage-hosts.cfg <<'EOF'
# Added by Atyro PVE Installer
manage_etc_hosts: false
EOF
    success "Cloud-init manage_etc_hosts disabled."
fi

python3 - "$IP_ADDRESS" "$FQDN" "$SHORT_HOSTNAME" <<'PY'
import sys, re
ip, fqdn, short = sys.argv[1:]
path = "/etc/hosts"
with open(path) as f: lines = f.readlines()
link_local = re.compile(r"^fe80:", re.I)
result = []
for line in lines:
    s = line.strip()
    if not s or s.startswith("#"): result.append(line); continue
    parts = s.split(); addr, aliases = parts[0], parts[1:]
    if link_local.match(addr): continue
    aliases = [n for n in aliases if n not in (short, fqdn)]
    if aliases: result.append(addr + "\t" + " ".join(aliases) + "\n")
if not any(l.split()[:2] == ["127.0.0.1", "localhost"]
           for l in result if l.strip() and not l.strip().startswith("#")):
    result.insert(0, "127.0.0.1 localhost\n")
result.append(f"{ip}\t{fqdn} {short}\n")
with open(path, "w") as f: f.writelines(result)
PY

hostname "$SHORT_HOSTNAME"
getent hosts "$SHORT_HOSTNAME" >/dev/null || die "Short hostname resolution failed."
getent hosts "$FQDN"           >/dev/null || die "FQDN resolution failed."
success "Hostname and /etc/hosts configured."

# --------------------------------------------------
# 8. Disable conflicting PVE repos
# --------------------------------------------------

info "Disabling conflicting Proxmox repo entries..."
python3 <<'PY'
from pathlib import Path
import re
files = [Path("/etc/apt/sources.list")] + list(Path("/etc/apt/sources.list.d").glob("*"))
pattern = re.compile(r"enterprise\.proxmox\.com|download\.proxmox\.com/debian/(pve|ceph)", re.I)
for path in files:
    if not path.is_file(): continue
    if path.suffix == ".sources":
        content = path.read_text(); blocks = re.split(r"(\n\s*\n)", content); changed = False
        for i, block in enumerate(blocks):
            if pattern.search(block):
                blocks[i] = "\n".join(
                    "# Disabled by Atyro Installer: " + line
                    if line.strip() and not line.lstrip().startswith("#") else line
                    for line in block.splitlines())
                changed = True
        if changed: path.write_text("".join(blocks)); print(f"[DISABLED] {path}")
    elif path.name.endswith(".list") or path.name == "sources.list":
        lines = path.read_text().splitlines(); changed = False; out = []
        for line in lines:
            if pattern.search(line) and not line.lstrip().startswith("#"):
                out.append("# Disabled by Atyro Installer: " + line); changed = True
            else: out.append(line)
        if changed: path.write_text("\n".join(out) + "\n"); print(f"[DISABLED] {path}")
PY

# --------------------------------------------------
# 9. Proxmox signing key
# --------------------------------------------------

info "Downloading Proxmox signing key..."
mkdir -p /usr/share/keyrings
wget -q --tries=3 --timeout=30 --show-progress "$KEY_URL" -O "${KEYRING}.tmp" \
    || die "Key download failed."
[[ -s "${KEYRING}.tmp" ]] || die "Downloaded key is empty."
gpg --show-keys "${KEYRING}.tmp" >/dev/null 2>&1 || die "Downloaded key is invalid."
install -m 0644 "${KEYRING}.tmp" "$KEYRING"
rm -f "${KEYRING}.tmp"
success "Proxmox signing key installed."

# --------------------------------------------------
# 10. no-subscription repo
# --------------------------------------------------

cat > "$REPO_FILE" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${CODENAME}
Components: pve-no-subscription
Signed-By: ${KEYRING}
EOF
chmod 0644 "$REPO_FILE"
success "Proxmox VE $PVE_VERSION repo configured."

# --------------------------------------------------
# 11. APT update + candidate
# --------------------------------------------------

info "Updating APT..."
apt-get update || die "apt-get update failed (after PVE repo)."
CANDIDATE="$(apt-cache policy proxmox-ve 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
[[ -n "${CANDIDATE:-}" && "$CANDIDATE" != "(none)" ]] || die "Proxmox VE unavailable."
success "Proxmox VE candidate: $CANDIDATE"

# --------------------------------------------------
# 12. System upgrade
# --------------------------------------------------

warn "Full Debian package upgrade will be performed."
read -r -p "Continue with full system upgrade? [y/N]: " UPGRADE_CONFIRM
[[ "$UPGRADE_CONFIRM" =~ ^[Yy]$ ]] || die "Installation cancelled before upgrade."

apt-get full-upgrade -y \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    -o Acquire::Retries=3 \
    || die "System upgrade failed."

# --------------------------------------------------
# 13. Install Proxmox VE
# --------------------------------------------------

info "Installing Proxmox VE $PVE_VERSION..."
apt-get install -y proxmox-ve postfix open-iscsi chrony \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    || die "Proxmox VE install failed."
success "Proxmox VE packages installed."

# --------------------------------------------------
# 14. Initramfs / boot
# --------------------------------------------------

info "Updating initramfs..."
update-initramfs -u -k all || warn "update-initramfs reported error."
command -v proxmox-boot-tool >/dev/null 2>&1 && \
    { proxmox-boot-tool refresh || warn "proxmox-boot-tool refresh error."; }

# --------------------------------------------------
# 15. Enable + start services (ordered)
# --------------------------------------------------

info "Enabling Proxmox services..."
systemctl daemon-reload
for s in pve-cluster pvedaemon pvestatd pveproxy pvescheduler; do
    systemctl enable "$s" 2>/dev/null || true
done
command -v chronyd >/dev/null 2>&1 && systemctl enable chrony 2>/dev/null || true

info "Starting pve-cluster..."
systemctl reset-failed pve-cluster 2>/dev/null || true
systemctl restart pve-cluster || { journalctl -u pve-cluster --no-pager -n 80; die "pve-cluster failed."; }

for i in {1..20}; do mountpoint -q /etc/pve && break; sleep 1; done
mountpoint -q /etc/pve || warn "/etc/pve not mounted after 20s — continuing."

for s in pvedaemon pvestatd pveproxy pvescheduler; do
    info "Starting $s..."
    systemctl reset-failed "$s" 2>/dev/null || true
    systemctl restart "$s" || { journalctl -u "$s" --no-pager -n 60; warn "$s failed."; }
done

command -v chronyd >/dev/null 2>&1 && { systemctl restart chrony || warn "chrony restart failed."; }

if systemctl list-unit-files pve-firewall.service --no-legend 2>/dev/null | grep -q pve-firewall; then
    systemctl reset-failed pve-firewall 2>/dev/null || true
    systemctl start pve-firewall || warn "PVE firewall did not start."
fi
systemctl reset-failed pve-guests 2>/dev/null || true

# --------------------------------------------------
# 16. Verify
# --------------------------------------------------

for PKG in proxmox-ve pve-manager; do
    dpkg-query -W -f='${Status}\n' "$PKG" 2>/dev/null | grep -q "install ok installed" \
        || die "Required package missing: $PKG"
done

[[ "$(hostname)" == "$SHORT_HOSTNAME" ]] || die "Hostname verification failed."
getent hosts "$SHORT_HOSTNAME" >/dev/null || die "Short hostname resolution failed."
getent hosts "$FQDN"           >/dev/null || die "FQDN resolution failed."

for SERVICE in pve-cluster pvedaemon pvestatd pveproxy; do
    systemctl is-active --quiet "$SERVICE" || { systemctl status "$SERVICE" --no-pager -l || true; die "$SERVICE not active."; }
    success "$SERVICE is active."
done

# --------------------------------------------------
# 17. Final report
# --------------------------------------------------

echo
echo "============================================"
echo "       ATYRO PROXMOX INSTALLATION"
echo "             COMPLETED"
echo "============================================"
echo "Debian       : $VERSION_ID ($CODENAME)"
echo "Proxmox VE   : $PVE_VERSION"
echo "Hostname     : $SHORT_HOSTNAME"
echo "FQDN         : $FQDN"
echo "IP Address   : $IP_ADDRESS"
echo "Package      : $CANDIDATE"
echo "Backup       : $BACKUP_DIR"
echo "Log          : $LOG_FILE"
echo
echo "Web Interface: https://${IP_ADDRESS}:8006"
echo "============================================"

warn "Reboot recommended to load the Proxmox kernel."

if [[ -t 0 ]]; then
    read -r -p "Reboot now? [y/N]: " REBOOT
    [[ "$REBOOT" =~ ^[Yy]$ ]] && { info "Rebooting..."; systemctl reboot; } || warn "Reboot skipped."
else
    warn "Non-interactive shell — reboot manually."
fi
