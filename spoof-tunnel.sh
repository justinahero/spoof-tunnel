#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

OK="✅"; ERR="❌"; WARN="⚠️ "; INFO="ℹ️ "
ROCKET="🚀"; GEAR="⚙️ "; TROPHY="🏆"; SEARCH="🔍"
TUNNEL="🛰️ "; SHIELD="🛡️ "; STOP="🛑"; PIN="📍"
CHART="📊"; LOGS="📜"; BACK="↩️ "; EXIT="🚪"
MENU="🧭"; SNAP="📸"; KEY="🔑"; HEART="❤️ "

SPOOFTUN_BIN="/usr/local/bin/spooftun"
SPOOFTUN_CONFIG_DIR="/etc/spooftun"
SPOOFTUN_LOG_DIR="/var/log/spooftun"
SPOOFTUN_SNAPSHOT_DIR="/etc/spooftun/snapshots"
SPOOFTUN_SYSCTL_FILE="/etc/sysctl.d/99-spooftun.conf"
SCRIPT_NAME=$(basename "$0")
VERSION="1.0.0"

IFACE=""
VXLAN_NAME=""
ROLE=""
TUN_ID=""
VNI=""
KH_REAL_IP=""
REMOTE_REAL=""
LOCAL_PRIV=""
REMOTE_PRIV=""
DEFAULT_SPOOF=""
REMOTE_DEFAULT=""
CLEANUP_SPOOF_IPS="false"

KH_SERVERS_REAL=()
IRAN_REAL_IP=""
SPOOF_IPS=()

print_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
  ╔══════════════════════════════════════════════════════════════╗
  ║                                                              ║
  ║   ███████╗██████╗  ██████╗  ██████╗ ███████╗               ║
  ║   ██╔════╝██╔══██╗██╔═══██╗██╔═══██╗██╔════╝               ║
  ║   ███████╗██████╔╝██║   ██║██║   ██║█████╗                 ║
  ║   ╚════██║██╔═══╝ ██║   ██║██║   ██║██╔══╝                 ║
  ║   ███████║██║     ╚██████╔╝╚██████╔╝██║                    ║
  ║   ╚══════╝╚═╝      ╚═════╝  ╚═════╝ ╚═╝                    ║
  ║                                                              ║
  ║        ████████╗██╗   ██╗███╗   ██╗                        ║
  ║           ██╔══╝██║   ██║████╗  ██║                        ║
  ║           ██║   ██║   ██║██╔██╗ ██║                        ║
  ║           ██║   ██║   ██║██║╚██╗██║                        ║
  ║           ██║   ╚██████╔╝██║ ╚████║                        ║
  ║           ╚═╝    ╚═════╝ ╚═╝  ╚═══╝                        ║
  ║                                                              ║
  ║      VXLAN Spoof-Tunnel Deployment & Management Suite       ║
EOF
    echo -e "  ║      ${DIM}github.com/justinahero/spoof-tunnel   v${VERSION}${NC}${CYAN}             ║"
    echo -e "  ╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

ui_line()       { printf "${CYAN}%0.s─${NC}" $(seq 1 60); echo; }
print_header()  { echo ""; ui_line; echo -e "  ${WHITE}${BOLD}${MENU}  $1${NC}"; ui_line; echo ""; }
print_success() { echo -e "  ${GREEN}${OK}  $1${NC}"; }
print_error()   { echo -e "  ${RED}${ERR}  $1${NC}"; }
print_warning() { echo -e "  ${YELLOW}${WARN} $1${NC}"; }
print_info()    { echo -e "  ${BLUE}${INFO} $1${NC}"; }
print_dim()     { echo -e "  ${DIM}$1${NC}"; }

log() {
    local level="$1"; shift
    mkdir -p "$SPOOFTUN_LOG_DIR"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "${SPOOFTUN_LOG_DIR}/spooftun.log" >/dev/null
}

error_exit() {
    print_error "$1"
    log "ERROR" "$1"
    exit "${2:-1}"
}

press_enter() {
    echo ""
    read -rp "  Press Enter to continue..." _
}

confirm() {
    local msg="$1"
    local answer
    echo -ne "  ${YELLOW}${WARN} ${msg} [y/N]: ${NC}"
    read -r answer
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

check_root() {
    [[ "$EUID" -eq 0 ]] || error_exit "Please run as root (use sudo)"
}

check_dependencies() {
    local deps=("ip" "iperf3" "ping")
    local missing=()
    for dep in "${deps[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_warning "Missing: ${missing[*]} — installing..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y -qq "${missing[@]}" \
                || error_exit "Failed to install dependencies"
        else
            error_exit "Please install manually: ${missing[*]}"
        fi
    fi
}

detect_default_interface() {
    local iface
    iface=$(ip route | grep default | awk '{print $5}' | head -1)
    [[ -n "$iface" ]] || error_exit "No default network interface found"
    echo "$iface"
}

enable_ip_forward() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
}

_trap_cleanup() {
    local exit_code=$?
    if [[ -n "$VXLAN_NAME" ]] && [[ $exit_code -ne 0 ]]; then
        log "WARNING" "Interrupted — cleaning up $VXLAN_NAME"
        ip link set "$VXLAN_NAME" down 2>/dev/null || true
        ip link del "$VXLAN_NAME" 2>/dev/null || true
        for ip in "${SPOOF_IPS[@]}"; do
            ip addr del "${ip}/32" dev lo 2>/dev/null || true
        done
    fi
    exit "$exit_code"
}
trap '_trap_cleanup' EXIT INT TERM

validate_tun_id() {
    local tun_id="$1"
    [[ "$tun_id" =~ ^[0-9]+$ ]] && [[ "$tun_id" -ge 1 ]] && [[ "$tun_id" -le 254 ]] \
        || error_exit "TUN_ID must be 1–254 (got: $tun_id)"
}

get_tunnel_params() {
    local role="$1" tun_id="$2"
    VXLAN_NAME="vx-tun${tun_id}"
    VNI=$(( 10000 + tun_id ))
    KH_REAL_IP="${KH_SERVERS_REAL[0]:-}"
    local subnet="172.28.${tun_id}"
    PRIV_IP_IRAN="${subnet}.15"
    PRIV_IP_KH="${subnet}.16"

    case "$role" in
        iran)
            REMOTE_REAL="${KH_REAL_IP}"
            LOCAL_PRIV="$PRIV_IP_IRAN"
            REMOTE_PRIV="$PRIV_IP_KH"
            DEFAULT_SPOOF="${SPOOF_IPS[0]:-}"
            REMOTE_DEFAULT="${SPOOF_IPS[1]:-}"
            ;;
        kh)
            REMOTE_REAL="$IRAN_REAL_IP"
            LOCAL_PRIV="$PRIV_IP_KH"
            REMOTE_PRIV="$PRIV_IP_IRAN"
            DEFAULT_SPOOF="${SPOOF_IPS[0]:-}"
            REMOTE_DEFAULT="${SPOOF_IPS[1]:-}"
            ;;
        *)
            error_exit "Invalid role: $role (must be 'iran' or 'kh')"
            ;;
    esac
}

add_spoof_ip() {
    local spoof_ip="$1" force="${2:-false}"
    if ip addr show lo 2>/dev/null | grep -q "${spoof_ip}/32"; then
        [[ "$force" == "true" ]] && ip addr del "${spoof_ip}/32" dev lo 2>/dev/null || return 0
    fi
    ip addr add "${spoof_ip}/32" dev lo 2>/dev/null || {
        log "ERROR" "Failed to add spoof IP: $spoof_ip"
        return 1
    }
    log "INFO" "Added spoof IP: ${spoof_ip}/32 → lo"
}

build_tunnel() {
    local local_spoof="$1"
    log "INFO" "Building tunnel $VXLAN_NAME (spoof: $local_spoof)"
    add_spoof_ip "$local_spoof" true
    ip link del "$VXLAN_NAME" 2>/dev/null || true
    ip link add "$VXLAN_NAME" type vxlan id "$VNI" \
        local "$local_spoof" dev "$IFACE" remote "$REMOTE_REAL" \
        dstport 80 nolearning 2>/dev/null || {
        log "ERROR" "Failed to create VXLAN interface"
        return 1
    }
    ip link set "$VXLAN_NAME" mtu 1400
    ip addr add "${LOCAL_PRIV}/24" dev "$VXLAN_NAME" 2>/dev/null || {
        log "ERROR" "Failed to assign IP to VXLAN"
        return 1
    }
    ip link set "$VXLAN_NAME" up
    log "INFO" "Tunnel $VXLAN_NAME UP — local: $LOCAL_PRIV remote: $REMOTE_PRIV"
    return 0
}

teardown_tunnel() {
    [[ -n "$VXLAN_NAME" ]] || return
    ip link set "$VXLAN_NAME" down 2>/dev/null || true
    ip link del "$VXLAN_NAME" 2>/dev/null || true
    if [[ "${CLEANUP_SPOOF_IPS:-false}" == "true" ]]; then
        for ip in "${SPOOF_IPS[@]}"; do
            ip addr del "${ip}/32" dev lo 2>/dev/null || true
        done
        log "INFO" "Removed spoof IPs from lo"
    fi
    log "INFO" "Tunnel $VXLAN_NAME torn down"
}

start_iperf_server() {
    pkill -f "iperf3 -s -B ${LOCAL_PRIV}" 2>/dev/null || true
    if iperf3 -s -B "$LOCAL_PRIV" -D 2>/dev/null; then
        log "INFO" "iperf3 daemon bound to $LOCAL_PRIV"
    else
        log "WARNING" "iperf3 server failed to start"
    fi
}

stop_iperf_server() {
    pkill -f "iperf3 -s -B ${LOCAL_PRIV}" 2>/dev/null || true
}

test_speed() {
    local remote_ip="$1"
    ping -c 2 -W 2 "$remote_ip" &>/dev/null || { log "DEBUG" "No ping to $remote_ip"; return 1; }
    local attempt=1 speed
    while [[ $attempt -le 3 ]]; do
        speed=$(timeout 10 iperf3 -c "$remote_ip" -t 3 -f m 2>/dev/null \
            | grep -a sender | tail -1 | awk '{print $(NF-1)}')
        if [[ -n "$speed" && "$speed" != "0.00" && "$speed" != "0" ]]; then
            echo "$speed"; return 0
        fi
        (( attempt++ )); sleep 2
    done
    return 1
}

do_auto_benchmark() {
    print_header "${TROPHY} Auto-Benchmark — Finding Best Spoof IP"
    print_warning "Make sure the OTHER server is running: spooftun $ROLE up $TUN_ID"
    echo ""
    ui_line

    best_ip=""    # global — wizard reads this after
    local best_speed=0 tested=0 passed=0
    for ip in "${SPOOF_IPS[@]}"; do
        if [[ "$ip" == "$REMOTE_DEFAULT" ]]; then
            print_dim "  ⏭  Skipping $ip (remote default)"
            continue
        fi
        (( tested++ ))
        echo -ne "  ${SEARCH} Testing ${CYAN}${ip}${NC} ... "
        if ! build_tunnel "$ip"; then
            echo -e "${RED}tunnel failed${NC}"
            teardown_tunnel; continue
        fi
        sleep 2
        local speed
        if ! speed=$(test_speed "$REMOTE_PRIV"); then
            echo -e "${RED}speed test failed${NC}"
            teardown_tunnel; continue
        fi
        (( passed++ ))
        printf "${GREEN}%.0f Mbps${NC}\n" "$speed"
        if awk "BEGIN {exit !($speed > $best_speed)}"; then
            best_speed=$speed; best_ip=$ip
            echo -e "     ${TROPHY} New leader!"
        fi
        teardown_tunnel
    done

    ui_line
    log "INFO" "Benchmark done: $passed/$tested passed"

    if [[ -z "$best_ip" ]]; then
        error_exit "No working spoof IPs found ($tested tested)."
    fi

    echo ""
    printf "  ${TROPHY} ${WHITE}WINNER: ${GREEN}%s${NC} (${CYAN}%.0f Mbps${NC})\n" "$best_ip" "$best_speed"
    echo ""
    log "INFO" "Best: $best_ip @ ${best_speed} Mbps"

    build_tunnel "$best_ip" || error_exit "Failed to build final tunnel"
    start_iperf_server
    print_success "Tunnel $TUN_ID UP with optimal IP!"
    echo -e "  ${PIN} Local: ${CYAN}$LOCAL_PRIV${NC}  Remote: ${CYAN}$REMOTE_PRIV${NC}"
    log "INFO" "Tunnel $TUN_ID active with $best_ip"
}

service_name() { echo "spooftun-tun${1:-$TUN_ID}"; }

write_service() {
    local role="$1" tun_id="$2"
    local svc; svc=$(service_name "$tun_id")
    cat > "/etc/systemd/system/${svc}.service" << EOF
[Unit]
Description=SpoofTun — VXLAN Tunnel ${tun_id} (${role})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SPOOFTUN_BIN} ${role} up ${tun_id}
ExecStop=${SPOOFTUN_BIN} ${role} down ${tun_id}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    log "INFO" "Service ${svc} written"
}

enable_service() {
    local svc; svc=$(service_name "$TUN_ID")
    systemctl enable --now "$svc" 2>/dev/null && print_success "Service ${svc} enabled & started" \
        || print_warning "Could not enable service (non-systemd system?)"
}

disable_service() {
    local svc; svc=$(service_name "$TUN_ID")
    systemctl disable --now "$svc" 2>/dev/null && print_success "Service ${svc} disabled" \
        || print_warning "Service ${svc} not found"
}

config_path() { echo "${SPOOFTUN_CONFIG_DIR}/tun${1}.conf"; }

save_config() {
    local role="$1" tun_id="$2" spoof_ip="${3:-${SPOOF_IPS[0]:-}}"
    mkdir -p "$SPOOFTUN_CONFIG_DIR"
    local cf; cf=$(config_path "$tun_id")
    cat > "$cf" << EOF
ROLE="$role"
TUN_ID="$tun_id"
ACTIVE_SPOOF="$spoof_ip"
IRAN_REAL_IP="$IRAN_REAL_IP"
KH_SERVERS_REAL=($(printf '"%s" ' "${KH_SERVERS_REAL[@]}"))
SPOOF_IPS=($(printf '"%s" ' "${SPOOF_IPS[@]}"))
EOF
    chmod 600 "$cf"
    log "INFO" "Config saved: $cf"
    print_success "Config saved: $cf"
}

load_config() {
    local tun_id="$1"
    local cf; cf=$(config_path "$tun_id")
    [[ -f "$cf" ]] || return 1
    source "$cf"
    return 0
}

snapshot_config() {
    local tun_id="$1"
    local cf; cf=$(config_path "$tun_id")
    [[ -f "$cf" ]] || { print_error "No config for tunnel $tun_id"; return 1; }
    mkdir -p "$SPOOFTUN_SNAPSHOT_DIR"
    local snap="${SPOOFTUN_SNAPSHOT_DIR}/tun${tun_id}-$(date '+%Y%m%d-%H%M%S').conf"
    cp "$cf" "$snap"
    print_success "Snapshot saved: $snap"
    log "INFO" "Snapshot: $snap"
}

rollback_config() {
    local tun_id="$1"
    local snaps=("${SPOOFTUN_SNAPSHOT_DIR}"/tun${tun_id}-*.conf)
    if [[ ${#snaps[@]} -eq 0 ]] || [[ ! -f "${snaps[0]}" ]]; then
        print_error "No snapshots found for tunnel $tun_id"
        return 1
    fi
    echo ""
    print_info "Available snapshots for Tunnel $tun_id:"
    echo ""
    local i=1
    for s in "${snaps[@]}"; do
        echo -e "  ${CYAN}[$i]${NC} $(basename "$s")"
        (( i++ ))
    done
    echo ""
    read -rp "  Choose snapshot [1-$((i-1))]: " choice
    local chosen="${snaps[$((choice-1))]}"
    [[ -f "$chosen" ]] || { print_error "Invalid choice"; return 1; }
    cp "$chosen" "$(config_path "$tun_id")"
    print_success "Rolled back tunnel $tun_id to: $(basename "$chosen")"
    log "INFO" "Rollback: $chosen"
}

tunnel_is_up() {
    local tun_id="$1"
    local vx="vx-tun${tun_id}"
    ip link show "$vx" 2>/dev/null | grep -q "UP"
}

list_tunnels() {
    print_header "${TUNNEL} Active SpoofTun Tunnels"
    local found=0
    for cf in "${SPOOFTUN_CONFIG_DIR}"/tun*.conf; do
        [[ -f "$cf" ]] || continue
        local tid; tid=$(basename "$cf" .conf | tr -d 'tun')
        local role="?"; grep -q 'ROLE="iran"' "$cf" && role="iran" || role="kh"
        local status
        if tunnel_is_up "$tid"; then
            status="${GREEN}UP${NC}"
        else
            status="${RED}DOWN${NC}"
        fi
        local svc_status=""
        if systemctl is-enabled "$(service_name "$tid")" &>/dev/null; then
            svc_status="${DIM}[autostart]${NC}"
        fi
        echo -e "  ${CYAN}Tunnel $tid${NC}  role=${YELLOW}$role${NC}  ${status}  ${svc_status}"
        (( found++ ))
    done
    [[ $found -eq 0 ]] && print_dim "  No tunnels configured yet."
    echo ""
}

health_check() {
    print_header "${HEART} Health Check"
    local cf
    for cf in "${SPOOFTUN_CONFIG_DIR}"/tun*.conf; do
        [[ -f "$cf" ]] || continue
        local tid; tid=$(basename "$cf" .conf | tr -d 'tun')
        echo -e "  ${CYAN}Tunnel $tid${NC}"
        if tunnel_is_up "$tid"; then
            print_success "Interface vx-tun${tid} is UP"
            local vx="vx-tun${tid}"
            ip -brief addr show "$vx" 2>/dev/null | awk '{print "    IP:", $3}'
            local rx tx
            rx=$(cat "/sys/class/net/${vx}/statistics/rx_bytes" 2>/dev/null || echo "?")
            tx=$(cat "/sys/class/net/${vx}/statistics/tx_bytes" 2>/dev/null || echo "?")
            echo -e "    RX: ${rx} bytes  TX: ${tx} bytes"
        else
            print_error "Interface vx-tun${tid} is DOWN"
        fi
        echo ""
    done
}

view_logs() {
    print_header "${LOGS} Recent Logs"
    local logfile="${SPOOFTUN_LOG_DIR}/spooftun.log"
    if [[ -f "$logfile" ]]; then
        tail -40 "$logfile"
    else
        print_dim "  No logs yet."
    fi
    echo ""
}

apply_kernel_opts() {
    print_header "${GEAR} Applying Kernel Optimizations"
    cat > "$SPOOFTUN_SYSCTL_FILE" << 'EOF'
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.core.rmem_default=16777216
net.core.wmem_default=16777216
net.core.netdev_max_backlog=65536
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.core.somaxconn=65535
EOF
    sysctl -p "$SPOOFTUN_SYSCTL_FILE" >/dev/null 2>&1 && \
        print_success "Kernel parameters applied" || \
        print_warning "Some parameters may not have applied"
    log "INFO" "Kernel optimization applied"
}

install_to_bin() {
    local src="${BASH_SOURCE[0]}"
    [[ -f "$src" ]] || src="$0"
    cp "$src" "$SPOOFTUN_BIN"
    chmod +x "$SPOOFTUN_BIN"
    mkdir -p "$SPOOFTUN_CONFIG_DIR" "$SPOOFTUN_LOG_DIR" "$SPOOFTUN_SNAPSHOT_DIR"
    print_success "Installed to $SPOOFTUN_BIN"
    print_info "Run 'sudo spooftun' to launch"
    log "INFO" "Installed v${VERSION}"
}

uninstall_from_bin() {
    confirm "Remove SpoofTun from $SPOOFTUN_BIN?" || { print_warning "Cancelled"; return; }
    rm -f "$SPOOFTUN_BIN"
    for svc in /etc/systemd/system/spooftun-*.service; do
        [[ -f "$svc" ]] && systemctl disable --now "$(basename "$svc")" 2>/dev/null
        rm -f "$svc"
    done
    systemctl daemon-reload 2>/dev/null || true
    print_success "SpoofTun uninstalled"
    log "INFO" "Uninstalled"
}

read_ip() {
    local prompt="$1" varname="$2" default="${3:-}"
    local ip
    while true; do
        if [[ -n "$default" ]]; then
            read -rp "  ${prompt} [${default}]: " ip
            ip="${ip:-$default}"
        else
            read -rp "  ${prompt}: " ip
        fi
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf -v "$varname" '%s' "$ip"
            return 0
        fi
        print_error "Invalid IP address: '$ip' — please enter a valid IPv4"
    done
}

read_ip_list() {
    local prompt="$1"
    local -n _arr="$2"   # nameref
    _arr=()
    local raw ip
    echo -e "  ${DIM}Enter one IP per line. Leave blank when done.${NC}"
    local idx=1
    while true; do
        read -rp "  IP #${idx}: " ip
        [[ -z "$ip" ]] && break
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            _arr+=("$ip")
            print_success "Added: $ip"
            (( idx++ ))
        else
            print_error "Invalid IPv4: '$ip'"
        fi
    done
}

wizard_deploy() {
    print_header "${ROCKET} Deploy New Tunnel"
    print_dim "  Answer each step — no config files to edit manually."
    echo ""

    echo -e "  ${WHITE}${BOLD}Step 1 / 6 — Server Role${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC}  iran  — This server is inside Iran"
    echo -e "  ${CYAN}[2]${NC}  kh   — This server is outside Iran"
    echo ""
    local role
    while true; do
        read -rp "  Choose [1/2]: " choice
        case "$choice" in
            1) role="iran"; break ;;
            2) role="kh";   break ;;
            *) print_error "Please enter 1 or 2" ;;
        esac
    done
    print_success "Role: $role"
    echo ""

    echo -e "  ${WHITE}${BOLD}Step 2 / 6 — Real IP of the Remote Server${NC}"
    echo ""
    if [[ "$role" == "iran" ]]; then
        print_dim "  Enter the REAL public IP of your KH (abroad) server."
        local kh_ip
        read_ip "KH server real IP" kh_ip
        KH_SERVERS_REAL=("$kh_ip")
        IRAN_REAL_IP=""   # Iran side doesn't need to know its own real IP
    else
        print_dim "  Enter the REAL public IP of your Iran server."
        read_ip "Iran server real IP" IRAN_REAL_IP
        KH_SERVERS_REAL=()
    fi
    print_success "Remote real IP saved."
    echo ""

    echo -e "  ${WHITE}${BOLD}Step 3 / 6 — Tunnel ID${NC}"
    print_dim "  A number 1–254. Each tunnel gets a unique private subnet."
    print_dim "  If this is your first tunnel, just press Enter."
    echo ""
    local tun_id
    while true; do
        read -rp "  Tunnel ID [1]: " tun_id
        tun_id="${tun_id:-1}"
        if [[ "$tun_id" =~ ^[0-9]+$ ]] && \
           [[ "$tun_id" -ge 1 ]] && [[ "$tun_id" -le 254 ]]; then
            break
        fi
        print_error "Must be a number between 1 and 254"
    done
    print_success "Tunnel ID: $tun_id"
    echo ""

    echo -e "  ${WHITE}${BOLD}Step 4 / 6 — Spoof IP Pool${NC}"
    echo ""
    print_dim "  These IPs will be used as the VXLAN source address (spoofed local IPs)."
    print_dim "  They should be IPs that exist in your network or are routable to this server."
    print_dim "  You need at least 1. Add more for auto-benchmark to find the fastest."
    echo ""

    read_ip_list "Spoof IP" SPOOF_IPS

    if [[ ${#SPOOF_IPS[@]} -eq 0 ]]; then
        print_error "At least one spoof IP is required."
        return 1
    fi
    echo ""
    print_info "${#SPOOF_IPS[@]} spoof IP(s) added."
    echo ""

    echo -e "  ${WHITE}${BOLD}Step 5 / 6 — Deploy Method${NC}"
    echo ""
    echo -e "  ${CYAN}[1]${NC}  Use first spoof IP and bring tunnel up immediately"
    echo -e "  ${CYAN}[2]${NC}  Auto-benchmark — test all IPs and pick fastest ${DIM}(needs remote server UP)${NC}"
    echo ""
    local deploy_mode
    while true; do
        read -rp "  Choose [1/2]: " choice
        case "$choice" in
            1) deploy_mode="up";   break ;;
            2) deploy_mode="auto"; break ;;
            *) print_error "Enter 1 or 2" ;;
        esac
    done
    echo ""

    echo -e "  ${WHITE}${BOLD}Step 6 / 6 — Auto-start on Boot${NC}"
    echo ""
    local do_systemd=false
    confirm "Enable systemd service so tunnel starts automatically on reboot?" \
        && do_systemd=true
    echo ""

    IFACE=$(detect_default_interface)
    [[ -z "$IRAN_REAL_IP" ]] && IRAN_REAL_IP="0.0.0.0"
    get_tunnel_params "$role" "$tun_id"
    ROLE="$role"
    TUN_ID="$tun_id"

    local first_spoof="${SPOOF_IPS[0]}"

    echo ""
    ui_line
    echo -e "  ${WHITE}${BOLD}Summary — please review before deploying${NC}"
    echo ""
    echo -e "  Role          : ${CYAN}$role${NC}"
    echo -e "  Tunnel ID     : ${CYAN}$tun_id${NC}"
    echo -e "  Interface     : ${CYAN}$IFACE${NC}"
    echo -e "  VXLAN Name    : ${CYAN}$VXLAN_NAME${NC}  (VNI: $VNI)"
    echo -e "  Remote Real IP: ${CYAN}$REMOTE_REAL${NC}"
    echo -e "  Local Priv IP : ${CYAN}$LOCAL_PRIV${NC}"
    echo -e "  Remote Priv IP: ${CYAN}$REMOTE_PRIV${NC}"
    echo -e "  Spoof Pool    : ${CYAN}${SPOOF_IPS[*]}${NC}"
    echo -e "  Deploy Mode   : ${CYAN}$deploy_mode${NC}"
    echo -e "  Autostart     : ${CYAN}$do_systemd${NC}"
    ui_line
    echo ""

    confirm "Deploy tunnel now?" || { print_warning "Cancelled."; return; }
    echo ""

    check_dependencies
    enable_ip_forward

    local active_spoof="$first_spoof"

    if [[ "$deploy_mode" == "auto" ]]; then
        do_auto_benchmark
        active_spoof="${best_ip:-$first_spoof}"
    else
        teardown_tunnel
        if build_tunnel "$first_spoof"; then
            start_iperf_server
            print_success "Tunnel $tun_id is UP!"
            echo -e "  ${PIN} Local: ${CYAN}$LOCAL_PRIV${NC}  Remote: ${CYAN}$REMOTE_PRIV${NC}"
            log "INFO" "Tunnel $tun_id deployed (role=$role spoof=$first_spoof)"
        else
            error_exit "Failed to build tunnel"
        fi
    fi

    save_config "$role" "$tun_id" "$active_spoof"

    if [[ "$do_systemd" == "true" ]]; then
        write_service "$role" "$tun_id"
        enable_service
    fi

    echo ""
    print_success "All done! Tunnel $tun_id is live."
}

show_manage_menu() {
    while true; do
        print_header "${GEAR} Manage Tunnels"
        echo -e "  ${CYAN}[1]${NC} List all tunnels"
        echo -e "  ${CYAN}[2]${NC} Take down a tunnel"
        echo -e "  ${CYAN}[3]${NC} Bring up a tunnel"
        echo -e "  ${CYAN}[4]${NC} Run auto-benchmark on a tunnel"
        echo -e "  ${CYAN}[5]${NC} Enable autostart (systemd)"
        echo -e "  ${CYAN}[6]${NC} Disable autostart"
        echo -e "  ${CYAN}[7]${NC} Snapshot config"
        echo -e "  ${CYAN}[8]${NC} Rollback config"
        echo -e "  ${CYAN}[0]${NC} ${BACK} Back"
        echo ""
        read -rp "  Choose: " choice
        echo ""

        case "$choice" in
            1) list_tunnels; press_enter ;;
            2)
                read -rp "  Tunnel ID to bring DOWN: " tid
                load_config "$tid" || { print_error "No config for $tid"; press_enter; continue; }
                IFACE=$(detect_default_interface)
                get_tunnel_params "$ROLE" "$tid"
                TUN_ID="$tid"
                teardown_tunnel
                stop_iperf_server
                print_success "Tunnel $tid is DOWN"
                log "INFO" "Tunnel $tid stopped"
                press_enter
                ;;
            3)
                read -rp "  Tunnel ID to bring UP: " tid
                load_config "$tid" || { print_error "No config for $tid"; press_enter; continue; }
                IFACE=$(detect_default_interface)
                get_tunnel_params "$ROLE" "$tid"
                TUN_ID="$tid"
                enable_ip_forward
                teardown_tunnel
                local spoof="${ACTIVE_SPOOF:-$DEFAULT_SPOOF}"
                if build_tunnel "$spoof"; then
                    start_iperf_server
                    print_success "Tunnel $tid UP (spoof: $spoof)"
                else
                    print_error "Failed"
                fi
                press_enter
                ;;
            4)
                read -rp "  Tunnel ID to benchmark: " tid
                load_config "$tid" || { print_error "No config for $tid"; press_enter; continue; }
                IFACE=$(detect_default_interface)
                get_tunnel_params "$ROLE" "$tid"
                ROLE="${ROLE:-iran}"; TUN_ID="$tid"
                enable_ip_forward
                do_auto_benchmark
                press_enter
                ;;
            5)
                read -rp "  Tunnel ID: " tid
                load_config "$tid" || { print_error "No config"; press_enter; continue; }
                TUN_ID="$tid"
                write_service "$ROLE" "$tid"
                enable_service
                press_enter
                ;;
            6)
                read -rp "  Tunnel ID: " tid
                TUN_ID="$tid"
                disable_service
                press_enter
                ;;
            7)
                read -rp "  Tunnel ID to snapshot: " tid
                snapshot_config "$tid"
                press_enter
                ;;
            8)
                read -rp "  Tunnel ID to rollback: " tid
                rollback_config "$tid"
                press_enter
                ;;
            0) return ;;
            *) print_error "Invalid choice" ;;
        esac
    done
}

show_reports_menu() {
    while true; do
        print_header "${LOGS} Reports & Logs"
        echo -e "  ${CYAN}[1]${NC} View recent logs"
        echo -e "  ${CYAN}[2]${NC} Health check"
        echo -e "  ${CYAN}[3]${NC} List tunnels"
        echo -e "  ${CYAN}[4]${NC} Clear logs"
        echo -e "  ${CYAN}[0]${NC} ${BACK} Back"
        echo ""
        read -rp "  Choose: " choice
        echo ""
        case "$choice" in
            1) view_logs; press_enter ;;
            2) health_check; press_enter ;;
            3) list_tunnels; press_enter ;;
            4)
                confirm "Clear log file?" && {
                    > "${SPOOFTUN_LOG_DIR}/spooftun.log"
                    print_success "Logs cleared"
                }
                press_enter
                ;;
            0) return ;;
            *) print_error "Invalid choice" ;;
        esac
    done
}

show_settings_menu() {
    while true; do
        print_header "${SHIELD} Settings"
        echo -e "  ${CYAN}[1]${NC} Apply kernel optimizations"
        echo -e "  ${CYAN}[2]${NC} Install spooftun to /usr/local/bin"
        echo -e "  ${CYAN}[3]${NC} Uninstall spooftun"
        echo -e "  ${CYAN}[4]${NC} Show version"
        echo -e "  ${CYAN}[0]${NC} ${BACK} Back"
        echo ""
        read -rp "  Choose: " choice
        echo ""
        case "$choice" in
            1) apply_kernel_opts; press_enter ;;
            2) install_to_bin; press_enter ;;
            3) uninstall_from_bin; press_enter ;;
            4) echo -e "  SpoofTun v${VERSION}"; press_enter ;;
            0) return ;;
            *) print_error "Invalid choice" ;;
        esac
    done
}

show_main_menu() {
    while true; do
        print_banner
        echo -e "  ${CYAN}[1]${NC}  ${ROCKET}  Deploy new tunnel"
        echo -e "  ${CYAN}[2]${NC}  ${GEAR}   Manage tunnels"
        echo -e "  ${CYAN}[3]${NC}  ${CHART}  Reports & Logs"
        echo -e "  ${CYAN}[4]${NC}  ${SHIELD}  Settings"
        echo -e "  ${CYAN}[0]${NC}  ${EXIT}  Exit"
        echo ""
        read -rp "  Choose: " choice
        echo ""
        case "$choice" in
            1) check_root; wizard_deploy; press_enter ;;
            2) check_root; show_manage_menu ;;
            3) check_root; show_reports_menu ;;
            4) check_root; show_settings_menu ;;
            0) echo -e "  ${DIM}Goodbye.${NC}"; echo ""; exit 0 ;;
            *) print_error "Invalid choice" ;;
        esac
    done
}

show_help() {
    print_banner
    cat << EOF
${WHITE}Usage:${NC}
  sudo spooftun [OPTION]
  sudo spooftun [iran|kh] [up|down|auto] [TUN_ID]

${WHITE}Interactive:${NC}
  sudo spooftun               Launch wizard

${WHITE}Direct commands:${NC}
  spooftun iran up 1          Bring tunnel 1 up (Iran role)
  spooftun kh down 1          Bring tunnel 1 down (KH role)
  spooftun iran auto 1        Auto-benchmark & pick best spoof IP

${WHITE}Options:${NC}
  --list, --status            List all tunnels and status
  --health                    Health check (interface + traffic stats)
  --logs                      View recent log entries
  --snapshot <TUN_ID>         Snapshot tunnel config
  --rollback <TUN_ID>         Rollback tunnel config to snapshot
  --optimize                  Apply kernel optimizations
  --install                   Install to /usr/local/bin/spooftun
  --uninstall                 Remove from system
  --version                   Show version
  --help, -h                  Show this help

${DIM}Tip: run 'sudo spooftun' with no arguments for the interactive wizard.${NC}

EOF
}

handle_direct() {
    local role="$1" action="$2" tun_id="${3:-1}"
    check_root
    ROLE="$role"; TUN_ID="$tun_id"
    validate_tun_id "$tun_id"
    IFACE=$(detect_default_interface)
    check_dependencies
    enable_ip_forward
    get_tunnel_params "$role" "$tun_id"
    log "INFO" "CLI: role=$role action=$action tun_id=$tun_id iface=$IFACE"

    case "$action" in
        up)
            teardown_tunnel
            if build_tunnel "$DEFAULT_SPOOF"; then
                start_iperf_server
                print_success "Tunnel $tun_id UP  (spoof: $DEFAULT_SPOOF)"
                echo -e "  ${PIN} Local: ${CYAN}$LOCAL_PRIV${NC}  Remote: ${CYAN}$REMOTE_PRIV${NC}"
                log "INFO" "Tunnel $tun_id up"
            else
                error_exit "Failed to build tunnel"
            fi
            ;;
        down)
            CLEANUP_SPOOF_IPS="false"
            teardown_tunnel
            stop_iperf_server
            print_success "Tunnel $VXLAN_NAME is DOWN"
            log "INFO" "Tunnel $tun_id down"
            ;;
        auto)
            do_auto_benchmark
            ;;
        *)
            error_exit "Unknown action: $action (use: up | down | auto)"
            ;;
    esac
}

main() {
    if [[ $# -eq 0 ]]; then
        show_main_menu
        return
    fi

    case "$1" in
        iran|kh)
            [[ $# -ge 2 ]] || { show_help; exit 1; }
            handle_direct "$@"
            ;;
        --list|--status)    check_root; list_tunnels ;;
        --health)           check_root; health_check ;;
        --logs)             check_root; view_logs ;;
        --snapshot)         check_root; snapshot_config "${2:-1}" ;;
        --rollback)         check_root; rollback_config "${2:-1}" ;;
        --optimize)         check_root; apply_kernel_opts ;;
        --install)          check_root; install_to_bin ;;
        --uninstall)        check_root; uninstall_from_bin ;;
        --version)          echo "SpoofTun v${VERSION}" ;;
        --help|-h)          show_help ;;
        *)
            print_error "Unknown option: $1"
            echo "  Use --help for available options"
            exit 1
            ;;
    esac
}

main "$@"
