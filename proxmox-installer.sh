
#!/usr/bin/env bash
#
# Atyro Proxmox VE Installer
# Supports Debian 12 (Bookworm) and Debian 13 (Trixie)
# Installs PVE 8 / PVE 9 respectively.
#

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

VERSION="2.0.0"
LOG_FILE="/var/log/atyro-proxmox-installer.log"
KEYRING="/usr/share/keyrings/proxmox-archive-keyring.gpg"
REPO_FILE="/etc/apt/sources.list.d/pve-install.sources"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Logging
mkdir -p /var/log
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

info() {
    echo -e "${CYAN}[INFO]${RESET} $*"
}

success() {
    echo -e "${GREEN}[SUCCESS]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[WARNING]${RESET} $*"
}

error() {
    echo -e "${RED}[ERROR]${RESET} $*" >&2
}

die() {
    error "$*"
    exit 1
}

trap 'die "Installation failed at line $LINENO. Check $LOG_FILE"' ERR

echo
echo "============================================"
echo "       ATYRO PROXMOX VE INSTALLER"
echo "              Version $VERSION"
echo "============================================"
echo

# Root check
[[ "$EUID" -eq 0 ]] || die "Please run this installer as root."

# Debian check
[[ -f /etc/os-release ]] || die "Cannot detect operating system."

source /etc/os-release

[[ "$ID" == "debian" ]] || die "Only Debian is supported."

# Version detection
case "$VERSION_ID" in
    12)
        CODENAME="bookworm"
        PVE_VERSION="8"
        KEY_URL="https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg"
        info "Detected Debian 12 (Bookworm) - Proxmox VE 8"
        ;;
    13)
        CODENAME="trixie"
        PVE_VERSION="9"
        KEY_URL="https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"
        info "Detected Debian 13 (Trixie) - Proxmox VE 9"
        ;;
    *)
        die "Unsupported Debian version: $VERSION_ID"
        ;;
esac

# Architecture check
ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == "amd64" ]] || die "Proxmox installer supports amd64 only."

# Systemd check
command -v systemctl >/dev/null 2>&1 || die "systemd is required."

# Existing installation check
if dpkg-query -W -f='${Status}' proxmox-ve 2>/dev/null | grep -q "install ok installed"; then
    die "Proxmox VE is already installed."
fi

# Hostname configuration
read -r -p "Enter Proxmox hostname [pve]: " HOSTNAME_INPUT
HOSTNAME_INPUT="${HOSTNAME_INPUT:-pve}"

[[ "$HOSTNAME_INPUT" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] ||
    die "Invalid hostname."

[[ "$HOSTNAME_INPUT" != *".."* ]] || die "Invalid hostname."

SHORT_HOSTNAME="${HOSTNAME_INPUT%%.*}"

if [[ "$HOSTNAME_INPUT" == *.* ]]; then
    FQDN="$HOSTNAME_INPUT"
else
    FQDN="${HOSTNAME_INPUT}.localdomain"
fi

info "Configuring hostname: $HOSTNAME_INPUT"

hostnamectl set-hostname "$SHORT_HOSTNAME"

# Detect primary IPv4
IP_ADDRESS="$(ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"

if [[ -z "$IP_ADDRESS" ]]; then
    warn "Automatic IP detection failed."
    read -r -p "Enter your static IPv4 address: " IP_ADDRESS
fi

python3 - "$IP_ADDRESS" <<'PY'
import ipaddress
import sys
ipaddress.IPv4Address(sys.argv[1])
PY

[[ -n "$IP_ADDRESS" ]] || die "Invalid IP address."

# Confirm IP address
info "Detected IP address: $IP_ADDRESS"
warn "Make sure this is a static IP configured on your network."

read -r -p "Continue with this IP? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Installation cancelled."

# Backup existing configuration
BACKUP_DIR="/root/atyro-pve-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

cp -a /etc/hosts "$BACKUP_DIR/hosts"
cp -a /etc/hostname "$BACKUP_DIR/hostname"

if [[ -d /etc/apt/sources.list.d ]]; then
    cp -a /etc/apt/sources.list.d "$BACKUP_DIR/"
fi

success "Configuration backup: $BACKUP_DIR"

# Configure /etc/hosts without duplicate entries
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
    addresses = parts[1:]

    if any(name in (short, fqdn) for name in addresses):
        addresses = [name for name in addresses
                     if name not in (short, fqdn)]
        if addresses:
            result.append(parts[0] + "\t" + " ".join(addresses) + "\n")
        continue

    result.append(line)

result.append(f"{ip}\t{fqdn} {short}\n")

with open(path, "w") as f:
    f.writelines(result)
PY

success "Hostname and /etc/hosts configured."

# Disable conflicting PVE enterprise repositories
info "Checking existing Proxmox enterprise repositories..."

for file in /etc/apt/sources.list.d/pve-enterprise.list \
            /etc/apt/sources.list.d/pve-enterprise.sources; do
    if [[ -f "$file" ]]; then
        mv "$file" "${file}.disabled"
        warn "Disabled: $file"
    fi
done

# Remove our previous installer repository
rm -f "$REPO_FILE"

# Ensure download utilities are available
if ! command -v wget >/dev/null 2>&1; then
    apt-get update || true
    apt-get install -y wget ca-certificates
fi

# Install Proxmox repository key
info "Downloading Proxmox repository key..."

mkdir -p /usr/share/keyrings

wget -q --show-progress "$KEY_URL" -O "${KEYRING}.tmp"

[[ -s "${KEYRING}.tmp" ]] || die "Proxmox key download failed."

install -m 0644 "${KEYRING}.tmp" "$KEYRING"
rm -f "${KEYRING}.tmp"

success "Proxmox repository key installed."

# Configure Proxmox no-subscription repository
cat > "$REPO_FILE" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${CODENAME}
Components: pve-no-subscription
Signed-By: ${KEYRING}
EOF

success "Proxmox VE $PVE_VERSION repository configured."

# Update package lists
info "Updating Debian and Proxmox repositories..."

apt-get update

# Upgrade Debian packages
info "Upgrading Debian packages..."

apt-get full-upgrade -y

# Install Proxmox VE
info "Installing Proxmox VE $PVE_VERSION..."

apt-get install -y \
    proxmox-ve \
    postfix \
    open-iscsi \
    chrony

# Refresh package configuration
info "Updating initramfs..."

update-initramfs -u -k all

# Enable required services
info "Enabling Proxmox services..."

systemctl enable pve-cluster
systemctl enable pvedaemon
systemctl enable pvestatd
systemctl enable pveproxy
systemctl enable chrony
systemctl enable open-iscsi

# Start services
systemctl restart chrony
systemctl restart open-iscsi

# Verify installation
info "Checking installed packages..."

dpkg-query -W proxmox-ve || die "Proxmox VE package missing."
dpkg-query -W pve-manager || die "PVE Manager package missing."

# Network and hostname verification
getent hosts "$SHORT_HOSTNAME" >/dev/null ||
    die "Hostname resolution failed."

success "Proxmox VE installation completed."

echo
echo "============================================"
echo "         INSTALLATION COMPLETED"
echo "============================================"
echo
echo " Debian       : $VERSION_ID ($CODENAME)"
echo " Proxmox VE   : $PVE_VERSION"
echo " Hostname     : $SHORT_HOSTNAME"
echo " FQDN         : $FQDN"
echo " IP Address   : $IP_ADDRESS"
echo " Backup       : $BACKUP_DIR"
echo " Log          : $LOG_FILE"
echo
echo " Web Interface:"
echo " https://${IP_ADDRESS}:8006"
echo
echo "============================================"

warn "A reboot is required to load the Proxmox kernel."

read -r -p "Reboot now? [y/N]: " REBOOT

if [[ "$REBOOT" =~ ^[Yy]$ ]]; then
    info "Rebooting system..."
    reboot
else
    warn "Reboot skipped. Reboot manually before using Proxmox VE."
fi
