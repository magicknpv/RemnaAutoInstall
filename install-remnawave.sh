#!/bin/bash
# =============================================================================
# RemnaWave Node Auto-Installer with ZeroTier + Prometheus + Monitoring
# Версия 2.0 — Idempotent (повторный запуск безопасен, установленные шаги пропускаются)
# =============================================================================

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Пути и константы
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/remnawave-installer"
NODE_DIR="/opt/remnanode"
AGENT_DIR="/opt/beszel-agent"
ZT_IP_FILE="/tmp/zt_ip.txt"
ZT_SUBNET="172.23.0.0/16"  # ⚠️ Измените если ваша сеть ZeroTier использует другую подсеть

# Логирование
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
log_error()   { echo -e "${RED}[✗]${NC} $1"; }
log_skip()    { echo -e "${CYAN}[→]${NC} $1 (уже установлено, пропускаю)"; }

# Инициализация директории состояния
init_state() {
    mkdir -p "$STATE_DIR"
}

# Проверка: установлен ли компонент (флаг-файл)
is_installed() {
    [[ -f "$STATE_DIR/$1" ]]
}

# Отметить компонент как установленный
mark_installed() {
    touch "$STATE_DIR/$1"
}

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт должен быть запущен от root (sudo)"
        exit 1
    fi
}

# =============================================================================
# 1. DOCKER
# =============================================================================
install_docker() {
    if is_installed "docker"; then
        log_skip "Docker"
        return 0
    fi
    
    log_info "Проверка Docker..."
    if ! command -v docker &> /dev/null; then
        log_info "Docker не найден, устанавливаю..."
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
        log_success "Docker установлен"
    else
        log_success "Docker уже установлен"
    fi
    
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        log_info "Установка docker compose plugin..."
        apt-get update && apt-get install -y docker-compose-plugin 2>/dev/null || true
    fi
    
    mark_installed "docker"
}

# =============================================================================
# 2. REMNAWAVE NODE
# =============================================================================
install_remnawave_node() {
    if is_installed "remnawave_node"; then
        log_skip "RemnaWave node"
        # Проверяем, запущены ли контейнеры, и перезапускаем если нужно
        if ! docker ps --format '{{.Names}}' | grep -qi remna; then
            log_warn "Контейнеры RemnaWave не запущены, перезапускаю..."
            cd "$NODE_DIR" && docker compose up -d 2>/dev/null || docker-compose up -d
        fi
        return 0
    fi
    
    log_info "=== Установка RemnaWave Node ==="
    
    mkdir -p "$NODE_DIR"
    cd "$NODE_DIR"
    
    # Если docker-compose.yml уже есть — спрашиваем, перезаписать ли
    if [[ -f docker-compose.yml ]]; then
        log_warn "docker-compose.yml уже существует в $NODE_DIR"
        read -p "Перезаписать? [y/N]: " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Использую существующий docker-compose.yml"
        else
            echo ""
            log_info "Вставьте НОВОЕ содержимое docker-compose.yml (Ctrl+D для завершения):"
            echo "--- НАЧНИТЕ ВВОД ---"
            COMPOSE_CONTENT=$(cat)
            if [[ -n "$COMPOSE_CONTENT" ]]; then
                echo "$COMPOSE_CONTENT" > docker-compose.yml
                log_success "docker-compose.yml обновлён"
            fi
        fi
    else
        echo ""
        log_info "Вставьте содержимое docker-compose.yml из панели RemnaWave:"
        log_info "(нажмите Ctrl+D когда закончите ввод)"
        echo "--- НАЧНИТЕ ВВОД ---"
        COMPOSE_CONTENT=$(cat)
        
        if [[ -z "$COMPOSE_CONTENT" ]]; then
            log_error "Пустое содержимое docker-compose.yml"
            exit 1
        fi
        
        echo "$COMPOSE_CONTENT" > docker-compose.yml
        log_success "docker-compose.yml сохранён в $NODE_DIR"
    fi
    
    # .env файл (опционально)
    if echo "$COMPOSE_CONTENT" 2>/dev/null | grep -q "env_file:" || [[ -f .env ]]; then
        if [[ ! -f .env ]]; then
            echo ""
            log_info "Вставьте содержимое .env файла (или Enter для пропуска):"
            ENV_CONTENT=$(cat)
            if [[ -n "$ENV_CONTENT" ]]; then
                echo "$ENV_CONTENT" > .env
                log_success ".env сохранён"
            fi
        fi
    fi
    
    log_info "Запускаю контейнеры RemnaWave..."
    if docker compose version &> /dev/null; then
        docker compose up -d
    else
        docker-compose up -d
    fi
    
    sleep 5
    
    if docker ps --format '{{.Names}}' | grep -qi remna; then
        log_success "RemnaWave node запущена"
        mark_installed "remnawave_node"
    else
        log_warn "Контейнер может запускаться... проверьте логи: cd $NODE_DIR && docker compose logs -f"
        log_warn "Шаг не отмечен как завершённый — при следующем запуске будет повторён"
    fi
}

# =============================================================================
# 3. ZEROTIER
# =============================================================================
get_zerotier_ip() {
    local ip=""
    # Способ 1: человекочитаемый вывод
    ip=$(zerotier-cli listnetworks 2>/dev/null | grep -v "^200 listnetworks <nwid>" | awk '{print $NF}' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    # Способ 2: JSON grep
    if [[ -z "$ip" ]]; then
        ip=$(zerotier-cli listnetworks -j 2>/dev/null | grep -oE '"assignedAddresses":\["[^"]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    # Способ 3: jq
    if [[ -z "$ip" ]] && command -v jq &> /dev/null; then
        ip=$(zerotier-cli listnetworks -j 2>/dev/null | jq -r '.[]?.assignedAddresses?[0] // empty' 2>/dev/null | cut -d'/' -f1 | head -1)
    fi
    echo "${ip%%/*}"
}

setup_zerotier() {
    if is_installed "zerotier"; then
        log_skip "ZeroTier"
        # Проверяем, есть ли IP, если нет — пытаемся получить
        if [[ ! -f "$ZT_IP_FILE" ]] || [[ -z "$(cat "$ZT_IP_FILE" 2>/dev/null)" ]]; then
            log_warn "ZeroTier установлен, но IP не сохранён, пытаюсь получить..."
            ZT_IP=$(get_zerotier_ip)
            if [[ -n "$ZT_IP" ]]; then
                echo "$ZT_IP" > "$ZT_IP_FILE"
                log_success "ZeroTier IP получен: $ZT_IP"
            fi
        fi
        return 0
    fi
    
    log_info "=== Настройка ZeroTier ==="
    
    if ! command -v zerotier-cli &> /dev/null; then
        log_info "Устанавливаю ZeroTier..."
        curl -s https://install.zerotier.com | sudo bash
        systemctl enable --now zerotier-one
        log_success "ZeroTier установлен"
    else
        log_success "ZeroTier уже установлен"
    fi
    
    # Проверяем, не подключены ли уже к нужной сети
    EXISTING_NET=$(zerotier-cli listnetworks 2>/dev/null | grep -v "^200 listnetworks <nwid>" | awk '{print $1}' | head -1)
    
    if [[ -n "$EXISTING_NET" ]]; then
        log_warn "ZeroTier уже подключён к сети: $EXISTING_NET"
        read -p "Использовать эту сеть? [Y/n]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            echo ""
            read -p "Введите НОВЫЙ ZeroTier Network ID: " ZT_NETWORK_ID
            if [[ -n "$ZT_NETWORK_ID" ]]; then
                zerotier-cli leave "$EXISTING_NET" 2>/dev/null || true
                zerotier-cli join "$ZT_NETWORK_ID"
            fi
        else
            ZT_NETWORK_ID="$EXISTING_NET"
        fi
    else
        echo ""
        read -p "Введите ZeroTier Network ID: " ZT_NETWORK_ID
        if [[ -z "$ZT_NETWORK_ID" ]]; then
            log_error "Network ID не может быть пустым"
            exit 1
        fi
        log_info "Подключаюсь к сети: $ZT_NETWORK_ID"
        zerotier-cli join "$ZT_NETWORK_ID"
    fi
    
    # Ожидание IP
    log_info "Ожидаю получения IP (макс. 90 сек)..."
    ZT_IP=""
    for i in {1..18}; do
        sleep 5
        local status=$(zerotier-cli listnetworks 2>/dev/null | grep -v "^200 listnetworks <nwid>" | head -1)
        log_info "Попытка $i/18: $status"
        
        ZT_IP=$(get_zerotier_ip)
        
        if [[ -n "$ZT_IP" ]]; then
            log_success "✓ Получен ZeroTier IP: $ZT_IP"
            break
        fi
    done
    
    if [[ -z "$ZT_IP" ]]; then
        log_error "✗ Не удалось получить IP адрес"
        echo ""
        log_warn "Текущий статус ZeroTier:"
        zerotier-cli listnetworks
        echo ""
        log_warn "Действия:"
        echo "  1. Авторизуйте ноду в панели https://my.zerotier.com"
        echo "  2. Перезапустите скрипт"
        exit 1
    fi
    
    echo "$ZT_IP" > "$ZT_IP_FILE"
    export ZT_IP
    mark_installed "zerotier"
}

# =============================================================================
# 4. PROMETHEUS + NODE EXPORTER
# =============================================================================
install_prometheus_monitoring() {
    ZT_IP=$(cat "$ZT_IP_FILE" 2>/dev/null || echo "")
    
    # ----- NODE EXPORTER -----
    if is_installed "node_exporter"; then
        log_skip "Node Exporter"
    else
        log_info "=== Установка Node Exporter ==="
        
        if ! command -v node_exporter &> /dev/null; then
            log_info "Устанавливаю node_exporter..."
            NODE_EXPORTER_VERSION="1.7.0"
            cd /tmp
            wget -q https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
            tar -xzf node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
            mv node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter /usr/local/bin/
            rm -rf node_exporter-*
            chmod +x /usr/local/bin/node_exporter
            log_success "node_exporter установлен"
        else
            log_success "node_exporter уже установлен"
        fi
        
        if [[ ! -f /etc/systemd/system/node_exporter.service ]]; then
            cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/node_exporter \
  --collector.systemd \
  --web.listen-address=:9100
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable --now node_exporter
            sleep 2
        fi
        
        if systemctl is-active --quiet node_exporter; then
            log_success "node_exporter запущен и работает"
            mark_installed "node_exporter"
        else
            log_warn "node_exporter не запустился, проверьте: journalctl -u node_exporter -n 20"
        fi
    fi
    
    # ----- PROMETHEUS -----
    if is_installed "prometheus"; then
        log_skip "Prometheus"
    else
        log_info "=== Установка Prometheus ==="
        
        if ! command -v prometheus &> /dev/null; then
            log_info "Устанавливаю Prometheus..."
            PROMETHEUS_VERSION="2.48.0"
            cd /tmp
            wget -q https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
            tar -xzf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
            mv prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus /usr/local/bin/
            mv prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool /usr/local/bin/
            mkdir -p /etc/prometheus /var/lib/prometheus
            cp -r prometheus-${PROMETHEUS_VERSION}.linux-amd64/consoles /etc/prometheus/ 2>/dev/null || true
            cp -r prometheus-${PROMETHEUS_VERSION}.linux-amd64/console_libraries /etc/prometheus/ 2>/dev/null || true
            rm -rf prometheus-*
            log_success "Prometheus установлен"
        else
            log_success "Prometheus уже установлен"
        fi
        
        if [[ -n "$ZT_IP" ]]; then
            log_info "Создаю prometheus.yml для IP: $ZT_IP"
            cat > /etc/prometheus/prometheus.yml << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  # - "first_rules.yml"
  # - "second_rules.yml"

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
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus/ \
  --web.listen-address=0.0.0.0:9090 \
  --web.enable-lifecycle
Restart=always

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable --now prometheus
        fi
        
        if systemctl is-active --quiet prometheus; then
            log_success "Prometheus запущен"
            mark_installed "prometheus"
        else
            log_warn "Prometheus не запустился, проверьте: journalctl -u prometheus -n 20"
        fi
    fi
    
    if [[ -n "$ZT_IP" ]]; then
        log_success "Prometheus UI: http://${ZT_IP}:9090"
    fi
}

# =============================================================================
# 5. BESZEL AGENT
# =============================================================================
install_beszel_agent() {
    if is_installed "beszel_agent"; then
        log_skip "Beszel Agent"
        # Проверяем, запущен ли контейнер
        if ! docker ps --format '{{.Names}}' | grep -q beszel-agent; then
            log_warn "Контейнер beszel-agent не запущен, перезапускаю..."
            cd "$AGENT_DIR" && docker compose up -d 2>/dev/null || docker-compose up -d
        fi
        return 0
    fi
    
    log_info "=== Установка Beszel Agent ==="
    
    mkdir -p "$AGENT_DIR"
    cd "$AGENT_DIR"
    
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
    environment:
      LISTEN: 45876
      KEY: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEYYsnCnXR6dh5nNdLY1ijqgWP6JzrbbFYcRSJF2m0gQ'
      TOKEN: f887063c-6966-45a7-a5af-ec68ae2a341d
      HUB_URL: https://beszel.serv2x.ru
EOF
    
    mkdir -p beszel_agent_data
    
    log_info "Запускаю beszel-agent..."
    if docker compose version &> /dev/null; then
        docker compose up -d
    else
        docker-compose up -d
    fi
    
    sleep 3
    if docker ps --format '{{.Names}}' | grep -q beszel-agent; then
        log_success "Beszel agent запущен"
        mark_installed "beszel_agent"
    else
        log_warn "Проверьте: docker logs beszel-agent"
    fi
}

# =============================================================================
# 6. IPTABLES
# =============================================================================
configure_firewall() {
    if is_installed "iptables_rules"; then
        log_skip "Правила iptables"
        return 0
    fi
    
    log_info "=== Настройка iptables ==="
    
    log_info "Разрешаю порты 9090/9100 только из подсети: $ZT_SUBNET"
    
    # Prometheus 9090
    iptables -C INPUT -p tcp -s "$ZT_SUBNET" --dport 9090 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp -s "$ZT_SUBNET" --dport 9090 -j ACCEPT
    iptables -C INPUT -p tcp --dport 9090 -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport 9090 -j DROP
    
    # Node Exporter 9100
    iptables -C INPUT -p tcp -s "$ZT_SUBNET" --dport 9100 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp -s "$ZT_SUBNET" --dport 9100 -j ACCEPT
    iptables -C INPUT -p tcp --dport 9100 -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport 9100 -j DROP
    
    log_success "Правила iptables применены"
    
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    log_success "Правила сохранены в /etc/iptables/rules.v4"
    
    if ! dpkg -l | grep -q iptables-persistent; then
        log_info "Устанавливаю iptables-persistent..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent 2>/dev/null || true
    fi
    
    mark_installed "iptables_rules"
    log_info "Активные правила для 9090/9100:"
    iptables -L INPUT -n --line-numbers | grep -E "9090|9100" || echo "  (нет правил в выводе)"
}

# =============================================================================
# УТИЛИТЫ
# =============================================================================
show_status() {
    echo -e "\n${CYAN}📊 Статус компонентов:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "%-25s %s\n" "Docker:" "$(is_installed "docker" && echo -e "${GREEN}✓ установлен${NC}" || echo -e "${YELLOW}○ не установлен${NC}")"
    printf "%-25s %s\n" "RemnaWave node:" "$(is_installed "remnawave_node" && echo -e "${GREEN}✓ установлен${NC}" || echo -e "${YELLOW}○ не установлен${NC}")"
    printf "%-25s %s\n" "ZeroTier:" "$(is_installed "zerotier" && echo -e "${GREEN}✓ установлен${NC}" || echo -e "${YELLOW}○ не установлен${NC}")"
    printf "%-25s %s\n" "Node Exporter:" "$(is_installed "node_exporter" && echo -e "${GREEN}✓ установлен${NC}" || echo -e "${YELLOW}○ не установлен${NC}")"
    printf "%-25s %s\n" "Prometheus:" "$(is_installed "prometheus" && echo -e "${GREEN}✓ установлен${NC}" || echo -e "${YELLOW}○ не установлен${NC}")"
    printf "%-25s %s\n" "Beszel Agent:" "$(is_installed "beszel_agent" && echo -e "${GREEN}✓ установлен${NC}" || echo -e "${YELLOW}○ не установлен${NC}")"
    printf "%-25s %s\n" "iptables rules:" "$(is_installed "iptables_rules" && echo -e "${GREEN}✓ применены${NC}" || echo -e "${YELLOW}○ не применены${NC}")"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ -f "$ZT_IP_FILE" ]]; then
        echo -e "🌐 ZeroTier IP: ${GREEN}$(cat "$ZT_IP_FILE")${NC}"
    fi
    echo ""
}

reset_installation() {
    log_warn "Сброс состояния установки..."
    read -p "Вы уверены? Все метки установки будут удалены (файлы и сервисы останутся) [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$STATE_DIR"
        log_success "Состояние сброшено. При следующем запуске все шаги будут выполнены заново."
    else
        log_info "Отменено"
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  RemnaWave Node Installer v2.0 (Idempotent)   ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_root
    init_state
    
    # Обработка аргументов
    case "${1:-}" in
        --status|-s)
            show_status
            exit 0
            ;;
        --reset|-r)
            reset_installation
            exit 0
            ;;
        --help|-h)
            echo "Использование: $0 [опции]"
            echo "Опции:"
            echo "  --status, -s   Показать статус установленных компонентов"
            echo "  --reset, -r    Сбросить метки установки (файлы не удаляются)"
            echo "  --help, -h     Показать эту справку"
            echo ""
            echo "Без аргументов: запустить установку/обновление"
            exit 0
            ;;
    esac
    
    show_status
    
    echo "Этапы установки (установленные будут пропущены):"
    echo "  1. Проверка/установка Docker"
    echo "  2. Установка RemnaWave node (docker-compose)"
    echo "  3. Настройка ZeroTier"
    echo "  4. Установка Prometheus + node_exporter"
    echo "  5. Установка Beszel monitoring agent"
    echo "  6. Настройка iptables"
    echo ""
    
    read -p "Продолжить установку? [y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Установка отменена"
        exit 0
    fi
    echo ""
    
    # Выполнение этапов (каждый проверяет, установлен ли компонент)
    install_docker
    echo ""
    
    install_remnawave_node
    echo ""
    
    setup_zerotier
    echo ""
    
    install_prometheus_monitoring
    echo ""
    
    install_beszel_agent
    echo ""
    
    configure_firewall
    echo ""
    
    # Финальный статус
    show_status
    
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Установка/обновление завершено!${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo ""
    echo "Полезные команды:"
    echo "  • RemnaWave логи:   cd /opt/remnanode && docker compose logs -f"
    echo "  • ZeroTier статус:  zerotier-cli listnetworks"
    echo "  • Prometheus UI:    http://$(cat "$ZT_IP_FILE" 2>/dev/null || echo 'ZT_IP'):9090"
    echo "  • Node Exporter:    curl http://$(cat "$ZT_IP_FILE" 2>/dev/null):9100/metrics | head"
    echo "  • Сервисы:          systemctl status prometheus node_exporter"
    echo "  • Beszel agent:     docker logs beszel-agent"
    echo "  • Beszel панель:    https://beszel.serv2x.ru"
    echo "  • Статус установки: $0 --status"
    echo "  • Сброс меток:      $0 --reset"
    echo ""
    log_info "Не забудьте авторизовать ноду в панели ZeroTier: https://my.zerotier.com"
    log_info "Docker-метрики уже собираются через beszel-agent ✅"
}

# Запуск
main "$@"