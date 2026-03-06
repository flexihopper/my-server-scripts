#!/bin/bash

# =============================================================
#   Оптимизация сервера для 3x-ui — Production Ready v3
#   Адаптация по RAM + CPU | Ubuntu/Debian | Требует: sudo
#
#   Блоки:
#    1.  Определение ресурсов (RAM + CPU профили)
#    2.  Загрузка модулей ядра
#    3.  Swap
#    4.  Sysctl (TCP/BBR/память)
#    5.  RPS / RFS
#    6.  CPU Governor → performance
#    7.  IRQ Affinity
#    8.  NIC Offloading (TSO/GRO/GSO)
#    9.  THP — отключение Transparent HugePages
#   10.  Disk I/O Scheduler
#   11.  OOM защита x-ui
#   12.  Лимиты файловых дескрипторов
#   13.  Conntrack hashsize
#   14.  Ротация логов x-ui
#   15.  GRUB — отключение IPv6
#   16.  Перезапуск x-ui
# =============================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: запустите через sudo"
    exit 1
fi

# ─────────────────────────────────────────────
# 1. ОПРЕДЕЛЕНИЕ РЕСУРСОВ
# ─────────────────────────────────────────────

# free -g округляет вниз: 1.9GB → 1 (неверный профиль).
# Используем MB и сравниваем точнее.
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
CPU_CORES=$(nproc)
CPU_MASK=$(printf '%x' $(( (1 << CPU_CORES) - 1 )))

echo ""
echo "========================================"
echo "   3x-ui Production Optimizer v3"
echo "========================================"
echo "  RAM: ${TOTAL_RAM_MB}MB | CPU: ${CPU_CORES} cores (mask: 0x${CPU_MASK})"
echo "========================================"

# --- Профиль по RAM ---
# Граница 1GB:   < 1536MB  (до 1.5GB включительно)
# Граница 2-3GB: < 3840MB  (до 3.75GB включительно)
# Граница 4GB+:  всё остальное
if [ "$TOTAL_RAM_MB" -lt 1536 ]; then
    RAM_TIER="1GB"
    CONNTRACK=131072;  HASHSIZE=32768
    BUFF_MAX=16777216; BUFF_TCP="4096 87380 16777216"
    NOFILE=65535;      FIN_TIMEOUT=7
    MAX_ORPHANS=16384; TW_BUCKETS=262144
elif [ "$TOTAL_RAM_MB" -lt 3840 ]; then
    RAM_TIER="2-3GB"
    CONNTRACK=262144;  HASHSIZE=65536
    BUFF_MAX=33554432; BUFF_TCP="4096 87380 33554432"
    NOFILE=131072;     FIN_TIMEOUT=5
    MAX_ORPHANS=32768; TW_BUCKETS=524288
else
    RAM_TIER="4GB+"
    CONNTRACK=524288;  HASHSIZE=131072
    BUFF_MAX=67108864; BUFF_TCP="4096 87380 67108864"
    NOFILE=262144;     FIN_TIMEOUT=3
    MAX_ORPHANS=65536; TW_BUCKETS=720000
fi

# --- Профиль по CPU ---
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

modprobe tcp_bbr    2>/dev/null && echo "    [+] tcp_bbr"    || echo "    [!] tcp_bbr недоступен → cubic"
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
# 4. SYSCTL — TCP / BBR / ПАМЯТЬ
# ─────────────────────────────────────────────
echo "[*] Применяю sysctl..."

grep -q "tcp_bbr" /proc/modules 2>/dev/null && TCP_CC="bbr" || TCP_CC="cubic"

cat <<EOF > /etc/sysctl.d/99-3xui-tuning.conf
# 3x-ui Production Tuning | RAM: $RAM_TIER | CPU: $CPU_TIER

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
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0

# --- VM / Память ---
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
echo "    [+] sysctl применён (TCP CC: $TCP_CC)"

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
        APPLIED=0
        for F in "${IFACE_PATH}queues/rx-"*/rps_cpus;    do [ -f "$F" ] && echo "$CPU_MASK"          > "$F" && APPLIED=1; done
        for F in "${IFACE_PATH}queues/rx-"*/rps_flow_cnt; do [ -f "$F" ] && echo "$FLOW_PER_QUEUE_P2" > "$F"; done
        [ "$APPLIED" -eq 1 ] && echo "    [+] $IFACE_NAME → rps_cpus=0x${CPU_MASK}, flow_cnt=${FLOW_PER_QUEUE_P2}"
    done

    cat <<EOF > /etc/udev/rules.d/99-3xui-rps.rules
ACTION=="add", SUBSYSTEM=="net", RUN+="/usr/local/bin/3xui-rps-apply.sh %k"
EOF
    cat <<SCRIPT > /usr/local/bin/3xui-rps-apply.sh
#!/bin/bash
IFACE="\$1"; [ -z "\$IFACE" ] || [ "\$IFACE" = "lo" ] && exit 0
for F in /sys/class/net/\${IFACE}/queues/rx-*/rps_cpus;    do [ -f "\$F" ] && echo "${CPU_MASK}"          > "\$F"; done
for F in /sys/class/net/\${IFACE}/queues/rx-*/rps_flow_cnt; do [ -f "\$F" ] && echo "${FLOW_PER_QUEUE_P2}" > "\$F"; done
SCRIPT
    chmod +x /usr/local/bin/3xui-rps-apply.sh
    echo "    [+] udev правило сохранено"
else
    echo "    [~] RPS/RFS пропущен (1 ядро)"
fi

# ─────────────────────────────────────────────
# 6. CPU GOVERNOR → performance
#    Режим performance фиксирует максимальную частоту CPU.
#    powersave/ondemand добавляют латентность из-за рампинга.
# ─────────────────────────────────────────────
echo "[*] Настраиваю CPU Governor..."

GOV_APPLIED=0
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    for CPU_PATH in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$CPU_PATH" ] && echo "performance" > "$CPU_PATH" && GOV_APPLIED=1
    done
    if [ "$GOV_APPLIED" -eq 1 ]; then
        echo "    [+] Governor → performance (все ядра)"
    fi
else
    echo "    [~] cpufreq недоступен (виртуальная среда без управления частотой)"
    GOV_APPLIED=2  # пометка: не ошибка, просто недоступно
fi

# Сохраняем через cpufrequtils или systemd (если доступно)
if command -v cpufreq-set &>/dev/null; then
    CPUFREQ_OK=0
    for i in $(seq 0 $(( CPU_CORES - 1 ))); do
        cpufreq-set -c "$i" -g performance 2>/dev/null && CPUFREQ_OK=1 || true
    done
    [ "$CPUFREQ_OK" -eq 1 ] && echo "    [+] cpufrequtils — governor закреплён" \
                             || echo "    [~] cpufrequtils недоступен на этой VM"
elif [ -f /etc/default/cpufrequtils ]; then
    sed -i 's/^GOVERNOR=.*/GOVERNOR="performance"/' /etc/default/cpufrequtils
    echo "    [+] /etc/default/cpufrequtils обновлён"
fi

# Через systemd-cpupower (если есть)
if command -v cpupower &>/dev/null; then
    cpupower frequency-set -g performance 2>/dev/null && echo "    [+] cpupower — governor применён" || true
fi

# rc.local fallback — гарантия при reboot
RC_LOCAL="/etc/rc.local"
if [ ! -f "$RC_LOCAL" ]; then
    echo '#!/bin/bash' > "$RC_LOCAL"
    echo 'exit 0' >> "$RC_LOCAL"
    chmod +x "$RC_LOCAL"
fi
# Вставляем перед exit 0
if ! grep -q "scaling_governor" "$RC_LOCAL"; then
    sed -i '/^exit 0/i for F in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -f "$F" ] \&\& echo performance > "$F"; done' "$RC_LOCAL"
    echo "    [+] rc.local — governor будет применяться при reboot"
fi

# ─────────────────────────────────────────────
# 7. IRQ AFFINITY
#    Привязываем прерывания сетевых карт к конкретным ядрам,
#    чтобы не конкурировать с ядром 0 (системные прерывания).
#    На многоядерных серверах снижает латентность и jitter.
# ─────────────────────────────────────────────
if [ "$CPU_CORES" -gt 1 ]; then
    echo "[*] Настраиваю IRQ Affinity..."

    IRQ_APPLIED=0
    # Получаем список IRQ сетевых устройств (исключаем lo)
    for IFACE_PATH in /sys/class/net/*/; do
        IFACE_NAME=$(basename "$IFACE_PATH")
        [ "$IFACE_NAME" = "lo" ] && continue

        # Ищем IRQ через msi_irqs или irq
        IRQ_DIR="${IFACE_PATH}device/msi_irqs"
        if [ -d "$IRQ_DIR" ]; then
            IRQ_NUM=0
            for IRQ in "$IRQ_DIR"/*; do
                IRQ_ID=$(basename "$IRQ")
                TARGET_CPU=$(( IRQ_NUM % CPU_CORES ))
                # Пропускаем CPU 0 если ядер > 2 (оставляем под системные прерывания)
                [ "$CPU_CORES" -gt 2 ] && [ "$TARGET_CPU" -eq 0 ] && TARGET_CPU=1
                AFFINITY=$(printf '%x' $(( 1 << TARGET_CPU )))
                if [ -f "/proc/irq/${IRQ_ID}/smp_affinity" ]; then
                    echo "$AFFINITY" > "/proc/irq/${IRQ_ID}/smp_affinity" 2>/dev/null || true
                    IRQ_APPLIED=$(( IRQ_APPLIED + 1 ))
                fi
                IRQ_NUM=$(( IRQ_NUM + 1 ))
            done
            [ "$IRQ_APPLIED" -gt 0 ] && echo "    [+] $IFACE_NAME → ${IRQ_APPLIED} IRQ распределено по ядрам"
        fi
    done

    [ "$IRQ_APPLIED" -eq 0 ] && echo "    [~] MSI IRQ недоступны (виртуальная среда) — пропущено"

    # Сохраняем через скрипт + rc.local
    cat <<'IRQSCRIPT' > /usr/local/bin/3xui-irq-affinity.sh
#!/bin/bash
CPU_CORES=$(nproc)
[ "$CPU_CORES" -le 1 ] && exit 0
for IFACE_PATH in /sys/class/net/*/; do
    IFACE_NAME=$(basename "$IFACE_PATH")
    [ "$IFACE_NAME" = "lo" ] && continue
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
    chmod +x /usr/local/bin/3xui-irq-affinity.sh

    if ! grep -q "irq-affinity" "$RC_LOCAL" 2>/dev/null; then
        sed -i '/^exit 0/i /usr/local/bin/3xui-irq-affinity.sh' "$RC_LOCAL"
        echo "    [+] rc.local — IRQ affinity будет применяться при reboot"
    fi
else
    echo "    [~] IRQ Affinity пропущен (1 ядро)"
fi

# ─────────────────────────────────────────────
# 8. NIC OFFLOADING (TSO / GRO / GSO)
#    На физических серверах: включаем — снижает CPU нагрузку.
#    На виртуалках (KVM/XEN/VMware): часто вызывает проблемы —
#    включаем GRO, отключаем TSO/GSO (разные драйверы ведут себя
#    по-разному, поэтому применяем аккуратно с проверкой).
# ─────────────────────────────────────────────
echo "[*] Настраиваю NIC Offloading..."

# Определяем тип виртуализации
IS_VIRTUAL=0
if systemd-detect-virt --quiet 2>/dev/null; then
    IS_VIRTUAL=1
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    echo "    [~] Виртуализация обнаружена: $VIRT_TYPE"
fi

NIC_SCRIPT="/usr/local/bin/3xui-nic-offload.sh"
cat <<'NICSCRIPT_HEADER' > "$NIC_SCRIPT"
#!/bin/bash
# NIC Offloading — 3x-ui
command -v ethtool &>/dev/null || exit 0
NICSCRIPT_HEADER

NIC_APPLIED=0
for IFACE_PATH in /sys/class/net/*/; do
    IFACE_NAME=$(basename "$IFACE_PATH")
    [ "$IFACE_NAME" = "lo" ] && continue
    # Проверяем что это реальный сетевой интерфейс (не tun/tap/docker/veth)
    IFACE_TYPE=$(cat "${IFACE_PATH}type" 2>/dev/null || echo "0")
    [[ "$IFACE_NAME" =~ ^(tun|tap|veth|docker|br-|virbr) ]] && continue

    if command -v ethtool &>/dev/null; then
        if [ "$IS_VIRTUAL" -eq 0 ]; then
            # Физический сервер: включаем всё
            ethtool -K "$IFACE_NAME" tso on  gso on  gro on  2>/dev/null || true
            echo "    [+] $IFACE_NAME → TSO/GSO/GRO включены (физический сервер)"
            echo "ethtool -K $IFACE_NAME tso on  gso on  gro on  2>/dev/null || true" >> "$NIC_SCRIPT"
        else
            # Виртуальная среда: TSO/GSO off, GRO on — безопасный вариант
            ethtool -K "$IFACE_NAME" tso off gso off gro on  2>/dev/null || true
            echo "    [+] $IFACE_NAME → TSO/GSO выкл, GRO вкл (виртуальная среда)"
            echo "ethtool -K $IFACE_NAME tso off gso off gro on  2>/dev/null || true" >> "$NIC_SCRIPT"
        fi
        NIC_APPLIED=1
    fi
done

[ "$NIC_APPLIED" -eq 0 ] && echo "    [~] ethtool недоступен — пропущено (установите: apt install ethtool)"
chmod +x "$NIC_SCRIPT"

# Применять при reboot через rc.local
if ! grep -q "nic-offload" "$RC_LOCAL" 2>/dev/null; then
    sed -i '/^exit 0/i /usr/local/bin/3xui-nic-offload.sh' "$RC_LOCAL"
fi

# ─────────────────────────────────────────────
# 9. THP — ОТКЛЮЧЕНИЕ TRANSPARENT HUGEPAGES
#    THP периодически делает фоновую дефрагментацию памяти,
#    что вызывает латентные спайки (stalls) до 100мс.
#    Для VPN-сервера, где важна стабильная задержка — выключаем.
# ─────────────────────────────────────────────
echo "[*] Отключаю Transparent HugePages..."

THP_PATHS=(
    "/sys/kernel/mm/transparent_hugepage/enabled"
    "/sys/kernel/mm/transparent_hugepage/defrag"
    "/sys/kernel/mm/redhat_transparent_hugepage/enabled"
    "/sys/kernel/mm/redhat_transparent_hugepage/defrag"
)

THP_APPLIED=0
for THP_PATH in "${THP_PATHS[@]}"; do
    if [ -f "$THP_PATH" ]; then
        echo "never" > "$THP_PATH"
        THP_APPLIED=1
    fi
done

if [ "$THP_APPLIED" -eq 1 ]; then
    echo "    [+] THP → never (латентные спайки устранены)"
else
    echo "    [~] THP файлы не найдены (ядро собрано без THP)"
fi

# Сохраняем в rc.local
if ! grep -q "transparent_hugepage" "$RC_LOCAL" 2>/dev/null; then
    sed -i '/^exit 0/i for F in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do [ -f "$F" ] \&\& echo never > "$F"; done' "$RC_LOCAL"
fi

# Через sysctl (современные ядра)
if sysctl -n kernel.mm.transparent_hugepage.enabled &>/dev/null 2>&1; then
    echo "kernel.mm.transparent_hugepage.enabled = never" >> /etc/sysctl.d/99-3xui-tuning.conf
    echo "kernel.mm.transparent_hugepage.defrag = never"  >> /etc/sysctl.d/99-3xui-tuning.conf
    sysctl -p /etc/sysctl.d/99-3xui-tuning.conf 2>&1 | grep -v "No such file" || true
fi

# ─────────────────────────────────────────────
# 10. DISK I/O SCHEDULER
#     mq-deadline — лучший выбор для SSD/NVMe на серверах:
#     минимальная задержка, fairness, не теряет запросы.
#     none (noop) — для NVMe где очередь команд реализована
#     в железе и планировщик только мешает.
# ─────────────────────────────────────────────
echo "[*] Настраиваю Disk I/O Scheduler..."

IO_APPLIED=0
for DISK in /sys/block/*/; do
    DISK_NAME=$(basename "$DISK")
    # Пропускаем виртуальные устройства loop, ram, dm
    [[ "$DISK_NAME" =~ ^(loop|ram|dm|md|sr) ]] && continue
    SCHED_FILE="${DISK}queue/scheduler"
    [ -f "$SCHED_FILE" ] || continue

    CURRENT_SCHED=$(cat "$SCHED_FILE")
    ROTATIONAL=$(cat "${DISK}queue/rotational" 2>/dev/null || echo "1")

    if [ "$ROTATIONAL" -eq 0 ]; then
        # SSD или NVMe
        if echo "$CURRENT_SCHED" | grep -q "none"; then
            echo "none" > "$SCHED_FILE" 2>/dev/null || true
            echo "    [+] $DISK_NAME (SSD/NVMe) → none"
        elif echo "$CURRENT_SCHED" | grep -q "mq-deadline"; then
            echo "mq-deadline" > "$SCHED_FILE" 2>/dev/null || true
            echo "    [+] $DISK_NAME (SSD) → mq-deadline"
        else
            echo "    [~] $DISK_NAME → планировщик не изменён ($CURRENT_SCHED)"
        fi
    else
        # HDD
        if echo "$CURRENT_SCHED" | grep -q "mq-deadline"; then
            echo "mq-deadline" > "$SCHED_FILE" 2>/dev/null || true
            echo "    [+] $DISK_NAME (HDD) → mq-deadline"
        elif echo "$CURRENT_SCHED" | grep -q "deadline"; then
            echo "deadline" > "$SCHED_FILE" 2>/dev/null || true
            echo "    [+] $DISK_NAME (HDD) → deadline"
        fi
    fi
    IO_APPLIED=1
done

[ "$IO_APPLIED" -eq 0 ] && echo "    [~] Блочные устройства не найдены"

# udev — сохраняем планировщик после reboot
cat <<'EOF' > /etc/udev/rules.d/60-3xui-ioscheduler.rules
# I/O Scheduler — 3x-ui production
ACTION=="add|change", KERNEL=="sd[a-z]|nvme[0-9]n[0-9]|vd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline"
EOF
echo "    [+] udev правило сохранено — scheduler применится после reboot"

# ─────────────────────────────────────────────
# 11. OOM ЗАЩИТА x-ui
#     oom_score_adj = -1000 → ядро НИКОГДА не убьёт этот процесс
#     при нехватке памяти. Убьёт что угодно другое первым.
# ─────────────────────────────────────────────
echo "[*] Настраиваю OOM защиту x-ui..."

if systemctl list-unit-files | grep -q "x-ui.service"; then
    mkdir -p /etc/systemd/system/x-ui.service.d

    # Читаем существующий override если есть
    OVERRIDE_FILE="/etc/systemd/system/x-ui.service.d/override.conf"
    if [ -f "$OVERRIDE_FILE" ]; then
        # Добавляем OOM если строки ещё нет
        grep -q "OOMScoreAdjust" "$OVERRIDE_FILE" || \
            sed -i '/^\[Service\]/a OOMScoreAdjust=-1000' "$OVERRIDE_FILE"
    else
        cat <<EOF > "$OVERRIDE_FILE"
[Service]
LimitNOFILE=$NOFILE
OOMScoreAdjust=-1000
EOF
    fi

    systemctl daemon-reload
    echo "    [+] x-ui.service → OOMScoreAdjust=-1000"

    # Применяем к текущему процессу если x-ui запущен
    XUI_PID=$(systemctl show x-ui --property=MainPID --value 2>/dev/null || echo "0")
    if [ "$XUI_PID" -gt 0 ] && [ -f "/proc/${XUI_PID}/oom_score_adj" ]; then
        echo "-1000" > "/proc/${XUI_PID}/oom_score_adj" 2>/dev/null || true
        echo "    [+] OOM защита применена к PID $XUI_PID (немедленно)"
    fi
else
    echo "    [~] x-ui.service не найден — OOM защита будет применена при установке"
    # Создаём скрипт который можно запустить вручную позже
    cat <<'OOMSCRIPT' > /usr/local/bin/3xui-oom-protect.sh
#!/bin/bash
PID=$(pgrep -f "x-ui" | head -1)
[ -z "$PID" ] && echo "x-ui не запущен" && exit 1
echo "-1000" > "/proc/${PID}/oom_score_adj"
echo "OOM защита применена к PID $PID"
OOMSCRIPT
    chmod +x /usr/local/bin/3xui-oom-protect.sh
    echo "    [~] Создан скрипт: /usr/local/bin/3xui-oom-protect.sh"
fi

# ─────────────────────────────────────────────
# 12. ЛИМИТЫ ФАЙЛОВЫХ ДЕСКРИПТОРОВ
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
    OVERRIDE_FILE="/etc/systemd/system/x-ui.service.d/override.conf"
    mkdir -p /etc/systemd/system/x-ui.service.d
    # Обновляем LimitNOFILE если уже есть override, иначе создаём
    if [ -f "$OVERRIDE_FILE" ]; then
        grep -q "LimitNOFILE" "$OVERRIDE_FILE" || \
            sed -i '/^\[Service\]/a LimitNOFILE='"$NOFILE" "$OVERRIDE_FILE"
    fi
fi

systemctl daemon-reload
echo "    [+] Дескрипторы: $NOFILE"

# ─────────────────────────────────────────────
# 13. CONNTRACK HASHSIZE
# ─────────────────────────────────────────────
if [ -f /sys/module/nf_conntrack/parameters/hashsize ]; then
    echo "$HASHSIZE" > /sys/module/nf_conntrack/parameters/hashsize
    echo "options nf_conntrack hashsize=$HASHSIZE" > /etc/modprobe.d/nf_conntrack.conf
    echo "    [+] Conntrack hashsize: $HASHSIZE"
fi

# ─────────────────────────────────────────────
# 14. РОТАЦИЯ ЛОГОВ x-ui
#     Без ротации логи x-ui заполняют диск за недели.
#     Настраиваем: ежедневно, храним 7 дней, сжимаем.
# ─────────────────────────────────────────────
echo "[*] Настраиваю ротацию логов x-ui..."

# Стандартные пути логов 3x-ui
XUI_LOG_PATHS=(
    "/usr/local/x-ui/bin/access.log"
    "/usr/local/x-ui/bin/error.log"
    "/var/log/x-ui/access.log"
    "/var/log/x-ui/error.log"
    "/var/log/x-ui.log"
    "/tmp/x-ui.log"
)

# Находим существующие директории логов
XUI_LOG_PATTERN=""
for LOG_PATH in "${XUI_LOG_PATHS[@]}"; do
    LOG_DIR=$(dirname "$LOG_PATH")
    LOG_FILE=$(basename "$LOG_PATH")
    if [ -d "$LOG_DIR" ] || [ -f "$LOG_PATH" ]; then
        XUI_LOG_PATTERN="${XUI_LOG_PATTERN}${LOG_PATH}\n"
    fi
done

# Всегда создаём конфиг logrotate — охватываем все возможные пути
cat <<'EOF' > /etc/logrotate.d/x-ui
/usr/local/x-ui/bin/access.log
/usr/local/x-ui/bin/error.log
/var/log/x-ui/access.log
/var/log/x-ui/error.log
/var/log/x-ui.log
{
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su root root
}
EOF

# Создаём директорию логов если нет
mkdir -p /var/log/x-ui
echo "    [+] logrotate настроен: ежедневно, 7 дней, gzip"
echo "    [+] Принудительная ротация: logrotate -f /etc/logrotate.d/x-ui"

# ─────────────────────────────────────────────
# 15. GRUB — IPv6 OFF
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
# 16. ПЕРЕЗАПУСК x-ui
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
printf "  %-22s: %s\n" "RAM профиль"       "$RAM_TIER (${TOTAL_RAM_MB}MB)"
printf "  %-22s: %s\n" "CPU профиль"       "$CPU_TIER"
printf "  %-22s: %s\n" "TCP CC"            "$TCP_CC"
printf "  %-22s: %s\n" "Conntrack max"     "$CONNTRACK"
printf "  %-22s: %s\n" "Conntrack hash"    "$HASHSIZE"
printf "  %-22s: %s\n" "Буферы (max)"      "$(( BUFF_MAX / 1024 / 1024 ))MB"
printf "  %-22s: %s\n" "SYN backlog"       "$SYN_BACKLOG"
printf "  %-22s: %s\n" "netdev backlog"    "$NETDEV_BACKLOG"
printf "  %-22s: %s\n" "somaxconn"         "$SOMAXCONN"
printf "  %-22s: %s\n" "FIN Timeout"       "${FIN_TIMEOUT}s"
printf "  %-22s: %s\n" "TW Buckets"        "$TW_BUCKETS"
printf "  %-22s: %s\n" "Max Orphans"       "$MAX_ORPHANS"
printf "  %-22s: %s\n" "NOFILE"            "$NOFILE"
printf "  %-22s: %s\n" "RPS/RFS"           "$([ "$RPS_ENABLED" -eq 1 ] && echo "Вкл (mask=0x${CPU_MASK}, flows=${FLOW_ENTRIES})" || echo "Откл (1 ядро)")"
printf "  %-22s: %s\n" "CPU Governor"      "$([ "$GOV_APPLIED" -eq 1 ] && echo "performance" || echo "недоступен (VM)")"
printf "  %-22s: %s\n" "IRQ Affinity"      "$([ "${IRQ_APPLIED:-0}" -gt 0 ] && echo "применён (${IRQ_APPLIED} IRQ)" || ([ "$CPU_CORES" -le 1 ] && echo "откл (1 ядро)" || echo "недоступен (VM)"))"
printf "  %-22s: %s\n" "NIC Offloading"    "$([ "$IS_VIRTUAL" -eq 0 ] && echo "TSO/GSO/GRO вкл" || echo "TSO/GSO выкл, GRO вкл (VM)")"
printf "  %-22s: %s\n" "THP"               "$([ "$THP_APPLIED" -eq 1 ] && echo "отключён" || echo "не найден")"
printf "  %-22s: %s\n" "I/O Scheduler"     "mq-deadline / none (NVMe)"
printf "  %-22s: %s\n" "OOM защита"        "x-ui → -1000"
printf "  %-22s: %s\n" "Логи"              "logrotate: 7 дней, gzip"
printf "  %-22s: %s\n" "Swap"              "1GB"
printf "  %-22s: %s\n" "IPv6"              "Отключён"
echo "========================================"
echo ""
echo "  Рекомендуется перезагрузка: sudo reboot"
echo ""
