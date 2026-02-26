#!/bin/bash

if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: запустите скрипт через sudo (sudo ./optimize_net_2gb.sh)"
    exit 1
fi

echo "--- Начинаю полную оптимизацию сервера для 3x-ui (2GB RAM, 2 ядра) ---"

# ============================================================
# 1. SYSCTL — сетевые параметры ядра
# ============================================================
echo "[1/4] Применяю параметры ядра..."

# Conntrack
sysctl -w net.netfilter.nf_conntrack_max=262144
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=3600
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=15

# Forwarding (только IPv4, IPv6 отключаем)
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv6.conf.all.forwarding=0

# Отключение IPv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
sysctl -w net.ipv6.conf.lo.disable_ipv6=1

# BBR
sysctl -w net.core.default_qdisc=fq
sysctl -w net.ipv4.tcp_congestion_control=bbr

# Буферы TCP (под 2GB RAM, оптимизированы для VPN)
sysctl -w net.core.rmem_max=33554432
sysctl -w net.core.wmem_max=33554432
sysctl -w net.ipv4.tcp_rmem="4096 87380 33554432"
sysctl -w net.ipv4.tcp_wmem="4096 65536 33554432"

# Оптимизация TCP для Xray
sysctl -w net.ipv4.tcp_fin_timeout=5
sysctl -w net.ipv4.tcp_tw_reuse=1
sysctl -w net.ipv4.tcp_keepalive_time=300
sysctl -w net.ipv4.tcp_keepalive_probes=3
sysctl -w net.ipv4.tcp_keepalive_intvl=15
sysctl -w net.core.somaxconn=131072
sysctl -w net.ipv4.tcp_max_tw_buckets=2880000
sysctl -w net.ipv4.tcp_max_orphans=65536
sysctl -w net.ipv4.tcp_max_syn_backlog=32768

# MTU и TFO
sysctl -w net.ipv4.tcp_mtu_probing=1
sysctl -w net.ipv4.tcp_fastopen=3

# Защита
sysctl -w net.ipv4.tcp_syncookies=1
sysctl -w net.ipv4.conf.all.rp_filter=1
sysctl -w net.ipv4.icmp_echo_ignore_broadcasts=1

# Память
sysctl -w vm.swappiness=10
sysctl -w vm.vfs_cache_pressure=50

echo "[1/4] Сохраняю в /etc/sysctl.d/99-net-tuning.conf..."
cat <<EOF > /etc/sysctl.d/99-net-tuning.conf
# === Conntrack ===
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15

# === Forwarding (только IPv4) ===
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 0

# === Отключение IPv6 ===
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# === BBR ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === Буферы TCP (2GB RAM, оптимизированы для VPN) ===
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# === Оптимизация TCP для Xray ===
net.ipv4.tcp_fin_timeout = 5
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 15
net.core.somaxconn = 131072
net.ipv4.tcp_max_tw_buckets = 2880000
net.ipv4.tcp_max_orphans = 65536
net.ipv4.tcp_max_syn_backlog = 32768

# === MTU и TCP Fast Open ===
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3

# === Защита ===
net.ipv4.tcp_syncookies = 1
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
echo 65536 > /sys/module/nf_conntrack/parameters/hashsize
cat <<EOF > /etc/modprobe.d/nf_conntrack.conf
options nf_conntrack hashsize=65536
EOF

# ============================================================
# 3. ЛИМИТЫ ФАЙЛОВ
# ============================================================
echo "[3/4] Настраиваю лимиты файловых дескрипторов..."

cat <<EOF > /etc/security/limits.d/99-nofile.conf
* soft nofile 131072
* hard nofile 131072
root soft nofile 131072
root hard nofile 131072
EOF

# PAM
if ! grep -q "pam_limits" /etc/pam.d/common-session 2>/dev/null; then
    echo "session required pam_limits.so" >> /etc/pam.d/common-session
fi

# Systemd глобально
mkdir -p /etc/systemd/system.conf.d/
cat <<EOF > /etc/systemd/system.conf.d/99-limits.conf
[Manager]
DefaultLimitNOFILE=131072
EOF

# Сервис x-ui отдельно
if systemctl list-units --type=service 2>/dev/null | grep -q "x-ui"; then
    mkdir -p /etc/systemd/system/x-ui.service.d/
    cat <<EOF > /etc/systemd/system/x-ui.service.d/limits.conf
[Service]
LimitNOFILE=131072
EOF
    systemctl daemon-reload
    echo "[INFO] Лимит применён к сервису x-ui"
else
    systemctl daemon-reload
    echo "[INFO] Сервис x-ui не найден, лимит применён глобально через systemd"
fi

# ============================================================
# 4. Отключение IPv6 в UFW
# ============================================================
echo "[4/4] Отключаю IPv6 в UFW..."

if [ -f /etc/ufw/sysctl.conf ]; then
    sed -i 's/net\/ipv6\/conf\/default\/forwarding=1/#net\/ipv6\/conf\/default\/forwarding=1/' /etc/ufw/sysctl.conf
    sed -i 's/net\/ipv6\/conf\/all\/forwarding=1/#net\/ipv6\/conf\/all\/forwarding=1/' /etc/ufw/sysctl.conf

    if ! grep -q "disable_ipv6" /etc/ufw/sysctl.conf; then
        cat <<EOF >> /etc/ufw/sysctl.conf
net/ipv6/conf/all/disable_ipv6=1
net/ipv6/conf/default/disable_ipv6=1
net/ipv6/conf/lo/disable_ipv6=1
EOF
    fi
    echo "[INFO] UFW sysctl обновлён"
fi

# Применить и перезапустить x-ui
sysctl -p /etc/sysctl.d/99-net-tuning.conf
systemctl restart x-ui 2>/dev/null && echo "[INFO] x-ui перезапущен" || echo "[INFO] x-ui не найден"

# ============================================================
# 5. ПРОВЕРКА РЕЗУЛЬТАТА
# ============================================================
echo ""
echo "========================================"
echo "        РЕЗУЛЬТАТ ОПТИМИЗАЦИИ"
echo "========================================"

echo ""
echo "--- Conntrack ---"
sysctl net.netfilter.nf_conntrack_max
sysctl net.netfilter.nf_conntrack_count 2>/dev/null

echo ""
echo "--- Forwarding ---"
sysctl net.ipv4.ip_forward

echo ""
echo "--- IPv6 ---"
sysctl net.ipv6.conf.all.disable_ipv6
ip -6 addr show 2>/dev/null | grep -v "::1" | grep inet6 && echo "ВНИМАНИЕ: IPv6 ещё активен" || echo "IPv6 отключён успешно"

echo ""
echo "--- BBR ---"
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc

echo ""
echo "--- Буферы TCP ---"
sysctl net.core.rmem_max
sysctl net.core.wmem_max

echo ""
echo "--- Оптимизация TCP ---"
sysctl net.ipv4.tcp_fin_timeout
sysctl net.ipv4.tcp_tw_reuse
sysctl net.ipv4.tcp_fastopen
sysctl net.core.somaxconn
sysctl net.ipv4.tcp_max_orphans

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
echo "  /etc/systemd/system/x-ui.service.d/limits.conf"
echo ""
echo "Изменения относительно оригинала (1GB → 2GB, 1 ядро → 2 ядра):"
echo "  tcp буферы:       16MB → 32MB"
echo "  somaxconn:        65535 → 131072"
echo "  tcp_max_tw_buckets: 1440000 → 2880000"
echo "  tcp_max_orphans:  4096 → 65536 (новое)"
echo "  tcp_max_syn_backlog: 16384 → 32768"
echo "  conntrack_max:    131072 → 262144"
echo "  hashsize:         32768 → 65536"
echo "  nofile лимит:     51200 → 131072"
echo "  tcp_fin_timeout:  10 → 5"
echo "  IPv6:             отключён"
