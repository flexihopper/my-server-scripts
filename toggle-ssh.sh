#!/usr/bin/env bash
set -e

TARGET_PORT=$1

if [[ "$EUID" -ne 0 ]]; then
    echo "Ошибка: запустите скрипт через sudo."
    exit 1
fi

if [[ "$TARGET_PORT" != "22" && "$TARGET_PORT" != "2244" ]]; then
    echo "Использование: sudo $0 [22|2244]"
    exit 1
fi

OLD_PORT=$([[ "$TARGET_PORT" == "22" ]] && echo "2244" || echo "22")

echo "=== Переключение SSH с порта $OLD_PORT на $TARGET_PORT ==="

# 1. Открываем новый порт в UFW ДО перезапуска (страховка от потери доступа)
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    echo "[UFW] Открываем порт ${TARGET_PORT}/tcp..."
    ufw allow "${TARGET_PORT}/tcp" >/dev/null
fi

# 2. Обновляем конфигурацию sshd (через drop-in файлы и основной конфиг)
# В OpenSSH действует правило FIRST MATCH WINS, поэтому префикс 01- имеет приоритет над остальными drop-in
mkdir -p /etc/ssh/sshd_config.d
if [[ -f /etc/ssh/sshd_config.d/01-custom.conf ]]; then
    sed -i -E "s/^Port .*/Port ${TARGET_PORT}/" /etc/ssh/sshd_config.d/01-custom.conf
fi
echo "Port ${TARGET_PORT}" > /etc/ssh/sshd_config.d/01-custom-port.conf
rm -f /etc/ssh/sshd_config.d/99-custom-port.conf

if grep -qE "^Port " /etc/ssh/sshd_config; then
    sed -i -E "s/^Port .*/Port ${TARGET_PORT}/" /etc/ssh/sshd_config
fi

# Проверка конфигурации перед применением
if ! sshd -t; then
    echo "Ошибка: проверка sshd -t не прошла! Откат изменений..."
    rm -f /etc/ssh/sshd_config.d/01-custom-port.conf
    rm -f /etc/ssh/sshd_config.d/99-custom-port.conf
    exit 1
fi

# 3. Обработка systemd ssh.socket (специфика Ubuntu 24.04)
if systemctl is-active --quiet ssh.socket; then
    echo "[Systemd] Обнаружен активный ssh.socket. Обновляем сокет..."
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat <<EOF > /etc/systemd/system/ssh.socket.d/port.conf
[Socket]
ListenStream=
ListenStream=0.0.0.0:${TARGET_PORT}
ListenStream=[::]:${TARGET_PORT}
EOF
    systemctl daemon-reload
    systemctl restart ssh.socket
    systemctl restart ssh.service || true
else
    echo "[Systemd] Перезапускаем ssh.service..."
    # Если есть старый override для сокета, синхронизируем его на всякий случай
    if [[ -f /etc/systemd/system/ssh.socket.d/port.conf ]]; then
        cat <<EOF > /etc/systemd/system/ssh.socket.d/port.conf
[Socket]
ListenStream=
ListenStream=0.0.0.0:${TARGET_PORT}
ListenStream=[::]:${TARGET_PORT}
EOF
        systemctl daemon-reload
    fi
    systemctl restart ssh.service
fi

# 4. Закрываем старый порт в UFW
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    echo "[UFW] Удаляем правило для старого порта ${OLD_PORT}/tcp..."
    ufw delete allow "${OLD_PORT}/tcp" >/dev/null || true
fi

echo "=== Готово! Проверяю прослушиваемые порты: ==="
ss -tulpn | grep -E ":(22|2244)\b" || echo "Внимание: порт не найден в выводе ss!"
