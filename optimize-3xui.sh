#!/bin/bash

# =============================================================
#   Оптимизация сервера для 3x-ui — Production Ready
#   Адаптация по RAM + CPU | Поддержка: Ubuntu/Debian
#   Требует: sudo
# =============================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: запустите через sudo"
    exit 1
fi

# ─────────────────────────────────────────────
# 1. ОПРЕДЕЛЕНИЕ РЕСУРСОВ
# ─────────────────────────────────────────────
TOTAL_RAM=$(free -g | awk '/^Mem:/{print $2}')
CPU_CORES=$(nproc)
# Битовая маска всех CPU (для RPS): 4 ядра = f, 8 ядер = ff
CPU_MASK=$(printf '%x' $(( (1 << CPU_CORES) - 1 )))

echo ""
echo "========================================"
echo "   3x-ui Production Optimizer"
echo "========================================"
echo "  RAM: ${TOTAL_RAM}GB | CPU: ${CPU_CORES} cores (mask: 0x${CPU_MASK})"
echo "========================================"

# ─────────────────────────────────────────────
# ПРОФИЛЬ ПО RAM
# ─────────────────────────────────────────────
if [ "$TOTAL_RAM" -le 1 ]; then
    RAM_TIER="1GB"
    CONNTRACK=131072
    HASHSIZE=32768
    BUFF_MAX=16777216
    BUFF_TCP="4096 87380 16777216"
    NOFILE=65535
    FIN_TIMEOUT=7
    MAX_ORPHANS=16384
    TW_BUCKETS=262144
elif [ "$TOTAL_RAM" -le 3 ]; then
    RAM_TIER="2-3GB"
    CONNTRACK=262144
    HASHSIZE=65536
    BUFF_MAX=33554432
    BUFF_TCP="4096 87380 33554432"
    NOFILE=131072
    FIN_TIMEOUT=5
    MAX_ORPHANS=32768
    TW_BUCKETS=524288
else
    RAM_TIER="4GB+"
    CONNTRACK=524288
    HASHSIZE=131072
    BUFF_MAX=67108864
    BUFF_TCP="4096 87380 67108864"
    NOFILE=262144
    FIN_TIMEOUT=3
    MAX_ORPHANS=65536
    TW_BUCKETS=720000
fi

# ─────────────────────────────────────────────
# ПРОФИЛЬ ПО CPU
# ─────────────────────────────────────────────
# SYN_BACKLOG    — очередь входящих SYN до accept()
# NETDEV_BACKLOG — очередь пакетов до обработки сетевым стеком
# SOMAXCONN      — макс. очередь accept() для listen-сокетов
# FLOW_ENTRIES   — таблица потоков RPS (степень 2)
# RPS_ENABLED    — включать ли RPS/RFS (бессмысленно на 1 ядре)

if [ "$CPU_CORES" -le 1 ]; then
    CPU_TIER="1 Core"
    SYN_BACKLOG=8192
    NETDEV_BACKLOG=16384
    SOMAXCONN=16384
    FLOW_ENTRIES=0
    RPS_ENABLED=0
elif [ "$CPU_CORES" -le 3 ]; then
    CPU_TIER="2-3 Cores"
    SYN_BACKLOG=32768
    NETDEV_BACKLOG=32768
    SOMAXCONN=32768
    FLOW_ENTRIES=32768
    RPS_ENABLED=1
elif [ "$CPU_CORES" -le 7 ]; then
    CPU_TIER="4-7 Cores"
    SYN_BACKLOG=65536
    NETDEV_BACKLOG=65536
    SOMAXCONN=65535
    FLOW_ENTRIES=65536
    RPS_ENABLED=1
else
    CPU_TIER="8+ Cores"
    SYN_BACKLOG=131072
    NETDEV_BACKLOG=131072
    SOMAXCONN=65535
    FLOW_ENTRIES=131072
    RPS_ENABLED=1
fi

echo "  RAM профиль : $RAM_TIER"
echo "  CPU профиль : $CPU_TIER"
echo "========================================"

# ─────────────────────────────────────────────
# 2. ЗАГРУЗКА МОДУЛЕЙ ЯДРА
# ─────────────────────────────────────────────
echo "[*] Загружаю модули ядра..."

modprobe tcp_bbr 2>/dev/null    && echo "    [+] tcp_bbr"    || echo "    [!] tcp_bbr недоступен, fallback -> cubic"
modprobe nf_conntrack 2>/dev/null && echo "    [+] nf_conntrack"

cat <<EOF > /etc/modules-load.d/3xui-modules.conf
tcp_bbr
nf_conntrack
EOF

# ─────────────────────────────────────────────
# 3. SWAP
# ─────────────────────────────────────────────
if ! swapon --show | grep -q '/swapfile'; then
    if [ ! -f /swapfile ]; then
        echo "[*] Создаю swap-файл 1GB..."
        fallocate -l 1G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
    else
        echo "[*] /swapfile существует, подключаю..."
    fi
    swapon /swapfile
    grep -qxF '/swapfile none swap sw 0 0' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "    [+] Swap подключён"
else
    echo "    [~] Swap уже активен"
fi

# ─────────────────────────────────────────────
# 4. SYSCTL — СЕТЬ, TCP, BBR, ПАМЯТЬ
# ─────────────────────────────────────────────
echo "[*] Применяю sysctl..."

if grep -q "tcp_bbr" /proc/modules 2>/dev/null; then
    TCP_CC="bbr"
else
    TCP_CC="cubic"
fi

cat <<EOF > /etc/sysctl.d/99-3xui-tuning.conf
# ==============================================
# 3x-ui Production Tuning
# RAM: $RAM_TIER | CPU: $CPU_TIER ($CPU_CORES cores)
# ==============================================

# --- Conntrack ---
net.netfilter.nf_conntrack_max = $CONNTRACK
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30

# --- Forwarding & BBR ---
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $TCP_CC

# --- Сетевые буферы (RAM: $RAM_TIER) ---
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = $BUFF_MAX
net.core.wmem_max = $BUFF_MAX
net.ipv4.tcp_rmem = $BUFF_TCP
net.ipv4.tcp_wmem = $BUFF_TCP
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# --- TCP оптимизация ---
net.ipv4.tcp_fin_timeout = $FIN_TIMEOUT
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_tw_buckets = $TW_BUCKETS
net.ipv4.tcp_max_orphans = $MAX_ORPHANS
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1

# --- Очереди и порты (CPU: $CPU_TIER) ---
net.ipv4.tcp_max_syn_backlog = $SYN_BACKLOG
net.core.netdev_max_backlog = $NETDEV_BACKLOG
net.core.somaxconn = $SOMAXCONN
net.ipv4.ip_local_port_range = 1024 65535

# --- RPS/RFS (CPU: $CPU_TIER) ---
net.core.rps_sock_flow_entries = $FLOW_ENTRIES

# --- Защита ---
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0

# --- Память и VM ---
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# --- Отключение IPv6 ---
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

sysctl -p /etc/sysctl.d/99-3xui-tuning.conf 2>&1 | grep -v "No such file" || true
echo "    [+] sysctl применён"

# ─────────────────────────────────────────────
# 5. RPS / RFS — РАСПРЕДЕЛЕНИЕ НАГРУЗКИ ПО ЯДРАМ
#    RPS (Receive Packet Steering) — раздаёт входящие пакеты
#    по всем CPU, а не только на то, куда пришло прерывание.
#    RFS (Receive Flow Steering) — направляет пакеты на CPU,
#    где реально работает приложение (меньше cache miss).
#    Итог: равномерная нагрузка, меньше латентность.
# ─────────────────────────────────────────────
if [ "$RPS_ENABLED" -eq 1 ]; then
    echo "[*] Настраиваю RPS/RFS (${CPU_CORES} ядер, mask=0x${CPU_MASK})..."

    # flow_cnt на очередь — делим FLOW_ENTRIES на число ядер, округляем до степени 2
    FLOW_PER_QUEUE=$(( FLOW_ENTRIES / CPU_CORES ))
    FLOW_PER_QUEUE_P2=1
    while [ "$FLOW_PER_QUEUE_P2" -lt "$FLOW_PER_QUEUE" ]; do
        FLOW_PER_QUEUE_P2=$(( FLOW_PER_QUEUE_P2 * 2 ))
    done

    for IFACE_PATH in /sys/class/net/*/; do
        IFACE_NAME=$(basename "$IFACE_PATH")
        [ "$IFACE_NAME" = "lo" ] && continue

        APPLIED=0
        for RPS_FILE in "${IFACE_PATH}queues/rx-"*/rps_cpus; do
            [ -f "$RPS_FILE" ] && echo "$CPU_MASK" > "$RPS_FILE" && APPLIED=1
        done
        for RFS_FILE in "${IFACE_PATH}queues/rx-"*/rps_flow_cnt; do
            [ -f "$RFS_FILE" ] && echo "$FLOW_PER_QUEUE_P2" > "$RFS_FILE"
        done
        [ "$APPLIED" -eq 1 ] && echo "    [+] $IFACE_NAME: rps_cpus=0x${CPU_MASK}, rps_flow_cnt=${FLOW_PER_QUEUE_P2}"
    done

    # udev — применять RPS/RFS автоматически для новых интерфейсов после reboot
    cat <<EOF > /etc/udev/rules.d/99-3xui-rps.rules
ACTION=="add", SUBSYSTEM=="net", RUN+="/usr/local/bin/3xui-rps-apply.sh %k"
EOF

    cat <<SCRIPT > /usr/local/bin/3xui-rps-apply.sh
#!/bin/bash
IFACE="\$1"
[ -z "\$IFACE" ] || [ "\$IFACE" = "lo" ] && exit 0
for F in /sys/class/net/\${IFACE}/queues/rx-*/rps_cpus;    do [ -f "\$F" ] && echo "${CPU_MASK}" > "\$F"; done
for F in /sys/class/net/\${IFACE}/queues/rx-*/rps_flow_cnt; do [ -f "\$F" ] && echo "${FLOW_PER_QUEUE_P2}"  > "\$F"; done
SCRIPT
    chmod +x /usr/local/bin/3xui-rps-apply.sh
    echo "    [+] udev правило сохранено — RPS/RFS будет применён после reboot"
else
    echo "    [~] RPS/RFS пропущен (1 ядро — не имеет смысла)"
fi

# ─────────────────────────────────────────────
# 6. ЛИМИТЫ ФАЙЛОВЫХ ДЕСКРИПТОРОВ
# ─────────────────────────────────────────────
echo "[*] Настраиваю лимиты дескрипторов ($NOFILE)..."

cat <<EOF > /etc/security/limits.d/99-3xui-nofile.conf
* soft nofile $NOFILE
* hard nofile $NOFILE
root soft nofile $NOFILE
root hard nofile $NOFILE
EOF

mkdir -p /etc/systemd/system.conf.d
cat <<EOF > /etc/systemd/system.conf.d/99-nofile.conf
[Manager]
DefaultLimitNOFILE=$NOFILE
EOF

if systemctl list-unit-files | grep -q "x-ui.service"; then
    mkdir -p /etc/systemd/system/x-ui.service.d
    cat <<EOF > /etc/systemd/system/x-ui.service.d/override.conf
[Service]
LimitNOFILE=$NOFILE
EOF
    echo "    [+] Лимиты применены к x-ui.service"
fi

systemctl daemon-reload
echo "    [+] Дескрипторы настроены"

# ─────────────────────────────────────────────
# 7. CONNTRACK HASHSIZE
# ─────────────────────────────────────────────
if [ -f /sys/module/nf_conntrack/parameters/hashsize ]; then
    echo $HASHSIZE > /sys/module/nf_conntrack/parameters/hashsize
    echo "options nf_conntrack hashsize=$HASHSIZE" > /etc/modprobe.d/nf_conntrack.conf
    echo "    [+] Conntrack hashsize: $HASHSIZE"
fi

# ─────────────────────────────────────────────
# 8. GRUB — IPv6 OFF
# ─────────────────────────────────────────────
if [ -f /etc/default/grub ]; then
    if ! grep -q "ipv6.disable=1" /etc/default/grub; then
        echo "[*] Отключаю IPv6 в GRUB..."
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 ipv6.disable=1"/' /etc/default/grub
        update-grub 2>/dev/null || grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
        echo "    [+] IPv6 отключён в GRUB"
    else
        echo "    [~] IPv6 в GRUB уже отключён"
    fi
fi

# ─────────────────────────────────────────────
# 9. ПЕРЕЗАПУСК x-ui
# ─────────────────────────────────────────────
if systemctl list-unit-files | grep -q "x-ui.service"; then
    echo "[*] Перезапускаю x-ui..."
    systemctl restart x-ui && echo "    [+] x-ui перезапущен" || echo "    [!] Не удалось перезапустить x-ui"
fi

# ─────────────────────────────────────────────
# ИТОГ
# ─────────────────────────────────────────────
echo ""
echo "========================================"
echo "   ОПТИМИЗАЦИЯ ВЫПОЛНЕНА УСПЕШНО"
echo "========================================"
printf "  %-20s: %s\n" "RAM профиль"     "$RAM_TIER"
printf "  %-20s: %s\n" "CPU профиль"     "$CPU_TIER"
printf "  %-20s: %s\n" "TCP CC"          "$TCP_CC"
printf "  %-20s: %s\n" "Conntrack max"   "$CONNTRACK"
printf "  %-20s: %s\n" "Conntrack hash"  "$HASHSIZE"
printf "  %-20s: %s\n" "Буферы (max)"    "$(( BUFF_MAX / 1024 / 1024 ))MB"
printf "  %-20s: %s\n" "SYN backlog"     "$SYN_BACKLOG"
printf "  %-20s: %s\n" "netdev backlog"  "$NETDEV_BACKLOG"
printf "  %-20s: %s\n" "somaxconn"       "$SOMAXCONN"
printf "  %-20s: %s\n" "FIN Timeout"     "${FIN_TIMEOUT}s"
printf "  %-20s: %s\n" "TW Buckets"      "$TW_BUCKETS"
printf "  %-20s: %s\n" "Max Orphans"     "$MAX_ORPHANS"
printf "  %-20s: %s\n" "NOFILE"          "$NOFILE"
printf "  %-20s: %s\n" "RPS/RFS"         "$([ "$RPS_ENABLED" -eq 1 ] && echo "Включён (mask=0x${CPU_MASK}, flows=${FLOW_ENTRIES})" || echo "Отключён (1 ядро)")"
printf "  %-20s: %s\n" "Swap"            "1GB"
printf "  %-20s: %s\n" "IPv6"            "Отключён"
echo "========================================"
echo ""
echo "  Рекомендуется перезагрузка: sudo reboot"
echo ""
