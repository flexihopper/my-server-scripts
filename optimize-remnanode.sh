#!/bin/bash

# =============================================================
#   Оптимизация хоста для Remnawave / Remnanode (Docker, host-network)
#   Ubuntu/Debian | Требует: root
#   Основа: flexihopper/my-server-scripts (optimize-remnanode.sh), v2 с правками
#
#   Запуск:
#     sudo bash optimize-remnanode.sh
#     sudo DISABLE_IPV6=0 bash optimize-remnanode.sh      # оставить IPv6
#     sudo SWAP_SIZE_MB=2048 bash optimize-remnanode.sh   # другой размер swap
#
#   Что изменено относительно оригинала:
#    - Нет `set -e`: сбой одного блока (swapon на LXC и т.п.) не рвёт весь скрипт
#    - BBR определяется через tcp_available_congestion_control
#      (работает и когда BBR вкомпилен в ядро)
#    - Swap: если в системе уже есть любой swap — новый не создаётся
#    - ip_local_port_range 10240-65535 (не пересекается с портами inbound'ов)
#    - tcp_fin_timeout=10, conntrack close_wait=30 (без чрезмерной агрессии)
#    - TSO/GSO больше НЕ отключаются; если старая версия их отключила — вернёт on
#    - IPv6: только через sysctl (флаг DISABLE_IPV6), GRUB не трогаем
#    - Убраны: IRQ affinity, I/O scheduler (на VPS бесполезны / вредны)
#    - RPS/RFS только для интерфейсов с одной rx-очередью, flow_cnt считается верно
#    - Governor/THP переживают ребут через systemd-юнит, а не rc.local
#    - Чистятся артефакты предыдущей версии скрипта
#
#   Блоки:
#    0.  Бэкап и очистка артефактов старой версии
#    1.  Определение ресурсов (RAM + CPU профили)
#    2.  Модули ядра / BBR
#    3.  Swap
#    4.  Sysctl
#    5.  RPS / RFS
#    6.  CPU governor + THP (systemd-юнит)
#    7.  Conntrack hashsize
#    8.  IPv6 / GRUB (только подсказки)
#    9.  OOM-приоритет контейнеров (инструкция)
# =============================================================

set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: запустите через sudo"
    exit 1
fi

DISABLE_IPV6="${DISABLE_IPV6:-1}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-1024}"

ok()   { echo "    [+] $*"; }
skip() { echo "    [~] $*"; }
warn() { echo "    [!] $*"; }

is_skip_iface() {
    case "$1" in
        lo|docker*|veth*|br-*|virbr*|tun*|tap*|wg*|warp*) return 0 ;;
    esac
    return 1
}

# ─────────────────────────────────────────────
# 0. БЭКАП И ОЧИСТКА СТАРОЙ ВЕРСИИ
# ─────────────────────────────────────────────
BACKUP=/root/sysctl-before-remnanode-tuning.txt
[ -f "$BACKUP" ] || sysctl -a > "$BACKUP" 2>/dev/null || true

echo "[*] Проверяю артефакты предыдущей версии скрипта..."

RC_LOCAL=/etc/rc.local
if [ -f "$RC_LOCAL" ] && grep -qE 'remnanode-|scaling_governor|transparent_hugepage' "$RC_LOCAL"; then
    cp -n "$RC_LOCAL" /root/rc.local.bak-remnanode 2>/dev/null || true
    sed -i \
        -e '\|remnanode-|d' \
        -e '\|cpu\*/cpufreq/scaling_governor; do|d' \
        -e '\|transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do|d' \
        "$RC_LOCAL"
    ok "Строки старого скрипта удалены из rc.local (бэкап: /root/rc.local.bak-remnanode)"
fi

if [ -f /usr/local/bin/remnanode-nic-offload.sh ]; then
    if grep -q "tso off" /usr/local/bin/remnanode-nic-offload.sh && command -v ethtool &>/dev/null; then
        for P in /sys/class/net/*/; do
            N=$(basename "$P")
            is_skip_iface "$N" && continue
            ethtool -K "$N" tso on gso on gro on 2>/dev/null || true
        done
        ok "TSO/GSO возвращены в on (старая версия их отключала)"
    fi
    rm -f /usr/local/bin/remnanode-nic-offload.sh
fi
rm -f /usr/local/bin/remnanode-irq-affinity.sh /etc/udev/rules.d/60-remnanode-ioscheduler.rules

# ─────────────────────────────────────────────
# 1. ОПРЕДЕЛЕНИЕ РЕСУРСОВ
# ─────────────────────────────────────────────
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
CPU_CORES=$(nproc)

echo ""
echo "========================================"
echo "   Remnanode Host Optimizer (v2)"
echo "========================================"
echo "  RAM: ${TOTAL_RAM_MB}MB | CPU: ${CPU_CORES} cores"
echo "========================================"

if [ "$TOTAL_RAM_MB" -lt 1536 ]; then
    RAM_TIER="1GB"
    CONNTRACK=131072;  HASHSIZE=32768
    BUFF_MAX=16777216; BUFF_TCP="4096 87380 16777216"
    MAX_ORPHANS=16384; TW_BUCKETS=262144
elif [ "$TOTAL_RAM_MB" -lt 3840 ]; then
    RAM_TIER="2-3GB"
    CONNTRACK=262144;  HASHSIZE=65536
    BUFF_MAX=33554432; BUFF_TCP="4096 87380 33554432"
    MAX_ORPHANS=32768; TW_BUCKETS=524288
else
    RAM_TIER="4GB+"
    CONNTRACK=524288;  HASHSIZE=131072
    BUFF_MAX=67108864; BUFF_TCP="4096 87380 67108864"
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
# 2. МОДУЛИ ЯДРА / BBR
# ─────────────────────────────────────────────
echo "[*] Загружаю модули ядра..."
modprobe tcp_bbr      2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    TCP_CC="bbr"
    ok "BBR доступен"
else
    TCP_CC="cubic"
    warn "BBR недоступен -> cubic"
fi

: > /etc/modules-load.d/remnanode-modules.conf
modinfo tcp_bbr      &>/dev/null && echo "tcp_bbr"      >> /etc/modules-load.d/remnanode-modules.conf
modinfo nf_conntrack &>/dev/null && echo "nf_conntrack" >> /etc/modules-load.d/remnanode-modules.conf

# ─────────────────────────────────────────────
# 3. SWAP
#    Создаём только если в системе нет НИКАКОГО swap
#    (раздел, /swap.img, zram, чужой swapfile — всё считается)
# ─────────────────────────────────────────────
echo "[*] Проверяю swap..."
SWAP_DEVICES=$(swapon --noheadings --show=NAME 2>/dev/null | wc -l)

if [ "$SWAP_DEVICES" -gt 0 ]; then
    skip "Swap уже есть: $(swapon --noheadings --show=NAME,SIZE 2>/dev/null | tr -s ' ' | tr '\n' ';') — новый не создаю"
else
    CREATED=0
    if [ ! -f /swapfile ]; then
        echo "    [*] Создаю swap-файл ${SWAP_SIZE_MB}MB..."
        if ! fallocate -l "${SWAP_SIZE_MB}M" /swapfile 2>/dev/null; then
            dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" status=none 2>/dev/null
        fi
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        CREATED=1
    fi
    if swapon /swapfile 2>/dev/null; then
        grep -qxF '/swapfile none swap sw 0 0' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        ok "Swap подключён"
    else
        warn "swapon не удался (LXC/OpenVZ или ограничения ФС) — swap пропущен"
        [ "$CREATED" -eq 1 ] && rm -f /swapfile
    fi
fi

# ─────────────────────────────────────────────
# 4. SYSCTL
# ─────────────────────────────────────────────
echo "[*] Применяю sysctl..."

if [ -f /etc/sysctl.d/98-remnawave.conf ]; then
    skip "Найден /etc/sysctl.d/98-remnawave.conf — наш файл 99-* грузится позже и перекрывает совпадающие ключи"
fi

IPV6_BLOCK=""
if [ "$DISABLE_IPV6" = "1" ]; then
    IPV6_BLOCK="# --- Отключение IPv6 (DISABLE_IPV6=1) ---
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1"
fi

cat <<EOF > /etc/sysctl.d/99-remnanode-tuning.conf
# Remnanode Host Tuning v2 | RAM: $RAM_TIER | CPU: $CPU_TIER

# --- Conntrack ---
net.netfilter.nf_conntrack_max = $CONNTRACK
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
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
net.ipv4.tcp_fin_timeout = 10
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
# Эфемерные порты начинаются с 10240, чтобы не пересекаться с портами inbound'ов
net.ipv4.ip_local_port_range = 10240 65535
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

$IPV6_BLOCK
EOF

sysctl -p /etc/sysctl.d/99-remnanode-tuning.conf 2>&1 | grep -vE "No such file|cannot stat" || true
ok "sysctl применён (TCP CC: $TCP_CC)"

# ─────────────────────────────────────────────
# 5. RPS / RFS
#    Только для интерфейсов с ОДНОЙ rx-очередью: при нескольких
#    очередях (virtio multiqueue, физические NIC) их уже раскидывает RSS.
# ─────────────────────────────────────────────
if [ "$RPS_ENABLED" -eq 1 ]; then
    echo "[*] Настраиваю RPS/RFS..."

    cat <<'SCRIPT' > /usr/local/bin/remnanode-rps-apply.sh
#!/bin/bash
# RPS/RFS для интерфейса с одной rx-очередью
IFACE="$1"
case "$IFACE" in lo|docker*|veth*|br-*|virbr*|tun*|tap*|wg*|warp*) exit 0 ;; esac
FLOW=__FLOW__
CORES=$(nproc)
[ "$CORES" -le 1 ] && exit 0
[ "$CORES" -gt 32 ] && exit 0
QDIR="/sys/class/net/${IFACE}/queues"
[ -d "$QDIR" ] || exit 0
QUEUES=$(ls -d "${QDIR}"/rx-* 2>/dev/null | wc -l)
[ "$QUEUES" -eq 1 ] || exit 0
MASK=$(printf '%x' $(( (1 << CORES) - 1 )))
echo "$MASK" > "${QDIR}/rx-0/rps_cpus"     2>/dev/null
echo "$FLOW" > "${QDIR}/rx-0/rps_flow_cnt" 2>/dev/null
exit 0
SCRIPT
    sed -i "s/__FLOW__/${FLOW_ENTRIES}/" /usr/local/bin/remnanode-rps-apply.sh
    chmod +x /usr/local/bin/remnanode-rps-apply.sh

    cat <<'EOF' > /etc/udev/rules.d/99-remnanode-rps.rules
ACTION=="add", SUBSYSTEM=="net", RUN+="/usr/local/bin/remnanode-rps-apply.sh %k"
EOF

    for IFACE_PATH in /sys/class/net/*/; do
        N=$(basename "$IFACE_PATH")
        is_skip_iface "$N" && continue
        /usr/local/bin/remnanode-rps-apply.sh "$N"
        Q=$(ls -d "${IFACE_PATH}queues"/rx-* 2>/dev/null | wc -l)
        if [ "$Q" -eq 1 ]; then
            ok "$N: 1 rx-очередь -> RPS/RFS включён"
        else
            skip "$N: rx-очередей=$Q — RPS не нужен"
        fi
    done
else
    skip "RPS/RFS пропущен (1 ядро)"
    rm -f /etc/udev/rules.d/99-remnanode-rps.rules /usr/local/bin/remnanode-rps-apply.sh
fi

# ─────────────────────────────────────────────
# 6. CPU GOVERNOR + THP (systemd-юнит вместо rc.local)
# ─────────────────────────────────────────────
echo "[*] Настраиваю CPU governor и THP..."

cat <<'EOF' > /usr/local/bin/remnanode-boot.sh
#!/bin/bash
for F in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "$F" ] && echo performance > "$F" 2>/dev/null
done
for F in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do
    [ -w "$F" ] && echo never > "$F" 2>/dev/null
done
exit 0
EOF
chmod +x /usr/local/bin/remnanode-boot.sh

if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
    cat <<'EOF' > /etc/systemd/system/remnanode-boot.service
[Unit]
Description=Remnanode host tuning (CPU governor, THP)
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/remnanode-boot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now remnanode-boot.service >/dev/null 2>&1 \
        && ok "Юнит remnanode-boot.service включён" \
        || { warn "Не удалось включить юнит, применяю один раз вручную"; /usr/local/bin/remnanode-boot.sh; }
else
    warn "systemd не найден — применяю один раз, после ребута настройка не сохранится"
    /usr/local/bin/remnanode-boot.sh
fi

THP_APPLIED=0
if grep -q '\[never\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; then
    THP_APPLIED=1
    ok "THP -> never"
else
    skip "THP не изменён (файлы недоступны)"
fi

if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    ok "Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
else
    skip "cpufreq недоступен (обычно так и есть на VPS)"
fi

# ─────────────────────────────────────────────
# 7. CONNTRACK HASHSIZE
# ─────────────────────────────────────────────
echo "[*] Conntrack hashsize..."
if [ -f /sys/module/nf_conntrack/parameters/hashsize ]; then
    if echo "$HASHSIZE" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null; then
        ok "hashsize: $HASHSIZE"
    else
        skip "Не удалось изменить hashsize на лету — применится после перезагрузки"
    fi
    echo "options nf_conntrack hashsize=$HASHSIZE" > /etc/modprobe.d/nf_conntrack.conf
else
    skip "nf_conntrack параметры недоступны — пропущено"
fi

# ─────────────────────────────────────────────
# 8. IPv6 / GRUB — только подсказки, GRUB не трогаем
# ─────────────────────────────────────────────
if [ -f /etc/default/grub ] && grep -q "ipv6.disable=1" /etc/default/grub; then
    if [ "$DISABLE_IPV6" = "1" ]; then
        skip "В GRUB остался ipv6.disable=1 от старой версии — он дублирует sysctl, можно убрать:"
    else
        warn "В GRUB остался ipv6.disable=1 от старой версии, IPv6 после ребута останется выключенным. Убрать:"
    fi
    echo "          sed -i 's/ ipv6.disable=1//' /etc/default/grub && update-grub"
fi

# ─────────────────────────────────────────────
# 9. OOM-ПРИОРИТЕТ (docker update --oom-score-adj не существует —
#    значение задаётся только при создании контейнера / в compose)
# ─────────────────────────────────────────────
COMPOSE_FILE="/opt/remnanode/docker-compose.yml"
echo "[*] OOM-приоритет: правится только в docker-compose.yml"
if [ -f "$COMPOSE_FILE" ]; then
    if grep -q "oom_score_adj" "$COMPOSE_FILE"; then
        skip "oom_score_adj уже прописан в $COMPOSE_FILE"
    else
        warn "Добавь вручную в сервис remnanode в $COMPOSE_FILE:"
        echo "          oom_score_adj: -500"
        echo "        затем: cd /opt/remnanode && docker compose up -d --force-recreate"
    fi
else
    skip "$COMPOSE_FILE не найден — пропущено"
fi

# ─────────────────────────────────────────────
# ИТОГ
# ─────────────────────────────────────────────
SWAP_TOTAL=$(free -m | awk '/^Swap:/{print $2}')
CT_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "n/a")

echo ""
echo "========================================"
echo "   ОПТИМИЗАЦИЯ ВЫПОЛНЕНА"
echo "========================================"
printf "  %-22s: %s\n" "RAM профиль"    "$RAM_TIER (${TOTAL_RAM_MB}MB)"
printf "  %-22s: %s\n" "CPU профиль"    "$CPU_TIER"
printf "  %-22s: %s\n" "TCP CC (факт)"  "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
printf "  %-22s: %s\n" "Conntrack"      "${CT_COUNT} / ${CONNTRACK}"
printf "  %-22s: %s\n" "Буферы (max)"   "$(( BUFF_MAX / 1024 / 1024 ))MB"
printf "  %-22s: %s\n" "THP"            "$([ "$THP_APPLIED" -eq 1 ] && echo "отключён" || echo "не изменён")"
printf "  %-22s: %s\n" "IPv6 (sysctl)"  "$([ "$DISABLE_IPV6" = "1" ] && echo "отключён" || echo "не тронут")"
printf "  %-22s: %s\n" "Swap (всего)"   "${SWAP_TOTAL}MB"
echo "========================================"
echo ""
echo "  Проверка:"
echo "    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max"
echo "    swapon --show"
echo "    cat /proc/sys/net/netfilter/nf_conntrack_count   # следи при росте нагрузки"
echo "    docker inspect remnanode | grep -i oom"
echo ""
echo "  Бэкап прежних sysctl: $BACKUP"
echo "  Рекомендуется перезагрузка: sudo reboot"
echo ""
