#!/bin/bash
# proxy-manager.sh - Dynamic Proxy Manager with IP Rotation
# Usage: ./proxy-manager.sh [start|stop|status|rotate|fetch|list]
#        ./proxy-manager.sh rotate [interval_seconds]
#        ./proxy-manager.sh fetch [country_code]

PROXY_HOST="127.0.0.1"
PROXY_PORT="8080"
SOCKS_PORT="1080"
USE_SOCKS=false
ROTATE_INTERVAL=30          # Default rotation interval (seconds)
PROXY_LIST_FILE="/tmp/proxy_list.txt"
CURRENT_PROXY_INDEX_FILE="/tmp/.proxy_current_index"
DAEMON_PID_FILE="/tmp/.proxy_rotator.pid"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Backup file for original env values
BACKUP_FILE="/tmp/.proxy_backup"

# ─── Default fallback proxies ──────────────────────────────
DEFAULT_PROXIES=(
    "127.0.0.1:8080"
    "127.0.0.1:3128"
    "127.0.0.1:8888"
)

# ─── Utility ────────────────────────────────────────────────
log() {
    local level="$1"; shift
    echo -e "[${level}] $(date '+%H:%M:%S') - $*"
}

banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║        DYNAMIC PROXY MANAGER - IP ROTATOR             ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ─── Backup/Restore ──────────────────────────────────────────
backup_env() {
    echo "# Proxy environment backup - $(date)" > "$BACKUP_FILE"
    for var in http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY; do
        echo "export ${var}=\"${!var}\"" >> "$BACKUP_FILE"
    done
}

restore_env() {
    if [ -f "$BACKUP_FILE" ]; then
        source "$BACKUP_FILE"
        while IFS= read -r line; do
            if [[ "$line" == export* ]]; then
                eval "$line"
            fi
        done < "$BACKUP_FILE"
        rm -f "$BACKUP_FILE"
        echo -e "${GREEN}[✓]${NC} Environment variables restored from backup"
    else
        for var in http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY; do
            unset "$var"
        done
        echo -e "${YELLOW}[!]${NC} No backup found. Unset proxy variables."
    fi
}

set_proxy_vars() {
    local host="$1" port="$2"
    export http_proxy="http://${host}:${port}"
    export https_proxy="http://${host}:${port}"
    export ftp_proxy="http://${host}:${port}"
    export no_proxy="localhost,127.0.0.1,::1"
    export HTTP_PROXY="http://${host}:${port}"
    export HTTPS_PROXY="http://${host}:${port}"
    export FTP_PROXY="http://${host}:${port}"
    export NO_PROXY="localhost,127.0.0.1,::1"
}

unset_proxy() {
    local proto="$1"
    local var="${proto}_proxy"
    local VAR="${proto^^}_proxy"
    unset "$var"
    unset "$VAR"
}

# ─── Fetch Fresh Proxies from Web ────────────────────────────
fetch_proxies() {
    local country="${1:-}"
    echo -e "${YELLOW}[*] Fetching fresh proxy list...${NC}"
    
    # Try multiple sources
    local tmpfile=$(mktemp)
    local count=0
    
    # Source 1: SSL Proxies
    echo -e "${BLUE}[*] Source 1: Checking SSL proxies...${NC}"
    local ssl_proxies=$(curl -s --connect-timeout 10 "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt" 2>/dev/null | head -200)
    if [ -n "$ssl_proxies" ]; then
        echo "$ssl_proxies" >> "$tmpfile"
        count=$((count + $(echo "$ssl_proxies" | wc -l)))
        echo -e "${GREEN}[✓] Got proxies from SSL list${NC}"
    fi
    
    # Source 2: GitHub proxy lists
    echo -e "${BLUE}[*] Source 2: Checking GitHub proxy list...${NC}"
    local gh_proxies=$(curl -s --connect-timeout 10 "https://raw.githubusercontent.com/roosterkid/openproxylist/main/HTTP_RAW.txt" 2>/dev/null | head -200)
    if [ -n "$gh_proxies" ]; then
        echo "$gh_proxies" >> "$tmpfile"
        count=$((count + $(echo "$gh_proxies" | wc -l)))
        echo -e "${GREEN}[✓] Got proxies from GitHub list${NC}"
    fi
    
    # Source 3: Generate random proxies from valid subnets as fallback
    if [ ! -s "$tmpfile" ]; then
        echo -e "${YELLOW}[!] No proxies fetched from web. Using fallback list.${NC}"
        for proxy in "${DEFAULT_PROXIES[@]}"; do
            echo "$proxy" >> "$tmpfile"
        done
    fi
    
    # Clean and deduplicate
    sort -u "$tmpfile" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$' > "$PROXY_LIST_FILE"
    local total=$(wc -l < "$PROXY_LIST_FILE")
    rm -f "$tmpfile"
    
    echo -e "${GREEN}[✓] Proxy list saved: $total proxies in $PROXY_LIST_FILE${NC}"
    echo 0 > "$CURRENT_PROXY_INDEX_FILE"
}

# ─── Get Next Proxy ──────────────────────────────────────────
get_next_proxy() {
    local host="127.0.0.1"
    local port="8080"
    
    if [ -f "$PROXY_LIST_FILE" ] && [ -s "$PROXY_LIST_FILE" ]; then
        local total=$(wc -l < "$PROXY_LIST_FILE")
        local idx=0
        
        if [ -f "$CURRENT_PROXY_INDEX_FILE" ]; then
            idx=$(cat "$CURRENT_PROXY_INDEX_FILE")
        fi
        
        local next_idx=$(( (idx + 1) % total ))
        echo "$next_idx" > "$CURRENT_PROXY_INDEX_FILE"
        
        local line_num=$((next_idx + 1))
        local proxy_line=$(sed -n "${line_num}p" "$PROXY_LIST_FILE")
        
        if [[ "$proxy_line" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([0-9]+)$ ]]; then
            host="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
        fi
    fi
    
    echo "$host $port"
}

# ─── Health Check Proxy ─────────────────────────────────────
check_proxy() {
    local host="$1" port="$2"
    local timeout=5
    
    if timeout "$timeout" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        # Quick HTTP check through proxy
        local result=$(timeout "$timeout" curl -s -x "http://${host}:${port}" \
            --connect-timeout 3 --max-time 4 \
            -o /dev/null -w "%{http_code}" \
            "http://httpbin.org/ip" 2>/dev/null || echo "0")
        if [ "$result" != "0" ]; then
            return 0
        fi
    fi
    return 1
}

# ─── Apply Proxy to System ───────────────────────────────────
apply_proxy_system() {
    local host="$1" port="$2"
    
    # Shell env
    set_proxy_vars "$host" "$port"
    
    # Shell persistence
    cat > /tmp/.proxy_env <<EOF
export http_proxy=http://${host}:${port}
export https_proxy=http://${host}:${port}
export ftp_proxy=http://${host}:${port}
export no_proxy=localhost,127.0.0.1,::1
export HTTP_PROXY=http://${host}:${port}
export HTTPS_PROXY=http://${host}:${port}
export FTP_PROXY=http://${host}:${port}
export NO_PROXY=localhost,127.0.0.1,::1
EOF
    
    # Services
    sudo tee /etc/apt/apt.conf.d/99proxy > /dev/null <<EOF
Acquire::http::Proxy "http://${host}:${port}";
Acquire::https::Proxy "http://${host}:${port}";
Acquire::ftp::Proxy "http://${host}:${port}";
EOF
    
    for conf in /etc/systemd/system.conf.d/proxy.conf /etc/systemd/user.conf.d/proxy.conf; do
        sudo mkdir -p "$(dirname "$conf")"
        sudo tee "$conf" > /dev/null <<EOF
[Manager]
DefaultEnvironment="http_proxy=http://${host}:${port}"
DefaultEnvironment="https_proxy=http://${host}:${port}"
DefaultEnvironment="ftp_proxy=http://${host}:${port}"
DefaultEnvironment="no_proxy=localhost,127.0.0.1,::1"
EOF
    done
    sudo systemctl daemon-reload 2>/dev/null
    
    # Docker
    local docker_dir="/etc/systemd/system/docker.service.d"
    sudo mkdir -p "$docker_dir"
    sudo tee "$docker_dir/proxy.conf" > /dev/null <<EOF
[Service]
Environment="HTTP_PROXY=http://${host}:${port}"
Environment="HTTPS_PROXY=http://${host}:${port}"
Environment="NO_PROXY=localhost,127.0.0.1,::1"
EOF
    sudo systemctl daemon-reload 2>/dev/null
    
    # Desktop
    if command -v gsettings &>/dev/null; then
        gsettings set org.gnome.system.proxy mode 'manual' 2>/dev/null
        gsettings set org.gnome.system.proxy.http host "$host" 2>/dev/null
        gsettings set org.gnome.system.proxy.http port "$port" 2>/dev/null
        gsettings set org.gnome.system.proxy.https host "$host" 2>/dev/null
        gsettings set org.gnome.system.proxy.https port "$port" 2>/dev/null
    fi
    
    echo -e "${GREEN}[✓]${NC} Proxy rotated to ${CYAN}${host}:${port}${NC}"
}

# ─── Rotate IP Function ──────────────────────────────────────
rotate_ip() {
    local interval="${1:-$ROTATE_INTERVAL}"
    
    # Ensure we have a proxy list
    if [ ! -f "$PROXY_LIST_FILE" ] || [ ! -s "$PROXY_LIST_FILE" ]; then
        fetch_proxies
    fi
    
    echo -e "${GREEN}[*] Starting proxy rotation every ${interval}s${NC}"
    echo -e "${GREEN}[*] Press Ctrl+C to stop${NC}"
    echo ""
    
    local count=0
    while true; do
        count=$((count + 1))
        
        # Get next proxy
        read -r host port <<< "$(get_next_proxy)"
        
        # Show current rotation
        echo -ne "${CYAN}[$(date '+%H:%M:%S')]${NC} "
        echo -ne "Rotation #${count}: ${YELLOW}${host}:${port}${NC} "
        
        # Health check
        if check_proxy "$host" "$port"; then
            echo -ne "${GREEN}[ALIVE]${NC} "
            apply_proxy_system "$host" "$port"
        else
            echo -e "${RED}[DEAD]${NC}"
            # Remove dead proxy
            if [ -f "$PROXY_LIST_FILE" ]; then
                sed -i "/^${host}:${port}$/d" "$PROXY_LIST_FILE"
            fi
        fi
        
        sleep "$interval"
    done
}

# ─── Start Rotator Daemon ────────────────────────────────────
start_rotator() {
    local interval="${1:-$ROTATE_INTERVAL}"
    
    if [ -f "$DAEMON_PID_FILE" ]; then
        local old_pid=$(cat "$DAEMON_PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo -e "${YELLOW}[!] Rotator is already running (PID: $old_pid)${NC}"
            return
        fi
        rm -f "$DAEMON_PID_FILE"
    fi
    
    # Start in background
    (
        # Ensure we have proxies
        if [ ! -f "$PROXY_LIST_FILE" ] || [ ! -s "$PROXY_LIST_FILE" ]; then
            fetch_proxies
        fi
        
        local count=0
        while true; do
            count=$((count + 1))
            read -r host port <<< "$(get_next_proxy)"
            
            echo "[$(date '+%H:%M:%S')] Rotation #${count}: ${host}:${port}" >> /tmp/.proxy_rotation.log
            
            if check_proxy "$host" "$port"; then
                apply_proxy_system "$host" "$port"
            else
                # Remove dead proxy silently
                if [ -f "$PROXY_LIST_FILE" ]; then
                    sed -i "/^${host}:${port}$/d" "$PROXY_LIST_FILE"
                fi
            fi
            
            sleep "$interval"
        done
    ) &
    
    local pid=$!
    echo "$pid" > "$DAEMON_PID_FILE"
    echo -e "${GREEN}[✓]${NC} Proxy rotator started (PID: $pid, interval: ${interval}s)"
}

stop_rotator() {
    if [ -f "$DAEMON_PID_FILE" ]; then
        local pid=$(cat "$DAEMON_PID_FILE")
        kill "$pid" 2>/dev/null && echo -e "${GREEN}[✓]${NC} Rotator stopped (PID: $pid)" || \
            echo -e "${YELLOW}[!]${NC} Rotator was not running"
        rm -f "$DAEMON_PID_FILE"
    else
        echo -e "${YELLOW}[!]${NC} Rotator is not running"
    fi
}

# ─── Status Display ─────────────────────────────────────────
show_status() {
    banner
    echo -e "${YELLOW}══════════════════ Proxy Status ══════════════════${NC}"
    
    # Check shell env vars
    local cur_http="${http_proxy:-<unset>}"
    local cur_https="${https_proxy:-<unset>}"
    local cur_ftp="${ftp_proxy:-<unset>}"
    local cur_no="${no_proxy:-<unset>}"
    
    # Also read from persistence file if vars are unset
    if [ "$cur_http" = "<unset>" ] && [ -f /tmp/.proxy_env ]; then
        source /tmp/.proxy_env 2>/dev/null
        cur_http="${http_proxy:-<unset>}"
        cur_https="${https_proxy:-<unset>}"
        cur_ftp="${ftp_proxy:-<unset>}"
        cur_no="${no_proxy:-<unset>}"
    fi
    
    echo -e "${BOLD}Environment Variables:${NC}"
    echo "  http_proxy  = ${cur_http}"
    echo "  https_proxy = ${cur_https}"
    echo "  ftp_proxy   = ${cur_ftp}"
    echo "  no_proxy    = ${cur_no}"
    echo ""
    
    echo -e "${BOLD}Rotator Status:${NC}"
    if [ -f "$DAEMON_PID_FILE" ]; then
        local pid=$(cat "$DAEMON_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "  ${GREEN}[RUNNING]${NC} PID: $pid"
        else
            echo -e "  ${RED}[STOPPED]${NC} (stale PID file)"
            rm -f "$DAEMON_PID_FILE"
        fi
    else
        echo -e "  ${YELLOW}[STOPPED]${NC}"
    fi
    
    # Rotation log tail
    if [ -f /tmp/.proxy_rotation.log ]; then
        echo ""
        echo -e "${BOLD}Last 5 Rotations:${NC}"
        tail -5 /tmp/.proxy_rotation.log | while read -r line; do
            echo "  ${CYAN}↻${NC} $line"
        done
    fi
    
    echo ""
    echo -e "${BOLD}Config Files:${NC}"
    for f in /etc/apt/apt.conf.d/99proxy /etc/systemd/system.conf.d/proxy.conf /etc/systemd/user.conf.d/proxy.conf /etc/systemd/system/docker.service.d/proxy.conf; do
        if [ -f "$f" ]; then
            local proxy_val=$(grep -oP '(http|https?)://[0-9.]+:[0-9]+' "$f" 2>/dev/null | head -1)
            echo -e "  ${GREEN}[EXISTS]${NC} $f ${YELLOW}(${proxy_val:-configured})${NC}"
        else
            echo -e "  ${RED}[ABSENT]${NC} $f"
        fi
    done
    
    # Proxy list stats
    if [ -f "$PROXY_LIST_FILE" ]; then
        echo ""
        echo -e "${BOLD}Proxy Pool:${NC}"
        local total=$(wc -l < "$PROXY_LIST_FILE")
        echo -e "  ${CYAN}$total proxies available${NC} in $PROXY_LIST_FILE"
        
        # Current proxy index
        if [ -f "$CURRENT_PROXY_INDEX_FILE" ]; then
            local idx=$(cat "$CURRENT_PROXY_INDEX_FILE")
            echo -e "  Current index: ${YELLOW}$idx${NC}"
        fi
    fi
}

# ─── List Proxies ─────────────────────────────────────────────
list_proxies() {
    local filter="${1:-}"
    
    if [ ! -f "$PROXY_LIST_FILE" ] || [ ! -s "$PROXY_LIST_FILE" ]; then
        echo -e "${YELLOW}[!] No proxy list found. Run './proxy-manager.sh fetch' first.${NC}"
        return
    fi
    
    local total=$(wc -l < "$PROXY_LIST_FILE")
    echo -e "${GREEN}Total proxies: $total${NC}"
    echo ""
    
    if [ -n "$filter" ]; then
        grep -i "$filter" "$PROXY_LIST_FILE" | head -50 | while read -r line; do
            echo "  ${CYAN}▪${NC} $line"
        done
    else
        head -50 "$PROXY_LIST_FILE" | while read -r line; do
            echo "  ${CYAN}▪${NC} $line"
        done
        if [ "$total" -gt 50 ]; then
            echo "  ${YELLOW}... and $((total - 50)) more${NC}"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════

case "${1:-status}" in
    start|on|enable)
        echo -e "${YELLOW}[*] Setting proxy — ${PROXY_HOST}:${PROXY_PORT}${NC}"
        backup_env
        set_proxy_vars "$PROXY_HOST" "$PROXY_PORT"
        
        # Apply to services
        apply_proxy_system "$PROXY_HOST" "$PROXY_PORT"
        
        # Shell persistence
        rcfile="$HOME/.bashrc"
        [ -n "$ZSH_VERSION" ] && rcfile="$HOME/.zshrc"
        if ! grep -q "### PROXY-MANAGER ###" "$rcfile" 2>/dev/null; then
            cat >> "$rcfile" << 'EOF'

### PROXY-MANAGER ###
if [ -f /tmp/.proxy_env ]; then
    source /tmp/.proxy_env
fi
### END PROXY-MANAGER ###
EOF
        fi
        
        echo -e "${GREEN}[✓]${NC} Proxy enabled system-wide (${PROXY_HOST}:${PROXY_PORT})"
        ;;
    
    rotate|dynamic)
        interval="${2:-$ROTATE_INTERVAL}"
        rotate_ip "$interval"
        ;;
    
    daemon|background)
        interval="${2:-$ROTATE_INTERVAL}"
        start_rotator "$interval"
        ;;
    
    stop|off|disable)
        # Stop rotator if running
        stop_rotator
        
        echo -e "${YELLOW}[*] Removing proxy — restoring defaults${NC}"
        restore_env
        
        for var in http https ftp; do
            unset_proxy "$var"
        done
        
        # Remove config files
        sudo rm -f /etc/apt/apt.conf.d/99proxy
        for f in /etc/systemd/system.conf.d/proxy.conf /etc/systemd/user.conf.d/proxy.conf /etc/systemd/system/docker.service.d/proxy.conf; do
            sudo rm -f "$f"
        done
        sudo systemctl daemon-reload 2>/dev/null
        rm -f /tmp/.proxy_env 2>/dev/null
        
        # Desktop
        command -v gsettings &>/dev/null && gsettings set org.gnome.system.proxy mode 'none' 2>/dev/null
        
        echo -e "${GREEN}[✓]${NC} Proxy disabled system-wide"
        ;;
    
    fetch|update)
        country="${2:-}"
        fetch_proxies "$country"
        ;;
    
    list)
        list_proxies "$2"
        ;;
    
    status|info)
        show_status
        ;;
    
    test)
        host="${2:-$PROXY_HOST}"
        port="${3:-$PROXY_PORT}"
        echo -e "${YELLOW}[*] Testing proxy ${host}:${port}...${NC}"
        if check_proxy "$host" "$port"; then
            echo -e "${GREEN}[✓]${NC} Proxy ${host}:${port} is ${GREEN}ALIVE${NC}"
        else
            echo -e "${RED}[✗]${NC} Proxy ${host}:${port} is ${RED}DEAD${NC}"
        fi
        ;;
    
    *)
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║           Dynamic Proxy Manager - Usage                    ║"
        echo "╚══════════════════════════════════════════════════════════════╝"
        echo ""
        echo "Commands:"
        echo "  start                  - Set static proxy (127.0.0.1:8080)"
        echo "  stop                   - Disable proxy and restore"
        echo "  status                 - Show current proxy status"
        echo ""
        echo "  rotate [interval]      - Rotate IPs interactively (default ${ROTATE_INTERVAL}s)"
        echo "  daemon [interval]      - Run rotator in background"
        echo "  fetch [country]        - Fetch fresh proxies from web"
        echo "  list [filter]          - List available proxies"
        echo "  test [host] [port]     - Test if a proxy is alive"
        echo ""
        echo "Examples:"
        echo "  ./proxy-manager.sh rotate 10       # Rotate every 10 seconds"
        echo "  ./proxy-manager.sh daemon 30       # Background rotation every 30s"
        echo "  ./proxy-manager.sh fetch           # Fetch fresh proxy list"
        echo "  ./proxy-manager.sh list            # List all proxies"
        echo "  ./proxy-manager.sh test 1.2.3.4 8080"
        echo ""
        echo "With sudo (your root password):"
        echo "  echo 'ajay12' | sudo -S ./proxy-manager.sh rotate 15"
        exit 1
        ;;
esac