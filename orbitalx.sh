#!/bin/bash

# ===========================================================
# OrbitalX - Hybrid Tor & Psiphon Multi-Instance Manager
# Version: Read from VERSION file
# Author: Issei-177013
# Description: Full-featured TUI manager for multiple Tor & Psiphon instances
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
INSTANCES_FILE="${CONFIG_DIR}/instances.conf"
PORT_ALLOC_FILE="${CONFIG_DIR}/port_allocator.conf"
MONITOR_INTERVAL_FILE="${CONFIG_DIR}/monitor_interval.conf"
DEFAULT_MONITOR_INTERVAL=600
TUI_MODE=0

# Psiphon specific - Using SpherionOS repository
PSIPHON_BIN="/etc/psiphon/psiphon-tunnel-core-x86_64"
PSIPHON_DEFAULT_CONFIG="/etc/psiphon/psiphon.config"
PSIPHON_BASE_DIR="/etc/psiphon-instances"
PSIPHON_VALID_REGIONS=("AT" "BE" "BG" "CA" "CH" "CZ" "DE" "DK" "EE" "ES" "FI" "FR" "GB" "HU" "IE" "IN" "IT" "JP" "LV" "NL" "NO" "PL" "RO" "RS" "SE" "SG" "SK" "US")
PSIPHON_BIN_URL="https://raw.githubusercontent.com/SpherionOS/PsiphonLinux/main/archive/psiphon-tunnel-core-x86_64"
PSIPHON_CONFIG_URL="https://raw.githubusercontent.com/SpherionOS/PsiphonLinux/main/psiphon.config"

# Global error message for TUI
LAST_ERROR=""

# Full country names mapping
declare -A FULL_NAMES=(
    ["TR"]="Turkey"
    ["US"]="United States"
    ["FR"]="France"
    ["AT"]="Austria"
    ["BE"]="Belgium"
    ["RO"]="Romania"
    ["CA"]="Canada"
    ["SG"]="Singapore"
    ["JP"]="Japan"
    ["IE"]="Ireland"
    ["FI"]="Finland"
    ["ES"]="Spain"
    ["PL"]="Poland"
    ["NL"]="Netherlands"
    ["IT"]="Italy"
    ["CH"]="Switzerland"
    ["SE"]="Sweden"
    ["NO"]="Norway"
    ["DK"]="Denmark"
    ["IS"]="Iceland"
    ["AU"]="Australia"
    ["IN"]="India"
    ["HK"]="Hong Kong"
    ["UA"]="Ukraine"
    ["CZ"]="Czech Republic"
    ["KR"]="South Korea"
    ["ZA"]="South Africa"
    ["MX"]="Mexico"
    ["MY"]="Malaysia"
    ["AZ"]="Azerbaijan"
    ["CY"]="Cyprus"
    ["GR"]="Greece"
    ["PT"]="Portugal"
    ["HU"]="Hungary"
    ["LU"]="Luxembourg"
)

# Helper function to get full country name
get_full_name() {
    local code=$1
    echo "${FULL_NAMES[$code]:-$code}"
}

# Read version from VERSION file
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

# Ensure valid working directory
if ! cd . 2>/dev/null; then
    cd /
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== HELPER FUNCTIONS ====================

log() {
    local level="${2:-INFO}"
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        LOG_DIR="/tmp/orbitalx"
        mkdir -p "$LOG_DIR" 2>/dev/null || true
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $1" >> "${LOG_DIR}/manager.log" 2>/dev/null || true
}

log_info() { log "$1" "INFO"; }
log_warn() { log "$1" "WARN"; }
log_error() { log "$1" "ERROR"; }

print_info() {
    log_info "$1"
    if [ $TUI_MODE -eq 0 ]; then
        echo -e "${GREEN}[INFO]${NC} $1"
    fi
}

print_warn() {
    log_warn "$1"
    if [ $TUI_MODE -eq 0 ]; then
        echo -e "${YELLOW}[WARN]${NC} $1"
    fi
}

print_error() {
    log_error "$1"
    if [ $TUI_MODE -eq 0 ]; then
        echo -e "${RED}[ERROR]${NC} $1"
    fi
}

set_error() {
    LAST_ERROR="$1"
    log_error "$1"
}

show_error_tui() {
    if [ -n "$LAST_ERROR" ]; then
        dialog --title "Error" --msgbox "$LAST_ERROR" 8 60
        LAST_ERROR=""
    fi
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "This command requires root privileges. Please run with sudo."
        exit 1
    fi
}

# Install missing packages
install_missing_packages() {
    local missing=()
    for cmd in tor curl nc ss pgrep pkill dialog jq; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        return 0
    fi

    print_info "Missing packages: ${missing[*]}"
    print_info "Attempting to install missing packages..."

    declare -A PKG_MAP=(
        ["tor"]="tor"
        ["curl"]="curl"
        ["nc"]="netcat-openbsd"
        ["ss"]="iproute2"
        ["pgrep"]="procps"
        ["pkill"]="procps"
        ["dialog"]="dialog"
        ["jq"]="jq"
    )

    local pkgs=()
    for cmd in "${missing[@]}"; do
        pkgs+=("${PKG_MAP[$cmd]}")
    done
    pkgs=($(printf "%s\n" "${pkgs[@]}" | sort -u))

    apt update -y
    apt install -y "${pkgs[@]}"

    local still_missing=()
    for cmd in "${missing[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            still_missing+=("$cmd")
        fi
    done

    if [ ${#still_missing[@]} -ne 0 ]; then
        print_error "Failed to install: ${still_missing[*]}"
        print_info "Please install manually: sudo apt install ${still_missing[*]}"
        return 1
    fi

    print_info "All missing packages installed successfully."
    return 0
}

# Install Psiphon binary and default config from SpherionOS
install_psiphon() {
    # Check if already installed and working
    if [ -f "$PSIPHON_BIN" ] && [ -f "$PSIPHON_DEFAULT_CONFIG" ]; then
        print_info "Psiphon already installed. Checking if it works..."
        if "$PSIPHON_BIN" -version &>/dev/null; then
            print_info "Psiphon binary is working correctly."
            return 0
        else
            print_warn "Existing Psiphon binary is not working. Reinstalling..."
            rm -f "$PSIPHON_BIN"
        fi
    fi

    print_info "Installing Psiphon tunnel core from SpherionOS repository..."

    # Ensure directory exists
    mkdir -p "$(dirname "$PSIPHON_BIN")"

    # Download binary
    local tmp_bin="/tmp/psiphon-tunnel-core-x86_64"
    if ! curl -sL "$PSIPHON_BIN_URL" -o "$tmp_bin"; then
        set_error "Failed to download Psiphon binary from $PSIPHON_BIN_URL"
        return 1
    fi

    if [ ! -s "$tmp_bin" ]; then
        set_error "Downloaded Psiphon binary is empty."
        return 1
    fi

    chmod +x "$tmp_bin"

    # Test the binary immediately
    print_info "Testing downloaded binary..."
    if ! "$tmp_bin" -version &>/dev/null; then
        print_warn "Binary test failed. Checking dependencies..."
        if command -v ldd &>/dev/null; then
            print_info "Missing libraries:"
            ldd "$tmp_bin" | grep "not found" || echo "  (none found)"
        fi
        # Install common missing libraries
        print_info "Installing common libraries for Psiphon..."
        apt update -y
        apt install -y libc6 libstdc++6 libgcc-s1 2>/dev/null || true
        # Try again
        if ! "$tmp_bin" -version &>/dev/null; then
            set_error "Psiphon binary still not working after installing libraries."
            rm -f "$tmp_bin"
            return 1
        fi
    fi

    mv "$tmp_bin" "$PSIPHON_BIN"
    print_info "✅ Psiphon binary installed to $PSIPHON_BIN"

    # Create default config if missing
    if [ ! -f "$PSIPHON_DEFAULT_CONFIG" ]; then
        print_info "Downloading default config from SpherionOS..."
        local tmp_config="/tmp/psiphon.config"
        if curl -sL "$PSIPHON_CONFIG_URL" -o "$tmp_config" && [ -s "$tmp_config" ]; then
            mv "$tmp_config" "$PSIPHON_DEFAULT_CONFIG"
            print_info "✅ Psiphon config installed to $PSIPHON_DEFAULT_CONFIG"
        else
            print_warn "Failed to download config from SpherionOS. Creating fallback config..."
            cat > "$PSIPHON_DEFAULT_CONFIG" << EOF
{
  "LocalSocksProxyPort": 1080,
  "LocalHttpProxyPort": 8080,
  "EgressRegion": "US",
  "ListenInterface": "127.0.0.1",
  "TunnelProtocol": "SSH+",
  "UpstreamProxyUrl": "",
  "UseIndicatorProtocol": true,
  "DNS": {
    "DNSServers": ["1.1.1.1", "8.8.8.8"],
    "Domain": "lan"
  }
}
EOF
            print_info "Fallback Psiphon config created at $PSIPHON_DEFAULT_CONFIG"
        fi
    fi

    # Final verification
    if ! "$PSIPHON_BIN" -version &>/dev/null; then
        set_error "Psiphon installation failed final verification."
        return 1
    fi

    print_info "✅ Psiphon installation complete and verified."
    return 0
}

check_prerequisites() {
    if ! command -v dialog &> /dev/null; then
        print_info "Dialog is not installed. Installing..."
        apt update -y && apt install -y dialog
    fi

    if ! install_missing_packages; then
        return 1
    fi

    # Attempt to install Psiphon automatically
    if ! install_psiphon; then
        print_warn "Psiphon installation failed. Psiphon support may be limited."
        print_info "You can manually install Psiphon from: https://github.com/SpherionOS/PsiphonLinux"
    fi

    return 0
}

create_dirs() {
    mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" "$PID_DIR"
    
    if [ ! -f "$INSTANCES_FILE" ]; then
        touch "$INSTANCES_FILE"
    fi
    
    if [ ! -f "$PORT_ALLOC_FILE" ]; then
        echo "TOR_LAST=9079" > "$PORT_ALLOC_FILE"
        echo "PSIPHON_SOCKS_LAST=1079" >> "$PORT_ALLOC_FILE"
        echo "PSIPHON_HTTP_LAST=8079" >> "$PORT_ALLOC_FILE"
    fi
    
    if [ ! -f "$MONITOR_INTERVAL_FILE" ]; then
        echo "$DEFAULT_MONITOR_INTERVAL" > "$MONITOR_INTERVAL_FILE"
    fi
}

get_next_port_tor() {
    source "$PORT_ALLOC_FILE"
    local next=$((TOR_LAST + 1))
    sed -i "s/TOR_LAST=.*/TOR_LAST=$next/" "$PORT_ALLOC_FILE"
    echo "$next"
}

get_next_port_psiphon_socks() {
    source "$PORT_ALLOC_FILE"
    local next=$((PSIPHON_SOCKS_LAST + 1))
    sed -i "s/PSIPHON_SOCKS_LAST=.*/PSIPHON_SOCKS_LAST=$next/" "$PORT_ALLOC_FILE"
    echo "$next"
}

get_next_port_psiphon_http() {
    source "$PORT_ALLOC_FILE"
    local next=$((PSIPHON_HTTP_LAST + 1))
    sed -i "s/PSIPHON_HTTP_LAST=.*/PSIPHON_HTTP_LAST=$next/" "$PORT_ALLOC_FILE"
    echo "$next"
}

get_monitor_interval() {
    if [ -f "$MONITOR_INTERVAL_FILE" ]; then
        cat "$MONITOR_INTERVAL_FILE"
    else
        echo "$DEFAULT_MONITOR_INTERVAL"
    fi
}

generate_instance_id() {
    local type=$1
    local country=$2
    local count=1
    while grep -q "^${type}-${country}-${count}:" "$INSTANCES_FILE"; do
        count=$((count + 1))
    done
    echo "${type}-${country}-${count}"
}

# ==================== TOR FUNCTIONS ====================

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

rotate_tor_ip() {
    local control_port=$1
    echo -e "AUTHENTICATE \"\"\r\nSIGNAL NEWNYM\r\nQUIT" | nc 127.0.0.1 "$control_port" > /dev/null 2>&1
    return $?
}

tor_create_instance() {
    local country=$1
    local port=$(get_next_port_tor)
    local control_port=$((port + 1000))
    local instance_id=$(generate_instance_id "TOR" "$country")
    local data_dir="${DATA_DIR}/${instance_id}"
    local log_file="${LOG_DIR}/tor_${instance_id}.log"
    local service_file="/etc/systemd/system/orbitalx-tor-${instance_id}.service"
    local torrc_file="${data_dir}/torrc"
    local result_file="/tmp/orbitalx_create_result_$$"

    mkdir -p "$data_dir"

    cat > "$torrc_file" << EOF
SocksPort 127.0.0.1:${port}
ControlPort 127.0.0.1:${control_port}
DataDirectory ${data_dir}
ExitNodes {${country}}
StrictNodes 1
NumEntryGuards 8
NewCircuitPeriod 86400
MaxCircuitDirtiness 86400
CircuitBuildTimeout 30
EnforceDistinctSubnets 0
LearnCircuitBuildTimeout 0
CircuitIdleTimeout 3600
EOF

    # Create systemd service
    cat > "$service_file" << EOF
[Unit]
Description=OrbitalX Tor Instance - ${instance_id}
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/tor -f ${torrc_file} --RunAsDaemon 0
StandardOutput=append:${log_file}
StandardError=append:${log_file}
Restart=on-failure
RestartSec=10
User=root
MemoryMax=512M
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "orbitalx-tor-${instance_id}"
    systemctl start "orbitalx-tor-${instance_id}"

    sleep 5
    if ! systemctl is-active --quiet "orbitalx-tor-${instance_id}"; then
        set_error "Tor instance ${instance_id} failed to start"
        systemctl disable "orbitalx-tor-${instance_id}" 2>/dev/null
        rm -f "$service_file"
        rm -rf "$data_dir"
        return 1
    fi

    # Try to get exit IP
    local exit_ip=""
    local ip_country=""
    local success=0
    for attempt in $(seq 1 10); do
        rotate_tor_ip "$control_port"
        sleep 3
        exit_ip=$(get_tor_exit_ip "$port")
        if [ -n "$exit_ip" ]; then
            ip_country=$(get_ip_country "$exit_ip")
            if [ "$ip_country" = "$country" ]; then
                success=1
                break
            fi
        fi
        sleep 2
    done

    if [ $success -eq 0 ]; then
        set_error "Could not get correct exit IP for ${instance_id}"
        systemctl stop "orbitalx-tor-${instance_id}"
        systemctl disable "orbitalx-tor-${instance_id}"
        rm -f "$service_file"
        rm -rf "$data_dir"
        return 1
    fi

    # Save instance
    echo "${instance_id}:TOR:${country}:${port}:${control_port}:${exit_ip}:active" >> "$INSTANCES_FILE"
    log_info "Created Tor instance ${instance_id} on port ${port} with IP ${exit_ip}"
    print_info "✅ Tor ${instance_id} created (${get_full_name "$country"}) on port ${port}"

    # Save result details for TUI
    echo "instance_id=${instance_id}" > "$result_file"
    echo "port=${port}" >> "$result_file"
    echo "exit_ip=${exit_ip}" >> "$result_file"
    echo "country=${country}" >> "$result_file"
    echo "type=TOR" >> "$result_file"
    echo "control_port=${control_port}" >> "$result_file"

    return 0
}

tor_remove_instance() {
    local instance_id=$1
    if ! grep -q "^${instance_id}:" "$INSTANCES_FILE"; then
        set_error "Instance ${instance_id} not found"
        return 1
    fi

    local line=$(grep "^${instance_id}:" "$INSTANCES_FILE")
    IFS=':' read -r id type country port control_port ip status <<< "$line"

    systemctl stop "orbitalx-tor-${instance_id}" 2>/dev/null
    systemctl disable "orbitalx-tor-${instance_id}" 2>/dev/null
    rm -f "/etc/systemd/system/orbitalx-tor-${instance_id}.service"
    systemctl daemon-reload

    rm -rf "${DATA_DIR}/${instance_id}"
    sed -i "/^${instance_id}:/d" "$INSTANCES_FILE"
    log_info "Removed Tor instance ${instance_id}"
    print_info "✅ Tor ${instance_id} removed"
    return 0
}

tor_start_instance() {
    local instance_id=$1
    systemctl start "orbitalx-tor-${instance_id}"
    log_info "Started Tor ${instance_id}"
    print_info "Tor ${instance_id} started"
}

tor_stop_instance() {
    local instance_id=$1
    systemctl stop "orbitalx-tor-${instance_id}"
    log_info "Stopped Tor ${instance_id}"
    print_info "Tor ${instance_id} stopped"
}

tor_restart_instance() {
    tor_stop_instance "$1"
    sleep 2
    tor_start_instance "$1"
}

tor_show_log() {
    local instance_id=$1
    local log_file="${LOG_DIR}/tor_${instance_id}.log"
    if [ ! -f "$log_file" ]; then
        dialog --msgbox "Log file not found: ${log_file}" 6 50
        return 1
    fi
    dialog --title "Tor Log - ${instance_id}" --tailbox "$log_file" 20 80
}

# ==================== PSIPHON FUNCTIONS ====================

psiphon_create_instance() {
    local country=$1

    # Check prerequisites for Psiphon
    if [ ! -f "$PSIPHON_BIN" ]; then
        set_error "Psiphon binary not found at $PSIPHON_BIN. Run 'orbitalx install' to install it."
        return 1
    fi

    # Test if binary works
    if ! "$PSIPHON_BIN" -version &>/dev/null; then
        # Try to diagnose
        local missing_libs=""
        if command -v ldd &>/dev/null; then
            missing_libs=$(ldd "$PSIPHON_BIN" 2>/dev/null | grep "not found" | awk '{print $1}')
        fi
        if [ -n "$missing_libs" ]; then
            set_error "Psiphon binary is not executable. Missing libraries: $missing_libs. Run 'orbitalx install' to reinstall."
        else
            set_error "Psiphon binary is not executable. Run 'orbitalx install' to reinstall."
        fi
        return 1
    fi

    if [ ! -f "$PSIPHON_DEFAULT_CONFIG" ]; then
        set_error "Psiphon config file not found at $PSIPHON_DEFAULT_CONFIG. Run 'orbitalx install' to install it."
        return 1
    fi

    local socks_port=$(get_next_port_psiphon_socks)
    local http_port=$(get_next_port_psiphon_http)
    local instance_id=$(generate_instance_id "PSIPHON" "$country")
    local result_file="/tmp/orbitalx_create_result_$$"

    # Validate region
    local valid=0
    for reg in "${PSIPHON_VALID_REGIONS[@]}"; do
        if [[ "$reg" == "$country" ]]; then
            valid=1
            break
        fi
    done
    if [ $valid -eq 0 ]; then
        set_error "Invalid country code for Psiphon: $country"
        return 1
    fi

    local instance_dir="${PSIPHON_BASE_DIR}/${instance_id}"
    mkdir -p "$instance_dir"

    local config_file="${instance_dir}/config.json"
    cp "$PSIPHON_DEFAULT_CONFIG" "$config_file"

    if command -v jq &>/dev/null; then
        jq --arg region "$country" --argjson socks "$socks_port" --argjson http "$http_port" \
           '.EgressRegion = $region | .LocalSocksProxyPort = $socks | .LocalHttpProxyPort = $http' \
           "$config_file" > tmp.$$ && mv tmp.$$ "$config_file"
    else
        sed -i "s/\"EgressRegion\":\"[^\"]*\"/\"EgressRegion\":\"$country\"/" "$config_file"
        sed -i "s/\"LocalSocksProxyPort\":[0-9]*/\"LocalSocksProxyPort\":$socks_port/" "$config_file"
        sed -i "s/\"LocalHttpProxyPort\":[0-9]*/\"LocalHttpProxyPort\":$http_port/" "$config_file"
    fi

    local service_file="/etc/systemd/system/orbitalx-psiphon-${instance_id}.service"
    local log_file="${LOG_DIR}/psiphon_${instance_id}.log"
    cat > "$service_file" << EOF
[Unit]
Description=OrbitalX Psiphon Instance - ${instance_id}
After=network.target

[Service]
Type=simple
WorkingDirectory=${instance_dir}
ExecStart=${PSIPHON_BIN} -config ${config_file}
StandardOutput=append:${log_file}
StandardError=append:${log_file}
Restart=on-failure
RestartSec=15
User=root
MemoryMax=512M
KillMode=process
KillSignal=SIGTERM
LimitNOFILE=65535
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "orbitalx-psiphon-${instance_id}"
    systemctl start "orbitalx-psiphon-${instance_id}"

    # Wait a bit and check status
    sleep 5
    if ! systemctl is-active --quiet "orbitalx-psiphon-${instance_id}"; then
        # Get last few lines from journal for this service
        local error_log=$(journalctl -u "orbitalx-psiphon-${instance_id}" --no-pager -n 10 2>/dev/null | tail -5)
        set_error "Psiphon instance ${instance_id} failed to start. Last logs:\n${error_log}"
        systemctl disable "orbitalx-psiphon-${instance_id}" 2>/dev/null
        rm -f "$service_file"
        rm -rf "$instance_dir"
        return 1
    fi

    echo "${instance_id}:PSIPHON:${country}:${socks_port}:${http_port}:active" >> "$INSTANCES_FILE"
    log_info "Created Psiphon instance ${instance_id} (SOCKS: $socks_port, HTTP: $http_port)"
    print_info "✅ Psiphon ${instance_id} created (${get_full_name "$country"}) on SOCKS $socks_port"

    # Save result details for TUI
    echo "instance_id=${instance_id}" > "$result_file"
    echo "socks_port=${socks_port}" >> "$result_file"
    echo "http_port=${http_port}" >> "$result_file"
    echo "country=${country}" >> "$result_file"
    echo "type=PSIPHON" >> "$result_file"

    return 0
}

psiphon_remove_instance() {
    local instance_id=$1
    if ! grep -q "^${instance_id}:" "$INSTANCES_FILE"; then
        set_error "Instance ${instance_id} not found"
        return 1
    fi

    systemctl stop "orbitalx-psiphon-${instance_id}" 2>/dev/null
    systemctl disable "orbitalx-psiphon-${instance_id}" 2>/dev/null
    rm -f "/etc/systemd/system/orbitalx-psiphon-${instance_id}.service"
    systemctl daemon-reload

    rm -rf "${PSIPHON_BASE_DIR}/${instance_id}"
    sed -i "/^${instance_id}:/d" "$INSTANCES_FILE"
    log_info "Removed Psiphon instance ${instance_id}"
    print_info "✅ Psiphon ${instance_id} removed"
    return 0
}

psiphon_start_instance() {
    local instance_id=$1
    systemctl start "orbitalx-psiphon-${instance_id}"
    log_info "Started Psiphon ${instance_id}"
    print_info "Psiphon ${instance_id} started"
}

psiphon_stop_instance() {
    local instance_id=$1
    systemctl stop "orbitalx-psiphon-${instance_id}"
    log_info "Stopped Psiphon ${instance_id}"
    print_info "Psiphon ${instance_id} stopped"
}

psiphon_restart_instance() {
    psiphon_stop_instance "$1"
    sleep 2
    psiphon_start_instance "$1"
}

psiphon_show_log() {
    local instance_id=$1
    local log_file="${LOG_DIR}/psiphon_${instance_id}.log"
    if [ ! -f "$log_file" ]; then
        dialog --msgbox "Log file not found: ${log_file}" 6 50
        return 1
    fi
    dialog --title "Psiphon Log - ${instance_id}" --tailbox "$log_file" 20 80
}

# ==================== GENERAL INSTANCE MANAGEMENT ====================

list_instances() {
    if [ ! -s "$INSTANCES_FILE" ]; then
        echo "No instances configured."
        return
    fi
    echo "Instances:"
    while IFS= read -r line; do
        IFS=':' read -r id type country port port2 status <<< "$line"
        if [ "$type" = "TOR" ]; then
            local full_name=$(get_full_name "$country")
            local active_status=$(systemctl is-active "orbitalx-tor-${id}" 2>/dev/null || echo "inactive")
            echo "  $id ($full_name) - TOR - Port: $port - Status: $active_status"
        elif [ "$type" = "PSIPHON" ]; then
            local full_name=$(get_full_name "$country")
            local active_status=$(systemctl is-active "orbitalx-psiphon-${id}" 2>/dev/null || echo "inactive")
            echo "  $id ($full_name) - PSIPHON - SOCKS: $port, HTTP: $port2 - Status: $active_status"
        fi
    done < "$INSTANCES_FILE"
}

# ==================== TUI FUNCTIONS ====================

main_menu() {
    while true; do
        choice=$(dialog --clear --title "OrbitalX v${VERSION} - Issei-177013" \
            --menu "Hybrid Tor & Psiphon Manager" 22 70 14 \
            1 "Create Instance (Tor)" \
            2 "Create Instance (Psiphon)" \
            3 "List/Manage Instances" \
            4 "Show Status" \
            5 "View Live Logs" \
            6 "Stop/Start/Restart Instance" \
            7 "Remove Instance" \
            8 "Stop All Instances" \
            9 "Set Monitor Interval" \
            10 "Administration" \
            11 "Exit" \
            2>&1 >/dev/tty)

        case $? in
            0)
                case $choice in
                    1) create_tor_tui ;;
                    2) create_psiphon_tui ;;
                    3) manage_instances_tui ;;
                    4) show_status_tui ;;
                    5) view_logs_tui ;;
                    6) control_instance_tui ;;
                    7) remove_instance_tui ;;
                    8) stop_all_tui ;;
                    9) set_interval_tui ;;
                    10) admin_menu ;;
                    11) clear; exit 0 ;;
                esac
                ;;
            1|255) clear; exit 0 ;;
        esac
    done
}

create_tor_tui() {
    local countries_list=()
    # Show all countries (allow duplicates, no restriction)
    for code in "${!FULL_NAMES[@]}"; do
        countries_list+=("$code" "$(get_full_name "$code")")
    done

    local country=$(dialog --clear --title "Create Tor Instance" \
        --menu "Select a country for Tor" 20 70 15 "${countries_list[@]}" \
        2>&1 >/dev/tty)

    if [ -n "$country" ]; then
        local result_file="/tmp/orbitalx_create_result_$$"
        (
            set +e
            tor_create_instance "$country" > /tmp/orbitalx_create.log 2>&1
            echo $? > /tmp/orbitalx_create.exit
        ) &
        pid=$!
        dialog --title "Creating Tor instance..." --infobox "Please wait..." 5 40
        wait $pid
        exit_code=$(cat /tmp/orbitalx_create.exit 2>/dev/null || echo 1)
        if [ $exit_code -eq 0 ] && [ -f "$result_file" ]; then
            source "$result_file"
            local msg="✅ Tor instance created successfully!\n\n"
            msg+="Instance ID: ${instance_id}\n"
            msg+="Country: $(get_full_name "$country")\n"
            msg+="Port: ${port}\n"
            msg+="Exit IP: ${exit_ip}\n"
            msg+="Control Port: ${control_port}\n\n"
            msg+="Use this port in Xray outbound: 127.0.0.1:${port}"
            dialog --msgbox "$msg" 12 60
            rm -f "$result_file"
        else
            show_error_tui
        fi
        rm -f /tmp/orbitalx_create.log /tmp/orbitalx_create.exit
    fi
}

create_psiphon_tui() {
    local countries_list=()
    for code in "${PSIPHON_VALID_REGIONS[@]}"; do
        countries_list+=("$code" "$(get_full_name "$code")")
    done

    if [ ${#countries_list[@]} -eq 0 ]; then
        dialog --msgbox "No Psiphon-supported countries available." 6 40
        return
    fi

    local country=$(dialog --clear --title "Create Psiphon Instance" \
        --menu "Select a country for Psiphon" 20 70 15 "${countries_list[@]}" \
        2>&1 >/dev/tty)

    if [ -n "$country" ]; then
        local result_file="/tmp/orbitalx_create_result_$$"
        (
            set +e
            psiphon_create_instance "$country" > /tmp/orbitalx_create.log 2>&1
            echo $? > /tmp/orbitalx_create.exit
        ) &
        pid=$!
        dialog --title "Creating Psiphon instance..." --infobox "Please wait..." 5 40
        wait $pid
        exit_code=$(cat /tmp/orbitalx_create.exit 2>/dev/null || echo 1)
        if [ $exit_code -eq 0 ] && [ -f "$result_file" ]; then
            source "$result_file"
            local msg="✅ Psiphon instance created successfully!\n\n"
            msg+="Instance ID: ${instance_id}\n"
            msg+="Country: $(get_full_name "$country")\n"
            msg+="SOCKS Port: ${socks_port}\n"
            msg+="HTTP Port: ${http_port}\n\n"
            msg+="Use SOCKS port in Xray outbound: 127.0.0.1:${socks_port}"
            dialog --msgbox "$msg" 12 60
            rm -f "$result_file"
        else
            show_error_tui
        fi
        rm -f /tmp/orbitalx_create.log /tmp/orbitalx_create.exit
    fi
}

manage_instances_tui() {
    if [ ! -s "$INSTANCES_FILE" ]; then
        dialog --msgbox "No instances configured." 6 40
        return
    fi

    local items=()
    while IFS= read -r line; do
        IFS=':' read -r id type country port port2 status <<< "$line"
        full_name=$(get_full_name "$country")
        if [ "$type" = "TOR" ]; then
            items+=("$id" "$full_name [TOR] Port: $port")
        else
            items+=("$id" "$full_name [PSIPHON] SOCKS: $port HTTP: $port2")
        fi
    done < "$INSTANCES_FILE"

    local instance=$(dialog --clear --title "Instances" \
        --menu "Select an instance to manage" 20 80 15 "${items[@]}" \
        2>&1 >/dev/tty)

    if [ -n "$instance" ]; then
        instance_menu_tui "$instance"
    fi
}

instance_menu_tui() {
    local instance_id=$1
    local line=$(grep "^${instance_id}:" "$INSTANCES_FILE")
    IFS=':' read -r id type country port port2 status <<< "$line"

    local type_label=""
    if [ "$type" = "TOR" ]; then
        type_label="Tor"
    else
        type_label="Psiphon"
    fi

    while true; do
        choice=$(dialog --clear --title "Manage ${instance_id} (${type_label})" \
            --menu "Select action" 15 60 5 \
            1 "Start" \
            2 "Stop" \
            3 "Restart" \
            4 "View Log" \
            5 "Back" \
            2>&1 >/dev/tty)

        case $? in
            0)
                case $choice in
                    1)
                        if [ "$type" = "TOR" ]; then
                            tor_start_instance "$instance_id"
                        else
                            psiphon_start_instance "$instance_id"
                        fi
                        dialog --msgbox "Instance started." 6 30
                        ;;
                    2)
                        if [ "$type" = "TOR" ]; then
                            tor_stop_instance "$instance_id"
                        else
                            psiphon_stop_instance "$instance_id"
                        fi
                        dialog --msgbox "Instance stopped." 6 30
                        ;;
                    3)
                        if [ "$type" = "TOR" ]; then
                            tor_restart_instance "$instance_id"
                        else
                            psiphon_restart_instance "$instance_id"
                        fi
                        dialog --msgbox "Instance restarted." 6 30
                        ;;
                    4)
                        if [ "$type" = "TOR" ]; then
                            tor_show_log "$instance_id"
                        else
                            psiphon_show_log "$instance_id"
                        fi
                        ;;
                    5) break ;;
                esac
                ;;
            1|255) break ;;
        esac
    done
}

show_status_tui() {
    if [ ! -s "$INSTANCES_FILE" ]; then
        dialog --msgbox "No instances." 6 30
        return
    fi

    local tmp_file="/tmp/orbitalx_status.txt"
    > "$tmp_file"
    printf "%-25s | %-15s | %-10s | %-20s\n" "Instance" "Country" "Type" "Port(s)" >> "$tmp_file"
    printf "%s\n" "--------------------------|-----------------|-----------|---------------------" >> "$tmp_file"

    while IFS= read -r line; do
        IFS=':' read -r id type country port port2 status <<< "$line"
        full_name=$(get_full_name "$country")
        if [ "$type" = "TOR" ]; then
            active=$(systemctl is-active "orbitalx-tor-${id}" 2>/dev/null || echo "inactive")
            port_display="SOCKS: $port"
            type_display="Tor"
        else
            active=$(systemctl is-active "orbitalx-psiphon-${id}" 2>/dev/null || echo "inactive")
            port_display="SOCKS: $port | HTTP: $port2"
            type_display="Psiphon"
        fi
        printf "%-25s | %-15s | %-10s | %-20s [%s]\n" "$id" "$full_name" "$type_display" "$port_display" "$active" >> "$tmp_file"
    done < "$INSTANCES_FILE"

    dialog --title "OrbitalX Status" --textbox "$tmp_file" 20 80
    rm -f "$tmp_file"
}

view_logs_tui() {
    if [ ! -s "$INSTANCES_FILE" ]; then
        dialog --msgbox "No instances." 6 30
        return
    fi

    local items=()
    while IFS= read -r line; do
        IFS=':' read -r id type country port port2 status <<< "$line"
        full_name=$(get_full_name "$country")
        items+=("$id" "$full_name [${type}]")
    done < "$INSTANCES_FILE"

    local instance=$(dialog --clear --title "View Logs" \
        --menu "Select an instance" 20 70 15 "${items[@]}" \
        2>&1 >/dev/tty)

    if [ -n "$instance" ]; then
        local line=$(grep "^${instance}:" "$INSTANCES_FILE")
        IFS=':' read -r id type country port port2 status <<< "$line"
        if [ "$type" = "TOR" ]; then
            tor_show_log "$instance"
        else
            psiphon_show_log "$instance"
        fi
    fi
}

control_instance_tui() {
    if [ ! -s "$INSTANCES_FILE" ]; then
        dialog --msgbox "No instances." 6 30
        return
    fi

    local items=()
    while IFS= read -r line; do
        IFS=':' read -r id type country port port2 status <<< "$line"
        full_name=$(get_full_name "$country")
        items+=("$id" "$full_name [${type}]")
    done < "$INSTANCES_FILE"

    local instance=$(dialog --clear --title "Control Instance" \
        --menu "Select an instance" 20 70 15 "${items[@]}" \
        2>&1 >/dev/tty)

    if [ -n "$instance" ]; then
        instance_menu_tui "$instance"
    fi
}

remove_instance_tui() {
    if [ ! -s "$INSTANCES_FILE" ]; then
        dialog --msgbox "No instances." 6 30
        return
    fi

    local items=()
    while IFS= read -r line; do
        IFS=':' read -r id type country port port2 status <<< "$line"
        full_name=$(get_full_name "$country")
        items+=("$id" "$full_name [${type}]")
    done < "$INSTANCES_FILE"

    local instance=$(dialog --clear --title "Remove Instance" \
        --menu "Select an instance to remove" 20 70 15 "${items[@]}" \
        2>&1 >/dev/tty)

    if [ -n "$instance" ]; then
        dialog --yesno "Are you sure you want to remove ${instance}?" 6 50
        if [ $? -eq 0 ]; then
            local line=$(grep "^${instance}:" "$INSTANCES_FILE")
            IFS=':' read -r id type country port port2 status <<< "$line"
            if [ "$type" = "TOR" ]; then
                tor_remove_instance "$instance"
            else
                psiphon_remove_instance "$instance"
            fi
            dialog --msgbox "Instance removed." 6 30
        fi
    fi
}

stop_all_tui() {
    dialog --yesno "Stop ALL instances (both Tor and Psiphon)?" 6 50
    if [ $? -eq 0 ]; then
        while IFS= read -r line; do
            IFS=':' read -r id type country port port2 status <<< "$line"
            if [ "$type" = "TOR" ]; then
                systemctl stop "orbitalx-tor-${id}" 2>/dev/null
            else
                systemctl stop "orbitalx-psiphon-${id}" 2>/dev/null
            fi
        done < "$INSTANCES_FILE"
        dialog --msgbox "All instances stopped." 6 30
    fi
}

set_interval_tui() {
    local current=$(get_monitor_interval)
    local new=$(dialog --title "Set Monitor Interval" \
        --inputbox "Current interval: ${current} seconds (approx $((current/60)) minutes)\nEnter new interval in seconds:" 10 50 "$current" \
        2>&1 >/dev/tty)

    if [ -n "$new" ] && [[ "$new" =~ ^[0-9]+$ ]] && [ $new -gt 0 ]; then
        echo "$new" > "$MONITOR_INTERVAL_FILE"
        dialog --msgbox "Monitor interval set to ${new} seconds ($((new/60)) minutes)." 6 50
    else
        dialog --msgbox "Invalid input. Please enter a positive number." 6 40
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
    dialog --infobox "Checking for updates..." 5 40
    if update_core; then
        local new_version=$(get_version)
        dialog --msgbox "✅ Update completed successfully!\n\nVersion: ${new_version}\n\nPlease restart OrbitalX to see the changes." 8 50
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

    # Create monitoring service (for future use, optional)
    cat > /etc/systemd/system/orbitalx-monitor.service << EOF
[Unit]
Description=OrbitalX Monitor Daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/orbitalx monitor
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable orbitalx-monitor.service 2>/dev/null || true
    systemctl start orbitalx-monitor.service 2>/dev/null || true

    VERSION=$(get_version)
    print_info "Installation complete."
    return 0
}

update_core() {
    check_root

    local current_version=$(get_version)
    print_info "Current version: $current_version"

    # Fetch remote version
    local remote_version=$(curl -sL "$REPO_RAW_URL_VERSION" 2>/dev/null | tr -d '\n\r')
    if [ -z "$remote_version" ]; then
        set_error "Failed to fetch remote version from GitHub."
        return 1
    fi
    print_info "Latest version: $remote_version"

    # Compare versions
    if [ "$current_version" = "$remote_version" ]; then
        print_info "You already have the latest version."
        return 0
    fi

    # Check if newer (using sort -V)
    if ! printf '%s\n' "$current_version" "$remote_version" | sort -V | head -n1 | grep -q "$remote_version"; then
        print_warn "Local version is newer than remote? Continuing anyway."
    fi

    print_info "Updating from $current_version to $remote_version..."

    # Determine script location
    local script_path=$(realpath "$0")
    local script_dir=$(dirname "$script_path")
    local installed_path="/usr/local/bin/orbitalx"

    # If we are inside a git repository, do git pull
    if [ -d "${script_dir}/.git" ]; then
        print_info "Git repository detected. Pulling latest changes..."
        cd "$script_dir"
        if git pull; then
            print_info "Git pull successful."
            # Update system installation if present
            if [ -f "$installed_path" ]; then
                cp "$script_path" "$installed_path"
                chmod +x "$installed_path"
                print_info "Updated $installed_path"
            fi
            # Update VERSION file in system location if present
            if [ -f "$installed_path" ] && [ -f "$script_dir/VERSION" ]; then
                cp "$script_dir/VERSION" "$(dirname "$installed_path")/VERSION"
                print_info "Updated VERSION file"
            fi
            # Restart monitor service
            systemctl restart orbitalx-monitor 2>/dev/null || true
            return 0
        else
            set_error "Git pull failed."
            return 1
        fi
    else
        # Not in git repo: download from GitHub
        print_info "Downloading latest version from GitHub..."
        local tmp_script="/tmp/orbitalx_update.sh"
        local tmp_version="/tmp/orbitalx_update_version"

        if ! curl -sL "$REPO_RAW_URL_SCRIPT" -o "$tmp_script" || [ ! -s "$tmp_script" ]; then
            set_error "Failed to download script."
            rm -f "$tmp_script"
            return 1
        fi

        if ! curl -sL "$REPO_RAW_URL_VERSION" -o "$tmp_version" || [ ! -s "$tmp_version" ]; then
            print_warn "Failed to download VERSION file, keeping existing."
        fi

        # If the script is installed in /usr/local/bin, replace it
        if [ -f "$installed_path" ]; then
            chmod +x "$tmp_script"
            mv "$tmp_script" "$installed_path"
            print_info "Updated $installed_path"
            if [ -f "$tmp_version" ]; then
                mv "$tmp_version" "$(dirname "$installed_path")/VERSION"
                print_info "Updated VERSION file"
            fi
            systemctl restart orbitalx-monitor 2>/dev/null || true
            return 0
        else
            # Not installed: replace the current script itself
            if [ -f "$tmp_script" ]; then
                chmod +x "$tmp_script"
                # Overwrite current script
                cp "$tmp_script" "$script_path"
                print_info "Updated script at $script_path"
                if [ -f "$tmp_version" ]; then
                    cp "$tmp_version" "$script_dir/VERSION"
                    print_info "Updated VERSION file"
                fi
                rm -f "$tmp_script" "$tmp_version"
                return 0
            else
                set_error "Update failed: cannot determine installation location."
                return 1
            fi
        fi
    fi
}

uninstall_core() {
    check_root
    systemctl stop orbitalx-monitor 2>/dev/null || true
    systemctl disable orbitalx-monitor 2>/dev/null || true
    rm -f /etc/systemd/system/orbitalx-monitor.service
    rm -f /usr/local/bin/orbitalx
    rm -f /usr/local/bin/VERSION
    systemctl daemon-reload

    if [ $1 -eq 0 ]; then
        rm -rf "$DATA_DIR" "$CONFIG_DIR" "$LOG_DIR" "$PID_DIR"
        rm -rf "$PSIPHON_BASE_DIR"
    fi
}

monitor_daemon() {
    # Placeholder for future monitoring
    while true; do
        sleep 60
    done
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
        list)
            list_instances
            ;;
        create-tor)
            shift
            if [ $# -eq 0 ]; then
                print_error "Usage: orbitalx create-tor <COUNTRY1> [COUNTRY2] ..."
                exit 1
            fi
            local success=0
            local failed=0
            local created=""
            for country in "$@"; do
                country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
                print_info "Creating Tor instance for $country..."
                if tor_create_instance "$country"; then
                    success=$((success + 1))
                    created="${created} $country"
                else
                    failed=$((failed + 1))
                    if [ -n "$LAST_ERROR" ]; then
                        print_error "Failed to create Tor instance for $country: $LAST_ERROR"
                    else
                        print_error "Failed to create Tor instance for $country (unknown error)"
                    fi
                fi
            done
            echo ""
            echo "========================================"
            echo "Summary: $success instance(s) created successfully, $failed failed."
            if [ $success -gt 0 ]; then
                echo "Created countries:${created}"
            fi
            echo "========================================"
            ;;
        create-psiphon)
            shift
            if [ $# -eq 0 ]; then
                print_error "Usage: orbitalx create-psiphon <COUNTRY1> [COUNTRY2] ..."
                exit 1
            fi
            local success=0
            local failed=0
            local created=""
            for country in "$@"; do
                country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
                print_info "Creating Psiphon instance for $country..."
                # Clear LAST_ERROR before each attempt
                LAST_ERROR=""
                if psiphon_create_instance "$country"; then
                    success=$((success + 1))
                    created="${created} $country"
                else
                    failed=$((failed + 1))
                    if [ -n "$LAST_ERROR" ]; then
                        print_error "Failed to create Psiphon instance for $country: $LAST_ERROR"
                    else
                        print_error "Failed to create Psiphon instance for $country (unknown error)"
                    fi
                fi
            done
            echo ""
            echo "========================================"
            echo "Summary: $success instance(s) created successfully, $failed failed."
            if [ $success -gt 0 ]; then
                echo "Created countries:${created}"
            fi
            echo "========================================"
            ;;
        create)
            shift
            if [ $# -eq 0 ]; then
                print_error "Usage: orbitalx create <COUNTRY1> [COUNTRY2] ..."
                exit 1
            fi
            local tor_success=0
            local tor_failed=0
            local psiphon_success=0
            local psiphon_failed=0
            local psiphon_skipped=0
            local tor_created=""
            local psiphon_created=""
            local psiphon_skipped_list=""

            for country in "$@"; do
                country=$(echo "$country" | tr '[:lower:]' '[:upper:]')

                # Check if country is valid
                if [ -z "${FULL_NAMES[$country]}" ]; then
                    print_error "Invalid country code: $country (skipping)"
                    continue
                fi

                echo ""
                echo "========================================"
                echo "Processing: $country ($(get_full_name "$country"))"
                echo "========================================"

                # Create Tor instance
                LAST_ERROR=""
                print_info "Creating Tor instance for $country..."
                if tor_create_instance "$country"; then
                    tor_success=$((tor_success + 1))
                    tor_created="${tor_created} $country"
                else
                    tor_failed=$((tor_failed + 1))
                    if [ -n "$LAST_ERROR" ]; then
                        print_error "Tor instance for $country failed: $LAST_ERROR"
                    else
                        print_error "Tor instance for $country failed"
                    fi
                fi

                # Create Psiphon instance if supported
                local psiphon_supported=0
                for reg in "${PSIPHON_VALID_REGIONS[@]}"; do
                    if [[ "$reg" == "$country" ]]; then
                        psiphon_supported=1
                        break
                    fi
                done

                if [ $psiphon_supported -eq 1 ]; then
                    LAST_ERROR=""
                    print_info "Creating Psiphon instance for $country..."
                    if psiphon_create_instance "$country"; then
                        psiphon_success=$((psiphon_success + 1))
                        psiphon_created="${psiphon_created} $country"
                    else
                        psiphon_failed=$((psiphon_failed + 1))
                        if [ -n "$LAST_ERROR" ]; then
                            print_error "Psiphon instance for $country failed: $LAST_ERROR"
                        else
                            print_error "Psiphon instance for $country failed"
                        fi
                    fi
                else
                    psiphon_skipped=$((psiphon_skipped + 1))
                    psiphon_skipped_list="${psiphon_skipped_list} $country"
                    print_warn "Skipping Psiphon for $country (not supported)"
                fi
            done

            # Summary
            echo ""
            echo "========================================"
            echo "             FINAL SUMMARY              "
            echo "========================================"
            echo "Tor:"
            echo "  ✅ Success: $tor_success instance(s)"
            [ $tor_success -gt 0 ] && echo "     Countries:${tor_created}"
            [ $tor_failed -gt 0 ] && echo "  ❌ Failed: $tor_failed instance(s)"
            echo ""
            echo "Psiphon:"
            echo "  ✅ Success: $psiphon_success instance(s)"
            [ $psiphon_success -gt 0 ] && echo "     Countries:${psiphon_created}"
            [ $psiphon_failed -gt 0 ] && echo "  ❌ Failed: $psiphon_failed instance(s)"
            [ $psiphon_skipped -gt 0 ] && echo "  ⏭️  Skipped (unsupported): $psiphon_skipped instance(s)"
            [ -n "$psiphon_skipped_list" ] && echo "     Countries:${psiphon_skipped_list}"
            echo "========================================"
            ;;
        remove)
            if [ -z "$2" ]; then
                print_error "Usage: orbitalx remove <INSTANCE_ID>"
                exit 1
            fi
            local line=$(grep "^${2}:" "$INSTANCES_FILE")
            if [ -z "$line" ]; then
                print_error "Instance not found"
                exit 1
            fi
            IFS=':' read -r id type country port port2 status <<< "$line"
            if [ "$type" = "TOR" ]; then
                tor_remove_instance "$2"
            else
                psiphon_remove_instance "$2"
            fi
            ;;
        start)
            if [ -z "$2" ]; then
                print_error "Usage: orbitalx start <INSTANCE_ID>"
                exit 1
            fi
            local line=$(grep "^${2}:" "$INSTANCES_FILE")
            if [ -z "$line" ]; then
                print_error "Instance not found"
                exit 1
            fi
            IFS=':' read -r id type country port port2 status <<< "$line"
            if [ "$type" = "TOR" ]; then
                tor_start_instance "$2"
            else
                psiphon_start_instance "$2"
            fi
            ;;
        stop)
            if [ -z "$2" ]; then
                print_error "Usage: orbitalx stop <INSTANCE_ID>"
                exit 1
            fi
            local line=$(grep "^${2}:" "$INSTANCES_FILE")
            if [ -z "$line" ]; then
                print_error "Instance not found"
                exit 1
            fi
            IFS=':' read -r id type country port port2 status <<< "$line"
            if [ "$type" = "TOR" ]; then
                tor_stop_instance "$2"
            else
                psiphon_stop_instance "$2"
            fi
            ;;
        restart)
            if [ -z "$2" ]; then
                print_error "Usage: orbitalx restart <INSTANCE_ID>"
                exit 1
            fi
            local line=$(grep "^${2}:" "$INSTANCES_FILE")
            if [ -z "$line" ]; then
                print_error "Instance not found"
                exit 1
            fi
            IFS=':' read -r id type country port port2 status <<< "$line"
            if [ "$type" = "TOR" ]; then
                tor_restart_instance "$2"
            else
                psiphon_restart_instance "$2"
            fi
            ;;
        status)
            show_status_tui
            ;;
        help)
            cat << EOF
OrbitalX v${VERSION} - Hybrid Tor & Psiphon Manager

CLI Commands:
  install                           Install systemd service
  uninstall                         Remove everything
  update                            Update from GitHub
  list                              List all instances
  create <COUNTRY1> [COUNTRY2] ...  Create BOTH Tor and Psiphon instances for countries
  create-tor <COUNTRY1> [COUNTRY2] ...  Create Tor instances only
  create-psiphon <COUNTRY1> [COUNTRY2] ... Create Psiphon instances only
  remove <INSTANCE_ID>              Remove an instance
  start <INSTANCE_ID>               Start an instance
  stop <INSTANCE_ID>                Stop an instance
  restart <INSTANCE_ID>             Restart an instance
  status                            Show TUI status
  help                              This help

Examples:
  orbitalx create US TR GB DE
  orbitalx create-tor US TR GB
  orbitalx create-psiphon DE FR NL
  orbitalx remove TOR-US-1
  orbitalx start PSIPHON-DE-1

Note: Psiphon binary is automatically installed from SpherionOS repository.
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
    check_root
    create_dirs
    check_prerequisites || exit 1
    main_menu
else
    TUI_MODE=0
    cli_mode "$@"
fi

exit 0