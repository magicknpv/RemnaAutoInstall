#!/bin/bash
# =============================================================================
# RemnaWave Node Auto-Installer v2.5 — Beszel Agent with D-Bus support
# =============================================================================

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Пути
STATE_DIR="/var/lib/remnawave-installer"
NODE_DIR="/opt/remnanode"
AGENT_DIR="/opt/beszel-agent"
ZT_IP_FILE="/tmp/zt_ip.txt"
ZT_SUBNET="172.23.0.0/16"
SSH_CONFIG_FILE="/etc/ssh/sshd_config"
SSH_CONFIG_BACKUP="/etc/ssh/sshd_config.backup.remnawave"
SSH_KEY_WATCH_PATH="/root/.ssh/authorized_keys"

# Логирование
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
log_error()   { echo -e "${RED}[✗]${NC} $1"; }
log_skip()    { echo -e "${CYAN}[→]${NC} $1 (уже установлено, пропускаю)"; }

init_state() { mkdir -p "$STATE_DIR"; }
is_installed() { [[ -f "$STATE_DIR/$1" ]]; }
mark_installed() { touch "$STATE_DIR/$1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт должен быть запущен от root (sudo)"
        exit 1
    fi
}

# =============================================================================
# 🔧 FIX: Обработка broken apt репозиториев
# =============================================================================
fix_broken_repos() {
    log_info "Проверяю apt репозитории..."
    local update_output
    update_output=$(apt-get update -qq 2>&1) || true
    
    if echo "$update_output" | grep -qiE "release|404|not found"; then
        log_warn "Найдены проблемы с репозиториями, исправляю..."
        local repos_to_disable="ookla docker-ce zerotier"
        for repo_name in $repos_to_disable; do
            find /etc/apt/sources.list.d/ -name "*${repo_name}*" -type f 2>/dev/null | while read -r repo_file; do
                if [[ -f "$repo_file" ]]; then
                    log_warn "Отключаю: $repo_file"
                    mv "$repo_file" "${repo_file}.disabled" 2>/dev/null || true
                fi
            done
        done
        apt-get update -qq --allow-releaseinfo-change 2>/dev/null || true
        log_success "Репозитории обработаны"
    else
        log_success "Репозитории в порядке"
    fi
}

# =============================================================================
# 1. DOCKER
# =============================================================================
install_docker() {
    if is_installed "docker"; then log_skip "Docker"; return 0; fi
    log_info "Проверка Docker..."
    if ! command -v docker &> /dev/null; then
        log_info "Docker не найден, устанавливаю..."
        fix_broken_repos
        if curl -fsSL https://get.docker.com -o /tmp/install-docker.sh 2>/dev/null; then
            if sh /tmp/install-docker.sh 2>&1; then
                log_success "Docker установлен"
            else
                log_warn "Пробую apt..."
                apt-get install -y docker.io docker-compose 2>/dev/null || true
            fi
            rm -f /tmp/install-docker.sh
        else
            log_warn "Не удалось скачать, пробую apt..."
            apt-get install -y docker.io docker-compose 2>/dev/null || true
        fi
        if command -v docker &> /dev/null; then
            systemctl enable --now docker 2>/dev/null || true
            log_success "Docker готов"
        else
            log_error "Не удалось установить Docker"
            return 1
        fi
    else
        log_success "Docker уже установлен"
    fi
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null 2>&1; then
        log_info "Установка docker compose..."
        apt-get update -qq 2>/dev/null || true
        apt-get install -y docker-compose-plugin 2>/dev/null || apt-get install -y docker-compose 2>/dev/null || true
    fi
    mark_installed "docker"
}

# =============================================================================
# 2. REMNAWAVE NODE
# =============================================================================
install_remnawave_node() {
    if is_installed "remnawave_node"; then
        log_skip "RemnaWave node"
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qi remna; then
            log_warn "Контейнеры не запущены, перезапускаю..."
            cd "$NODE_DIR" && docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null || true
        fi
        return 0
    fi
    log_info "=== Установка RemnaWave Node ==="
    mkdir -p "$NODE_DIR"; cd "$NODE_DIR"
    if [[ -f docker-compose.yml ]]; then
        log_warn "docker-compose.yml уже существует"
        read -p "Перезаписать? [y/N]: " -n 1 -r; echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo ""; log_info "Вставьте новое содержимое (Ctrl+D):"; echo "--- НАЧНИТЕ ---"
            COMPOSE_CONTENT=$(cat)
            [[ -n "$COMPOSE_CONTENT" ]] && echo "$COMPOSE_CONTENT" > docker-compose.yml && log_success "Обновлён"
        fi
    else
        echo ""; log_info "Вставьте docker-compose.yml из панели (Ctrl+D):"; echo "--- НАЧНИТЕ ---"
        COMPOSE_CONTENT=$(cat)
        [[ -z "$COMPOSE_CONTENT" ]] && { log_error "Пустой ввод"; exit 1; }
        echo "$COMPOSE_CONTENT" > docker-compose.yml; log_success "Сохранён"
    fi
    if echo "$COMPOSE_CONTENT" 2>/dev/null | grep -q "env_file:" || [[ -f .env ]]; then
        if [[ ! -f .env ]]; then
            echo ""; log_info "Вставьте .env или нажмите Enter:"; ENV_CONTENT=$(cat)
            [[ -n "$ENV_CONTENT" ]] && echo "$ENV_CONTENT" > .env && log_success ".env сохранён"
        fi
    fi
    log_info "Запускаю контейнеры..."
    docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null || true
    sleep 5
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qi remna; then
        log_success "RemnaWave запущена"; mark_installed "remnawave_node"
    else
        log_warn "Проверьте: cd $NODE_DIR && docker compose logs -f"
    fi
}

# =============================================================================
# 3. ZEROTIER
# =============================================================================
get_zerotier_ip() {
    local ip=""
    ip=$(zerotier-cli listnetworks 2>/dev/null | grep -v "^200 listnetworks <nwid>" | awk '{print $NF}' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -z "$ip" ]]; then
        ip=$(zerotier-cli listnetworks -j 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | head -1 | cut -d'/' -f1)
    fi
    echo "$ip"
}

setup_zerotier() {
    if is_installed "zerotier"; then
        log_skip "ZeroTier"
        if [[ ! -f "$ZT_IP_FILE" ]] || [[ -z "$(cat "$ZT_IP_FILE" 2>/dev/null)" ]]; then
            ZT_IP=$(get_zerotier_ip)
            [[ -n "$ZT_IP" ]] && echo "$ZT_IP" > "$ZT_IP_FILE" && log_success "IP получен: $ZT_IP"
        fi
        return 0
    fi
    log_info "=== Настройка ZeroTier ==="
    if ! command -v zerotier-cli &> /dev/null; then
        log_info "Устанавливаю ZeroTier..."; curl -s https://install.zerotier.com | sudo bash
        systemctl enable --now zerotier-one; log_success "ZeroTier установлен"
    else
        log_success "ZeroTier уже установлен"
    fi
    EXISTING_NET=$(zerotier-cli listnetworks 2>/dev/null | grep -v "^200 listnetworks <nwid>" | awk '{print $1}' | head -1)
    if [[ -n "$EXISTING_NET" ]]; then
        log_warn "Уже подключён к сети: $EXISTING_NET"
        read -p "Использовать её? [Y/n]: " -n 1 -r; echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            echo ""; read -p "Введите новый Network ID: " ZT_NETWORK_ID
            [[ -n "$ZT_NETWORK_ID" ]] && { zerotier-cli leave "$EXISTING_NET" 2>/dev/null || true; zerotier-cli join "$ZT_NETWORK_ID"; }
        else
            ZT_NETWORK_ID="$EXISTING_NET"
        fi
    else
        echo ""; read -p "Введите ZeroTier Network ID: " ZT_NETWORK_ID
        [[ -z "$ZT_NETWORK_ID" ]] && { log_error "Пустой ID"; exit 1; }
        log_info "Подключаюсь: $ZT_NETWORK_ID"; zerotier-cli join "$ZT_NETWORK_ID"
    fi
    log_info "Ожидаю IP (до 90 сек)..."
    ZT_IP=""; for i in {1..18}; do
        sleep 5
        ZT_IP=$(get_zerotier_ip)
        [[ -n "$ZT_IP" ]] && { log_success "✓ IP: $ZT_IP"; break; }
        log_info "Попытка $i/18..."
    done
    if [[ -z "$ZT_IP" ]]; then
        log_error "✗ Не получен IP"; zerotier-cli listnetworks
        log_warn "Авторизуйте ноду в https://my.zerotier.com"
        exit 1
    fi
    echo "$ZT_IP" > "$ZT_IP_FILE"; export ZT_IP; mark_installed "zerotier"
}

# =============================================================================
# 4. PROMETHEUS + NODE EXPORTER
# =============================================================================
install_prometheus_monitoring() {
    ZT_IP=$(cat "$ZT_IP_FILE" 2>/dev/null || echo "")
    # Node Exporter
    if ! is_installed "node_exporter"; then
        log_info "=== Node Exporter ==="
        if ! command -v node_exporter &> /dev/null; then
            log_info "Устанавливаю..."; cd /tmp
            wget -q https://github.com/prometheus/node_exporter/releases/download/v1.7.0/node_exporter-1.7.0.linux-amd64.tar.gz
            tar -xzf node_exporter-1.7.0.linux-amd64.tar.gz
            mv node_exporter-1.7.0.linux-amd64/node_exporter /usr/local/bin/
            rm -rf node_exporter-*; chmod +x /usr/local/bin/node_exporter
            log_success "Установлен"
        fi
        if [[ ! -f /etc/systemd/system/node_exporter.service ]]; then
            cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Node Exporter
After=network.target
[Service]
User=root
ExecStart=/usr/local/bin/node_exporter --collector.systemd --web.listen-address=:9100
Restart=always
[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload; systemctl enable --now node_exporter; sleep 2
        fi
        systemctl is-active --quiet node_exporter && { log_success "Запущен"; mark_installed "node_exporter"; } || log_warn "Не запустился"
    else
        log_skip "Node Exporter"
    fi
    # Prometheus
    if ! is_installed "prometheus"; then
        log_info "=== Prometheus ==="
        if ! command -v prometheus &> /dev/null; then
            log_info "Устанавливаю..."; cd /tmp
            wget -q https://github.com/prometheus/prometheus/releases/download/v2.48.0/prometheus-2.48.0.linux-amd64.tar.gz
            tar -xzf prometheus-2.48.0.linux-amd64.tar.gz
            mv prometheus-2.48.0.linux-amd64/prometheus /usr/local/bin/
            mv prometheus-2.48.0.linux-amd64/promtool /usr/local/bin/
            mkdir -p /etc/prometheus /var/lib/prometheus
            rm -rf prometheus-*
            log_success "Установлен"
        fi
        if [[ -n "$ZT_IP" ]]; then
            cat > /etc/prometheus/prometheus.yml << EOF
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['${ZT_IP}:9090']
  - job_name: 'node_exporter'
    static_configs:
      - targets: ['${ZT_IP}:9100']
EOF
        fi
        if [[ ! -f /etc/systemd/system/prometheus.service ]]; then
            cat > /etc/systemd/system/prometheus.service << EOF
[Unit]
Description=Prometheus
After=network.target
[Service]
User=root
ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus/ --web.listen-address=0.0.0.0:9090 --web.enable-lifecycle
Restart=always
[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload; systemctl enable --now prometheus
        fi
        systemctl is-active --quiet prometheus && { log_success "Запущен"; mark_installed "prometheus"; } || log_warn "Не запустился"
    else
        log_skip "Prometheus"
    fi
    [[ -n "$ZT_IP" ]] && log_success "Prometheus UI: http://${ZT_IP}:9090"
}

# =============================================================================
# 5. BESZEL AGENT ✨ ОБНОВЛЁННЫЙ КОНФИГ ✨
# =============================================================================
install_beszel_agent() {
    if is_installed "beszel_agent"; then
        log_skip "Beszel Agent"
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q beszel-agent; then
            log_warn "Контейнер не запущен, перезапускаю..."
            cd "$AGENT_DIR" && docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null || true
        fi
        return 0
    fi
    
    log_info "=== Установка Beszel Agent (с D-Bus) ==="
    mkdir -p "$AGENT_DIR"; cd "$AGENT_DIR"
    
    # ✅ ОБНОВЛЁННЫЙ docker-compose.yml с поддержкой D-Bus и опциональными монтированиями
    cat > docker-compose.yml << 'EOF'
services:
  beszel-agent:
    image: henrygd/beszel-agent
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./beszel_agent_data:/var/lib/beszel-agent
      # D-Bus socket for system monitoring (required for some metrics)
      - /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:ro
      # Optional: systemd private socket for deeper system metrics
      # - /var/run/systemd/private:/var/run/systemd/private:ro
      # Optional: Monitor other disks/partitions by mounting in /extra-filesystems
      # Example: - /mnt/disk/.beszel:/extra-filesystems/sda1:ro
    environment:
      LISTEN: 45876
      KEY: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEYYsnCnXR6dh5nNdLY1ijqgWP6JzrbbFYcRSJF2m0gQ'
      TOKEN: f887063c-6966-45a7-a5af-ec68ae2a341d
      HUB_URL: https://beszel.serv2x.ru
    # Optional: Disable AppArmor if needed
    # security_opt:
    #   - apparmor:unconfined
EOF
    
    # Создаём директорию для данных
    mkdir -p beszel_agent_data
    
    log_info "Запускаю beszel-agent..."
    if docker compose version &> /dev/null 2>&1; then
        docker compose up -d
    else
        docker-compose up -d
    fi
    
    sleep 3
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q beszel-agent; then
        log_success "Beszel agent запущен"; mark_installed "beszel_agent"
    else
        log_warn "Проверьте: docker logs beszel-agent"
    fi
}

# =============================================================================
# 6. SSH HARDENING + SAFE KEY WAIT
# =============================================================================
configure_ssh() {
    if is_installed "ssh_hardening"; then log_skip "SSH"; return 0; fi
    log_info "=== SSH Hardening (Safe Key Wait) ==="
    log_warn "⚠️  Парольный доступ будет отключён! Не закрывайте окно!"
    [[ ! -f "$SSH_CONFIG_BACKUP" ]] && cp "$SSH_CONFIG_FILE" "$SSH_CONFIG_BACKUP" && log_success "Бэкап: $SSH_CONFIG_BACKUP"
    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    touch "$SSH_KEY_WATCH_PATH"; chmod 600 "$SSH_KEY_WATCH_PATH"
    cat > "$SSH_CONFIG_FILE" << 'EOF'
Port 22
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication no
UsePAM no
PubkeyAcceptedKeyTypes +ssh-ed25519,ecdsa-sha2-nistp256
Subsystem sftp /usr/lib/openssh/sftp-server
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 60
X11Forwarding no
AllowTcpForwarding no
PermitEmptyPasswords no
EOF
    log_success "Конфиг применён"
    if ! sshd -t 2>&1; then
        log_error "❌ Ошибка валидации! Восстанавливаю бэкап..."
        cp "$SSH_CONFIG_BACKUP" "$SSH_CONFIG_FILE"; exit 1
    fi
    log_success "Конфиг валиден ✓"
    echo ""; echo -e "${MAGENTA}╔════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║${NC}  🔐 ДОБАВЬТЕ КЛЮЧ СЕЙЧАС  ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════╝${NC}"; echo ""
    log_info "В новом окне:"
    echo "  ssh-copy-id -i ~/.ssh/id_ed25519.pub root@$(cat "$ZT_IP_FILE" 2>/dev/null || echo 'IP')"
    echo "  ИЛИ: nano /root/.ssh/authorized_keys"; echo ""
    INITIAL_KEYS=$(wc -l < "$SSH_KEY_WATCH_PATH" 2>/dev/null || echo 0)
    [[ "$INITIAL_KEYS" -eq 0 ]] && log_warn "⚠️  authorized_keys пуст! Добавьте ключ!"
    while true; do
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -p "Ключ добавлен? Могу перезапустить SSH? [y/N]: " -n 1 -r; echo
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            CURRENT_KEYS=$(wc -l < "$SSH_KEY_WATCH_PATH" 2>/dev/null || echo 0)
            if [[ "$CURRENT_KEYS" -eq 0 ]]; then
                log_error "❌ Файл пуст! Не перезапускаю SSH!"; continue
            fi
            log_warn "⚠️  ФИНАЛЬНО: пароль больше не сработает! Подтвердить рестарт? [y/N]: "
            read -p "" -n 1 -r; echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then break; else log_info "Отменено"; return 0; fi
        else
            log_info "Отменено. Для ручного рестарта: systemctl restart ssh"; return 0
        fi
    done
    log_info "Перезапускаю SSH..."; systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        log_success "✓ SSH работает"
    else
        log_error "❌ SSH не запустился! Восстанавливаю..."; cp "$SSH_CONFIG_BACKUP" "$SSH_CONFIG_FILE"; systemctl restart ssh 2>/dev/null || true; exit 1
    fi
    cat > /etc/systemd/system/ssh-key-watcher.service << 'EOF'
[Unit]
Description=Restart SSH on key change
[Service]
Type=oneshot
ExecStart=/bin/systemctl restart ssh
ExecStartPre=/bin/bash -c 'systemctl restart sshd 2>/dev/null || true'
RemainAfterExit=yes
EOF
    cat > /etc/systemd/system/ssh-key-watcher.path << EOF
[Unit]
Description=Watch authorized_keys
[Path]
PathChanged=$SSH_KEY_WATCH_PATH
Unit=ssh-key-watcher.service
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable --now ssh-key-watcher.path 2>/dev/null || true
    log_success "Watcher настроен"
    mark_installed "ssh_hardening"
    echo ""; log_success "✓ SSH Hardening завершён! Ключей: $(wc -l < "$SSH_KEY_WATCH_PATH")"
}

# =============================================================================
# 7. IPTABLES
# =============================================================================
configure_firewall() {
    if is_installed "iptables_rules"; then log_skip "iptables"; return 0; fi
    log_info "=== iptables ==="
    # 9090
    iptables -C INPUT -p tcp -s "$ZT_SUBNET" --dport 9090 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp -s "$ZT_SUBNET" --dport 9090 -j ACCEPT
    iptables -C INPUT -p tcp --dport 9090 -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport 9090 -j DROP
    # 9100
    iptables -C INPUT -p tcp -s "$ZT_SUBNET" --dport 9100 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp -s "$ZT_SUBNET" --dport 9100 -j ACCEPT
    iptables -C INPUT -p tcp --dport 9100 -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport 9100 -j DROP
    mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    apt-get install -y iptables-persistent 2>/dev/null || true
    mark_installed "iptables_rules"
    log_success "Правила применены"
}

# =============================================================================
# УТИЛИТЫ
# =============================================================================
show_status() {
    echo -e "\n${CYAN}📊 Статус:${NC}"; echo "━━━━━━━━━━━━━━━━━━━━"
    for comp in docker remnawave_node zerotier node_exporter prometheus beszel_agent ssh_hardening iptables_rules; do
        local name="${comp//_/ }"; name="${name^}"
        printf "%-20s %s\n" "$name:" "$(is_installed "$comp" && echo -e "${GREEN}✓${NC}" || echo -e "${YELLOW}○${NC}")"
    done
    echo "━━━━━━━━━━━━━━━━━━━━"
    [[ -f "$ZT_IP_FILE" ]] && echo "🌐 ZeroTier IP: $(cat "$ZT_IP_FILE")"
    [[ -f "$SSH_KEY_WATCH_PATH" ]] && echo "🔐 SSH ключей: $(wc -l < "$SSH_KEY_WATCH_PATH" 2>/dev/null || echo 0)"; echo ""
}

reset_installation() {
    log_warn "Сброс меток установки?"; read -p "[y/N]: " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] && rm -rf "$STATE_DIR" && log_success "Сброшено" || log_info "Отменено"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo -e "${GREEN}╔════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  RemnaWave Installer v2.5  ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════╝${NC}"; echo ""
    check_root; init_state
    case "${1:-}" in
        --status|-s) show_status; exit 0 ;;
        --reset|-r) reset_installation; exit 0 ;;
        --help|-h) echo "Использование: $0 [--status|--reset|--help]"; exit 0 ;;
    esac
    show_status
    echo "Этапы (установленные пропускаются):"
    echo "  1. Docker  2. RemnaWave  3. ZeroTier  4. Prometheus+Node"
    echo "  5. Beszel (D-Bus)  6. 🔐 SSH (Safe)  7. iptables"; echo ""
    read -p "Продолжить? [y/N]: " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "Отменено"; exit 0; }; echo ""
    install_docker; echo ""
    install_remnawave_node; echo ""
    setup_zerotier; echo ""
    install_prometheus_monitoring; echo ""
    install_beszel_agent; echo ""
    configure_ssh; echo ""
    configure_firewall; echo ""
    show_status
    echo -e "${GREEN}✓ Готово!${NC}"
    echo "Полезное:"
    echo "  • SSH: ssh root@$(cat "$ZT_IP_FILE" 2>/dev/null || echo IP)"
    echo "  • Prometheus: http://$(cat "$ZT_IP_FILE" 2>/dev/null):9090"
    echo "  • Beszel: https://beszel.serv2x.ru"
    echo "  • Статус: $0 --status"; echo ""
    log_info "Авторизуйте ноду в ZeroTier: https://my.zerotier.com"
}

main "$@"