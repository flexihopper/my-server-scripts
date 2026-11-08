#!/usr/bin/env bash
# =============================================================
#   Установка guard-скрипта и systemd таймера для защиты
#   разрешающего правила Relay IP в nftables Remnawave (Remnanode)
#
#   Использование:
#     sudo ./setup-remna-relay-guard.sh <IP_АДРЕС_1> [IP_АДРЕС_2 ...]
#
#   Пример:
#     sudo ./setup-remna-relay-guard.sh 188.130.138.26
#
#   Или в одну строку через curl / stdin:
#     cat setup-remna-relay-guard.sh | sudo bash -s -- 188.130.138.26
# =============================================================

set -euo pipefail

# 0. Проверка прав суперпользователя
if [[ "$EUID" -ne 0 ]]; then
    echo "Ошибка: запустите скрипт с правами root (sudo)." >&2
    exit 1
fi

# Получаем IP-адреса из аргументов
TARGET_IPS=("$@")

# Если аргументы не переданы, запрашиваем интерактивно (если доступен tty)
if [[ ${#TARGET_IPS[@]} -eq 0 ]]; then
    if [[ -t 0 ]]; then
        read -r -p "Введите IP-адрес релея (или несколько через пробел): " input_ips
        read -r -a TARGET_IPS <<< "$input_ips"
    fi
fi

# Проверка, что хотя бы один IP задан
if [[ ${#TARGET_IPS[@]} -eq 0 ]]; then
    echo "Ошибка: не указан ни один IP-адрес." >&2
    echo "Использование: sudo $0 <IP_АДРЕС_1> [IP_АДРЕС_2 ...]" >&2
    echo "Пример: sudo $0 188.130.138.26" >&2
    exit 1
fi

# Валидация формата IPv4 / CIDR
for ip in "${TARGET_IPS[@]}"; do
    if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        echo "Ошибка: '$ip' не является валидным IPv4-адресом или подсетью CIDR." >&2
        exit 1
    fi
done

IPS_STR="${TARGET_IPS[*]}"
SCRIPT_PATH="/usr/local/bin/ensure-relay-ip.sh"
SERVICE_PATH="/etc/systemd/system/remna-relay-guard.service"
TIMER_PATH="/etc/systemd/system/remna-relay-guard.timer"

echo "=== Установка Remna Relay Guard для IP: $IPS_STR ==="

echo "[1/4] Создание скрипта проверки nftables ($SCRIPT_PATH)..."
cat << EOF > "$SCRIPT_PATH"
#!/usr/bin/env bash
set -euo pipefail

# Список IP для контроля (переданные в аргументах или установленные по умолчанию)
DEFAULT_IPS=($IPS_STR)
if [[ \$# -gt 0 ]]; then
    IPS=("\$@")
else
    IPS=("\${DEFAULT_IPS[@]}")
fi

# Проверка наличия таблицы и цепочки Remnawave
if ! nft list table ip remnanode &>/dev/null || ! nft list chain ip remnanode input &>/dev/null; then
    exit 0
fi

RULES_ADDED=0

for IP in "\${IPS[@]}"; do
    # Проверка наличия разрешающего правила
    if nft list chain ip remnanode input | grep -qE "ip saddr[[:space:]]+\${IP}[[:space:]]+accept"; then
        continue
    fi

    # Добавление правила на первое место
    nft insert rule ip remnanode input ip saddr "\$IP" accept
    logger -t remna-relay-guard "[+] Правило для \$IP добавлено в ip remnanode input."
    echo "[+] Правило для \$IP добавлено в ip remnanode input."
    RULES_ADDED=1
done

# Если были добавлены новые правила и существует /etc/nftables.conf — сохраняем
if [[ "\$RULES_ADDED" -eq 1 ]] && [[ -f /etc/nftables.conf ]]; then
    nft list ruleset > /etc/nftables.conf
fi
EOF

chmod +x "$SCRIPT_PATH"

echo "[2/4] Создание systemd-сервиса ($SERVICE_PATH)..."
cat << EOF > "$SERVICE_PATH"
[Unit]
Description=Guard rule for Relay IP ($IPS_STR) in Remnawave nftables
After=network.target remnanode.service docker.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
EOF

echo "[3/4] Создание systemd-таймера ($TIMER_PATH, интервал 30 сек)..."
cat << EOF > "$TIMER_PATH"
[Unit]
Description=Periodic check for Relay IP in Remnawave nftables

[Timer]
OnBootSec=10s
OnUnitActiveSec=30s

[Install]
WantedBy=timers.target
EOF

echo "[4/4] Запуск и применение таймера..."
systemctl daemon-reload
systemctl enable --now remna-relay-guard.timer
systemctl restart remna-relay-guard.timer

# Пробный запуск скрипта
"$SCRIPT_PATH" || true

echo "--------------------------------------------------------"
echo "Установка успешно завершена!"
echo "Статус таймера:"
systemctl status remna-relay-guard.timer --no-pager

