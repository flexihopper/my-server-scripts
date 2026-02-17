#!/bin/bash

if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: запустите скрипт через sudo (sudo ./optimize_net.sh)"
    exit 1
fi

echo "--- Начинаю полную оптимизацию сервера для 3x-ui ---"

# ============================================================
# 1. SYSCTL — сетевые параметры ядра
# ============================================================
echo "[1/4] Применяю параметры ядра..."

sysctl -w net.netfilter.nf_conntrack_max=262144
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=3600
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=15
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.core.default_qdisc=fq
sysctl -w net.ipv4.tcp_congestion_control=bbr
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216"
sysctl -w net.ipv4.tcp_syncookies=1
sysctl -w net.ipv4.tcp_max_syn_backlog=4096
sysctl -w net.ipv4.conf.all.rp_filter=1
sysctl -w net.ipv4.icmp_echo_ignore_broadcasts=1

echo "[1/4] Сохраняю в /etc/sysctl.d/99-net-tuning.conf..."
cat <<EOF > /etc/sysctl.d/99-net-tuning.conf
# Conntrack
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15

# Forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Буферы TCP
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Защита
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF

# ============================================================
# 2. HASHSIZE — параметр модуля ядра
# ============================================================
echo "[2/4] Настраиваю hashsize..."
echo 65536 > /sys/module/nf_conntrack/parameters/hashsize
cat <<EOF > /etc/modprobe.d/nf_conntrack.conf
options nf_conntrack hashsize=65536
EOF

# ============================================================
# 3. ЛИМИТЫ ФАЙЛОВ — системные и для x-ui
# ============================================================
echo "[3/4] Настраиваю лимиты файловых дескрипторов..."

# Системные лимиты (для всех процессов)
cat <<EOF > /etc/security/limits.d/99-nofile.conf
* soft nofile 51200
* hard nofile 51200
root soft nofile 51200
root hard nofile 51200
EOF

# Лимит для PAM (чтобы limits.d подхватился)
if ! grep -q "pam_limits" /etc/pam.d/common-session 2>/dev/null; then
    echo "session required pam_limits.so" >> /etc/pam.d/common-session
fi

# Лимит для systemd (глобально)
mkdir -p /etc/systemd/system.conf.d/
cat <<EOF > /etc/systemd/system.conf.d/99-limits.conf
[Manager]
DefaultLimitNOFILE=51200
EOF

# Лимит для сервиса x-ui отдельно (на случай если systemd не подхватит глобальный)
if systemctl list-units --type=service | grep -q "x-ui"; then
    mkdir -p /etc/systemd/system/x-ui.service.d/
    cat <<EOF > /etc/systemd/system/x-ui.service.d/limits.conf
[Service]
LimitNOFILE=51200
EOF
    systemctl daemon-reload
    echo "[INFO] Лимит применён к сервису x-ui"
else
    echo "[INFO] Сервис x-ui не найден, лимит применён глобально"
fi

# ============================================================
# 4. ПРОВЕРКА РЕЗУЛЬТАТА
# ============================================================
echo "[4/4] Проверяю результат..."
echo ""
echo "=== Conntrack ==="
sysctl net.netfilter.nf_conntrack_count
sysctl net.netfilter.nf_conntrack_max

echo ""
echo "=== Forwarding ==="
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding

echo ""
echo "=== BBR ==="
sysctl net.ipv4.tcp_congestion_control

echo ""
echo "=== Hashsize ==="
cat /sys/module/nf_conntrack/parameters/hashsize

echo ""
echo "=== Лимиты файлов (текущая сессия) ==="
ulimit -n

echo ""
echo "--- Готово! Все настройки сохранены и выживут после перезагрузки ---"
