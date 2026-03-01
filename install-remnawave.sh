#!/bin/bash
# =============================================================================
# RemnaWave Node Auto-Installer with ZeroTier + Prometheus + Monitoring
# Версия 1.2 — Исправлен node_exporter и улучшена надёжность
# =============================================================================
# Этот скрипт выполняет:
# 1. Проверку/установку Docker
# 2. Запуск RemnaWave node через docker-compose (запрашивает конфиг)
# 3. Установку ZeroTier и подключение к внутренней сети
# 4. Установку Prometheus и node_exporter на хост (с корректными флагами)
# 5. Установку beszel-agent для мониторинга
# 6. Настройку iptables для закрытия портов 9090/9100 во внешнюю сеть
# =============================================================================

set -e  # Выход при ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Логирование
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт должен быть запущен от root (sudo)"
        exit 1
    fi
}

# Проверка и установка Docker
install_docker() {
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
}

# Установка RemnaWave node через docker-compose
install_remnawave_node() {
    log_info "=== Установка RemnaWave Node ==="
    
    NODE_DIR="/opt/remnanode"
    mkdir -p "$NODE_DIR"
    cd "$NODE_DIR"
    
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
    
    # Запрос .env если нужно
    if echo "$COMPOSE_CONTENT" | grep -q "env_file:"; then
        echo ""
        log_info "Вставьте содержимое .env файла (или Enter для пропуска):"
        ENV_CONTENT=$(cat)
        if [[ -n "$ENV_CONTENT" ]]; then
            echo "$ENV_CONTENT" > .env
            log_success ".env сохранён"
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
    else
        log_warn "Проверьте логи: cd $NODE_DIR && docker compose logs -f"
    fi
}

# 🔧 Надёжное получение ZeroTier IP (3 способа fallback)
get_zerotier_ip() {
    local ip=""
    
    # Способ 1: Парсинг человекочитаемого вывода (самый надёжный)
    ip=$(zerotier-cli listnetworks 2>/dev/null | grep -v "^200 listnetworks <nwid>" | awk '{print $NF}' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    
    # Способ 2: JSON парсинг через grep
    if [[ -z "$ip" ]]; then
        ip=$(zerotier-cli listnetworks -j 2>/dev/null | grep -oE '"assignedAddresses":\["[^"]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    
    # Способ 3: Через jq если установлен
    if [[ -z "$ip" ]] && command -v jq &> /dev/null; then
        ip=$(zerotier-cli listnetworks -j 2>/dev/null | jq -r '.[]?.assignedAddresses?[0] // empty' 2>/dev/null | cut -d'/' -f1 | head -1)
    fi
    
    # Убираем маску подсети если осталась
    echo "${ip%%/*}"
}

# Установка ZeroTier и получение внутреннего IP
setup_zerotier() {
    log_info "=== Настройка ZeroTier ==="
    
    if ! command -v zerotier-cli &> /dev/null; then
        log_info "Устанавливаю ZeroTier..."
        curl -s https://install.zerotier.com | sudo bash
        systemctl enable --now zerotier-one
        log_success "ZeroTier установлен"
    else
        log_success "ZeroTier уже установлен"
    fi
    
    echo ""
    read -p "Введите ZeroTier Network ID: " ZT_NETWORK_ID
    
    if [[ -z "$ZT_NETWORK_ID" ]]; then
        log_error "Network ID не может быть пустым"
        exit 1
    fi
    
    log_info "Подключаюсь к сети: $ZT_NETWORK_ID"
    zerotier-cli join "$ZT_NETWORK_ID"
    
    # Ожидание IP с выводом статуса
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
        echo "  2. Перезапустите скрипт, или"
        echo "  3. Выполните: zerotier-cli leave $ZT_NETWORK_ID && zerotier-cli join $ZT_NETWORK_ID"
        exit 1
    fi
    
    echo "$ZT_IP" > /tmp/zt_ip.txt
    export ZT_IP
}

# Установка Prometheus и node_exporter на хост
install_prometheus_monitoring() {
    log_info "=== Установка Prometheus и Node Exporter ==="
    
    ZT_IP=$(cat /tmp/zt_ip.txt)
    
    # ========== NODE EXPORTER ==========
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
    
    # ✅ ИСПРАВЛЕННЫЙ systemd сервис для node_exporter
    # Убран несуществующий флаг --collector.docker (удалён в v1.5+)
    # Добавлен --web.listen-address=:9100 для доступа по всем интерфейсам
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
        if systemctl is-active --quiet node_exporter; then
            log_success "node_exporter запущен и работает"
        else
            log_warn "node_exporter не запустился, проверьте: journalctl -u node_exporter -n 20"
        fi
    fi
    
    # ========== PROMETHEUS ==========
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
    
    # Конфигурация Prometheus
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
    
    # systemd сервис для Prometheus
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
        log_success "Prometheus запущен"
    fi
    
    log_success "Prometheus UI: http://${ZT_IP}:9090"
}

# Установка beszel-agent через docker-compose
install_beszel_agent() {
    log_info "=== Установка Beszel Agent ==="
    
    AGENT_DIR="/opt/beszel-agent"
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
      - ./beszel_agent_/var/lib/beszel-agent
    environment:
      LISTEN: 45876
      KEY: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEYYsnCnXR6dh5nNdLY1ijqgWP6JzrbbFYcRSJF2m0gQ'
      TOKEN: f887063c-6966-45a7-a5af-ec68ae2a341d
      HUB_URL: https://beszel.serv2x.ru
EOF
    
    log_info "Запускаю beszel-agent..."
    if docker compose version &> /dev/null; then
        docker compose up -d
    else
        docker-compose up -d
    fi
    
    sleep 3
    if docker ps --format '{{.Names}}' | grep -q beszel-agent; then
        log_success "Beszel agent запущен"
    else
        log_warn "Проверьте: docker logs beszel-agent"
    fi
}

# Настройка iptables для защиты портов
configure_firewall() {
    log_info "=== Настройка iptables ==="
    
    ZT_SUBNET="172.23.0.0/16"  # ⚠️ Измените если ваша сеть ZeroTier использует другую подсеть
    
    log_info "Разрешаю порты 9090/9100 только из подсети: $ZT_SUBNET"
    
    # Prometheus 9090 (сначала ACCEPT, потом DROP)
    iptables -C INPUT -p tcp -s "$ZT_SUBNET" --dport 9090 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp -s "$ZT_SUBNET" --dport 9090 -j ACCEPT
    iptables -C INPUT -p tcp --dport 9090 -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport 9090 -j DROP
    
    # Node Exporter 9100
    iptables -C INPUT -p tcp -s "$ZT_SUBNET" --dport 9100 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp -s "$ZT_SUBNET" --dport 9100 -j ACCEPT
    iptables -C INPUT -p tcp --dport 9100 -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport 9100 -j DROP
    
    log_success "Правила iptables применены"
    
    # Сохранение правил
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    log_success "Правила сохранены в /etc/iptables/rules.v4"
    
    # Установка iptables-persistent
    if ! dpkg -l | grep -q iptables-persistent; then
        log_info "Устанавливаю iptables-persistent..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent 2>/dev/null || true
    fi
    
    log_info "Активные правила для 9090/9100:"
    iptables -L INPUT -n --line-numbers | grep -E "9090|9100" || echo "  (нет правил в выводе)"
}

# Основная функция
main() {
    echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  RemnaWave Node Installer v1.2 (Fixed)        ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_root
    
    echo "Этапы установки:"
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
    
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Установка завершена успешно!${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo ""
    echo "Полезные команды:"
    echo "  • RemnaWave логи:   cd /opt/remnanode && docker compose logs -f"
    echo "  • ZeroTier статус:  zerotier-cli listnetworks"
    echo "  • Prometheus UI:    http://$(cat /tmp/zt_ip.txt 2>/dev/null || echo 'ZT_IP'):9090"
    echo "  • Node Exporter:    curl http://$(cat /tmp/zt_ip.txt 2>/dev/null):9100/metrics | head"
    echo "  • Сервисы:          systemctl status prometheus node_exporter"
    echo "  • Beszel agent:     docker logs beszel-agent"
    echo ""
    log_info "Не забудьте авторизовать ноду в панели ZeroTier: https://my.zerotier.com"
    log_info "Docker-метрики уже собираются через beszel-agent ✅"
}

# Запуск
main "$@"