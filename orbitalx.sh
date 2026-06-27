#!/bin/bash

# ===========================================================
# OrbitalX - Tor Multi-Location Manager for Xray
# Version: Read from VERSION file
# Description: TUI-based management with predefined countries
#              and fixed ports. Monitor interval configurable.
# ===========================================================

set -e

# ==================== GLOBALS ====================
SCRIPT_NAME="OrbitalX"
REPO_RAW_URL_SCRIPT="https://raw.githubusercontent.com/Issei-177013/OrbitalX/main/orbitalx.sh"
REPO_RAW_URL_VERSION="https://raw.githubusercontent.com/Issei-177013/OrbitalX/main/VERSION"
CONFIG_DIR="/etc/orbitalx"
DATA_DIR="/var/lib/orbitalx"
LOG_DIR="/var/log/orbitalx"
PID_DIR="/var/run/orbitalx"
ACTIVE_FILE="${CONFIG_DIR}/active.conf"
AVAILABLE_FILE="${CONFIG_DIR}/available.conf"
MONITOR_INTERVAL_FILE="${CONFIG_DIR}/monitor_interval.conf"
DEFAULT_MONITOR_INTERVAL=600
MAX_RETRY=3
TUI_MODE=0

# Global error message for TUI
LAST_ERROR=""

# Ordered list of countries (by port order)
COUNTRIES_ORDERED=("DE" "TR" "US" "FR" "NL" "GB" "CA" "JP" "IT" "SE" "CH" "ES")

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

# Read version from VERSION file (local or installed)
get_version() {
    local script_dir="$(dirname "$0")"
    if [ -f "$script_dir/VERSION" ]; then
        cat "$script_dir/VERSION" | tr -d '\n\r'
    elif [ -f "VERSION" ]; then
        cat "VERSION" | tr -d '\n\r'
    else
        echo "0.0.0"
    fi
}

VERSION=$(get_version)

# Ensure we have a valid working directory
if ! cd . 2>/dev/null; then
    cd /
fi

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
    log "[INFO] $1"
    if [ $TUI_MODE -eq 0 ]; then
        echo -e "${GREEN}[INFO]${NC} $1"
    fi
}

print_warn() {
    log "[WARN] $1"
    if [ $TUI_MODE -eq 0 ]; then
        echo -e "${YELLOW}[WARN]${NC} $1"
    fi
}

print_error() {
    log "[ERROR] $1"
    if [ $TUI_MODE -eq 0 ]; then
        echo -e "${RED}[ERROR]${NC} $1"
    fi
}

set_error() {
    LAST_ERROR="$1"
    log "[ERROR] $1"
}

show_error_tui() {
    if [ -n "$LAST_ERROR" ]; then
        dialog --title "Error" --msgbox "$LAST_ERROR" 8 60
        LAST_ERROR=""
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This command requires root privileges. Please run with sudo."
        exit 1
    fi
}

check_dialog() {
    if ! command -v dialog &> /dev/null; then
        echo "Dialog is not installed. Installing..."
        sudo apt update && sudo apt install dialog -y
    fi
}

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

create_dirs() {
    mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" "$PID_DIR"
    
    if [ ! -f "$AVAILABLE_FILE" ]; then
        for code in "${COUNTRIES_ORDERED[@]}"; do
            echo "$code:${PREDEFINED_PORTS[$code]}" >> "$AVAILABLE_FILE"
        done
    fi
    
    touch "$ACTIVE_FILE"
    
    if [ ! -f "$MONITOR_INTERVAL_FILE" ]; then
        echo "$DEFAULT_MONITOR_INTERVAL" > "$MONITOR_INTERVAL_FILE"
    fi
}

get_monitor_interval() {
    if [ -f "$MONITOR_INTERVAL_FILE" ]; then
        cat "$MONITOR_INTERVAL_FILE"
    else
        echo "$DEFAULT_MONITOR_INTERVAL"
    fi
}

find_control_port() {
    local base=10050
    local port=$base
    while ss -tuln | grep -q ":$port "; do
        ((port++))
    done
    echo "$port"
}

get_tor_exit_ip() {
    local port=$1
    local ip=$(curl -s --socks5-hostname 127.0.0.1:"$port" --max-time 5 https://api.ipify.org?format=text 2>/dev/null)
    if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
    else
        echo ""
    fi
}

get_ip_country() {
    local ip=$1
    local country=$(curl -s --max-time 3 "http://ip-api.com/line/$ip?fields=countryCode" 2>/dev/null)
    if [ -n "$country" ] && [[ "$country" =~ ^[A-Z]{2}$ ]]; then
        echo "$country"
    else
        echo ""
    fi
}

check_ip_quality() {
    local port=$1
    local ip=$(get_tor_exit_ip "$port")
    if [ -n "$ip" ]; then
        return 0
    else
        return 1
    fi
}

rotate_tor_ip() {
    local control_port=$1
    echo -e "AUTHENTICATE \"\"\r\nSIGNAL NEWNYM\r\nQUIT" | nc 127.0.0.1 "$control_port" > /dev/null 2>&1
    return $?
}

# ==================== CORE FUNCTIONS ====================

activate_country() {
    local country=$1
    local port=$2
    
    sed -i "/^${country}:/d" "$AVAILABLE_FILE"
    
    local control_port=$(find_control_port)
    local data_dir="${DATA_DIR}/${country}"
    mkdir -p "$data_dir"
    
    # Stronger exit node enforcement
    cat > "${data_dir}/torrc" << EOF
SocksPort 127.0.0.1:${port}
ControlPort 127.0.0.1:${control_port}
DataDirectory ${data_dir}
ExitNodes {${country}}
StrictNodes 1
NumEntryGuards 1
NewCircuitPeriod 86400
MaxCircuitDirtiness 86400
CircuitBuildTimeout 30
EOF

    tor -f "${data_dir}/torrc" --RunAsDaemon 1 --Log "notice file ${LOG_DIR}/tor_${country}.log"
    sleep 3

    if ! pgrep -f "tor -f ${data_dir}/torrc" > /dev/null; then
        set_error "Failed to start Tor for ${country}."
        echo "${country}:${port}" >> "$AVAILABLE_FILE"
        return 1
    fi

    # Try up to 10 times to get correct exit country
    local exit_ip=""
    local ip_country=""
    local success=0
    
    for attempt in $(seq 1 10); do
        # Force new circuit
        rotate_tor_ip "$control_port"
        sleep 3
        
        exit_ip=$(get_tor_exit_ip "$port")
        if [ -n "$exit_ip" ]; then
            ip_country=$(get_ip_country "$exit_ip")
            if [ "$ip_country" = "$country" ]; then
                success=1
                break
            else
                print_warn "Attempt $attempt: IP $exit_ip is in $ip_country, not $country. Retrying..."
            fi
        else
            print_warn "Attempt $attempt: No IP yet. Retrying..."
        fi
        sleep 2
    done

    if [ $success -eq 0 ]; then
        # Failed to get correct country
        set_error "Could not find an exit node in ${country}. Please try again later or choose another country."
        pkill -f "tor -f ${data_dir}/torrc" || true
        rm -rf "$data_dir"
        echo "${country}:${port}" >> "$AVAILABLE_FILE"
        return 1
    fi

    echo "${country}:${port}:${control_port}:${exit_ip}" >> "$ACTIVE_FILE"
    print_info "Activated ${country} on port ${port} with IP ${exit_ip} (${ip_country})."
    return 0
}

deactivate_country() {
    local country=$1
    if ! grep -q "^${country}:" "$ACTIVE_FILE"; then
        set_error "Country ${country} is not active."
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

stop_all_instances() {
    pkill -f "tor -f ${DATA_DIR}/" || true
    print_info "All Tor instances stopped."
}

monitor_daemon() {
    local interval=$(get_monitor_interval)
    while true; do
        if [ -s "$ACTIVE_FILE" ]; then
            while IFS= read -r line; do
                IFS=':' read -r country port control_port saved_ip <<< "$line"
                data_dir="${DATA_DIR}/${country}"
                
                # Check if Tor process is running
                if ! pgrep -f "tor -f ${data_dir}/torrc" > /dev/null; then
                    print_warn "${country} is down. Restarting..."
                    tor -f "${data_dir}/torrc" --RunAsDaemon 1 --Log "notice file ${LOG_DIR}/tor_${country}.log"
                    sleep 5
                    # After restart, try to get correct country
                    local new_ip=$(get_tor_exit_ip "$port")
                    if [ -n "$new_ip" ]; then
                        ip_country=$(get_ip_country "$new_ip")
                        if [ "$ip_country" = "$country" ]; then
                            sed -i "s/^${country}:${port}:${control_port}:[^:]*$/${country}:${port}:${control_port}:${new_ip}/" "$ACTIVE_FILE"
                            print_info "Restored ${country} with IP ${new_ip} (${ip_country})"
                        else
                            print_error "After restart, IP ${new_ip} is in ${ip_country}, not ${country}. Manual intervention needed."
                        fi
                    fi
                    continue
                fi
                
                # Check IP reachability
                if ! check_ip_quality "$port"; then
                    print_warn "IP for ${country} is unreachable. Attempting to rotate..."
                    local rotated=0
                    for attempt in {1..3}; do
                        if rotate_tor_ip "$control_port"; then
                            sleep 5
                            local new_ip=$(get_tor_exit_ip "$port")
                            if [ -n "$new_ip" ]; then
                                ip_country=$(get_ip_country "$new_ip")
                                if [ "$ip_country" = "$country" ]; then
                                    sed -i "s/^${country}:${port}:${control_port}:[^:]*$/${country}:${port}:${control_port}:${new_ip}/" "$ACTIVE_FILE"
                                    print_info "✅ Rotated IP for ${country}: ${new_ip} (${ip_country})"
                                    rotated=1
                                    break
                                else
                                    print_warn "Rotated IP ${new_ip} is in ${ip_country}, not ${country}. Trying again..."
                                fi
                            else
                                print_warn "No IP after rotation, trying again..."
                            fi
                        fi
                        sleep 3
                    done
                    if [ $rotated -eq 0 ]; then
                        print_error "Could not get valid ${country} IP after 3 rotation attempts."
                    fi
                else
                    # IP reachable: check country consistency
                    current_ip=$(get_tor_exit_ip "$port")
                    if [ -n "$current_ip" ]; then
                        ip_country=$(get_ip_country "$current_ip")
                        if [ "$ip_country" != "$country" ]; then
                            print_warn "IP changed to ${current_ip} (${ip_country}), not ${country}. Attempting to fix..."
                            # Force rotation
                            rotate_tor_ip "$control_port"
                            sleep 5
                            new_ip=$(get_tor_exit_ip "$port")
                            if [ -n "$new_ip" ]; then
                                new_country=$(get_ip_country "$new_ip")
                                if [ "$new_country" = "$country" ]; then
                                    sed -i "s/^${country}:${port}:${control_port}:[^:]*$/${country}:${port}:${control_port}:${new_ip}/" "$ACTIVE_FILE"
                                    print_info "✅ Forced rotation fixed IP for ${country}: ${new_ip} (${new_country})"
                                else
                                    print_error "Cannot fix country for ${country}. Current IP: ${new_ip} (${new_country})"
                                fi
                            fi
                        fi
                    fi
                fi
            done < "$ACTIVE_FILE"
        fi
        sleep "$interval"
    done
}

# ==================== TUI FUNCTIONS ====================

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

show_available_tui() {
    if [ ! -s "$AVAILABLE_FILE" ]; then
        dialog --msgbox "No countries available. All are active." 6 40
        return
    fi
    
    local items=()
    while IFS= read -r line; do
        IFS=':' read -r code port <<< "$line"
        items+=("$code" "Port: $port")
    done < "$AVAILABLE_FILE"
    
    dialog --title "Available Countries" \
        --menu "Select a country to view details (press Enter)" \
        15 50 10 "${items[@]}" \
        2>&1 >/dev/tty
}

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
            (
                activate_country "$country" "$port" > /tmp/orbitalx_activate.log 2>&1
                echo $? > /tmp/orbitalx_activate.exit
            ) &
            pid=$!
            
            dialog --title "Activating ${country}..." --infobox "Please wait..." 5 40
            wait $pid
            exit_code=$(cat /tmp/orbitalx_activate.exit 2>/dev/null || echo 1)
            
            if [ $exit_code -eq 0 ]; then
                dialog --msgbox "✅ ${country} activated successfully!\n\nUse port ${port} in Xray outbound." 8 50
            else
                show_error_tui
            fi
            rm -f /tmp/orbitalx_activate.log /tmp/orbitalx_activate.exit
        else
            dialog --msgbox "Error: port not found." 6 40
        fi
    fi
}

show_status_tui() {
    if [ ! -s "$ACTIVE_FILE" ]; then
        dialog --msgbox "No active locations." 6 40
        return
    fi
    
    local tmp_file="/tmp/orbitalx_status.txt"
    > "$tmp_file"
    
    echo "Country | Port | Status | Exit IP | Country" >> "$tmp_file"
    echo "--------|------|--------|---------|---------" >> "$tmp_file"
    
    while IFS= read -r line; do
        IFS=':' read -r country port control_port saved_ip <<< "$line"
        if pgrep -f "tor -f ${DATA_DIR}/${country}/torrc" > /dev/null; then
            current_ip=$(get_tor_exit_ip "$port")
            if [ -z "$current_ip" ]; then
                echo "${country} | ${port} | ⚠️ Issue | ${saved_ip:-Unknown} | -" >> "$tmp_file"
            else
                ip_country=$(get_ip_country "$current_ip")
                echo "${country} | ${port} | ✅ Active | ${current_ip} | ${ip_country:-Unknown}" >> "$tmp_file"
                if [ "$current_ip" != "$saved_ip" ] && [ "$saved_ip" != "unknown" ]; then
                    sed -i "s/^${country}:${port}:${control_port}:${saved_ip}$/${country}:${port}:${control_port}:${current_ip}/" "$ACTIVE_FILE"
                fi
            fi
        else
            echo "${country} | ${port} | ❌ Stopped | ${saved_ip:-Unknown} | -" >> "$tmp_file"
        fi
    done < "$ACTIVE_FILE"
    
    dialog --title "Active Locations" --textbox "$tmp_file" 20 65
    rm -f "$tmp_file"
}

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
        (
            deactivate_country "$country" > /tmp/orbitalx_deactivate.log 2>&1
            echo $? > /tmp/orbitalx_deactivate.exit
        ) &
        pid=$!
        
        dialog --title "Deactivating ${country}..." --infobox "Please wait..." 5 40
        wait $pid
        exit_code=$(cat /tmp/orbitalx_deactivate.exit 2>/dev/null || echo 1)
        
        if [ $exit_code -eq 0 ]; then
            dialog --msgbox "✅ ${country} deactivated and moved back to available list." 6 50
        else
            show_error_tui
        fi
        rm -f /tmp/orbitalx_deactivate.log /tmp/orbitalx_deactivate.exit
    fi
}

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

stop_all_tui() {
    dialog --yesno "Are you sure you want to stop all active Tor instances?" 6 50
    if [ $? -eq 0 ]; then
        (
            stop_all_instances > /tmp/orbitalx_stop.log 2>&1
        ) &
        pid=$!
        dialog --infobox "Stopping all instances..." 5 40
        wait $pid
        dialog --msgbox "All instances stopped." 6 30
        rm -f /tmp/orbitalx_stop.log
    fi
}

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

install_tui() {
    dialog --infobox "Installing OrbitalX..." 5 40
    if install_core; then
        dialog --msgbox "✅ Installation complete.\nService enabled: orbitalx.service" 6 50
        exec /usr/local/bin/orbitalx
    else
        show_error_tui
    fi
}

update_tui() {
    dialog --infobox "Updating OrbitalX from GitHub..." 5 40
    if update_core; then
        dialog --msgbox "✅ Update completed successfully.\nService restarted." 6 40
        exec /usr/local/bin/orbitalx
    else
        show_error_tui
    fi
}

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

    print_info "Downloading OrbitalX from GitHub..."
    local tmp_script="/tmp/orbitalx_install.sh"
    local tmp_version="/tmp/orbitalx_version"

    curl -sL "$REPO_RAW_URL_SCRIPT" -o "$tmp_script"
    if [ $? -ne 0 ] || [ ! -s "$tmp_script" ]; then
        set_error "Failed to download script from GitHub."
        return 1
    fi

    curl -sL "$REPO_RAW_URL_VERSION" -o "$tmp_version"
    if [ $? -eq 0 ] && [ -s "$tmp_version" ]; then
        cp "$tmp_version" /usr/local/bin/VERSION
    else
        echo "0.0.0" > /usr/local/bin/VERSION
        print_warn "Could not download VERSION, using fallback 0.0.0"
    fi

    chmod +x "$tmp_script"
    mv "$tmp_script" /usr/local/bin/orbitalx

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

    VERSION=$(get_version)
    print_info "Installation complete. Service enabled and started."
    return 0
}

update_core() {
    check_root

    if [ -d "$(dirname "$(realpath "$0")")/.git" ]; then
        local repo_dir="$(dirname "$(realpath "$0")")"
        cd "$repo_dir"
        print_info "Git repository detected. Pulling latest changes..."
        if git pull; then
            print_info "Git pull successful."
            if [ -f "/usr/local/bin/orbitalx" ]; then
                cp "$repo_dir/orbitalx.sh" /usr/local/bin/orbitalx 2>/dev/null || cp "$repo_dir/orbitalx" /usr/local/bin/orbitalx 2>/dev/null
                chmod +x /usr/local/bin/orbitalx
            fi
            if [ -f "$repo_dir/VERSION" ] && [ -f "/usr/local/bin/VERSION" ]; then
                cp "$repo_dir/VERSION" /usr/local/bin/VERSION
            fi
            systemctl restart orbitalx 2>/dev/null || true
            VERSION=$(get_version)
            return 0
        else
            set_error "Git pull failed. See logs for details."
            return 1
        fi
    fi

    if [ -f "/usr/local/bin/orbitalx" ]; then
        print_info "Updating installed OrbitalX from GitHub..."
        local tmp_script="/tmp/orbitalx_update.sh"
        local tmp_version="/tmp/orbitalx_update_version"

        if curl -sL "$REPO_RAW_URL_SCRIPT" -o "$tmp_script" && [ -s "$tmp_script" ]; then
            chmod +x "$tmp_script"
            mv "$tmp_script" /usr/local/bin/orbitalx
            print_info "Script updated."
        else
            set_error "Failed to download script from GitHub."
            rm -f "$tmp_script"
            return 1
        fi

        if curl -sL "$REPO_RAW_URL_VERSION" -o "$tmp_version" && [ -s "$tmp_version" ]; then
            mv "$tmp_version" /usr/local/bin/VERSION
            print_info "VERSION file updated."
        else
            print_warn "Could not download VERSION, keeping existing."
            rm -f "$tmp_version"
        fi

        systemctl restart orbitalx 2>/dev/null || true
        VERSION=$(get_version)
        print_info "Update completed successfully."
        return 0
    else
        set_error "OrbitalX is not installed. Please run 'orbitalx install' first."
        return 1
    fi
}

uninstall_core() {
    check_root
    systemctl stop orbitalx 2>/dev/null || true
    systemctl disable orbitalx 2>/dev/null || true
    rm -f /etc/systemd/system/orbitalx.service
    rm -f /usr/local/bin/orbitalx
    rm -f /usr/local/bin/VERSION
    systemctl daemon-reload
    
    if [ $1 -eq 0 ]; then
        rm -rf "$DATA_DIR" "$CONFIG_DIR" "$LOG_DIR" "$PID_DIR"
    fi
}

# ==================== CLI COMMANDS ====================

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

if [ $# -eq 0 ]; then
    TUI_MODE=1
    check_dialog
    check_prerequisites || exit 1
    create_dirs
    main_menu
else
    TUI_MODE=0
    cli_mode "$@"
fi

exit 0