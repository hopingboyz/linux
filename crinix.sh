#!/usr/bin/env bash
# ==============================================================================
# CrinixCloud Premium MOTD Installation Script
# Version: 2.0
# Description: Enhanced system information display with comprehensive monitoring
# ==============================================================================

set -euo pipefail

# Color definitions for better readability
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly RESET='\033[0m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'

# ASCII Art with gradient effect
readonly LOGO="${GREEN}
   ╔═══════════════════════════════════════════════════════════╗
   ║${CYAN}    ██████╗██████╗ ██╗███╗   ██╗██╗██╗  ██╗       ${GREEN}║
   ║${CYAN}   ██╔════╝██╔══██╗██║████╗  ██║██║╚██╗██╔╝       ${GREEN}║
   ║${CYAN}   ██║     ██████╔╝██║██╔██╗ ██║██║ ╚███╔╝        ${GREEN}║
   ║${CYAN}   ██║     ██╔══██╗██║██║╚██╗██║██║ ██╔██╗        ${GREEN}║
   ║${CYAN}   ╚██████╗██║  ██║██║██║ ╚████║██║██╔╝ ██╗       ${GREEN}║
   ║${CYAN}    ╚═════╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝       ${GREEN}║
   ║${WHITE}           C L O U D   D A T A C E N T E R          ${GREEN}║
   ╚═══════════════════════════════════════════════════════════╝${RESET}"

print_header() {
    echo -e "${GREEN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║               CrinixCloud MOTD Installation Script               ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

print_success() {
    echo -e "${GREEN}✓${RESET} $1"
}

print_info() {
    echo -e "${CYAN}→${RESET} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${RESET} $1"
}

print_error() {
    echo -e "${RED}✗${RESET} $1" >&2
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

backup_original_motd() {
    local backup_dir="/etc/update-motd.d/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    print_info "Backing up original MOTD files to $backup_dir"
    
    for file in /etc/update-motd.d/*; do
        if [[ -f "$file" ]]; then
            cp "$file" "$backup_dir/" 2>/dev/null || true
        fi
    done
    print_success "Backup completed"
}

disable_default_motd() {
    print_info "Disabling default MOTD components..."
    
    # Disable all default MOTD scripts
    for motd_script in /etc/update-motd.d/*; do
        if [[ -f "$motd_script" ]]; then
            local script_name=$(basename "$motd_script")
            case "$script_name" in
                00-header|10-help-text|50-motd-news|80-esm|80-livepatch|90-updates-available|91-release-upgrade|92-unattended-upgrades|95-hwe-eol|97-overlayroot|98-fsck-at-reboot|98-reboot-required)
                    chmod -x "$motd_script" 2>/dev/null
                    print_info "  Disabled: $script_name"
                    ;;
            esac
        fi
    done
    print_success "Default MOTD disabled"
}

get_system_info() {
    # Get OS information
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_NAME="$PRETTY_NAME"
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
    else
        OS_NAME=$(uname -s)
        OS_VERSION=$(uname -r)
    fi
    
    # Get CPU information
    CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^[ \t]*//')
    CPU_CORES=$(nproc)
    
    # Get memory information in GB
    MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEM_TOTAL_GB=$(echo "scale=1; $MEM_TOTAL_KB / 1024 / 1024" | bc)
    
    # Get disk information
    DISK_TOTAL_GB=$(df -BG / | awk 'NR==2 {print $2}' | sed 's/G//')
    DISK_USED_GB=$(df -BG / | awk 'NR==2 {print $3}' | sed 's/G//')
    DISK_PERCENT=$(df -h / | awk 'NR==2 {print $5}')
    
    # Get network information
    PRIMARY_IP=$(ip route get 1 | awk '{print $7; exit}')
    INTERFACE=$(ip route get 1 | awk '{print $5; exit}')
}

create_custom_motd() {
    cat > /etc/update-motd.d/00-crinixcloud << 'MOTD_EOF'
#!/usr/bin/env bash
# ==============================================================================
# CrinixCloud Premium MOTD
# Dynamic System Information Display
# ==============================================================================

# Color definitions
C1='\033[1;36m'    # Cyan - Titles
C2='\033[1;32m'    # Green - Values
C3='\033[1;33m'    # Yellow - Labels
C4='\033[1;35m'    # Magenta - Highlights
C5='\033[1;34m'    # Blue - Subtle info
RST='\033[0m'      # Reset
BOLD='\033[1m'     # Bold
DIM='\033[2m'      # Dim

# Function to create a progress bar
progress_bar() {
    local value=$1
    local max=100
    local bar_length=20
    local filled=$((value * bar_length / max))
    local empty=$((bar_length - filled))
    
    printf "["
    for ((i=0; i<filled; i++)); do printf "█"; done
    for ((i=0; i<empty; i++)); do printf "░"; done
    printf "] %3d%%" "$value"
}

# Clear screen for new connections
if [[ "$SHOW_MOTD" != "false" ]]; then
    clear
fi

# ASCII Art Logo
echo -e "${C1}"
cat << "LOGO"
   ╔═══════════════════════════════════════════════════════════╗
   ║    ██████╗██████╗ ██╗███╗   ██╗██╗██╗  ██╗              ║
   ║   ██╔════╝██╔══██╗██║████╗  ██║██║╚██╗██╔╝              ║
   ║   ██║     ██████╔╝██║██╔██╗ ██║██║ ╚███╔╝               ║
   ║   ██║     ██╔══██╗██║██║╚██╗██║██║ ██╔██╗               ║
   ║   ╚██████╗██║  ██║██║██║ ╚████║██║██╔╝ ██╗              ║
   ║    ╚═════╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝╚═╝╚═╝  ╚═╝              ║
   ║           C L O U D   D A T A C E N T E R                ║
   ╚═══════════════════════════════════════════════════════════╝
LOGO
echo -e "${RST}"

# Welcome message
echo -e "${C2}${BOLD}✨ Welcome to CrinixCloud — Where Performance Meets Reliability ✨${RST}"
echo -e "${C5}High Performance • Enterprise Grade • 99.9% Uptime • 24/7 Support${RST}"
echo

# System Status Section
echo -e "${C1}${BOLD}📊 SYSTEM STATUS${RST}"
echo -e "${DIM}══════════════════════════════════════════════════════════════${RST}"

# Hostname and OS
HOSTNAME=$(hostname -f 2>/dev/null || hostname)
OS_INFO=$(source /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "Unknown OS")
echo -e "${C3}Hostname:${RST} ${C2}$HOSTNAME${RST}"
echo -e "${C3}OS:${RST} ${C2}$OS_INFO${RST}"
echo -e "${C3}Kernel:${RST} ${C2}$(uname -r)${RST}"

# Uptime
UPTIME=$(uptime -p | sed 's/up //')
BOOT_TIME=$(who -b | awk '{print $3 " " $4}')
echo -e "${C3}Uptime:${RST} ${C2}$UPTIME${RST} ${DIM}(since $BOOT_TIME)${RST}"

echo

# Resource Usage Section
echo -e "${C1}${BOLD}📈 RESOURCE USAGE${RST}"
echo -e "${DIM}══════════════════════════════════════════════════════════════${RST}"

# CPU Information
CPU_NAME=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -c 40)
CPU_CORES=$(nproc)
CPU_LOAD=$(awk '{printf "%.2f", $1}' /proc/loadavg)
CPU_LOAD_PERC=$(echo "scale=0; ($CPU_LOAD * 100) / $CPU_CORES" | bc)
echo -e "${C3}CPU:${RST} ${C2}${CPU_NAME}${RST}"
echo -e "${C3}Cores:${RST} ${C2}$CPU_CORES${RST} ${C3}Load:${RST} ${C2}$CPU_LOAD${RST} ${DIM}($(progress_bar $CPU_LOAD_PERC))${RST}"

# Memory Information
MEM_TOTAL=$(free -h | awk '/Mem:/ {print $2}')
MEM_USED=$(free -h | awk '/Mem:/ {print $3}')
MEM_FREE=$(free -h | awk '/Mem:/ {print $4}')
MEM_PERC=$(free | awk '/Mem:/ {printf "%d", $3/$2 * 100}')
echo -e "${C3}Memory:${RST} ${C2}$MEM_USED / $MEM_TOTAL${RST} ${DIM}($(progress_bar $MEM_PERC))${RST}"
echo -e "${C3}Available:${RST} ${C2}$MEM_FREE${RST}"

# Disk Information
DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
DISK_AVAIL=$(df -h / | awk 'NR==2 {print $4}')
DISK_PERC=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')
echo -e "${C3}Disk (/) :${RST} ${C2}$DISK_USED / $DISK_TOTAL${RST} ${DIM}($(progress_bar $DISK_PERC))${RST}"
echo -e "${C3}Free:${RST} ${C2}$DISK_AVAIL${RST}"

echo

# Network & Services Section
echo -e "${C1}${BOLD}🌐 NETWORK INFORMATION${RST}"
echo -e "${DIM}══════════════════════════════════════════════════════════════${RST}"

# IP Addresses
IPV4_ADDR=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
IPV6_ADDR=$(ip -6 addr show scope global | grep -oP '(?<=inet6\s)[0-9a-f:]+' | head -1)
echo -e "${C3}IPv4:${RST} ${C2}${IPV4_ADDR:-Not Configured}${RST}"
if [[ -n "$IPV6_ADDR" ]]; then
    echo -e "${C3}IPv6:${RST} ${C2}$IPV6_ADDR${RST}"
fi

# Network Interface
INTERFACE=$(ip route get 1 | awk '{print $5; exit}')
RX_TX=$(ifconfig $INTERFACE 2>/dev/null | awk '/RX packets/ {rx=$5} /TX packets/ {tx=$5} END {print rx, tx}' | numfmt --to=iec --suffix=B)
echo -e "${C3}Interface:${RST} ${C2}$INTERFACE${RST}"

echo

# System Activity Section
echo -e "${C1}${BOLD}👥 SYSTEM ACTIVITY${RST}"
echo -e "${DIM}══════════════════════════════════════════════════════════════${RST}"

# Users and Processes
LOGIN_USERS=$(who | wc -l)
TOTAL_USERS=$(cut -d: -f1 /etc/passwd | wc -l)
PROCESSES=$(ps -e --no-header | wc -l)
echo -e "${C3}Logged in Users:${RST} ${C2}$LOGIN_USERS${RST}"
echo -e "${C3}Total Processes:${RST} ${C2}$PROCESSES${RST}"

# System Updates (if apt is available)
if command -v apt-get &> /dev/null; then
    UPDATES=$(apt-get -s dist-upgrade 2>/dev/null | grep ^Inst | wc -l)
    SEC_UPDATES=$(apt-get -s dist-upgrade 2>/dev/null | grep -i security | wc -l)
    echo -e "${C3}Available Updates:${RST} ${C2}$UPDATES${RST} ${DIM}($SEC_UPDATES security)${RST}"
fi

# Swap Usage
if [[ -f /proc/swaps ]] && [[ $(wc -l < /proc/swaps) -gt 1 ]]; then
    SWAP_TOTAL=$(free -h | awk '/Swap:/ {print $2}')
    SWAP_USED=$(free -h | awk '/Swap:/ {print $3}')
    SWAP_PERC=$(free | awk '/Swap:/ {printf "%d", ($3/$2)*100}')
    echo -e "${C3}Swap Usage:${RST} ${C2}$SWAP_USED / $SWAP_TOTAL${RST} ${DIM}($(progress_bar $SWAP_PERC))${RST}"
fi

echo

# Service Status (example services)
echo -e "${C1}${BOLD}🛡️  SERVICE STATUS${RST}"
echo -e "${DIM}══════════════════════════════════════════════════════════════${RST}"

check_service() {
    local service=$1
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo -e "${C3}$service:${RST} ${C2}● Running${RST}"
    elif rc-service "$service" status 2>/dev/null | grep -q "status: started"; then
        echo -e "${C3}$service:${RST} ${C2}● Running${RST}"
    else
        echo -e "${C3}$service:${RST} ${DIM}○ Stopped${RST}"
    fi
}

check_service ssh
check_service cron
check_service nginx 2>/dev/null || check_service apache2 2>/dev/null || check_service httpd 2>/dev/null

echo

# Footer with important information
echo -e "${C1}${BOLD}📞 CONTACT & SUPPORT${RST}"
echo -e "${DIM}══════════════════════════════════════════════════════════════${RST}"
echo -e "${C3}Support Email:${RST} ${C2}support@crinixcloud.site${RST}"
echo -e "${C3}Discord:${RST} ${C2}https://discord.gg/7CtNC27PwS${RST}"
echo -e "${C3}Website:${RST} ${C2}https://crinixcloud.site${RST}"
echo -e "${C3}Documentation:${RST} ${C2}https://docs.crinixcloud.site${RST}"
echo
echo -e "${C4}${BOLD}💎 Quality Wise — No Compromise 💎${RST}"
echo -e "${DIM}Last update: $(date '+%Y-%m-%d %H:%M:%S %Z')${RST}"
echo

MOTD_EOF

    chmod +x /etc/update-motd.d/00-crinixcloud
}

create_optional_themes() {
    # Create alternative theme (minimal)
    cat > /etc/update-motd.d/01-crinixcloud-minimal << 'MINIMAL_EOF'
#!/usr/bin/env bash
# Minimal MOTD theme

echo "┌─────────────────────────────────────┐"
echo "│    🚀 CrinixCloud $(hostname)       │"
echo "├─────────────────────────────────────┤"
echo "│ OS:     $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
echo "│ Load:   $(awk '{printf "%.2f", $1}' /proc/loadavg)"
echo "│ Memory: $(free -h | awk '/Mem:/ {print $3 "/" $2}')"
echo "│ Disk:   $(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')"
echo "│ Uptime: $(uptime -p | sed 's/up //')"
echo "└─────────────────────────────────────┘"
MINIMAL_EOF

    chmod +x /etc/update-motd.d/01-crinixcloud-minimal
    chmod -x /etc/update-motd.d/01-crinixcloud-minimal  # Disabled by default
}

test_motd() {
    print_info "Testing the new MOTD..."
    echo
    echo -e "${YELLOW}Preview of your new MOTD:${RESET}"
    echo "──────────────────────────────────────────────────"
    /etc/update-motd.d/00-crinixcloud || true
    echo "──────────────────────────────────────────────────"
    echo
}

show_instructions() {
    cat << INSTRUCTIONS

${GREEN}✅ Installation Complete!${RESET}

${BOLD}What was installed:${RESET}
• Disabled all default Ubuntu/Debian MOTD scripts
• Created premium CrinixCloud MOTD at /etc/update-motd.d/00-crinixcloud
• Created backup of original files

${BOLD}To use the new MOTD:${RESET}
1. Reconnect via SSH to see the new display
2. The MOTD updates automatically on each login

${BOLD}Management commands:${RESET}
• View MOTD: ${CYAN}run-parts /etc/update-motd.d/${RESET}
• Disable MOTD: ${CYAN}chmod -x /etc/update-motd.d/00-crinixcloud${RESET}
• Enable MOTD: ${CYAN}chmod +x /etc/update-motd.d/00-crinixcloud${RESET}
• Restore backup: ${CYAN}Check /etc/update-motd.d/backup_*/${RESET}

${BOLD}Need help?${RESET}
• Discord: https://discord.gg/7CtNC27PwS
• Email: support@crinixcloud.site

${GREEN}Thank you for choosing CrinixCloud!${RESET}

INSTRUCTIONS
}

main() {
    print_header
    
    check_root
    
    print_info "Starting CrinixCloud Premium MOTD installation..."
    echo
    
    # Backup original MOTD
    backup_original_motd
    
    # Disable default MOTD
    disable_default_motd
    
    # Get system info for customization
    get_system_info
    
    # Create custom MOTD
    print_info "Creating custom MOTD..."
    create_custom_motd
    print_success "Custom MOTD created"
    
    # Create optional themes
    print_info "Creating additional themes..."
    create_optional_themes
    print_success "Additional themes created"
    
    # Test the MOTD
    test_motd
    
    # Show instructions
    show_instructions
    
    print_success "CrinixCloud Premium MOTD installation completed successfully!"
}

# Run main function
main "$@"
