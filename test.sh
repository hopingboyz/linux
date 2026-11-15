
#!/usr/bin/env bash
#
# Atyro Proxmox VE Installer
# Version: 3.0.0
# Debian 12 = Proxmox VE 8
# Debian 13 = Proxmox VE 9
#

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
umask 022

VERSION="3.0.0"
LOG_FILE="/var/log/atyro-proxmox-installer.log"
KEYRING="/usr/share/keyrings/proxmox-archive-keyring.gpg"
REPO_FILE="/etc/apt/sources.list.d/pve-install.sources"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

mkdir -p /var/log
touch "$LOG_FILE"
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
# 1. Root and OS checks
# --------------------------------------------------

[[ "$EUID" -eq 0 ]] || die "Run this installer as root."
[[ -f /etc/os-release ]] || die "OS detection failed."
command -v systemctl >/dev/null || die "systemd required."
command -v apt-get >/dev/null || die "APT is required."
command -v python3 >/dev/null || die "Python3 is required."
command -v ip >/dev/null || die "iproute2 is required."

source /etc/os-release

[[ "$ID" == "debian" ]] || die "Only Debian is supported."

case "$VERSION_ID" in
    12)
        CODENAME="bookworm"
        PVE_VERSION="8"
        KEY_URL="https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg"
        ;;
    13)
        CODENAME="trixie"
        PVE_VERSION="9"
        KEY_URL="https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"
        ;;
    *)
        die "Unsupported Debian version: $VERSION_ID"
        ;;
esac

ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "amd64" ]] || die "Only amd64 is supported."

info "Detected Debian $VERSION_ID ($CODENAME)"
info "Target Proxmox VE version: $PVE_VERSION"

# --------------------------------------------------
# 2. Existing Proxmox installation protection
# --------------------------------------------------

for pkg in proxmox-ve pve-manager corosync; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null |
        grep -q "install ok installed"; then
        die "Existing Proxmox package detected: $pkg. Installer will not overwrite it."
    fi
done

if [[ -f /etc/pve/corosync.conf ]]; then
    die "Existing cluster configuration detected. Refusing fresh installation."
fi

if [[ -f /var/lib/pve-cluster/config.db ]]; then
    die "Existing PVE cluster database detected. Refusing to overwrite it."
fi

# --------------------------------------------------
# 3. Hostname configuration
# --------------------------------------------------

read -r -p "Enter Proxmox hostname [pve]: " HOSTNAME_INPUT
HOSTNAME_INPUT="${HOSTNAME_INPUT:-pve}"

[[ ${#HOSTNAME_INPUT} -le 253 ]] || die "Hostname is too long."

if [[ ! "$HOSTNAME_INPUT" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]]; then
    die "Invalid hostname format."
fi

SHORT_HOSTNAME="${HOSTNAME_INPUT%%.*}"

if [[ "$HOSTNAME_INPUT" == *.* ]]; then
    FQDN="$HOSTNAME_INPUT"
else
    FQDN="${SHORT_HOSTNAME}.localdomain"
fi

info "Hostname: $SHORT_HOSTNAME"
info "FQDN: $FQDN"

# --------------------------------------------------
# 4. Management IP detection
# --------------------------------------------------

IP_ADDRESS="$(ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"

if [[ -z "$IP_ADDRESS" ]]; then
    warn "Automatic management IP detection failed."
    read -r -p "Enter your static management IPv4: " IP_ADDRESS
fi

python3 - "$IP_ADDRESS" <<'PY'
import ipaddress
import sys
ipaddress.IPv4Address(sys.argv[1])
PY

# Ensure selected IP actually belongs to this machine.
if ! ip -o -4 addr show |
    awk '{split($4,a,"/"); print a[1]}' |
    grep -Fxq "$IP_ADDRESS"; then
    die "Selected IP is not assigned to this machine."
fi

info "Management IP: $IP_ADDRESS"

read -r -p "Continue with this configuration? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Installation cancelled."

# --------------------------------------------------
# 5. Configuration backup
# --------------------------------------------------

BACKUP_DIR="/root/atyro-pve-backup-$(date +%Y%m%d-%H%M%S)"

mkdir -p "$BACKUP_DIR"

cp -a /etc/hosts "$BACKUP_DIR/hosts"
cp -a /etc/hostname "$BACKUP_DIR/hostname"

[[ -f /etc/apt/sources.list ]] &&
    cp -a /etc/apt/sources.list "$BACKUP_DIR/sources.list"

[[ -d /etc/apt/sources.list.d ]] &&
    cp -a /etc/apt/sources.list.d "$BACKUP_DIR/sources.list.d"

success "Backup created: $BACKUP_DIR"

# --------------------------------------------------
# 6. Configure hostname and /etc/hosts
# --------------------------------------------------

hostnamectl set-hostname "$SHORT_HOSTNAME"

python3 - "$IP_ADDRESS" "$FQDN" "$SHORT_HOSTNAME" <<'PY'
import sys

ip, fqdn, short = sys.argv[1:]
path = "/etc/hosts"

with open(path) as f:
    lines = f.readlines()

result = []

for line in lines:
    stripped = line.strip()

    if not stripped or stripped.startswith("#"):
        result.append(line)
        continue

    parts = stripped.split()
    aliases = parts[1:]

    # Remove only exact hostname aliases.
    aliases = [
        name for name in aliases
        if name not in (short, fqdn)
    ]

    if aliases:
        result.append(parts[0] + "\t" + " ".join(aliases) + "\n")

# Ensure localhost entry exists.
if not any(
    line.split()[:2] == ["127.0.0.1", "localhost"]
    for line in result if line.strip() and not line.strip().startswith("#")
):
    result.insert(0, "127.0.0.1 localhost\n")

result.append(f"{ip}\t{fqdn} {short}\n")

with open(path, "w") as f:
    f.writelines(result)
PY

hostname "$SHORT_HOSTNAME"

getent hosts "$SHORT_HOSTNAME" >/dev/null ||
    die "Short hostname resolution failed."

getent hosts "$FQDN" >/dev/null ||
    die "FQDN resolution failed."

success "Hostname and /etc/hosts configured."

# --------------------------------------------------
# 7. Disable conflicting Proxmox repositories
# --------------------------------------------------

info "Checking existing Proxmox repository configurations..."

python3 <<'PY'
from pathlib import Path
import re

files = [Path("/etc/apt/sources.list")]
files += list(Path("/etc/apt/sources.list.d").glob("*"))

pattern = re.compile(
    r"enterprise\.proxmox\.com|"
    r"download\.proxmox\.com/debian/(pve|ceph)",
    re.I
)

for path in files:
    if not path.is_file():
        continue

    if path.suffix == ".sources":
        content = path.read_text()
        blocks = re.split(r"(\n\s*\n)", content)
        changed = False

        for i, block in enumerate(blocks):
            if pattern.search(block):
                lines = block.splitlines()
                blocks[i] = "\n".join(
                    "# Disabled by Atyro Installer: " + line
                    if line.strip() and not line.lstrip().startswith("#")
                    else line
                    for line in lines
                )
                changed = True

        if changed:
            path.write_text("".join(blocks))
            print(f"[DISABLED] {path}")

    elif path.name.endswith(".list") or path.name == "sources.list":
        lines = path.read_text().splitlines()
        changed = False
        output = []

        for line in lines:
            if pattern.search(line) and not line.lstrip().startswith("#"):
                output.append("# Disabled by Atyro Installer: " + line)
                changed = True
            else:
                output.append(line)

        if changed:
            path.write_text("\n".join(output) + "\n")
            print(f"[DISABLED] {path}")
PY

# --------------------------------------------------
# 8. Install required utilities
# --------------------------------------------------

if ! command -v wget >/dev/null 2>&1; then
    apt-get update
    apt-get install -y wget ca-certificates
fi

apt-get install -y ca-certificates gnupg

# --------------------------------------------------
# 9. Install official Proxmox archive key
# --------------------------------------------------

info "Downloading Proxmox signing key..."

mkdir -p /usr/share/keyrings

wget -q --show-progress "$KEY_URL" -O "${KEYRING}.tmp"

[[ -s "${KEYRING}.tmp" ]] || die "Proxmox signing key download failed."

# Validate key file before installing.
gpg --show-keys "${KEYRING}.tmp" >/dev/null 2>&1 ||
    die "Downloaded Proxmox key is invalid."

install -m 0644 "${KEYRING}.tmp" "$KEYRING"
rm -f "${KEYRING}.tmp"

success "Proxmox signing key installed."

# --------------------------------------------------
# 10. Configure no-subscription repository
# --------------------------------------------------

cat > "$REPO_FILE" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${CODENAME}
Components: pve-no-subscription
Signed-By: ${KEYRING}
EOF

success "Proxmox VE $PVE_VERSION repository configured."

# --------------------------------------------------
# 11. Update repositories
# --------------------------------------------------

info "Updating APT repositories..."

apt-get update

# Confirm Proxmox packages are available.
apt-cache policy proxmox-ve

CANDIDATE="$(apt-cache policy proxmox-ve |
    awk '/Candidate:/ {print $2; exit}')"

[[ -n "$CANDIDATE" && "$CANDIDATE" != "(none)" ]] ||
    die "Proxmox VE package is unavailable."

success "Proxmox VE package candidate: $CANDIDATE"

# --------------------------------------------------
# 12. System upgrade
# --------------------------------------------------

warn "A full Debian package upgrade will be performed."

read -r -p "Continue with full system upgrade? [y/N]: " UPGRADE_CONFIRM

[[ "$UPGRADE_CONFIRM" =~ ^[Yy]$ ]] ||
    die "Installation cancelled before system upgrade."

apt-get full-upgrade -y

# --------------------------------------------------
# 13. Install Proxmox VE
# --------------------------------------------------

info "Installing Proxmox VE $PVE_VERSION..."

apt-get install -y \
    proxmox-ve \
    postfix \
    open-iscsi \
    chrony

success "Proxmox VE packages installed."

# --------------------------------------------------
# 14. Initramfs and boot configuration
# --------------------------------------------------

info "Updating initramfs..."

update-initramfs -u -k all

if command -v proxmox-boot-tool >/dev/null 2>&1; then
    proxmox-boot-tool refresh
fi

# --------------------------------------------------
# 15. Enable essential services
# --------------------------------------------------

info "Enabling Proxmox services..."

systemctl enable pve-cluster
systemctl enable pvedaemon
systemctl enable pvestatd
systemctl enable pveproxy
systemctl enable chrony

# Start cluster filesystem first.
info "Starting Proxmox cluster filesystem..."

if ! systemctl restart pve-cluster; then
    journalctl -u pve-cluster --no-pager -n 60
    die "pve-cluster failed. See the service logs above."
fi

# Start dependent services.
for SERVICE in pvedaemon pvestatd pveproxy; do
    info "Starting $SERVICE..."

    if ! systemctl restart "$SERVICE"; then
        journalctl -u "$SERVICE" --no-pager -n 40
        die "$SERVICE failed to start."
    fi
done

systemctl restart chrony

# Firewall is checked separately.
if systemctl list-unit-files pve-firewall.service --no-legend |
    grep -q pve-firewall; then

    if ! systemctl start pve-firewall; then
        warn "PVE firewall did not start. Check its logs."
    fi
fi

# --------------------------------------------------
# 16. Verify installed packages
# --------------------------------------------------

for PKG in proxmox-ve pve-manager; do
    dpkg-query -W -f='${Status}\n' "$PKG" 2>/dev/null |
        grep -q "install ok installed" ||
        die "Required package missing: $PKG"
done

# --------------------------------------------------
# 17. Verify hostname and services
# --------------------------------------------------

[[ "$(hostname)" == "$SHORT_HOSTNAME" ]] ||
    die "Hostname verification failed."

getent hosts "$SHORT_HOSTNAME" >/dev/null ||
    die "Short hostname resolution failed."

getent hosts "$FQDN" >/dev/null ||
    die "FQDN resolution failed."

for SERVICE in pve-cluster pvedaemon pvestatd pveproxy; do
    if ! systemctl is-active --quiet "$SERVICE"; then
        systemctl status "$SERVICE" --no-pager -l || true
        die "Required service is not active: $SERVICE"
    fi

    success "$SERVICE is active."
done

# --------------------------------------------------
# 18. Final installation report
# --------------------------------------------------

echo
echo "============================================"
echo "       ATYRO PROXMOX INSTALLATION"
echo "             COMPLETED"
echo "============================================"
echo
echo "Debian       : $VERSION_ID ($CODENAME)"
echo "Proxmox VE   : $PVE_VERSION"
echo "Hostname     : $SHORT_HOSTNAME"
echo "FQDN         : $FQDN"
echo "IP Address   : $IP_ADDRESS"
echo "Package      : $CANDIDATE"
echo "Backup       : $BACKUP_DIR"
echo "Log          : $LOG_FILE"
echo
echo "Web Interface:"
echo "https://${IP_ADDRESS}:8006"
echo
echo "============================================"

warn "A reboot is recommended to load the Proxmox kernel."

read -r -p "Reboot now? [y/N]: " REBOOT

if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
    info "Rebooting system..."
    systemctl reboot
else
    warn "Reboot skipped. Reboot manually before using Proxmox."
fi
