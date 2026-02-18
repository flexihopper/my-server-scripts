#!/bin/bash

if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: запустите скрипт через sudo (sudo ./optimize_net.sh)"
    exit 1
fi

echo "--- Начинаю полную оптимизацию сервера для 3x-ui (~1GB RAM) ---"

# ============================================================
# 1. SYSCTL — сетевые параметры ядра
# ============================================================
echo "[1/4] Применяю параметры ядра..."

# Conntrack
sysctl -w net.netfilter.nf_conntrack_max=131072
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=3600
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=15

# Forwarding
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=1

# BBR
sysctl -w net.core.default_qdisc=fq
sysctl -w net.ipv4.tcp_congestion_control=bbr

# Буферы TCP (под ~1GB RAM, увеличены для VPN)
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216"

# Оптимизация TCP для Xray
sysctl -w net.ipv4.tcp_fin_timeout=10
sysctl -w net.ipv4.tcp_tw_reuse=1
sysctl -w net.ipv4.tcp_keepalive_time=300
sysctl -w net.ipv4.tcp_keepalive_probes=3
sysctl -w net.ipv4.tcp_keepalive_intvl=15
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_max_tw_buckets=1440000

# MTU и TFO
sysctl -w net.ipv4.tcp_mtu_probing=1
sysctl -w net.ipv4.tcp_fastopen=3

# Защита
sysctl -w net.ipv4.tcp_syncookies=1
sysctl -w net.ipv4.tcp_max_syn_backlog=16384
sysctl -w net.ipv4.conf.all.rp_filter=1
sysctl -w net.ipv4.icmp_echo_ignore_broadcasts=1

# Память
sysctl -w vm.swappiness=10
sysctl -w vm.vfs_cache_pressure=50

echo "[1/4] Сохраняю в /etc/sysctl.d/99-net-tuning.conf..."
cat <<EOF > /etc/sysctl.d/99-net-tuning.conf
# === Conntrack ===
net.netfilter.nf_conntrack_max = 131072
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15

# === Forwarding ===
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# === BBR ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === Буферы TCP (~1GB RAM, оптимизированы для VPN) ===
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# === Оптимизация TCP для Xray ===
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 15
net.core.somaxconn = 65535
net.ipv4.tcp_max_tw_buckets = 1440000

# === MTU и TCP Fast Open ===
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3

# === Защита ===
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1

# === Память ===
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF

# ============================================================
# 2. HASHSIZE — параметр модуля ядра
# ============================================================
echo "[2/4] Настраиваю hashsize..."
echo 32768 > /sys/module/nf_conntrack/parameters/hashsize
cat <<EOF > /etc/modprobe.d/nf_conntrack.conf
options nf_conntrack hashsize=32768
EOF

# ============================================================
# 3. ЛИМИТЫ ФАЙЛОВ
# ============================================================
echo "[3/4] Настраиваю лимиты файловых дескрипторов..."

cat <<EOF > /etc/security/limits.d/99-nofile.conf
* soft nofile 51200
* hard nofile 51200
root soft nofile 51200
root hard nofile 51200
EOF

# PAM
if ! grep -q "pam_limits" /etc/pam.d/common-session 2>/dev/null; then
    echo "session required pam_limits.so" >> /etc/pam.d/common-session
fi

# Systemd глобально
mkdir -p /etc/systemd/system.conf.d/
cat <<EOF > /etc/systemd/system.conf.d/99-limits.conf
[Manager]
DefaultLimitNOFILE=51200
EOF

# Сервис x-ui отдельно
if systemctl list-units --type=service 2>/dev/null | grep -q "x-ui"; then
    mkdir -p /etc/systemd/system/x-ui.service.d/
    cat <<EOF > /etc/systemd/system/x-ui.service.d/limits.conf
[Service]
LimitNOFILE=51200
EOF
    systemctl daemon-reload
    echo "[INFO] Лимит применён к сервису x-ui"
else
    systemctl daemon-reload
    echo "[INFO] Сервис x-ui не найден, лимит применён глобально через systemd"
fi

# ============================================================
# 4. ПРОВЕРКА РЕЗУЛЬТАТА
# ============================================================
echo ""
echo "========================================"
echo "        РЕЗУЛЬТАТ ОПТИМИЗАЦИИ"
echo "========================================"

echo ""
echo "--- Conntrack ---"
sysctl net.netfilter.nf_conntrack_max
sysctl net.netfilter.nf_conntrack_count

echo ""
echo "--- Forwarding ---"
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding

echo ""
echo "--- BBR ---"
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc

echo ""
echo "--- Буферы TCP ---"
sysctl net.core.rmem_max
sysctl net.core.wmem_max

echo ""
echo "--- Оптимизация TCP для Xray ---"
sysctl net.ipv4.tcp_fin_timeout
sysctl net.ipv4.tcp_tw_reuse
sysctl net.ipv4.tcp_fastopen
sysctl net.core.somaxconn

echo ""
echo "--- Память ---"
sysctl vm.swappiness
sysctl vm.vfs_cache_pressure

echo ""
echo "--- Hashsize ---"
cat /sys/module/nf_conntrack/parameters/hashsize

echo ""
echo "--- Лимиты файлов (текущая сессия) ---"
ulimit -n

echo ""
echo "--- Использование памяти ---"
free -h

echo ""
echo "========================================"
echo " Готово! Настройки сохранены навсегда  "
echo "========================================"
echo ""
echo "Файлы конфигурации:"
echo "  /etc/sysctl.d/99-net-tuning.conf"
echo "  /etc/modprobe.d/nf_conntrack.conf"
echo "  /etc/security/limits.d/99-nofile.conf"
echo "  /etc/systemd/system.conf.d/99-limits.conf"
echo ""
echo "ВНИМАНИЕ: Буферы TCP увеличены до 16 МБ."
echo "При большом числе клиентов (100+) следите за памятью через 'free -h'"
