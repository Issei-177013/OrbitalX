#!/bin/bash

# ===========================================================
# OrbitalX - Tor Multi-Location Manager for Xray
# Version : 3.0
# Description: TUI-based management with predefined countries
#              and fixed ports. Monitor interval configurable.
# ===========================================================

set -e

# ==================== GLOBALS ====================
SCRIPT_NAME="OrbitalX"
VERSION="3.0"
REPO_RAW_URL="https://raw.githubusercontent.com/Issei-177013/OrbitalX/main/orbitalx.sh"
CONFIG_DIR="/etc/orbitalx"
DATA_DIR="/var/lib/orbitalx"
LOG_DIR="/var/log/orbitalx"
PID_DIR="/var/run/orbitalx"
ACTIVE_FILE="${CONFIG_DIR}/active.conf"
AVAILABLE_FILE="${CONFIG_DIR}/available.conf"
MONITOR_INTERVAL_FILE="${CONFIG_DIR}/monitor_interval.conf"
DEFAULT_MONITOR_INTERVAL=600
MAX_RETRY=3

# Predefined countries with fixed ports
declare -A PREDEFINED_PORTS=(
    ["DE"]=9080
    ["TR"]=9081
    ["US"]=9082
    ["FR"]=9083
    ["NL"]=9084
    ["GB"]=9085
    ["CA"]=9086
    ["JP"]=9087
    ["IT"]=9088
    ["SE"]=9089
    ["CH"]=9090
    ["ES"]=9091
)

# Colors (for CLI mode)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== HELPER FUNCTIONS ====================

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_DIR}/manager.log"
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    log "[INFO] $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    log "[WARN] $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log "[ERROR] $1"
}

# Check if running as root (for privileged commands)
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This command requires root privileges. Please run with sudo."
        exit 1
    fi
}

# Check if dialog is installed
check_dialog() {
    if ! command -v dialog &> /dev/null; then
        echo "Dialog is not installed. Installing..."
        sudo apt update && sudo apt install dialog -y
    fi
}

# Check prerequisites
check_prerequisites() {
    local missing=()
    for cmd in tor curl nc ss pgrep pkill dialog; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -ne 0 ]; then
        print_error "Missing: ${missing[*]}"
        print_info "Install with: sudo apt update && sudo apt install tor curl netcat-openbsd iproute2 procps dialog -y"
        return 1
    fi
    return 0
}

# Create directories and initial files
create_dirs() {
    mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" "$PID_DIR"
    
    if [ ! -f "$AVAILABLE_FILE" ]; then
        for code in "${!PREDEFINED_PORTS[@]}"; do
            echo "$code:${PREDEFINED_PORTS[$code]}" >> "$AVAILABLE_FILE"
        done
    fi
    
    touch "$ACTIVE_FILE"
    
    if [ ! -f "$MONITOR_INTERVAL_FILE" ]; then
        echo "$DEFAULT_MONITOR_INTERVAL" > "$MONITOR_INTERVAL_FILE"
    fi
}

# Get monitor interval
get_monitor_interval() {
    if [ -f "$MONITOR_INTERVAL_FILE" ]; then
        cat "$MONITOR_INTERVAL_FILE"
    else
        echo "$DEFAULT_MONITOR_INTERVAL"
    fi
}

# Find free control port
find_control_port() {
    local base=10050
    local port=$base
    while ss -tuln | grep -q ":$port "; do
        ((port++))
    done
    echo "$port"
}

# Get exit IP of Tor instance
get_tor_exit_ip() {
    local port=$1
    local ip=$(curl -s --socks5-hostname 127.0.0.1:"$port" --max-time 5 https://api.ipify.org?format=text 2>/dev/null)
    if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
    else
        echo ""
    fi
}

# Check IP quality
check_ip_quality() {
    local port=$1
    local start_time=$(date +%s%N)
    local ip=$(get_tor_exit_ip "$port")
    local end_time=$(date +%s%N)
    if [ -z "$ip" ]; then
        return 1
    fi
    local elapsed=$(( (end_time - start_time) / 1000000 ))
    if [ $elapsed -gt 2000 ]; then
        return 1
    fi
    return 0
}

# Rotate Tor IP
rotate_tor_ip() {
    local control_port=$1
    echo -e "AUTHENTICATE \"\"\r\nSIGNAL NEWNYM\r\nQUIT" | nc 127.0.0.1 "$control_port" > /dev/null 2>&1
    return $?
}

# ==================== CORE FUNCTIONS (used by both CLI and TUI) ====================

# Activate a country (given code and port)
activate_country() {
    local country=$1
    local port=$2
    
    # Remove from available
    sed -i "/^${country}:/d" "$AVAILABLE_FILE"
    
    local control_port=$(find_control_port)
    local data_dir="${DATA_DIR}/${country}"
    mkdir -p "$data_dir"
    
    cat > "${data_dir}/torrc" << EOF
SocksPort 127.0.0.1:${port}
ControlPort 127.0.0.1:${control_port}
DataDirectory ${data_dir}
ExitNodes {${country}}
StrictNodes 1
NumEntryGuards 1
NewCircuitPeriod 3600
MaxCircuitDirtiness 3600
EOF

    tor -f "${data_dir}/torrc" --RunAsDaemon 1 --Log "notice file ${LOG_DIR}/tor_${country}.log"
    sleep 3

    if ! pgrep -f "tor -f ${data_dir}/torrc" > /dev/null; then
        print_error "Failed to start Tor for ${country}."
        echo "${country}:${port}" >> "$AVAILABLE_FILE"
        return 1
    fi

    # Find good IP
    local exit_ip=""
    local retry=0
    while [ $retry -lt $MAX_RETRY ]; do
        if check_ip_quality "$port"; then
            exit_ip=$(get_tor_exit_ip "$port")
            break
        else
            rotate_tor_ip "$control_port"
            sleep 5
            retry=$((retry+1))
        fi
    done

    if [ -z "$exit_ip" ]; then
        exit_ip=$(get_tor_exit_ip "$port")
        if [ -z "$exit_ip" ]; then
            print_error "Cannot get IP. Removing instance."
            pkill -f "tor -f ${data_dir}/torrc" || true
            rm -rf "$data_dir"
            echo "${country}:${port}" >> "$AVAILABLE_FILE"
            return 1
        fi
    fi

    echo "${country}:${port}:${control_port}:${exit_ip}" >> "$ACTIVE_FILE"
    print_info "Activated ${country} on port ${port} with IP ${exit_ip}."
    return 0
}

# Deactivate a country
deactivate_country() {
    local country=$1
    if ! grep -q "^${country}:" "$ACTIVE_FILE"; then
        print_error "Country ${country} not active."
        return 1
    fi
    
    local line=$(grep "^${country}:" "$ACTIVE_FILE")
    IFS=':' read -r c port control_port ip <<< "$line"
    
    local data_dir="${DATA_DIR}/${country}"
    pkill -f "tor -f ${data_dir}/torrc" || true
    rm -rf "$data_dir"
    
    sed -i "/^${country}:/d" "$ACTIVE_FILE"
    echo "${country}:${port}" >> "$AVAILABLE_FILE"
    
    print_info "Deactivated ${country}."
    return 0
}

# Stop all active instances
stop_all_instances() {
    pkill -f "tor -f ${DATA_DIR}/" || true
    print_info "All Tor instances stopped."
}

# Background monitor (daemon)
monitor_daemon() {
    local interval=$(get_monitor_interval)
    while true; do
        if [ -s "$ACTIVE_FILE" ]; then
            while IFS= read -r line; do
                IFS=':' read -r country port control_port saved_ip <<< "$line"
                data_dir="${DATA_DIR}/${country}"
                
                if ! pgrep -f "tor -f ${data_dir}/torrc" > /dev/null; then
                    print_warn "${country} is down. Restarting..."
                    tor -f "${data_dir}/torrc" --RunAsDaemon 1 --Log "notice file ${LOG_DIR}/tor_${country}.log"
                    sleep 2
                fi
                
                if ! check_ip_quality "$port"; then
                    print_warn "Poor IP quality for ${country}. Rotating..."
                    if rotate_tor_ip "$control_port"; then
                        sleep 5
                        local retry=0
                        local new_ip=""
                        while [ $retry -lt $MAX_RETRY ]; do
                            if check_ip_quality "$port"; then
                                new_ip=$(get_tor_exit_ip "$port")
                                break
                            else
                                rotate_tor_ip "$control_port"
                                sleep 5
                                retry=$((retry+1))
                            fi
                        done
                        if [ -n "$new_ip" ]; then
                            sed -i "s/^${country}:${port}:${control_port}:[^:]*$/${country}:${port}:${control_port}:${new_ip}/" "$ACTIVE_FILE"
                            print_info "New IP for ${country}: ${new_ip}"
                        fi
                    fi
                fi
            done < "$ACTIVE_FILE"
        fi
        sleep "$interval"
    done
}

# ==================== TUI FUNCTIONS ====================

# Show main menu
main_menu() {
    while true; do
        choice=$(dialog --clear --title "OrbitalX v${VERSION}" \
            --menu "Tor Location Manager for Xray" 18 60 10 \
            1 "Show Available Countries" \
            2 "Activate a Country" \
            3 "Show Active Status" \
            4 "Deactivate a Country" \
            5 "Set Monitor Interval" \
            6 "Stop All Instances" \
            7 "Install / Update / Uninstall" \
            8 "Exit" \
            2>&1 >/dev/tty)

        case $? in
            0)
                case $choice in
                    1) show_available_tui ;;
                    2) activate_tui ;;
                    3) show_status_tui ;;
                    4) deactivate_tui ;;
                    5) set_interval_tui ;;
                    6) stop_all_tui ;;
                    7) admin_menu ;;
                    8) clear; exit 0 ;;
                esac
                ;;
            1|255) clear; exit 0 ;;
        esac
    done
}

# Show available countries
show_available_tui() {
    if [ ! -s "$AVAILABLE_FILE" ]; then
        dialog --msgbox "No countries available. All are active." 6 40
        return
    fi
    
    local list=""
    local i=1
    while IFS= read -r line; do
        IFS=':' read -r code port <<< "$line"
        list="${list}${i} \"${code} (Port: ${port})\" "
        ((i++))
    done < "$AVAILABLE_FILE"
    
    eval dialog --title "Available Countries" --menu "Select to view details" 15 50 10 $list 2>&1 >/dev/tty
    # Just show and return
}

# Activate a country (select from available)
activate_tui() {
    if [ ! -s "$AVAILABLE_FILE" ]; then
        dialog --msgbox "No countries available to activate." 6 40
        return
    fi
    
    local items=()
    while IFS= read -r line; do
        IFS=':' read -r code port <<< "$line"
        items+=("$code" "Port: $port")
    done < "$AVAILABLE_FILE"
    
    local country=$(dialog --clear --title "Activate Country" \
        --menu "Select a country to activate" 15 50 10 "${items[@]}" \
        2>&1 >/dev/tty)
    
    if [ -n "$country" ]; then
        local port=$(grep "^${country}:" "$AVAILABLE_FILE" | cut -d':' -f2)
        if [ -n "$port" ]; then
            # Run activation in background with progress
            (
                activate_country "$country" "$port" > /tmp/orbitalx_activate.log 2>&1
                echo $? > /tmp/orbitalx_activate.exit
            ) &
            pid=$!
            
            # Show spinner
            dialog --title "Activating ${country}..." --infobox "Please wait..." 5 40
            wait $pid
            exit_code=$(cat /tmp/orbitalx_activate.exit 2>/dev/null || echo 1)
            
            if [ $exit_code -eq 0 ]; then
                dialog --msgbox "✅ ${country} activated successfully!\n\nUse port ${port} in Xray outbound." 8 50
            else
                dialog --msgbox "❌ Failed to activate ${country}.\nCheck logs: ${LOG_DIR}/tor_${country}.log" 8 50
            fi
            rm -f /tmp/orbitalx_activate.log /tmp/orbitalx_activate.exit
        else
            dialog --msgbox "Error: port not found." 6 40
        fi
    fi
}

# Show active status
show_status_tui() {
    if [ ! -s "$ACTIVE_FILE" ]; then
        dialog --msgbox "No active locations." 6 40
        return
    fi
    
    local status_text=""
    while IFS= read -r line; do
        IFS=':' read -r country port control_port saved_ip <<< "$line"
        if pgrep -f "tor -f ${DATA_DIR}/${country}/torrc" > /dev/null; then
            current_ip=$(get_tor_exit_ip "$port")
            if [ -z "$current_ip" ]; then
                status_text="${status_text}${country} | ${port} | ⚠️ Issue | Unknown\n"
            else
                status_text="${status_text}${country} | ${port} | ✅ Active | ${current_ip}\n"
                if [ "$current_ip" != "$saved_ip" ]; then
                    sed -i "s/^${country}:${port}:${control_port}:${saved_ip}$/${country}:${port}:${control_port}:${current_ip}/" "$ACTIVE_FILE"
                fi
            fi
        else
            status_text="${status_text}${country} | ${port} | ❌ Stopped | ${saved_ip}\n"
        fi
    done < "$ACTIVE_FILE"
    
    dialog --title "Active Locations" --msgbox "Country | Port | Status | Exit IP\n----------------------------------------\n${status_text}" 20 60
}

# Deactivate a country
deactivate_tui() {
    if [ ! -s "$ACTIVE_FILE" ]; then
        dialog --msgbox "No active countries to deactivate." 6 40
        return
    fi
    
    local items=()
    while IFS= read -r line; do
        IFS=':' read -r code port rest <<< "$line"
        items+=("$code" "Port: $port")
    done < "$ACTIVE_FILE"
    
    local country=$(dialog --clear --title "Deactivate Country" \
        --menu "Select a country to deactivate" 15 50 10 "${items[@]}" \
        2>&1 >/dev/tty)
    
    if [ -n "$country" ]; then
        deactivate_country "$country"
        dialog --msgbox "Country ${country} deactivated and moved back to available list." 6 50
    fi
}

# Set monitor interval
set_interval_tui() {
    local current=$(get_monitor_interval)
    local new=$(dialog --title "Set Monitor Interval" \
        --inputbox "Current interval: ${current} seconds (approx $((current/60)) minutes)\nEnter new interval in seconds:" 10 50 "$current" \
        2>&1 >/dev/tty)
    
    if [ -n "$new" ] && [[ "$new" =~ ^[0-9]+$ ]] && [ $new -gt 0 ]; then
        echo "$new" > "$MONITOR_INTERVAL_FILE"
        systemctl restart orbitalx 2>/dev/null || true
        dialog --msgbox "Monitor interval set to ${new} seconds ($((new/60)) minutes)." 6 50
    else
        dialog --msgbox "Invalid input. Please enter a positive number." 6 40
    fi
}

# Stop all instances (TUI)
stop_all_tui() {
    dialog --yesno "Are you sure you want to stop all active Tor instances?" 6 50
    if [ $? -eq 0 ]; then
        stop_all_instances
        dialog --msgbox "All instances stopped." 6 30
    fi
}

# Admin menu (install/update/uninstall)
admin_menu() {
    while true; do
        choice=$(dialog --clear --title "Administration" \
            --menu "OrbitalX Admin" 12 50 5 \
            1 "Install (full setup)" \
            2 "Update from Git" \
            3 "Uninstall" \
            4 "Back" \
            2>&1 >/dev/tty)
        
        case $? in
            0)
                case $choice in
                    1) install_tui ;;
                    2) update_tui ;;
                    3) uninstall_tui ;;
                    4) break ;;
                esac
                ;;
            *) break ;;
        esac
    done
}

# Install (TUI)
install_tui() {
    dialog --infobox "Installing OrbitalX..." 5 40
    if install_core; then
        dialog --msgbox "Installation complete.\nService enabled: orbitalx.service" 6 50
    else
        dialog --msgbox "Installation failed. Check logs." 6 40
    fi
}

# Update (TUI)
update_tui() {
    dialog --infobox "Updating OrbitalX from GitHub..." 5 40
    if update_core; then
        dialog --msgbox "Update completed successfully.\nService restarted." 6 40
    else
        dialog --msgbox "Update failed. Check logs or try manually." 6 40
    fi
}

# Uninstall (TUI)
uninstall_tui() {
    dialog --yesno "Are you sure you want to uninstall OrbitalX?" 6 50
    if [ $? -eq 0 ]; then
        dialog --yesno "Delete all data (config, logs, Tor data)?" 6 50
        local delete_data=$?
        uninstall_core $delete_data
        dialog --msgbox "Uninstall complete." 6 30
        clear
        exit 0
    fi
}

# ==================== CORE INSTALL/UPDATE/UNINSTALL ====================

install_core() {
    check_root
    check_prerequisites || return 1
    create_dirs

    # Download the script from GitHub
    print_info "Downloading OrbitalX from GitHub..."
    local tmp_file="/tmp/orbitalx_install.sh"
    curl -sL "$REPO_RAW_URL" -o "$tmp_file"
    if [ $? -ne 0 ] || [ ! -s "$tmp_file" ]; then
        print_error "Failed to download script from GitHub."
        return 1
    fi
    chmod +x "$tmp_file"
    mv "$tmp_file" /usr/local/bin/orbitalx

    # Create systemd service
    cat > /etc/systemd/system/orbitalx.service << EOF
[Unit]
Description=OrbitalX - Tor Multi-Location Manager
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/orbitalx monitor
ExecStop=/usr/local/bin/orbitalx stop-all
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable orbitalx.service
    systemctl start orbitalx.service

    print_info "Installation complete. Service enabled and started."
    return 0
}

update_core() {
    check_root
    local script_path=$(realpath "$0")
    local script_dir=$(dirname "$script_path")
    
    # Check if we are inside a git repo
    if [ -d "${script_dir}/.git" ]; then
        print_info "Git repository detected. Pulling latest changes..."
        cd "$script_dir"
        git pull
        if [ $? -eq 0 ]; then
            print_info "Git pull successful."
            # If the script is installed in /usr/local/bin, copy the updated version
            if [ -f "/usr/local/bin/orbitalx" ]; then
                cp "$script_path" /usr/local/bin/orbitalx
                chmod +x /usr/local/bin/orbitalx
                print_info "Updated /usr/local/bin/orbitalx"
            fi
            systemctl restart orbitalx 2>/dev/null || true
        else
            print_error "Git pull failed."
            return 1
        fi
    elif [ "$script_path" == "/usr/local/bin/orbitalx" ]; then
        print_info "Downloading latest version from GitHub..."
        local tmp_file="/tmp/orbitalx_new.sh"
        curl -sL "$REPO_RAW_URL" -o "$tmp_file"
        if [ $? -eq 0 ] && [ -s "$tmp_file" ]; then
            chmod +x "$tmp_file"
            mv "$tmp_file" /usr/local/bin/orbitalx
            print_info "Update successful. Restarting service..."
            systemctl restart orbitalx 2>/dev/null || true
        else
            print_error "Download failed. Check network or repository URL."
            rm -f "$tmp_file"
            return 1
        fi
    else
        print_error "OrbitalX is not installed in a standard location or not in a git repo."
        print_info "Please install first with 'orbitalx install' or re-run the one-liner."
        return 1
    fi
    return 0
}

uninstall_core() {
    check_root
    systemctl stop orbitalx 2>/dev/null || true
    systemctl disable orbitalx 2>/dev/null || true
    rm -f /etc/systemd/system/orbitalx.service
    rm -f /usr/local/bin/orbitalx
    systemctl daemon-reload
    
    if [ $1 -eq 0 ]; then
        rm -rf "$DATA_DIR" "$CONFIG_DIR" "$LOG_DIR" "$PID_DIR"
    fi
}

# ==================== CLI COMMANDS (for compatibility) ====================

cli_mode() {
    case "$1" in
        install)
            install_core
            ;;
        uninstall)
            uninstall_core 0
            ;;
        update)
            update_core
            ;;
        add)
            # CLI add: expects country code as $2
            if [ -z "$2" ]; then
                print_error "Usage: orbitalx add <COUNTRY>"
                exit 1
            fi
            country=$(echo "$2" | tr '[:lower:]' '[:upper:]')
            if ! grep -q "^${country}:" "$AVAILABLE_FILE"; then
                print_error "Country not available."
                exit 1
            fi
            port=$(grep "^${country}:" "$AVAILABLE_FILE" | cut -d':' -f2)
            activate_country "$country" "$port"
            ;;
        remove)
            if [ -z "$2" ]; then
                print_error "Usage: orbitalx remove <COUNTRY>"
                exit 1
            fi
            deactivate_country "$(echo "$2" | tr '[:lower:]' '[:upper:]')"
            ;;
        status)
            if [ -s "$ACTIVE_FILE" ]; then
                echo "Active Locations:"
                cat "$ACTIVE_FILE"
            else
                echo "No active locations."
            fi
            ;;
        available)
            if [ -s "$AVAILABLE_FILE" ]; then
                echo "Available Countries:"
                cat "$AVAILABLE_FILE"
            else
                echo "No available countries."
            fi
            ;;
        set-interval)
            if [ -z "$2" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                print_error "Usage: orbitalx set-interval <SECONDS>"
                exit 1
            fi
            echo "$2" > "$MONITOR_INTERVAL_FILE"
            systemctl restart orbitalx 2>/dev/null || true
            print_info "Interval set to $2 seconds."
            ;;
        monitor)
            monitor_daemon
            ;;
        stop-all)
            stop_all_instances
            ;;
        help)
            cat << EOF
OrbitalX v${VERSION} - Tor Location Manager

CLI Commands:
  install                Install systemd service
  uninstall              Remove everything
  update                 Update from Git
  add <COUNTRY>          Activate a country (e.g., DE)
  remove <COUNTRY>       Deactivate a country
  status                 Show active locations
  available              Show available countries
  set-interval <SEC>     Change monitor interval
  monitor                Run daemon
  stop-all               Stop all instances
  help                   This help

Run without arguments for TUI menu.
EOF
            ;;
        *)
            print_error "Unknown command. Run 'orbitalx help' or just 'orbitalx' for TUI."
            exit 1
            ;;
    esac
}

# ==================== MAIN ====================

# If no arguments, run TUI
if [ $# -eq 0 ]; then
    check_dialog
    check_prerequisites || exit 1
    create_dirs
    main_menu
else
    # CLI mode
    cli_mode "$@"
fi

exit 0
