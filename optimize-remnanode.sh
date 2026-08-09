#!/bin/bash

# =============================================================
#   Оптимизация хоста для Remnawave / Remnanode (Docker)
#   Адаптация по RAM + CPU | Ubuntu/Debian | Требует: sudo
#
#   В отличие от версии под 3x-ui, здесь НЕТ привязки к
#   systemd-юниту "x-ui" — Remnanode работает в Docker
#   (network_mode: host), поэтому:
#     - NOFILE/логи уже настроены в docker-compose.yml (ulimits, json-file)
#     - OOM-приоритет ставится через `docker update`, не через systemd override
#     - Все sysctl-настройки применяются к хосту напрямую,
#       т.к. host-network контейнер использует сетевой стек хоста
#
#   Блоки:
#    1.  Определение ресурсов (RAM + CPU профили)
#    2.  Загрузка модулей ядра
#    3.  Swap
#    4.  Sysctl (TCP/BBR/память/conntrack)
#    5.  RPS / RFS
#    6.  CPU Governor -> performance
#    7.  IRQ Affinity
#    8.  NIC Offloading (TSO/GRO/GSO)
#    9.  THP — отключение Transparent HugePages
#   10.  Disk I/O Scheduler
#   11.  Conntrack hashsize
#   12.  GRUB — отключение IPv6
#   13.  OOM-приоритет для контейнеров remnanode/caddy
# =============================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: запустите через sudo"
    exit 1
fi

# ─────────────────────────────────────────────
# 1. ОПРЕДЕЛЕНИЕ РЕСУРСОВ
# ─────────────────────────────────────────────
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
CPU_CORES=$(nproc)
CPU_MASK=$(printf '%x' $(( (1 << CPU_CORES) - 1 )))

echo ""
echo "========================================"
echo "   Remnanode Host Optimizer"
echo "========================================"
echo "  RAM: ${TOTAL_RAM_MB}MB | CPU: ${CPU_CORES} cores (mask: 0x${CPU_MASK})"
echo "========================================"

if [ "$TOTAL_RAM_MB" -lt 1536 ]; then
    RAM_TIER="1GB"
    CONNTRACK=131072;  HASHSIZE=32768
    BUFF_MAX=16777216; BUFF_TCP="4096 87380 16777216"
    FIN_TIMEOUT=7
    MAX_ORPHANS=16384; TW_BUCKETS=262144
elif [ "$TOTAL_RAM_MB" -lt 3840 ]; then
    RAM_TIER="2-3GB"
    CONNTRACK=262144;  HASHSIZE=65536
    BUFF_MAX=33554432; BUFF_TCP="4096 87380 33554432"
    FIN_TIMEOUT=5
    MAX_ORPHANS=32768; TW_BUCKETS=524288
else
    RAM_TIER="4GB+"
    CONNTRACK=524288;  HASHSIZE=131072
    BUFF_MAX=67108864; BUFF_TCP="4096 87380 67108864"
    FIN_TIMEOUT=3
    MAX_ORPHANS=65536; TW_BUCKETS=720000
fi

if [ "$CPU_CORES" -le 1 ]; then
    CPU_TIER="1 Core"
    SYN_BACKLOG=8192;   NETDEV_BACKLOG=16384
    SOMAXCONN=16384;    FLOW_ENTRIES=0
    RPS_ENABLED=0
elif [ "$CPU_CORES" -le 3 ]; then
    CPU_TIER="2-3 Cores"
    SYN_BACKLOG=32768;  NETDEV_BACKLOG=32768
    SOMAXCONN=32768;    FLOW_ENTRIES=32768
    RPS_ENABLED=1
elif [ "$CPU_CORES" -le 7 ]; then
    CPU_TIER="4-7 Cores"
    SYN_BACKLOG=65536;  NETDEV_BACKLOG=65536
    SOMAXCONN=65535;    FLOW_ENTRIES=65536
    RPS_ENABLED=1
else
    CPU_TIER="8+ Cores"
    SYN_BACKLOG=131072; NETDEV_BACKLOG=131072
    SOMAXCONN=65535;    FLOW_ENTRIES=131072
    RPS_ENABLED=1
fi

echo "  RAM профиль : $RAM_TIER"
echo "  CPU профиль : $CPU_TIER"
echo "========================================"

# ─────────────────────────────────────────────
# 2. ЗАГРУЗКА МОДУЛЕЙ ЯДРА
# ─────────────────────────────────────────────
echo "[*] Загружаю модули ядра..."
modprobe tcp_bbr      2>/dev/null && echo "    [+] tcp_bbr"      || echo "    [!] tcp_bbr недоступен -> cubic"
modprobe nf_conntrack 2>/dev/null && echo "    [+] nf_conntrack"

cat <<EOF > /etc/modules-load.d/remnanode-modules.conf
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
# 4. SYSCTL — TCP / BBR / ПАМЯТЬ / CONNTRACK
#    ВАЖНО: используем ОДИН файл, чтобы не конфликтовать с
#    sysctl-файлом, который мог накатить install_remnawave.sh
#    (проверь после запуска: sysctl net.ipv4.tcp_congestion_control)
# ─────────────────────────────────────────────
echo "[*] Применяю sysctl..."

grep -q "tcp_bbr" /proc/modules 2>/dev/null && TCP_CC="bbr" || TCP_CC="cubic"

# убираем возможный старый файл от eGamesAPI-скрипта, чтобы не спорил порядком применения
if [ -f /etc/sysctl.d/98-remnawave.conf ]; then
    echo "    [~] Найден /etc/sysctl.d/98-remnawave.conf (от install-скрипта) — объединяю с ним"
fi

cat <<EOF > /etc/sysctl.d/99-remnanode-tuning.conf
# Remnanode Host Tuning | RAM: $RAM_TIER | CPU: $CPU_TIER

# --- Conntrack ---
net.netfilter.nf_conntrack_max = $CONNTRACK
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30

# --- Forwarding & congestion control ---
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = $TCP_CC

# --- Буферы (RAM: $RAM_TIER) ---
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = $BUFF_MAX
net.core.wmem_max = $BUFF_MAX
net.ipv4.tcp_rmem = $BUFF_TCP
net.ipv4.tcp_wmem = $BUFF_TCP
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# --- TCP ---
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

# --- Очереди (CPU: $CPU_TIER) ---
net.ipv4.tcp_max_syn_backlog = $SYN_BACKLOG
net.core.netdev_max_backlog = $NETDEV_BACKLOG
net.core.somaxconn = $SOMAXCONN
net.ipv4.ip_local_port_range = 1024 65535
net.core.rps_sock_flow_entries = $FLOW_ENTRIES

# --- Защита ---
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0

# --- VM / Память ---
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# --- Отключение IPv6 (защита от лика мимо туннеля) ---
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

sysctl -p /etc/sysctl.d/99-remnanode-tuning.conf 2>&1 | grep -v "No such file" || true
echo "    [+] sysctl применён (TCP CC: $TCP_CC)"
echo "    [i] Проверь итоговое значение: sysctl net.ipv4.tcp_congestion_control net.core.rmem_max"

# ─────────────────────────────────────────────
# 5. RPS / RFS
# ─────────────────────────────────────────────
if [ "$RPS_ENABLED" -eq 1 ]; then
    echo "[*] Настраиваю RPS/RFS (${CPU_CORES} ядер, mask=0x${CPU_MASK})..."

    FLOW_PER_QUEUE=$(( FLOW_ENTRIES / CPU_CORES ))
    FLOW_PER_QUEUE_P2=1
    while [ "$FLOW_PER_QUEUE_P2" -lt "$FLOW_PER_QUEUE" ]; do
        FLOW_PER_QUEUE_P2=$(( FLOW_PER_QUEUE_P2 * 2 ))
    done

    for IFACE_PATH in /sys/class/net/*/; do
        IFACE_NAME=$(basename "$IFACE_PATH")
        [ "$IFACE_NAME" = "lo" ] && continue
        [[ "$IFACE_NAME" =~ ^(docker|veth|br-|virbr|tun|tap) ]] && continue
        APPLIED=0
        for F in "${IFACE_PATH}queues/rx-"*/rps_cpus;    do [ -f "$F" ] && echo "$CPU_MASK"          > "$F" && APPLIED=1; done
        for F in "${IFACE_PATH}queues/rx-"*/rps_flow_cnt; do [ -f "$F" ] && echo "$FLOW_PER_QUEUE_P2" > "$F"; done
        [ "$APPLIED" -eq 1 ] && echo "    [+] $IFACE_NAME -> rps_cpus=0x${CPU_MASK}, flow_cnt=${FLOW_PER_QUEUE_P2}"
    done

    cat <<EOF > /etc/udev/rules.d/99-remnanode-rps.rules
ACTION=="add", SUBSYSTEM=="net", RUN+="/usr/local/bin/remnanode-rps-apply.sh %k"
EOF
    cat <<SCRIPT > /usr/local/bin/remnanode-rps-apply.sh
#!/bin/bash
IFACE="\$1"
case "\$IFACE" in lo|docker*|veth*|br-*|virbr*|tun*|tap*) exit 0 ;; esac
for F in /sys/class/net/\${IFACE}/queues/rx-*/rps_cpus;    do [ -f "\$F" ] && echo "${CPU_MASK}"          > "\$F"; done
for F in /sys/class/net/\${IFACE}/queues/rx-*/rps_flow_cnt; do [ -f "\$F" ] && echo "${FLOW_PER_QUEUE_P2}" > "\$F"; done
SCRIPT
    chmod +x /usr/local/bin/remnanode-rps-apply.sh
    echo "    [+] udev правило сохранено"
else
    echo "    [~] RPS/RFS пропущен (1 ядро)"
fi

# ─────────────────────────────────────────────
# 6. CPU GOVERNOR -> performance
# ─────────────────────────────────────────────
echo "[*] Настраиваю CPU Governor..."

RC_LOCAL="/etc/rc.local"
if [ ! -f "$RC_LOCAL" ]; then
    echo '#!/bin/bash' > "$RC_LOCAL"
    echo 'exit 0' >> "$RC_LOCAL"
    chmod +x "$RC_LOCAL"
fi

GOV_APPLIED=0
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    for CPU_PATH in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$CPU_PATH" ] && echo "performance" > "$CPU_PATH" && GOV_APPLIED=1
    done
    [ "$GOV_APPLIED" -eq 1 ] && echo "    [+] Governor -> performance (все ядра)"
    if ! grep -q "scaling_governor" "$RC_LOCAL"; then
        sed -i '/^exit 0/i for F in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -f "$F" ] \&\& echo performance > "$F"; done' "$RC_LOCAL"
    fi
    command -v cpupower &>/dev/null && cpupower frequency-set -g performance &>/dev/null || true
else
    echo "    [~] cpufreq недоступен (виртуальная среда без управления частотой — обычно так и есть на VPS)"
fi

# ─────────────────────────────────────────────
# 7. IRQ AFFINITY
# ─────────────────────────────────────────────
if [ "$CPU_CORES" -gt 1 ]; then
    echo "[*] Настраиваю IRQ Affinity..."
    IRQ_APPLIED=0
    for IFACE_PATH in /sys/class/net/*/; do
        IFACE_NAME=$(basename "$IFACE_PATH")
        [ "$IFACE_NAME" = "lo" ] && continue
        [[ "$IFACE_NAME" =~ ^(docker|veth|br-|virbr|tun|tap) ]] && continue
        IRQ_DIR="${IFACE_PATH}device/msi_irqs"
        if [ -d "$IRQ_DIR" ]; then
            IRQ_NUM=0
            for IRQ in "$IRQ_DIR"/*; do
                IRQ_ID=$(basename "$IRQ")
                TARGET_CPU=$(( IRQ_NUM % CPU_CORES ))
                [ "$CPU_CORES" -gt 2 ] && [ "$TARGET_CPU" -eq 0 ] && TARGET_CPU=1
                AFFINITY=$(printf '%x' $(( 1 << TARGET_CPU )))
                [ -f "/proc/irq/${IRQ_ID}/smp_affinity" ] && echo "$AFFINITY" > "/proc/irq/${IRQ_ID}/smp_affinity" 2>/dev/null && IRQ_APPLIED=$(( IRQ_APPLIED + 1 )) || true
                IRQ_NUM=$(( IRQ_NUM + 1 ))
            done
            [ "$IRQ_APPLIED" -gt 0 ] && echo "    [+] $IFACE_NAME -> ${IRQ_APPLIED} IRQ распределено по ядрам"
        fi
    done
    [ "$IRQ_APPLIED" -eq 0 ] && echo "    [~] MSI IRQ недоступны (частая ситуация на VPS) — пропущено"

    cat <<'IRQSCRIPT' > /usr/local/bin/remnanode-irq-affinity.sh
#!/bin/bash
CPU_CORES=$(nproc)
[ "$CPU_CORES" -le 1 ] && exit 0
for IFACE_PATH in /sys/class/net/*/; do
    IFACE_NAME=$(basename "$IFACE_PATH")
    case "$IFACE_NAME" in lo|docker*|veth*|br-*|virbr*|tun*|tap*) continue ;; esac
    IRQ_DIR="${IFACE_PATH}device/msi_irqs"
    [ -d "$IRQ_DIR" ] || continue
    IRQ_NUM=0
    for IRQ in "$IRQ_DIR"/*; do
        IRQ_ID=$(basename "$IRQ")
        TARGET_CPU=$(( IRQ_NUM % CPU_CORES ))
        [ "$CPU_CORES" -gt 2 ] && [ "$TARGET_CPU" -eq 0 ] && TARGET_CPU=1
        AFFINITY=$(printf '%x' $(( 1 << TARGET_CPU )))
        [ -f "/proc/irq/${IRQ_ID}/smp_affinity" ] && echo "$AFFINITY" > "/proc/irq/${IRQ_ID}/smp_affinity" 2>/dev/null || true
        IRQ_NUM=$(( IRQ_NUM + 1 ))
    done
done
IRQSCRIPT
    chmod +x /usr/local/bin/remnanode-irq-affinity.sh
    if ! grep -q "irq-affinity" "$RC_LOCAL" 2>/dev/null; then
        sed -i '/^exit 0/i /usr/local/bin/remnanode-irq-affinity.sh' "$RC_LOCAL"
    fi
else
    echo "    [~] IRQ Affinity пропущен (1 ядро)"
fi

# ─────────────────────────────────────────────
# 8. NIC OFFLOADING (TSO / GRO / GSO)
# ─────────────────────────────────────────────
echo "[*] Настраиваю NIC Offloading..."

IS_VIRTUAL=0
if systemd-detect-virt --quiet 2>/dev/null; then
    IS_VIRTUAL=1
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    echo "    [~] Виртуализация обнаружена: $VIRT_TYPE"
fi

NIC_SCRIPT="/usr/local/bin/remnanode-nic-offload.sh"
echo '#!/bin/bash' > "$NIC_SCRIPT"
echo 'command -v ethtool &>/dev/null || exit 0' >> "$NIC_SCRIPT"

NIC_APPLIED=0
if command -v ethtool &>/dev/null; then
    for IFACE_PATH in /sys/class/net/*/; do
        IFACE_NAME=$(basename "$IFACE_PATH")
        [ "$IFACE_NAME" = "lo" ] && continue
        [[ "$IFACE_NAME" =~ ^(tun|tap|veth|docker|br-|virbr) ]] && continue

        if [ "$IS_VIRTUAL" -eq 0 ]; then
            ethtool -K "$IFACE_NAME" tso on  gso on  gro on  2>/dev/null || true
            echo "    [+] $IFACE_NAME -> TSO/GSO/GRO включены (физический сервер)"
            echo "ethtool -K $IFACE_NAME tso on  gso on  gro on  2>/dev/null || true" >> "$NIC_SCRIPT"
        else
            ethtool -K "$IFACE_NAME" tso off gso off gro on  2>/dev/null || true
            echo "    [+] $IFACE_NAME -> TSO/GSO выкл, GRO вкл (виртуальная среда)"
            echo "ethtool -K $IFACE_NAME tso off gso off gro on  2>/dev/null || true" >> "$NIC_SCRIPT"
        fi
        NIC_APPLIED=1
    done
fi
[ "$NIC_APPLIED" -eq 0 ] && echo "    [~] ethtool недоступен — пропущено (apt install ethtool)"
chmod +x "$NIC_SCRIPT"
if ! grep -q "nic-offload" "$RC_LOCAL" 2>/dev/null; then
    sed -i '/^exit 0/i /usr/local/bin/remnanode-nic-offload.sh' "$RC_LOCAL"
fi

# ─────────────────────────────────────────────
# 9. THP — ОТКЛЮЧЕНИЕ TRANSPARENT HUGEPAGES
# ─────────────────────────────────────────────
echo "[*] Отключаю Transparent HugePages..."

THP_APPLIED=0
for THP_PATH in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag \
                /sys/kernel/mm/redhat_transparent_hugepage/enabled /sys/kernel/mm/redhat_transparent_hugepage/defrag; do
    if [ -f "$THP_PATH" ]; then
        echo "never" > "$THP_PATH"
        THP_APPLIED=1
    fi
done

if [ "$THP_APPLIED" -eq 1 ]; then
    echo "    [+] THP -> never"
else
    echo "    [~] THP файлы не найдены (частая ситуация в контейнеризированных VPS-ядрах)"
fi

if ! grep -q "transparent_hugepage" "$RC_LOCAL" 2>/dev/null; then
    sed -i '/^exit 0/i for F in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do [ -f "$F" ] \&\& echo never > "$F"; done' "$RC_LOCAL"
fi

# ─────────────────────────────────────────────
# 10. DISK I/O SCHEDULER
# ─────────────────────────────────────────────
echo "[*] Настраиваю Disk I/O Scheduler..."

IO_APPLIED=0
for DISK in /sys/block/*/; do
    DISK_NAME=$(basename "$DISK")
    [[ "$DISK_NAME" =~ ^(loop|ram|dm|md|sr) ]] && continue
    SCHED_FILE="${DISK}queue/scheduler"
    [ -f "$SCHED_FILE" ] || continue

    CURRENT_SCHED=$(cat "$SCHED_FILE")
    ROTATIONAL=$(cat "${DISK}queue/rotational" 2>/dev/null || echo "1")

    if [ "$ROTATIONAL" -eq 0 ]; then
        if echo "$CURRENT_SCHED" | grep -q "none"; then
            echo "none" > "$SCHED_FILE" 2>/dev/null || true
            echo "    [+] $DISK_NAME (SSD/NVMe) -> none"
        elif echo "$CURRENT_SCHED" | grep -q "mq-deadline"; then
            echo "mq-deadline" > "$SCHED_FILE" 2>/dev/null || true
            echo "    [+] $DISK_NAME (SSD) -> mq-deadline"
        fi
    else
        if echo "$CURRENT_SCHED" | grep -q "mq-deadline"; then
            echo "mq-deadline" > "$SCHED_FILE" 2>/dev/null || true
            echo "    [+] $DISK_NAME (HDD) -> mq-deadline"
        fi
    fi
    IO_APPLIED=1
done
[ "$IO_APPLIED" -eq 0 ] && echo "    [~] Блочные устройства не найдены"

cat <<'EOF' > /etc/udev/rules.d/60-remnanode-ioscheduler.rules
ACTION=="add|change", KERNEL=="sd[a-z]|nvme[0-9]n[0-9]|vd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
EOF

# ─────────────────────────────────────────────
# 11. CONNTRACK HASHSIZE
# ─────────────────────────────────────────────
if [ -f /sys/module/nf_conntrack/parameters/hashsize ]; then
    if echo "$HASHSIZE" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null; then
        echo "    [+] Conntrack hashsize: $HASHSIZE"
    else
        echo "    [~] Не удалось изменить hashsize на лету (модуль уже активен) — применится после перезагрузки"
    fi
    echo "options nf_conntrack hashsize=$HASHSIZE" > /etc/modprobe.d/nf_conntrack.conf
else
    echo "    [~] nf_conntrack параметры недоступны — пропущено"
fi

# ─────────────────────────────────────────────
# 12. GRUB — IPv6 OFF
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
# 13. OOM-ПРИОРИТЕТ ДЛЯ КОНТЕЙНЕРОВ remnanode/caddy
#     ВАЖНО: `docker update --oom-score-adj` НЕ поддерживается Docker —
#     флаг применяется только при СОЗДАНИИ контейнера (docker run/create
#     или ключ oom_score_adj в docker-compose.yml), не через update.
#     Поэтому сюда просто выводим инструкцию, а не пытаемся патчить
#     контейнер на лету — это гарантированно не сработает.
# ─────────────────────────────────────────────
COMPOSE_FILE="/opt/remnanode/docker-compose.yml"
echo "[*] OOM-приоритет: требует правки docker-compose.yml, не применяется на лету"

if [ -f "$COMPOSE_FILE" ]; then
    if grep -q "oom_score_adj" "$COMPOSE_FILE"; then
        echo "    [~] oom_score_adj уже прописан в $COMPOSE_FILE"
    else
        echo "    [!] Добавь вручную в x-common якорь в $COMPOSE_FILE:"
        echo "          oom_score_adj: -500"
        echo "        затем: cd /opt/remnanode && docker compose up -d --force-recreate"
    fi
else
    echo "    [~] $COMPOSE_FILE не найден — пропущено, поправь путь при необходимости"
fi

# ─────────────────────────────────────────────
# ИТОГ
# ─────────────────────────────────────────────
echo ""
echo "========================================"
echo "   ОПТИМИЗАЦИЯ ВЫПОЛНЕНА"
echo "========================================"
printf "  %-22s: %s\n" "RAM профиль"    "$RAM_TIER (${TOTAL_RAM_MB}MB)"
printf "  %-22s: %s\n" "CPU профиль"    "$CPU_TIER"
printf "  %-22s: %s\n" "TCP CC"         "$TCP_CC"
printf "  %-22s: %s\n" "Conntrack max"  "$CONNTRACK"
printf "  %-22s: %s\n" "Буферы (max)"   "$(( BUFF_MAX / 1024 / 1024 ))MB"
printf "  %-22s: %s\n" "RPS/RFS"        "$([ "$RPS_ENABLED" -eq 1 ] && echo "Вкл" || echo "Откл (1 ядро)")"
printf "  %-22s: %s\n" "THP"            "$([ "$THP_APPLIED" -eq 1 ] && echo "отключён" || echo "не найден")"
printf "  %-22s: %s\n" "IPv6"           "Отключён"
printf "  %-22s: %s\n" "Swap"           "1GB"
echo "========================================"
echo ""
echo "  Проверь после ребута:"
echo "    sysctl net.ipv4.tcp_congestion_control"
echo "    sysctl net.core.rmem_max"
echo "    docker inspect remnanode | grep -i oom"
echo ""
echo "  Рекомендуется перезагрузка: sudo reboot"
echo ""
