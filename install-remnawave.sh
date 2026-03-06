#!/bin/bash
# =============================================================================
# RemnaWave Node Auto-Installer with ZeroTier + Prometheus + Monitoring
# Версия 2.3 — Fix: обработка broken apt repos при установке Docker
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

# Пути и константы
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Инициализация директории состояния
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
# 🛠️ УТИЛИТА: Исправление broken apt репозиториев
# =============================================================================
fix_broken_repos() {
    log_info "Проверяю apt репозитории на ошибки..."
    
    # Пробуем apt-get update, ловим ошибки
    if ! apt-get update -qq 2>&1 | tee /tmp/apt_update.log | grep -q "Release\|NO_PUBKEY\|404"; then
        log_success "Все репозитории в порядке"
        return 0
    fi
    
    log_warn "Обнаружены проблемы с репозиториями, пытаюсь исправить..."
    
    # Список известных проблемных репозиториев для Ubuntu Noble
    local PROBLEM_REPOS=(
        "ookla/speedtest-cli"
        "docker-ce"
        "zerotier"
    )
    
    for repo in "${PROBLEM_REPOS[@]}"; do
        for file in /etc/apt/sources.list.d/*"${repo}"*.list /etc/apt/sources.list.d/*"${repo}"*.sources 2>/dev/null; do
            if [[ -f "$file" ]]; then
                log_warn "Временно отключаю проблемный репозиторий: $(basename "$file")"
                mv "$file" "${file}.disabled" 2>/dev/null || true
            fi
        done
    done
    
    # Пробуем ещё раз update
    if apt-get update -qq 2>/dev/null; then
        log_success "Проблемы с репозиториями устранены"
        return 0
    else
        log_warn "Не все репозитории удалось исправить, продолжаю с --allow-releaseinfo-change"
        apt-get update -qq --allow-releaseinfo-change 2>/dev/null || true
        return 0  # Не прерываем установку из-за repos
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
        
        # 🔧 Исправляем broken repos перед установкой
        fix_broken_repos
        
        # Устанавливаем Docker с обработкой ошибок
        if curl -fsSL https://get.docker.com -o /tmp/install-docker.sh 2>/dev/null; then
            sh /tmp/install-docker.sh 2>&1 | tee /tmp/docker_install.log || {
                log_warn "Docker install script завершился с ошибкой, пробую альтернативный метод..."
                apt-get install -y docker.io docker-compose 2>/dev/null || true
            }
            rm -f /tmp/install-docker.sh
        else
            log_warn "Не удалось скачать Docker install script, пробую apt..."
            apt-get update -qq --allow-releaseinfo-change 2>/dev/null || true
            apt-get install -y docker.io docker-compose 2>/dev/null || true
        fi
        
        # Проверяем результат
        if command -v docker &> /dev/null; then
            systemctl enable --now docker 2>/dev/null || true
            log_success "Docker установлен"
        else
            log_error "Не удалось установить Docker"
            log_warn "Попробуйте установить вручную: curl -fsSL https://get.docker.com | sh"
            return 1
        fi
    else
        log_success "Docker уже установлен"
    fi
    
    # Docker Compose plugin
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        log_info "Установка docker compose plugin..."
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
        if ! docker ps --format '{{.Names}}' | grep -qi remna; then
            log_warn "Контейнеры RemnaWave не запущены, перезапускаю..."
            cd "$NODE_DIR" && (docker compose up -d 2>/dev/null || docker-compose up -d)
        fi
        return 0
    fi
    log_info "=== Установка RemnaWave Node ==="
    mkdir -p "$NODE_DIR"; cd "$NODE_DIR"
    if [[ -f docker-compose.yml ]]; then
        log_warn "docker-compose.yml уже существует в $NODE_DIR"
        read -p "Перезаписать? [y/N]: " -n 1 -r; echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo ""; log_info "Вставьте НОВОЕ содержимое docker-compose.yml (Ctrl+D):"
            echo "--- НАЧНИТЕ ВВОД ---"; COMPOSE_CONTENT=$(cat)
            [[ -n "$COMPOSE_CONTENT" ]] && echo "$COMPOSE_CONTENT" > docker-compose.yml && log_success "docker-compose.yml обновлён"
        else log_info "Использую существующий docker-compose.yml"; fi
    else
        echo ""; log_info "Вставьте содержимое docker-compose.yml из панели RemnaWave:"
        log_info "(нажмите Ctrl+D когда закончите ввод)"; echo "--- НАЧНИТЕ ВВОД ---"
        COMPOSE_CONTENT=$(cat)
        [[ -z "$COMPOSE_CONTENT" ]] && { log_error "Пустое содержимое docker-compose.yml"; exit 1; }
        echo "$COMPOSE_CONTENT" > docker-compose.yml; log_success "docker-compose.yml сохранён в $NODE_DIR"
    fi
    if echo "$COMPOSE_CONTENT" 2>/dev/null | grep -q "env_file:" || [[ -f .env ]]; then
        if [[ ! -f .env ]]; then
            echo ""; log_info "Вставьте содержимое .env файла (или Enter для пропуска):"
            ENV_CONTENT=$(cat); [[ -n "$ENV_CONTENT" ]] && echo "$ENV_CONTENT" > .env && log_success ".env сохранён"
        fi
    fi
    log_info "Запускаю контейнеры RemnaWave..."
    (docker compose version &> /dev/null && docker compose up -d) || docker-compose up -d
    sleep 5
    if docker ps --format '{{.Names}}' | grep -qi remna; then
        log_success "RemnaWave node запущена"; mark_installed "remnawave_node"
    else log_warn "Проверьте логи: cd $NODE_DIR && docker compose logs -f"; fi
}

# =============================================================================
# 3. ZEROTIER
# =============================================================================
get_zerotier_ip() {
    local ip=""
    ip=$(zerotier-cli listnetworks 2>/dev/null | grep -v "^200 listnetworks <nwid>" | awk '{print $NF}' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [[ -z "$ip" ]] && ip=$(zerotier-cli listnetworks -j 2>/dev/null | grep -oE '"assignedAddresses":\["[^"]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [[ -z "$ip" ]] && command -v jq &> /dev/null && ip=$(zerotier-cli listnetworks -j 2>/dev/null | jq -r '.[]?.assignedAddresses?[0] // empty' 2>/dev/null | cut -d'/' -f1 | head -1)
    echo "${ip%%/*}"
}

setup_zerotier() {
    if is_installed "zerotier"; then
        log_skip "ZeroTier"
        if [[ ! -f "$ZT_IP_FILE" ]] || [[ -z "$(cat "$ZT_IP_FILE" 2>/dev/null)" ]]; then
            log_warn "ZeroTier установлен, но IP не сохранён, пытаюсь получить..."
            ZT_IP=$(get_zerotier_ip); [[ -n "$ZT_IP" ]] && echo "$ZT_IP" > "$ZT_IP_FILE" && log_success "ZeroTier IP получен: $ZT_IP"
        fi
        return 0
    fi
    log_info "=== Настройка ZeroTier ==="
    if ! command -v zerotier-cli &> /dev/null; then
        log_info "Устанавливаю ZeroTier..."; curl -s https://install.zerotier.com | sudo bash
        systemctl enable --now zerotier-one; log_success "ZeroTier установлен"
    else log_success "ZeroTier уже установлен"; fi
    EXISTING_NET=$(zerotier-cli listnetworks 2>/dev/null | grep -v "^200 listnetworks <nwid>" | awk '{print $1}' | head -1)
    if [[ -n "$EXISTING_NET" ]]; then
        log_warn "ZeroTier уже подключён к сети: $EXISTING_NET"
        read -p "Использовать эту сеть? [Y/n]: " -n 1 -r; echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            echo ""; read -p "Введите НОВЫЙ ZeroTier Network ID: " ZT_NETWORK_ID
            [[ -n "$ZT_NETWORK_ID" ]] && { zerotier-cli leave "$EXISTING_NET" 2>/dev/null || true; zerotier-cli join "$ZT_NETWORK_ID"; }
        else ZT_NETWORK_ID="$EXISTING_NET"; fi
    else
        echo ""; read -p "Введите ZeroTier Network ID: " ZT_NETWORK_ID
        [[ -z "$ZT_NETWORK_ID" ]] && { log_error "Network ID не может быть пустым"; exit 1; }
        log_info "Подключаюсь к сети: $ZT_NETWORK_ID"; zerotier-cli join "$ZT_NETWORK_ID"
    fi
    log_info "Ожидаю получения IP (макс. 90 сек)..."
    ZT_IP=""; for i in {1..18}; do
        sleep 5; local status=$(zerotier-cli listnetworks 2>/dev/null | grep -v "^200 listnetworks <nwid>" | head -1)
        log_info "Попытка $i/18: $status"; ZT_IP=$(get_zerotier_ip)
        [[ -n "$ZT_IP" ]] && { log_success "✓ Получен ZeroTier IP: $ZT_IP"; break; }
    done
    [[ -z "$ZT_IP" ]] && { log_error "✗ Не удалось получить IP адрес"; zerotier-cli listnetworks; log_warn "Авторизуйте ноду в https://my.zerotier.com"; exit 1; }
    echo "$ZT_IP" > "$ZT_IP_FILE"; export ZT_IP; mark_installed "zerotier"
}

# =============================================================================
# 4. PROMETHEUS + NODE EXPORTER
# =============================================================================
install_prometheus_monitoring() {
    ZT_IP=$(cat "$ZT_IP_FILE" 2>/dev/null || echo "")
    # Node Exporter
    if ! is_installed "node_exporter"; then
        log_info "=== Установка Node Exporter ==="
        if ! command -v node_exporter &> /dev/null; then
            log_info "Устанавливаю node_exporter..."; NODE_EXPORTER_VERSION="1.7.0"; cd /tmp
            wget -q https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
            tar -xzf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
            mv node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
            rm -rf node_exporter-*; chmod +x /usr/local/bin/node_exporter; log_success "node_exporter установлен"
        else log_success "node_exporter уже установлен"; fi
        if [[ ! -f /etc/systemd/system/node_exporter.service ]]; then
            cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
After=network.target
[Service]
User=root
ExecStart=/usr/local/bin/node_exporter --collector.systemd --web.listen-address=:9100
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload; systemctl enable --now node_exporter; sleep 2
        fi
        systemctl is-active --quiet node_exporter && { log_success "node_exporter запущен"; mark_installed "node_exporter"; } || log_warn "node_exporter не запустился"
    else log_skip "Node Exporter"; fi
    # Prometheus
    if ! is_installed "prometheus"; then
        log_info "=== Установка Prometheus ==="
        if ! command -v prometheus &> /dev/null; then
            log_info "Устанавливаю Prometheus..."; PROMETHEUS_VERSION="2.48.0"; cd /tmp
            wget -q https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
            tar -xzf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
            mv prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus /usr/local/bin/
            mv prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool /usr/local/bin/
            mkdir -p /etc/prometheus /var/lib/prometheus
            cp -r prometheus-${PROMETHEUS_VERSION}.linux-amd64/consoles /etc/prometheus/ 2>/dev/null || true
            cp -r prometheus-${PROMETHEUS_VERSION}.linux-amd64/console_libraries /etc/prometheus/ 2>/dev/null || true
            rm -rf prometheus-*; log_success "Prometheus установлен"
        else log_success "Prometheus уже установлен"; fi
        if [[ -n "$ZT_IP" ]]; then
            log_info "Создаю prometheus.yml для IP: $ZT_IP"
            cat > /etc/prometheus/prometheus.yml << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s
rule_files:
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
Description=Prometheus Monitoring System
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
        systemctl is-active --quiet prometheus && { log_success "Prometheus запущен"; mark_installed "prometheus"; } || log_warn "Prometheus не запустился"
    else log_skip "Prometheus"; fi
    [[ -n "$ZT_IP" ]] && log_success "Prometheus UI: http://${ZT_IP}:9090"
}

# =============================================================================
# 5. BESZEL AGENT
# =============================================================================
install_beszel_agent() {
    if is_installed "beszel_agent"; then
        log_skip "Beszel Agent"
        if ! docker ps --format '{{.Names}}' | grep -q beszel-agent; then
            log_warn "Контейнер beszel-agent не запущен, перезапускаю..."
            cd "$AGENT_DIR" && (docker compose up -d 2>/dev/null || docker-compose up -d)
        fi
        return 0
    fi
    log_info "=== Установка Beszel Agent ==="
    mkdir -p "$AGENT_DIR"; cd "$AGENT_DIR"
    cat > docker-compose.yml << 'EOF'
services:
  beszel-agent:
    image: henrygd/beszel-agent
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./beszel_agent_/var/lib/beszel-agent
    environment:
      LISTEN: 45876
      KEY: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEYYsnCnXR6dh5nNdLY1ijqgWP6JzrbbFYcRSJF2m0gQ'
      TOKEN: f887063c-6966-45a7-a5af-ec68ae2a341d
      HUB_URL: https://beszel.serv2x.ru
EOF
    mkdir -p beszel_agent_data
    log_info "Запускаю beszel-agent..."
    (docker compose version &> /dev/null && docker compose up -d) || docker-compose up -d
    sleep 3
    if docker ps --format '{{.Names}}' | grep -q beszel-agent; then
        log_success "Beszel agent запущен"; mark_installed "beszel_agent"
    else log_warn "Проверьте: docker logs beszel-agent"; fi
}

# =============================================================================
# 6. SSH HARDENING + SAFE KEY WAIT
# =============================================================================
configure_ssh() {
    if is_installed "ssh_hardening"; then
        log_skip "SSH конфигурация"
        return 0
    fi
    
    log_info "=== Настройка SSH (Hardening + Safe Key Wait) ==="
    echo ""
    log_warn "⚠️  ВНИМАНИЕ: Сейчас будет отключён парольный доступ к SSH!"
    log_warn "⚠️  Не закрывайте это окно пока не добавите свой SSH ключ!"
    echo ""
    
    if [[ ! -f "$SSH_CONFIG_BACKUP" ]]; then
        log_info "Создаю бэкап оригинального sshd_config..."
        cp "$SSH_CONFIG_FILE" "$SSH_CONFIG_BACKUP"
        log_success "Бэкап сохранён: $SSH_CONFIG_BACKUP"
    else
        log_info "Бэкап уже существует: $SSH_CONFIG_BACKUP"
    fi
    
    log_info "Готовлю директорию для SSH ключей..."
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch "$SSH_KEY_WATCH_PATH"
    chmod 600 "$SSH_KEY_WATCH_PATH"
    log_success "Файл создан: $SSH_KEY_WATCH_PATH"
    
    echo ""
    log_info "Текущие ключи в authorized_keys:"
    if [[ -s "$SSH_KEY_WATCH_PATH" ]]; then
        wc -l < "$SSH_KEY_WATCH_PATH" | xargs -I {} echo "  📌 Найдено ключей: {}"
        cat "$SSH_KEY_WATCH_PATH" | head -3 | sed 's/^/    /'
        [[ $(wc -l < "$SSH_KEY_WATCH_PATH") -gt 3 ]] && echo "    ... и ещё $(( $(wc -l < "$SSH_KEY_WATCH_PATH") - 3 ))"
    else
        echo "  ⚠️  Файл пустой! Нужно добавить ключ!"
    fi
    echo ""
    
    log_info "Применяю безопасные настройки SSH (без перезапуска)..."
    cat > "$SSH_CONFIG_FILE" << 'EOF'
# RemnaWave SSH Hardening Config
# Managed by install-remnawave.sh - do not edit manually

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

# Дополнительные безопасные настройки
Protocol 2
X11Forwarding no
AllowTcpForwarding no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
EOF
    log_success "Конфигурация sshd_config применена"
    
    log_info "Валидирую конфигурацию SSH..."
    if sshd -t 2>&1; then
        log_success "Конфигурация SSH валидна ✓"
    else
        log_error "❌ Ошибка валидации sshd_config!"
        log_warn "Восстанавливаю бэкап..."
        cp "$SSH_CONFIG_BACKUP" "$SSH_CONFIG_FILE"
        exit 1
    fi
    
    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║${NC}  🔐 ДОБАВЬТЕ SSH КЛЮЧ ПЕРЕД ПЕРЕЗАПУСКОМ SSH  ${MAGENTA}║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    log_info "Откройте НОВОЕ окно терминала и выполните:"
    echo ""
    echo "  # Вариант 1: Через ssh-copy-id (с вашей локальной машины):"
    echo "  ssh-copy-id -i ~/.ssh/id_ed25519.pub root@$(cat "$ZT_IP_FILE" 2>/dev/null || echo '<SERVER_IP>')"
    echo ""
    echo "  # Вариант 2: Вручную скопировать ключ:"
    echo "  cat ~/.ssh/id_ed25519.pub | ssh root@$(cat "$ZT_IP_FILE" 2>/dev/null || echo '<SERVER_IP>') 'cat >> /root/.ssh/authorized_keys'"
    echo ""
    echo "  # Вариант 3: Если вы уже в сессии — откройте второе окно и добавьте:"
    echo "  nano /root/.ssh/authorized_keys"
    echo "  # (вставьте публичный ключ, сохраните Ctrl+O, выйдите Ctrl+X)"
    echo ""
    log_info "После добавления ключа вернитесь в это окно и подтвердите."
    echo ""
    
    INITIAL_KEY_COUNT=$(wc -l < "$SSH_KEY_WATCH_PATH" 2>/dev/null || echo "0")
    
    if [[ "$INITIAL_KEY_COUNT" -eq 0 ]]; then
        log_warn "⚠️  Файл authorized_keys пустой!"
        log_warn "⚠️  ДОБАВЬТЕ КЛЮЧ сейчас, иначе потеряете доступ после перезапуска SSH!"
        echo ""
    fi
    
    while true; do
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        read -p "Вы добавили SSH ключ и можете войти по ключу? [y/N]: " -n 1 -r
        echo
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            CURRENT_KEY_COUNT=$(wc -l < "$SSH_KEY_WATCH_PATH" 2>/dev/null || echo "0")
            
            if [[ "$CURRENT_KEY_COUNT" -eq 0 ]]; then
                log_error "❌ Файл authorized_keys всё ещё пустой!"
                log_error "❌ Не перезапускаю SSH — вы потеряете доступ!"
                echo ""
                log_warn "Добавьте ключ и повторите подтверждение."
                echo ""
                continue
            fi
            
            if [[ "$CURRENT_KEY_COUNT" -gt "$INITIAL_KEY_COUNT" ]]; then
                log_success "✓ Обнаружен новый ключ в authorized_keys"
            else
                log_warn "! Количество ключей не изменилось (но продолжаю по вашему подтверждению)"
            fi
            
            echo ""
            log_warn "⚠️  ФИНАЛЬНОЕ ПОДТВЕРЖДЕНИЕ:"
            read -p "Вы уверены, что можете войти по SSH ключу? После рестарта пароль не сработает! [y/N]: " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                break
            else
                log_info "Отменено пользователем. SSH не перезапущен."
                log_warn "Конфигурация применена, но SSH работает со старыми настройками."
                log_warn "Запустите скрипт снова когда будете готовы."
                return 0
            fi
        else
            log_info "Отменено. Конфигурация применена, но SSH не перезапущен."
            log_warn "Вы можете добавить ключ позже и перезапустить SSH вручную:"
            echo "  systemctl restart ssh"
            echo ""
            log_info "Хотите выйти или подождать?"
            read -p "Продолжить ожидание? [y/N]: " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                return 0
            fi
        fi
    done
    
    echo ""
    log_info "Перезапускаю SSH сервис..."
    if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
        log_success "✓ SSH сервис перезапущен"
    else
        log_warn "Не удалось перезапустить SSH через systemctl, пробую reload..."
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    fi
    
    sleep 2
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        log_success "✓ SSH работает корректно"
    else
        log_error "❌ SSH не запустился!"
        log_warn "Восстанавливаю бэкап конфигурации..."
        cp "$SSH_CONFIG_BACKUP" "$SSH_CONFIG_FILE"
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        exit 1
    fi
    
    log_info "Настраиваю watcher для автоматического рестарта при добавлении ключей..."
    
    cat > /etc/systemd/system/ssh-key-watcher.service << 'EOF'
[Unit]
Description=Restart SSH on authorized_keys change
After=sshd.service

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart ssh
ExecStartPre=/bin/bash -c 'systemctl restart sshd 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    
    cat > /etc/systemd/system/ssh-key-watcher.path << EOF
[Unit]
Description=Watch for changes in authorized_keys

[Path]
PathChanged=$SSH_KEY_WATCH_PATH
Unit=ssh-key-watcher.service

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable --now ssh-key-watcher.path 2>/dev/null || log_warn "Не удалось активировать ssh-key-watcher.path"
    
    log_success "Watcher настроен: SSH будет перезапущен при изменении $SSH_KEY_WATCH_PATH"
    
    mark_installed "ssh_hardening"
    
    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✓ SSH Hardening завершён успешно!${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
    echo ""
    log_info "📋 Текущие настройки SSH:"
    echo "  • Порт: 22"
    echo "  • Root login: только по ключу ✓"
    echo "  • Password auth: отключён ✓"
    echo "  • Поддерживаемые ключи: ed25519, ecdsa"
    echo "  • MaxAuthTries: 3"
    echo "  • Ключей в authorized_keys: $(wc -l < "$SSH_KEY_WATCH_PATH")"
    echo ""
    log_info "🔐 Для добавления новых ключей в будущем:"
    echo "  1. Добавьте ключ в /root/.ssh/authorized_keys"
    echo "  2. SSH перезагрузится автоматически (watcher)"
    echo "  3. Или вручную: systemctl restart ssh"
}

# =============================================================================
# 7. IPTABLES
# =============================================================================
configure_firewall() {
    if is_installed "iptables_rules"; then log_skip "Правила iptables"; return 0; fi
    log_info "=== Настройка iptables ==="
    log_info "Разрешаю порты 9090/9100 только из подсети: $ZT_SUBNET"
    iptables -C INPUT -p tcp -s "$ZT_SUBNET" --dport 9090 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp -s "$ZT_SUBNET" --dport 9090 -j ACCEPT
    iptables -C INPUT -p tcp --dport 9090 -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport 9090 -j DROP
    iptables -C INPUT -p tcp -s "$ZT_SUBNET" --dport 9100 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp -s "$ZT_SUBNET" --dport 9100 -j ACCEPT
    iptables -C INPUT -p tcp --dport 9100 -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport 9100 -j DROP
    log_success "Правила iptables применены"
    mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    log_success "Правила сохранены в /etc/iptables/rules.v4"
    if ! dpkg -l | grep -q iptables-persistent; then
        log_info "Устанавливаю iptables-persistent..."; DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent 2>/dev/null || true
    fi
    mark_installed "iptables_rules"
    log_info "Активные правила для 9090/9100:"; iptables -L INPUT -n --line-numbers | grep -E "9090|9100" || echo "  (нет правил в выводе)"
}

# =============================================================================
# УТИЛИТЫ
# =============================================================================
show_status() {
    echo -e "\n${CYAN}📊 Статус компонентов:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "%-25s %s\n" "Docker:" "$(is_installed "docker" && echo -e "${GREEN}✓${NC}" || echo -e "${YELLOW}○${NC}")"
    printf "%-25s %s\n" "RemnaWave node:" "$(is_installed "remnawave_node" && echo -e "${GREEN}✓${NC}" || echo -e "${YELLOW}○${NC}")"
    printf "%-25s %s\n" "ZeroTier:" "$(is_installed "zerotier" && echo -e "${GREEN}✓${NC}" || echo -e "${YELLOW}○${NC}")"
    printf "%-25s %s\n" "Node Exporter:" "$(is_installed "node_exporter" && echo -e "${GREEN}✓${NC}" || echo -e "${YELLOW}○${NC}")"
    printf "%-25s %s\n" "Prometheus:" "$(is_installed "prometheus" && echo -e "${GREEN}✓${NC}" || echo -e "${YELLOW}○${NC}")"
    printf "%-25s %s\n" "Beszel Agent:" "$(is_installed "beszel_agent" && echo -e "${GREEN}✓${NC}" || echo -e "${YELLOW}○${NC}")"
    printf "%-25s %s\n" "SSH Hardening:" "$(is_installed "ssh_hardening" && echo -e "${GREEN}✓${NC}" || echo -e "${YELLOW}○${NC}")"
    printf "%-25s %s\n" "iptables rules:" "$(is_installed "iptables_rules" && echo -e "${GREEN}✓${NC}" || echo -e "${YELLOW}○${NC}")"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    [[ -f "$ZT_IP_FILE" ]] && echo -e "🌐 ZeroTier IP: ${GREEN}$(cat "$ZT_IP_FILE")${NC}"
    [[ -f "$SSH_KEY_WATCH_PATH" ]] && echo -e "🔐 SSH ключей: ${GREEN}$(wc -l < "$SSH_KEY_WATCH_PATH" 2>/dev/null || echo 0)${NC}"
    echo ""
}

reset_installation() {
    log_warn "Сброс состояния установки..."
    read -p "Вы уверены? Все метки установки будут удалены (файлы и сервисы останутся) [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$STATE_DIR"; log_success "Состояние сброшено."
    else log_info "Отменено"; fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  RemnaWave Node Installer v2.3 (Fix apt repos)${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_root; init_state
    
    case "${1:-}" in
        --status|-s) show_status; exit 0 ;;
        --reset|-r) reset_installation; exit 0 ;;
        --help|-h)
            echo "Использование: $0 [опции]"
            echo "Опции:"
            echo "  --status, -s   Показать статус компонентов"
            echo "  --reset, -r    Сбросить метки установки"
            echo "  --help, -h     Показать справку"
            echo ""
            echo "Без аргументов: запустить установку/обновление"
            exit 0 ;;
    esac
    
    show_status
    
    echo "Этапы (установленные будут пропущены):"
    echo "  1. Docker (с обработкой broken repos)"
    echo "  2. RemnaWave node"
    echo "  3. ZeroTier"
    echo "  4. Prometheus + node_exporter"
    echo "  5. Beszel monitoring agent"
    echo "  6. 🔐 SSH Hardening (Safe Key Wait)"
    echo "  7. iptables firewall"
    echo ""
    
    read -p "Продолжить? [y/N]: " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { log_info "Отменено"; exit 0; }
    echo ""
    
    install_docker; echo ""
    install_remnawave_node; echo ""
    setup_zerotier; echo ""
    install_prometheus_monitoring; echo ""
    install_beszel_agent; echo ""
    configure_ssh; echo ""
    configure_firewall; echo ""
    
    show_status
    
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Установка/обновление завершено!${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo ""
    echo "Полезные команды:"
    echo "  • SSH тест:         ssh -v root@$(cat "$ZT_IP_FILE" 2>/dev/null || echo 'ZT_IP')"
    echo "  • SSH статус:       systemctl status ssh"
    echo "  • Watcher статус:   systemctl status ssh-key-watcher.path"
    echo "  • Добавить ключ:    nano /root/.ssh/authorized_keys"
    echo "  • RemnaWave логи:   cd /opt/remnanode && docker compose logs -f"
    echo "  • ZeroTier:         zerotier-cli listnetworks"
    echo "  • Prometheus:       http://$(cat "$ZT_IP_FILE" 2>/dev/null):9090"
    echo "  • Node Exporter:    curl http://$(cat "$ZT_IP_FILE" 2>/dev/null):9100/metrics | head"
    echo "  • Beszel:           docker logs beszel-agent | https://beszel.serv2x.ru"
    echo "  • Статус:           $0 --status"
    echo "  • Сброс:            $0 --reset"
    echo ""
    log_info "Авторизуйте ноду в ZeroTier: https://my.zerotier.com"
    log_info "SSH: пароль отключён, используйте только ключи 🔑"
}

main "$@"