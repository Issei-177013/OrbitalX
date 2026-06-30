#!/bin/bash

# ===========================================================
# OrbitalX - Tor/Psiphon Multi-Location Manager for Xray
# Version: Read from VERSION file
# Author: Issei-177013
# Description: TUI-based management with predefined countries
#              and fixed ports. Supports Tor and Psiphon modes.
# ===========================================================

set -e

# ==================== GLOBALS ====================
SCRIPT_NAME="OrbitalX"
REPO_RAW_URL_SCRIPT="https://raw.githubusercontent.com/Issei-177013/OrbitalX/main/orbitalx.sh"
REPO_RAW_URL_VERSION="https://raw.githubusercontent.com/Issei-177013/OrbitalX/main/VERSION"
REPO_SERVER_ENTRIES_URL="https://raw.githubusercontent.com/Issei-177013/OrbitalX/main/assets/server_entries.txt"
REPO_SERVER_DAT_URL="https://raw.githubusercontent.com/Issei-177013/OrbitalX/main/assets/server_list.dat"

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

LAST_ERROR=""

# Psiphon settings
PSIPHON_BIN="/usr/local/bin/psiphon-tunnel-core"
PSIPHON_CONFIG_DIR="${CONFIG_DIR}/psiphon"
PSIPHON_DATA_DIR="${DATA_DIR}/psiphon"
PSIPHON_BASE_SOCKS_PORT=1080
PSIPHON_BASE_HTTP_PORT=8080
PSIPHON_DOWNLOAD_URL="https://raw.githubusercontent.com/Psiphon-Labs/psiphon-tunnel-core-binaries/master/linux/psiphon-tunnel-core-x86_64"
PSIPHON_SERVER_LIST_URL="https://s3.amazonaws.com/psiphon/web/server_list_download"
PSIPHON_SERVER_ENTRIES_FILE="${PSIPHON_CONFIG_DIR}/server_entries.txt"
PSIPHON_SERVER_DAT_FILE="${PSIPHON_CONFIG_DIR}/server_list.dat"

SELECTED_MODE="tor"

# Full list of countries (35)
COUNTRIES_ORDERED=(
    "TR" "US" "FR" "AT" "BE" "RO" "CA" "SG" "JP" "IE"
    "FI" "ES" "PL" "NL" "IT" "CH" "SE" "NO" "DK" "IS"
    "AU" "IN" "HK" "UA" "CZ" "KR" "ZA" "MX" "MY" "AZ"
    "CY" "GR" "PT" "HU" "LU"
)

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

declare -A PREDEFINED_PORTS
PORT=9080
for country in "${COUNTRIES_ORDERED[@]}"; do
    PREDEFINED_PORTS["$country"]=$PORT
    ((PORT++))
done

get_full_name() {
    local code=$1
    echo "${FULL_NAMES[$code]:-$code}"
}

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

if ! cd . 2>/dev/null; then
    cd /
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ==================== HELPER FUNCTIONS ====================

log() {
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        LOG_DIR="/tmp/orbitalx"
        mkdir -p "$LOG_DIR" 2>/dev/null || true
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "${LOG_DIR}/manager.log" 2>/dev/null || true
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
        echo "This command requires root privileges. Please run with sudo."
        exit 1
    fi
}

# ==================== PSIPHON FUNCTIONS ====================

convert_dat_to_entries() {
    local dat_file="$1"
    local entries_file="$2"
    
    # Method 1: Use psiphon-tunnel-core binary if available
    if [ -f "$PSIPHON_BIN" ] && [ -x "$PSIPHON_BIN" ]; then
        print_info "Converting server_list.dat using psiphon-tunnel-core..."
        if "$PSIPHON_BIN" -serverList > "$entries_file" 2>/dev/null && [ -s "$entries_file" ]; then
            print_info "Conversion successful using psiphon-tunnel-core."
            return 0
        fi
        print_warn "psiphon-tunnel-core conversion failed."
    fi

    # Method 2: Use Python with protobuf
    if command -v python3 &> /dev/null; then
        # Check if protobuf is installed
        if python3 -c "import google.protobuf" 2>/dev/null; then
            print_info "Converting server_list.dat using Python + protobuf..."
            cat > /tmp/convert_psiphon.py << 'EOF'
import sys
import json
import struct
import os

def parse_server_list_dat(file_path):
    with open(file_path, 'rb') as f:
        data = f.read()
    
    entries = []
    i = 0
    while i < len(data):
        if i + 4 > len(data):
            break
        length = struct.unpack('<I', data[i:i+4])[0]
        i += 4
        if i + length > len(data):
            break
        entry_data = data[i:i+length]
        i += length
        try:
            entry = json.loads(entry_data.decode('utf-8'))
            entries.append(entry)
        except:
            continue
    
    return entries

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 convert_psiphon.py <input.dat> <output.txt>")
        sys.exit(1)
    
    entries = parse_server_list_dat(sys.argv[1])
    with open(sys.argv[2], 'w') as f:
        for entry in entries:
            f.write(json.dumps(entry) + '\n')
    
    print(f"Converted {len(entries)} entries")
EOF
            if python3 /tmp/convert_psiphon.py "$dat_file" "$entries_file" && [ -s "$entries_file" ]; then
                print_info "Conversion successful using Python."
                rm -f /tmp/convert_psiphon.py
                return 0
            fi
            rm -f /tmp/convert_psiphon.py
        else
            print_info "protobuf not installed. Attempting to install..."
            if pip3 install protobuf 2>/dev/null || python3 -m pip install protobuf 2>/dev/null; then
                print_info "protobuf installed. Retrying conversion..."
                # Recursive call with protobuf now installed
                convert_dat_to_entries "$dat_file" "$entries_file"
                return $?
            else
                print_warn "Could not install protobuf. Skipping Python conversion."
            fi
        fi
    fi

    return 1
}

prepare_psiphon_server_entries() {
    mkdir -p "$PSIPHON_CONFIG_DIR"
    
    # If server_entries.txt already exists and is not empty, use it
    if [ -f "$PSIPHON_SERVER_ENTRIES_FILE" ] && [ -s "$PSIPHON_SERVER_ENTRIES_FILE" ]; then
        print_info "Using existing server_entries.txt"
        return 0
    fi

    # If server_list.dat exists, try to convert it
    if [ -f "$PSIPHON_SERVER_DAT_FILE" ] && [ -s "$PSIPHON_SERVER_DAT_FILE" ]; then
        print_info "Found server_list.dat. Attempting to convert..."
        if convert_dat_to_entries "$PSIPHON_SERVER_DAT_FILE" "$PSIPHON_SERVER_ENTRIES_FILE"; then
            return 0
        else
            print_warn "Conversion failed. Trying to download from repository..."
        fi
    else
        # Try to download server_list.dat from repository
        print_info "Downloading server_list.dat from repository..."
        if curl -sL -o "$PSIPHON_SERVER_DAT_FILE" "$REPO_SERVER_DAT_URL" && [ -s "$PSIPHON_SERVER_DAT_FILE" ]; then
            print_info "server_list.dat downloaded. Converting..."
            if convert_dat_to_entries "$PSIPHON_SERVER_DAT_FILE" "$PSIPHON_SERVER_ENTRIES_FILE"; then
                return 0
            else
                print_warn "Conversion failed after download."
            fi
        fi
    fi

    # Fallback: download server_entries.txt directly from repository
    print_info "Downloading server_entries.txt from repository (fallback)..."
    if curl -sL -o "$PSIPHON_SERVER_ENTRIES_FILE" "$REPO_SERVER_ENTRIES_URL" && [ -s "$PSIPHON_SERVER_ENTRIES_FILE" ]; then
        print_info "server_entries.txt downloaded successfully from repository."
        return 0
    fi

    # Final fallback: try official Psiphon server list
    print_warn "Could not get from repository. Trying official server list..."
    if curl -sL -o "$PSIPHON_SERVER_ENTRIES_FILE" "$PSIPHON_SERVER_LIST_URL" && [ -s "$PSIPHON_SERVER_ENTRIES_FILE" ]; then
        print_info "Server list downloaded from official source."
        return 0
    fi

    # If all fails, give a clear error
    set_error "Could not obtain server_entries.txt. Please manually place it in $PSIPHON_SERVER_ENTRIES_FILE"
    return 1
}

install_psiphon() {
    if [ -f "$PSIPHON_BIN" ] && [ -x "$PSIPHON_BIN" ] && file "$PSIPHON_BIN" | grep -q "ELF"; then
        return 0
    fi

    print_info "Downloading Psiphon tunnel core..."
    mkdir -p "$(dirname "$PSIPHON_BIN")"
    
    local tmp_file="/tmp/psiphon_download"
    if curl -L -H "User-Agent: Mozilla/5.0" -o "$tmp_file" "$PSIPHON_DOWNLOAD_URL"; then
        if file "$tmp_file" | grep -q "ELF"; then
            chmod +x "$tmp_file"
            mv "$tmp_file" "$PSIPHON_BIN"
            print_info "Psiphon installed successfully."
            return 0
        else
            print_error "Downloaded file is not a valid ELF binary."
            rm -f "$tmp_file"
            return 1
        fi
    else
        set_error "Failed to download Psiphon."
        return 1
    fi
}

create_psiphon_config() {
    local country=$1
    local port=$2
    local http_port=$((PSIPHON_BASE_HTTP_PORT + port - PSIPHON_BASE_SOCKS_PORT))
    local config_file="${PSIPHON_CONFIG_DIR}/psiphon_${country}.config"
    local data_dir="${PSIPHON_DATA_DIR}/${country}"

    mkdir -p "$PSIPHON_CONFIG_DIR" "$data_dir"

    # Ensure server entries are available
    if ! prepare_psiphon_server_entries; then
        return 1
    fi

    cat > "$config_file" << EOF
{
  "LocalHttpProxyPort": $http_port,
  "LocalSocksProxyPort": $port,
  "EgressRegion": "$country",
  "PropagationChannelId": "FFFFFFFFFFFFFFFF",
  "SponsorId": "FFFFFFFFFFFFFFFF",
  "ClientId": "orbitalx",
  "DataStoreDirectory": "$data_dir",
  "ServerEntriesFilename": "$PSIPHON_SERVER_ENTRIES_FILE",
  "ConnectionPoolSize": 2,
  "TunnelPoolSize": 2,
  "UseIndistinguishableTLS": true,
  "UseDnsCache": true,
  "EnableNetworkMonitor": false,
  "TunnelEstablishTimeout": 60
}
EOF
    echo "$config_file"
}

start_psiphon_instance() {
    local country=$1
    local port=$2
    local config_file=$(create_psiphon_config "$country" "$port")
    
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    if pgrep -f "psiphon-tunnel-core.*psiphon_${country}\\.config" > /dev/null; then
        return 0
    fi

    if [ ! -f "$PSIPHON_BIN" ]; then
        if ! install_psiphon; then
            return 1
        fi
    fi

    print_info "Starting Psiphon for $(get_full_name "$country") on port $port..."
    nohup "$PSIPHON_BIN" -config "$config_file" >> "${LOG_DIR}/psiphon_${country}.log" 2>&1 &
    sleep 4

    if pgrep -f "psiphon-tunnel-core.*psiphon_${country}\\.config" > /dev/null; then
        print_info "✅ Psiphon for $(get_full_name "$country") started on port $port"
        return 0
    else
        set_error "Failed to start Psiphon for $(get_full_name "$country"). Check log: ${LOG_DIR}/psiphon_${country}.log"
        return 1
    fi
}

stop_psiphon_instance() {
    local country=$1
    local config_file="${PSIPHON_CONFIG_DIR}/psiphon_${country}.config"
    
    if pgrep -f "psiphon-tunnel-core.*psiphon_${country}\\.config" > /dev/null; then
        pkill -f "psiphon-tunnel-core.*psiphon_${country}\\.config" && print_info "Stopped Psiphon for $(get_full_name "$country")"
    fi
}

stop_all_psiphon() {
    pkill -f "psiphon-tunnel-core.*${PSIPHON_CONFIG_DIR}" 2>/dev/null || true
    print_info "All Psiphon instances stopped."
}

get_psiphon_ip() {
    local port=$1
    local ip=$(curl -s --socks5-hostname 127.0.0.1:"$port" --max-time 5 https://api.ipify.org?format=text 2>/dev/null)
    if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
    else
        echo ""
    fi
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

find_control_port() {
    local base=10050
    local port=$base
    while ss -tuln | grep -q ":$port "; do
        ((port++))
    done
    echo "$port"
}

# ==================== INSTALL PREREQUISITES ====================

install_missing_packages() {
    local missing=()
    for cmd in tor curl nc ss pgrep pkill dialog wget file python3 pip3; do
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
        ["wget"]="wget"
        ["file"]="file"
        ["python3"]="python3 python3-pip"
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

check_prerequisites() {
    if ! command -v dialog &> /dev/null; then
        print_info "Dialog is not installed. Installing..."
        apt update -y && apt install -y dialog
    fi

    if ! install_missing_packages; then
        return 1
    fi

    return 0
}

create_dirs() {
    mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" "$PID_DIR" "$PSIPHON_CONFIG_DIR" "$PSIPHON_DATA_DIR"
    
    if [ -f "$AVAILABLE_FILE" ]; then
        declare -A existing
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                code=$(echo "$line" | cut -d':' -f1)
                existing["$code"]=1
            fi
        done < "$AVAILABLE_FILE"
        for code in "${COUNTRIES_ORDERED[@]}"; do
            if [ -z "${existing[$code]}" ]; then
                echo "$code:${PREDEFINED_PORTS[$code]}" >> "$AVAILABLE_FILE"
            fi
        done
    else
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

# ==================== CORE FUNCTIONS ====================

activate_tor_country() {
    local country=$1
    local port=$2
    
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
NewCircuitPeriod 86400
MaxCircuitDirtiness 86400
CircuitBuildTimeout 30
EOF

    tor -f "${data_dir}/torrc" --RunAsDaemon 1 --Log "notice file ${LOG_DIR}/tor_${country}.log"
    sleep 3

    if ! pgrep -f "tor -f ${data_dir}/torrc" > /dev/null; then
        set_error "Failed to start Tor for $(get_full_name "$country")."
        echo "${country}:${port}" >> "$AVAILABLE_FILE"
        return 1
    fi

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
            else
                print_warn "Attempt $attempt: IP $exit_ip is in $ip_country, not $country. Retrying..."
            fi
        else
            print_warn "Attempt $attempt: No IP yet. Retrying..."
        fi
        sleep 2
    done

    if [ $success -eq 0 ]; then
        set_error "Could not find an exit node in ${country} ($(get_full_name "$country")). Please try again later or choose another country."
        pkill -f "tor -f ${data_dir}/torrc" || true
        rm -rf "$data_dir"
        echo "${country}:${port}" >> "$AVAILABLE_FILE"
        return 1
    fi

    echo "${country}:${port}:${control_port}:${exit_ip}:tor" >> "$ACTIVE_FILE"
    print_info "Activated $(get_full_name "$country") via Tor on port ${port} with IP ${exit_ip} (${ip_country})."
    return 0
}

activate_psiphon_country() {
    local country=$1
    local port=$2
    
    sed -i "/^${country}:/d" "$AVAILABLE_FILE"
    
    local psiphon_port=$((PSIPHON_BASE_SOCKS_PORT + port - 9080))
    
    if ! start_psiphon_instance "$country" "$psiphon_port"; then
        echo "${country}:${port}" >> "$AVAILABLE_FILE"
        return 1
    fi

    sleep 10

    local exit_ip=""
    local attempt=0
    while [ $attempt -lt 20 ]; do
        exit_ip=$(get_psiphon_ip "$psiphon_port")
        if [ -n "$exit_ip" ]; then
            break
        fi
        print_warn "Waiting for Psiphon IP... (attempt $((attempt+1))/20)"
        sleep 3
        attempt=$((attempt+1))
    done

    if [ -z "$exit_ip" ]; then
        exit_ip="unknown"
        print_warn "Could not get IP for Psiphon $(get_full_name "$country")"
    fi

    echo "${country}:${port}:0:${exit_ip}:psiphon" >> "$ACTIVE_FILE"
    print_info "Activated $(get_full_name "$country") via Psiphon on port ${psiphon_port} (Xray port: ${port}) with IP ${exit_ip}."
    return 0
}

activate_country() {
    local country=$1
    local port=$2
    local mode=$3
    
    if [ "$mode" = "psiphon" ]; then
        activate_psiphon_country "$country" "$port"
    else
        activate_tor_country "$country" "$port"
    fi
}

deactivate_country() {
    local country=$1
    if ! grep -q "^${country}:" "$ACTIVE_FILE"; then
        set_error "Country $(get_full_name "$country") is not active."
        return 1
    fi
    
    local line=$(grep "^${country}:" "$ACTIVE_FILE")
    IFS=':' read -r c port control_port ip type <<< "$line"
    
    if [ -z "$type" ]; then
        type="tor"
    fi
    
    if [ "$type" = "psiphon" ]; then
        stop_psiphon_instance "$country"
    else
        local data_dir="${DATA_DIR}/${country}"
        pkill -f "tor -f ${data_dir}/torrc" || true
        rm -rf "$data_dir"
    fi
    
    sed -i "/^${country}:/d" "$ACTIVE_FILE"
    echo "${country}:${port}" >> "$AVAILABLE_FILE"
    
    print_info "Deactivated $(get_full_name "$country") (${type})."
    return 0
}

stop_all_instances() {
    pkill -f "tor -f ${DATA_DIR}/" || true
    stop_all_psiphon
    print_info "All instances stopped."
}

monitor_daemon() {
    local interval=$(get_monitor_interval)
    while true; do
        if [ -s "$ACTIVE_FILE" ]; then
            while IFS= read -r line; do
                IFS=':' read -r country port control_port saved_ip type <<< "$line"
                
                if [ -z "$type" ]; then
                    type="tor"
                fi
                
                if [ "$type" = "psiphon" ]; then
                    local psiphon_port=$((PSIPHON_BASE_SOCKS_PORT + port - 9080))
                    if ! pgrep -f "psiphon-tunnel-core.*psiphon_${country}\\.config" > /dev/null; then
                        print_warn "Psiphon for $(get_full_name "$country") is down. Restarting..."
                        start_psiphon_instance "$country" "$psiphon_port"
                        sleep 3
                        local new_ip=$(get_psiphon_ip "$psiphon_port")
                        if [ -n "$new_ip" ] && [ "$new_ip" != "$saved_ip" ]; then
                            sed -i "s/^${country}:${port}:0:${saved_ip}:psiphon$/${country}:${port}:0:${new_ip}:psiphon/" "$ACTIVE_FILE"
                            print_info "Updated IP for Psiphon $(get_full_name "$country"): ${new_ip}"
                        fi
                    fi
                else
                    data_dir="${DATA_DIR}/${country}"
                    full_name=$(get_full_name "$country")
                    
                    if ! pgrep -f "tor -f ${data_dir}/torrc" > /dev/null; then
                        print_warn "${full_name} (Tor) is down. Restarting..."
                        tor -f "${data_dir}/torrc" --RunAsDaemon 1 --Log "notice file ${LOG_DIR}/tor_${country}.log"
                        sleep 5
                        local new_ip=$(get_tor_exit_ip "$port")
                        if [ -n "$new_ip" ]; then
                            ip_country=$(get_ip_country "$new_ip")
                            if [ "$ip_country" = "$country" ]; then
                                sed -i "s/^${country}:${port}:${control_port}:[^:]*:tor$/${country}:${port}:${control_port}:${new_ip}:tor/" "$ACTIVE_FILE"
                                print_info "Restored ${full_name} with IP ${new_ip} (${ip_country})"
                            else
                                print_error "After restart, IP ${new_ip} is in ${ip_country}, not ${country}. Manual intervention needed."
                            fi
                        fi
                        continue
                    fi
                    
                    if ! check_ip_quality "$port"; then
                        print_warn "IP for ${full_name} (Tor) is unreachable. Attempting to rotate..."
                        local rotated=0
                        for attempt in {1..3}; do
                            if rotate_tor_ip "$control_port"; then
                                sleep 5
                                local new_ip=$(get_tor_exit_ip "$port")
                                if [ -n "$new_ip" ]; then
                                    ip_country=$(get_ip_country "$new_ip")
                                    if [ "$ip_country" = "$country" ]; then
                                        sed -i "s/^${country}:${port}:${control_port}:[^:]*:tor$/${country}:${port}:${control_port}:${new_ip}:tor/" "$ACTIVE_FILE"
                                        print_info "✅ Rotated IP for ${full_name}: ${new_ip} (${ip_country})"
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
                        current_ip=$(get_tor_exit_ip "$port")
                        if [ -n "$current_ip" ]; then
                            ip_country=$(get_ip_country "$current_ip")
                            if [ "$ip_country" != "$country" ]; then
                                print_warn "IP changed to ${current_ip} (${ip_country}), not ${country}. Attempting to fix..."
                                rotate_tor_ip "$control_port"
                                sleep 5
                                new_ip=$(get_tor_exit_ip "$port")
                                if [ -n "$new_ip" ]; then
                                    new_country=$(get_ip_country "$new_ip")
                                    if [ "$new_country" = "$country" ]; then
                                        sed -i "s/^${country}:${port}:${control_port}:[^:]*:tor$/${country}:${port}:${control_port}:${new_ip}:tor/" "$ACTIVE_FILE"
                                        print_info "✅ Forced rotation fixed IP for ${full_name}: ${new_ip} (${new_country})"
                                    else
                                        print_error "Cannot fix country for ${full_name}. Current IP: ${new_ip} (${new_country})"
                                    fi
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
        choice=$(dialog --clear --title "OrbitalX v${VERSION} - Issei-177013" \
            --menu "Tor/Psiphon Location Manager for Xray" 18 60 10 \
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
        full_name=$(get_full_name "$code")
        items+=("$code" "$full_name [${code}] - Port: $port")
    done < "$AVAILABLE_FILE"
    
    dialog --title "Available Countries" \
        --menu "Select a country to view details (press Enter)" \
        20 70 15 "${items[@]}" \
        2>&1 >/dev/tty
}

activate_tui() {
    if [ ! -s "$AVAILABLE_FILE" ]; then
        dialog --msgbox "No countries available to activate." 6 40
        return
    fi
    
    local mode_choice=$(dialog --clear --title "Select Mode" \
        --menu "Choose network mode for activation:" 12 50 2 \
        1 "Tor (recommended, country-specific)" \
        2 "Psiphon (faster, country may vary)" \
        2>&1 >/dev/tty)
    
    case $mode_choice in
        1) SELECTED_MODE="tor" ;;
        2) SELECTED_MODE="psiphon" ;;
        *) return ;;
    esac
    
    local items=()
    while IFS= read -r line; do
        IFS=':' read -r code port <<< "$line"
        full_name=$(get_full_name "$code")
        items+=("$code" "$full_name [${code}] - Port: $port")
    done < "$AVAILABLE_FILE"
    
    local country=$(dialog --clear --title "Activate Country (${SELECTED_MODE})" \
        --menu "Select a country to activate via ${SELECTED_MODE}" 20 70 15 "${items[@]}" \
        2>&1 >/dev/tty)
    
    if [ -n "$country" ]; then
        local port=$(grep "^${country}:" "$AVAILABLE_FILE" | cut -d':' -f2)
        if [ -n "$port" ]; then
            (
                set +e
                activate_country "$country" "$port" "$SELECTED_MODE" > /tmp/orbitalx_activate.log 2>&1
                echo $? > /tmp/orbitalx_activate.exit
            ) &
            pid=$!
            
            dialog --title "Activating $(get_full_name "$country") via ${SELECTED_MODE}..." --infobox "Please wait..." 5 40
            wait $pid
            exit_code=$(cat /tmp/orbitalx_activate.exit 2>/dev/null || echo 1)
            
            if [ $exit_code -eq 0 ]; then
                dialog --msgbox "✅ $(get_full_name "$country") activated via ${SELECTED_MODE}!\n\nUse port ${port} in Xray outbound." 8 50
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
    
    printf "%-20s | %-6s | %-10s | %-15s | %-8s | %-6s\n" "Country" "Port" "Status" "Exit IP" "Code" "Type" >> "$tmp_file"
    printf "%s\n" "----------------------|--------|------------|-----------------|----------|--------" >> "$tmp_file"
    
    while IFS= read -r line; do
        IFS=':' read -r country port control_port saved_ip type <<< "$line"
        
        if [ -z "$type" ]; then
            type="tor"
        fi
        
        full_name=$(get_full_name "$country")
        
        if [ "$type" = "psiphon" ]; then
            psiphon_port=$((PSIPHON_BASE_SOCKS_PORT + port - 9080))
            if pgrep -f "psiphon-tunnel-core.*psiphon_${country}\\.config" > /dev/null; then
                current_ip=$(get_psiphon_ip "$psiphon_port")
                if [ -z "$current_ip" ]; then
                    printf "%-20s | %-6s | %-10s | %-15s | %-8s | %-6s\n" "$full_name" "$port" "⚠️ Issue" "${saved_ip:-Unknown}" "$country" "$type" >> "$tmp_file"
                else
                    printf "%-20s | %-6s | %-10s | %-15s | %-8s | %-6s\n" "$full_name" "$port" "✅ Active" "$current_ip" "$country" "$type" >> "$tmp_file"
                    if [ "$current_ip" != "$saved_ip" ] && [ "$saved_ip" != "unknown" ]; then
                        sed -i "s/^${country}:${port}:0:${saved_ip}:psiphon$/${country}:${port}:0:${current_ip}:psiphon/" "$ACTIVE_FILE"
                    fi
                fi
            else
                printf "%-20s | %-6s | %-10s | %-15s | %-8s | %-6s\n" "$full_name" "$port" "❌ Stopped" "${saved_ip:-Unknown}" "$country" "$type" >> "$tmp_file"
            fi
        else
            if pgrep -f "tor -f ${DATA_DIR}/${country}/torrc" > /dev/null; then
                current_ip=$(get_tor_exit_ip "$port")
                if [ -z "$current_ip" ]; then
                    printf "%-20s | %-6s | %-10s | %-15s | %-8s | %-6s\n" "$full_name" "$port" "⚠️ Issue" "${saved_ip:-Unknown}" "$country" "$type" >> "$tmp_file"
                else
                    ip_country=$(get_ip_country "$current_ip")
                    printf "%-20s | %-6s | %-10s | %-15s | %-8s | %-6s\n" "$full_name" "$port" "✅ Active" "$current_ip" "${ip_country:-?}" "$type" >> "$tmp_file"
                    if [ "$current_ip" != "$saved_ip" ] && [ "$saved_ip" != "unknown" ]; then
                        sed -i "s/^${country}:${port}:${control_port}:${saved_ip}:tor$/${country}:${port}:${control_port}:${current_ip}:tor/" "$ACTIVE_FILE"
                    fi
                fi
            else
                printf "%-20s | %-6s | %-10s | %-15s | %-8s | %-6s\n" "$full_name" "$port" "❌ Stopped" "${saved_ip:-Unknown}" "$country" "$type" >> "$tmp_file"
            fi
        fi
    done < "$ACTIVE_FILE"
    
    dialog --title "Active Locations" --textbox "$tmp_file" 25 90
    rm -f "$tmp_file"
}

deactivate_tui() {
    if [ ! -s "$ACTIVE_FILE" ]; then
        dialog --msgbox "No active countries to deactivate." 6 40
        return
    fi
    
    local items=()
    while IFS= read -r line; do
        IFS=':' read -r code port control_port ip type <<< "$line"
        if [ -z "$type" ]; then
            type="tor"
        fi
        full_name=$(get_full_name "$code")
        items+=("$code" "$full_name [${code}] - Port: $port (${type})")
    done < "$ACTIVE_FILE"
    
    local country=$(dialog --clear --title "Deactivate Country" \
        --menu "Select a country to deactivate" 20 70 15 "${items[@]}" \
        2>&1 >/dev/tty)
    
    if [ -n "$country" ]; then
        (
            set +e
            deactivate_country "$country" > /tmp/orbitalx_deactivate.log 2>&1
            echo $? > /tmp/orbitalx_deactivate.exit
        ) &
        pid=$!
        
        dialog --title "Deactivating $(get_full_name "$country")..." --infobox "Please wait..." 5 40
        wait $pid
        exit_code=$(cat /tmp/orbitalx_deactivate.exit 2>/dev/null || echo 1)
        
        if [ $exit_code -eq 0 ]; then
            dialog --msgbox "✅ $(get_full_name "$country") deactivated and moved back to available list." 6 50
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
    dialog --yesno "Are you sure you want to stop all active instances (Tor + Psiphon)?" 6 50
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
        dialog --yesno "Delete all data (config, logs, Tor data, Psiphon config)?" 6 50
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

    # Install Psiphon binary
    install_psiphon

    cat > /etc/systemd/system/orbitalx.service << EOF
[Unit]
Description=OrbitalX - Tor/Psiphon Multi-Location Manager
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
        help)
            ;;
        *)
            check_root
            ;;
    esac

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
                print_error "Usage: orbitalx add <COUNTRY> [tor|psiphon]"
                exit 1
            fi
            country=$(echo "$2" | tr '[:lower:]' '[:upper:]')
            if ! grep -q "^${country}:" "$AVAILABLE_FILE"; then
                print_error "Country $(get_full_name "$country") not available."
                exit 1
            fi
            mode="${3:-tor}"
            if [ "$mode" != "tor" ] && [ "$mode" != "psiphon" ]; then
                mode="tor"
            fi
            port=$(grep "^${country}:" "$AVAILABLE_FILE" | cut -d':' -f2)
            activate_country "$country" "$port" "$mode"
            ;;
        remove)
            if [ -z "$2" ]; then
                print_error "Usage: orbitalx remove <COUNTRY>"
                exit 1
            fi
            country=$(echo "$2" | tr '[:lower:]' '[:upper:]')
            deactivate_country "$country"
            ;;
        status)
            if [ -s "$ACTIVE_FILE" ]; then
                echo "Active Locations:"
                while IFS= read -r line; do
                    IFS=':' read -r code port control_port ip type <<< "$line"
                    [ -z "$type" ] && type="tor"
                    full_name=$(get_full_name "$code")
                    echo "$full_name [$code] | Port: $port | Type: $type | IP: $ip"
                done < "$ACTIVE_FILE"
            else
                echo "No active locations."
            fi
            ;;
        available)
            if [ -s "$AVAILABLE_FILE" ]; then
                echo "Available Countries:"
                while IFS= read -r line; do
                    IFS=':' read -r code port <<< "$line"
                    full_name=$(get_full_name "$code")
                    echo "$full_name [$code] - Port: $port"
                done < "$AVAILABLE_FILE"
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
OrbitalX v${VERSION} - Tor/Psiphon Location Manager

CLI Commands:
  install                Install systemd service
  uninstall              Remove everything
  update                 Update from Git
  add <COUNTRY> [tor|psiphon]  Activate a country (default: tor)
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
    check_root
    create_dirs
    check_prerequisites || exit 1
    main_menu
else
    TUI_MODE=0
    cli_mode "$@"
fi

exit 0