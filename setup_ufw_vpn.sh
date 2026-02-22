#!/bin/bash

# Проверка на права root
if [[ $EUID -ne 0 ]]; then
   echo "Ошибка: запустите скрипт через sudo"
   exit 1
fi

echo "--- Начинаю настройку UFW + NAT для 3x-ui ---"

# 1. Установка UFW (если вдруг удален)
echo "[1/6] Установка UFW..."
apt update && apt install ufw -y

# 2. Определение сетевого интерфейса
INTERFACE=$(ip route show | grep default | awk '{print $5}')
echo "[2/6] Определен сетевой интерфейс: $INTERFACE"

# 3. Настройка NAT (Masquerade) в before.rules
echo "[3/6] Настройка NAT в /etc/ufw/before.rules..."
# Проверяем, нет ли уже там блока *nat, чтобы не дублировать
if ! grep -q "*nat" /etc/ufw/before.rules; then
    # Создаем временный файл с блоком NAT и объединяем с оригиналом
    cat <<EOF > /tmp/before.rules.tmp
# NAT settings
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o $INTERFACE -j MASQUERADE
COMMIT

EOF
    cat /etc/ufw/before.rules >> /tmp/before.rules.tmp
    mv /tmp/before.rules.tmp /etc/ufw/before.rules
    echo "Блок NAT успешно добавлен."
else
    echo "Блок NAT уже существует в /etc/ufw/before.rules, пропускаю."
fi

# 4. Включение Forwarding в конфигах UFW
echo "[4/6] Настройка Forwarding..."
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

# Раскомментируем параметры в /etc/ufw/sysctl.conf
sed -i 's/#net\/ipv4\/ip_forward=1/net\/ipv4\/ip_forward=1/' /etc/ufw/sysctl.conf
sed -i 's/#net\/ipv6\/conf\/default\/forwarding=1/net\/ipv6\/conf\/default\/forwarding=1/' /etc/ufw/sysctl.conf
sed -i 's/#net\/ipv6\/conf\/all\/forwarding=1/net\/ipv6\/conf\/all\/forwarding=1/' /etc/ufw/sysctl.conf


# 6. Финальная активация
echo "[6/6] Активация UFW..."

# Удаляем iptables-persistent, чтобы не было конфликтов
apt purge iptables-persistent netfilter-persistent -y

echo "y" | ufw enable
ufw reload

echo ""
echo "=========================================="
echo " Настройка завершена! "
echo " Интерфейс: $INTERFACE "
echo " NAT: Активен "
echo "=========================================="
ufw status verbose
