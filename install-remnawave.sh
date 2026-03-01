#!/bin/bash
# =============================================================================
# RemnaWave Node Auto-Installer with ZeroTier + Prometheus + Monitoring
# =============================================================================
# Этот скрипт выполняет:
# 1. Установку Docker (если не установлен)
# 2. Запуск ноды RemnaWave через docker-compose (запрашивает конфиг у пользователя)
# 3. Установку ZeroTier и подключение к внутренней сети
# 4. Установку Prometheus и node_exporter на хост с конфигурацией под ZeroTier IP
# 5. Установку beszel-agent для мониторинга
# 6. Настройку iptables для закрытия портов 9090/9100 во внешнюю сеть
# =============================================================================

set -e  # Выход при ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
        apt-get update && apt-get install -y docker-compose-plugin
    fi
}

# Установка RemnaWave node через docker-compose
install_remnawave_node() {
    log_info "=== Установка RemnaWave Node ==="
    
    # Создаём директорию
    NODE_DIR="/opt/remnanode"
    mkdir -p "$NODE_DIR"
    cd "$NODE_DIR"
    
    # Запрашиваем содержимое docker-compose.yml
    echo ""
    log_info "Вставьте содержимое docker-compose.yml из панели RemnaWave:"
    log_info "(нажмите Ctrl+D когда закончите ввод, или вставьте и нажмите Enter дважды)"
    echo "--- НАЧНИТЕ ВВОД ---"
    
    COMPOSE_CONTENT=$(cat)
    
    if [[ -z "$COMPOSE_CONTENT" ]]; then
        log_error "Пустое содержимое docker-compose.yml"
        exit 1
    fi
    
    # Сохраняем docker-compose.yml
    echo "$COMPOSE_CONTENT" > docker-compose.yml
    log_success "docker-compose.yml сохранён в $NODE_DIR"
    
    # Запрашиваем .env если нужно
    if echo "$COMPOSE_CONTENT" | grep -q "env_file:"; then
        echo ""
        log_info "Вставьте содержимое .env файла (или нажмите Enter для пропуска):"
        ENV_CONTENT=$(cat)
        if [[ -n "$ENV_CONTENT" ]]; then
            echo "$ENV_CONTENT" > .env
            log_success ".env сохранён"
        fi
    fi
    
    # Запускаем контейнеры
    log_info "Запускаю контейнеры RemnaWave..."
    if docker compose version &> /dev/null; then
        docker compose up -d
    else
        docker-compose up -d
    fi
    
    sleep 5
    
    # Проверка статуса
    if docker ps | grep -q remnanode; then
        log_success "RemnaWave node запущена успешно"
        docker compose logs -f -t &
    else
        log_warn "Контейнер может запускаться... проверьте логи: cd $NODE_DIR && docker compose logs -f"
    fi
}

# Установка ZeroTier и получение внутреннего IP
setup_zerotier() {
    log_info "=== Настройка ZeroTier ==="
    
    # Установка ZeroTier
    if ! command -v zerotier-cli &> /dev/null; then
        log_info "Устанавливаю ZeroTier..."
        curl -s https://install.zerotier.com | sudo bash
        systemctl enable --now zerotier-one
        log_success "ZeroTier установлен"
    else
        log_success "ZeroTier уже установлен"
    fi
    
    # Запрос ID сети
    echo ""
    read -p "Введите ZeroTier Network ID: " ZT_NETWORK_ID
    
    if [[ -z "$ZT_NETWORK_ID" ]]; then
        log_error "Network ID не может быть пустым"
        exit 1
    fi
    
    # Подключение к сети
    log_info "Подключаюсь к сети ZeroTier: $ZT_NETWORK_ID"
    zerotier-cli join "$ZT_NETWORK_ID"
    
    # Ожидание авторизации и получения IP
    log_info "Ожидаю авторизации в сети ZeroTier (макс. 60 сек)..."
    ZT_IP=""
    for i in {1..12}; do
        sleep 5
        ZT_IP=$(zerotier-cli listnetworks -j 2>/dev/null | grep -oP '"assignedAddresses":\["\K[0-9./]+' | head -1)
        if [[ -n "$ZT_IP" ]]; then
            # Убираем маску подсети если есть
            ZT_IP="${ZT_IP%%/*}"
            log_success "Получен ZeroTier IP: $ZT_IP"
            break
        fi
        log_info "Попытка $i/12: ожидаю IP..."
    done
    
    if [[ -z "$ZT_IP" ]]; then
        log_error "Не удалось получить IP адрес ZeroTier"
        log_warn "Проверьте в панели ZeroTier, что нода авторизована"
        log_warn "После авторизации перезапустите скрипт или выполните: zerotier-cli listnetworks"
        exit 1
    fi
    
    # Сохраняем IP для дальнейшего использования
    echo "$ZT_IP" > /tmp/zt_ip.txt
    export ZT_IP
}

# Установка Prometheus и node_exporter на хост
install_prometheus_monitoring() {
    log_info "=== Установка Prometheus и Node Exporter ==="
    
    ZT_IP=$(cat /tmp/zt_ip.txt)
    
    # Установка node_exporter
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
    
    # Создание systemd сервиса для node_exporter
    if [[ ! -f /etc/systemd/system/node_exporter.service ]]; then
        cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/node_exporter --collector.systemd --collector.docker
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now node_exporter
        log_success "node_exporter запущен как сервис"
    fi
    
    # Установка Prometheus
    if ! command -v prometheus &> /dev/null; then
        log_info "Устанавливаю Prometheus..."
        PROMETHEUS_VERSION="2.48.0"
        cd /tmp
        wget -q https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
        tar -xzf prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz
        mv prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus /usr/local/bin/
        mv prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool /usr/local/bin/
        mkdir -p /etc/prometheus /var/lib/prometheus
        cp -r prometheus-${PROMETHEUS_VERSION}.linux-amd64/consoles /etc/prometheus/
        cp -r prometheus-${PROMETHEUS_VERSION}.linux-amd64/console_libraries /etc/prometheus/
        rm -rf prometheus-*
        log_success "Prometheus установлен"
    else
        log_success "Prometheus уже установлен"
    fi
    
    # Конфигурация Prometheus
    log_info "Настраиваю prometheus.yml для ZeroTier IP: $ZT_IP"
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
    
    # Создание systemd сервиса для Prometheus
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
        log_success "Prometheus запущен как сервис"
    fi
    
    log_success "Prometheus доступен на http://${ZT_IP}:9090"
}

# Установка beszel-agent через docker-compose
install_beszel_agent() {
    log_info "=== Установка Beszel Agent ==="
    
    AGENT_DIR="/opt/beszel-agent"
    mkdir -p "$AGENT_DIR"
    cd "$AGENT_DIR"
    
    # Создаём docker-compose.yml для beszel-agent
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
    
    log_info "Запускаю beszel-agent..."
    if docker compose version &> /dev/null; then
        docker compose up -d
    else
        docker-compose up -d
    fi
    
    sleep 3
    
    if docker ps | grep -q beszel-agent; then
        log_success "Beszel agent запущен успешно"
    else
        log_warn "Проверьте статус: docker compose logs -f"
    fi
}

# Настройка iptables для защиты портов
configure_firewall() {
    log_info "=== Настройка iptables ==="
    
    # Получаем ZeroTier IP и определяем подсеть (предполагаем стандартную /16)
    ZT_IP=$(cat /tmp/zt_ip.txt)
    ZT_SUBNET="172.23.0.0/16"  # Измените если ваша сеть ZeroTier использует другую подсеть
    
    log_info "Разрешаю доступ к портам 9090/9100 только из подсети ZeroTier: $ZT_SUBNET"
    
    # Правила для Prometheus (9090)
    iptables -A INPUT -p tcp -s "$ZT_SUBNET" --dport 9090 -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -p tcp --dport 9090 -j DROP 2>/dev/null || true
    
    # Правила для Node Exporter (9100)
    iptables -A INPUT -p tcp -s "$ZT_SUBNET" --dport 9100 -j ACCEPT 2>/dev/null || true
    iptables -A INPUT -p tcp --dport 9100 -j DROP 2>/dev/null || true
    
    log_success "Правила iptables применены"
    
    # Сохранение правил
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save
    elif command -v iptables-save &> /dev/null; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        log_success "Правила сохранены в /etc/iptables/rules.v4"
    fi
    
    # Установка iptables-persistent для автозагрузки
    if ! dpkg -l | grep -q iptables-persistent; then
        log_info "Устанавливаю iptables-persistent для сохранения правил..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    fi
    
    log_info "Текущие правила для портов 9090/9100:"
    iptables -L INPUT -n --line-numbers | grep -E "9090|9100" || echo "Правила не найдены в выводе"
}

# Основная функция
main() {
    echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  RemnaWave Node Auto-Installer with Monitoring ${GREEN}║${NC}"
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
    echo "  • Логи RemnaWave:   cd /opt/remnanode && docker compose logs -f"
    echo "  • Статус ZeroTier:  zerotier-cli listnetworks"
    echo "  • Prometheus UI:    http://$(cat /tmp/zt_ip.txt):9090"
    echo "  • Статус сервисов:  systemctl status prometheus node_exporter"
    echo "  • Beszel agent:     docker logs beszel-agent"
    echo ""
    log_info "Не забудьте авторизовать ноду в панели ZeroTier!"
}

# Запуск
main "$@"