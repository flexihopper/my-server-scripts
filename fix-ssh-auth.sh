#!/usr/bin/env bash
# ==============================================================================
# fix-ssh-auth.sh
# Скрипт проверки и исправления уязвимости OpenSSH "first match wins"
# (отключение входа по паролю и устранение конфликтов с cloud-init / sshd_config.d)
#
# Может запускаться:
# 1) Локально на сервере:
#    sudo ./fix-ssh-auth.sh [--check]
#
# 2) С локального ПК сразу по списку серверов:
#    ./fix-ssh-auth.sh -f servers.txt --check   # аудит без sudo и без паролей!
#    ./fix-ssh-auth.sh -f servers.txt           # проверка и исправление
# ==============================================================================

set -euo pipefail

DEFAULT_USER="www"
DEFAULT_PORT="2244"
FALLBACK_PORT="22"
CHECK_ONLY=false
SERVERS_FILE=""
TARGETS=()
SUDO_PASS=""

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Использование:
  1. Локально на сервере:
     sudo $0 [--check]

  2. Удалённо по списку серверов:
     $0 [опции] <хост1> [хост2 ...]
     $0 [опции] -f servers.txt
     $0 [опции] -f servers.txt --check   # аудит без правок (не требует sudo)

Опции:
  -f, --file FILE     Файл со списком серверов (по одному на строку)
  -c, --check         Только проверка (аудит), без внесения изменений (не требует sudo)
  -u, --user USER     Пользователь SSH по умолчанию (по умолчанию: $DEFAULT_USER)
  -p, --port PORT     Порт SSH по умолчанию (по умолчанию: $DEFAULT_PORT)
  -h, --help          Показать эту справку

Формат хостов:
  192.168.1.10
  192.168.1.10:2244
  ubuntu@192.168.1.10
  ubuntu@192.168.1.10:2244
EOF
    exit 0
}

# Разбор аргументов
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file)
            SERVERS_FILE="$2"
            shift 2
            ;;
        -c|--check)
            CHECK_ONLY=true
            shift
            ;;
        -u|--user)
            DEFAULT_USER="$2"
            shift 2
            ;;
        -p|--port)
            DEFAULT_PORT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            TARGETS+=("$1")
            shift
            ;;
    esac
done

# ==============================================================================
# Полезная нагрузка (выполняется на целевом сервере)
# ==============================================================================
REMOTE_PAYLOAD=$(cat <<'PAYLOAD_EOF'
#!/bin/bash
set -euo pipefail

MODE="${1:-check}"

# Функция проверки состояния (работает БЕЗ прав root)
check_status() {
    local issues=()
    local warnings=()

    # 1. Активное значение PasswordAuthentication по sshd -T
    # Используем временный ключ, чтобы запустить sshd -T без root-прав
    local dummy_key
    dummy_key=$(mktemp)
    rm -f "$dummy_key"
    ssh-keygen -q -t ed25519 -N '' -f "$dummy_key" 2>/dev/null || true

    local active_pw="unknown"
    local active_kbd="unknown"
    if [ -f "$dummy_key" ]; then
        active_pw=$(sshd -T -h "$dummy_key" 2>/dev/null | grep -Ei '^passwordauthentication ' | awk '{print $2}' || echo "unknown")
        active_kbd=$(sshd -T -h "$dummy_key" 2>/dev/null | grep -Ei '^kbdinteractiveauthentication ' | awk '{print $2}' || echo "unknown")
        rm -f "$dummy_key" "${dummy_key}.pub"
    else
        active_pw=$(sshd -T 2>/dev/null | grep -Ei '^passwordauthentication ' | awk '{print $2}' || echo "unknown")
        active_kbd=$(sshd -T 2>/dev/null | grep -Ei '^kbdinteractiveauthentication ' | awk '{print $2}' || echo "unknown")
    fi

    # Проверка парольного входа
    if [ "$active_pw" = "yes" ]; then
        issues+=("КРИТИЧНО: sshd -T сообщает PasswordAuthentication = yes (вход по паролю РАЗРЕШЁН)")
    fi

    if [ "$active_kbd" = "yes" ]; then
        issues+=("sshd -T: KbdInteractiveAuthentication = yes (PAM может запрашивать пароль)")
    fi

    # Проверка конфликтующих файлов в sshd_config.d
    if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]; then
        if grep -qEi '^[# ]*PasswordAuthentication[[:space:]]+yes' /etc/ssh/sshd_config.d/50-cloud-init.conf 2>/dev/null; then
            issues+=("Найден /etc/ssh/sshd_config.d/50-cloud-init.conf с PasswordAuthentication yes (first match wins)")
        fi
    fi

    if [ -d /etc/ssh/sshd_config.d ]; then
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [ -f "$f" ] || continue
            [ "$f" = "/etc/ssh/sshd_config.d/01-custom.conf" ] && continue
            if grep -qEi '^[# ]*PasswordAuthentication[[:space:]]+yes' "$f" 2>/dev/null; then
                issues+=("В файле $f найден PasswordAuthentication yes")
            fi
        done
    fi

    # Проверка наличия 01-custom.conf
    if [ ! -f /etc/ssh/sshd_config.d/01-custom.conf ]; then
        if [ "$active_pw" = "no" ] && [ ${#issues[@]} -eq 0 ]; then
            warnings+=("Вход по паролю отключен, но нет 01-custom.conf (рекомендуется для защиты от перезаписи)")
        else
            issues+=("Отсутствует приоритетный drop-in /etc/ssh/sshd_config.d/01-custom.conf")
        fi
    fi

    if [ ${#issues[@]} -eq 0 ]; then
        if [ ${#warnings[@]} -eq 0 ]; then
            echo "RESULT:OK"
        else
            echo "RESULT:OK_WITH_WARNINGS"
            for w in "${warnings[@]}"; do
                echo "WARNING:$w"
            done
        fi
        return 0
    else
        echo "RESULT:NEEDS_FIX"
        for issue in "${issues[@]}"; do
            echo "ISSUE:$issue"
        done
        return 1
    fi
}

# Если запрошен только чек — запускаем и выходим
if [ "$MODE" = "check" ]; then
    set +e
    check_status
    exit $?
fi

# ==================== ВНЕСЕНИЕ ИСПРАВЛЕНИЙ (требует root) ====================
if [ "$EUID" -ne 0 ]; then
    echo "ERROR:Для применения исправлений требуются права root (sudo)."
    exit 1
fi

# 1. Резервная копия
BACKUP_DIR="/root/ssh-backup-fix-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -r /etc/ssh "$BACKUP_DIR/" 2>/dev/null || true

# 2. Определяем текущий эффективный порт и root-login
CURRENT_PORT=$(sshd -T 2>/dev/null | grep -Ei '^port ' | awk '{print $2}' | head -1 || echo "22")
CURRENT_PORT=${CURRENT_PORT:-22}
CURRENT_ROOT=$(sshd -T 2>/dev/null | grep -Ei '^permitrootlogin ' | awk '{print $2}' | head -1 || echo "no")
CURRENT_ROOT=${CURRENT_ROOT:-no}

# 3. Удаляем облачные drop-in конфиги
mkdir -p /etc/ssh/sshd_config.d
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf
rm -f /etc/ssh/sshd_config.d/*cloud*.conf

# 4. Создаём приоритетный 01-custom.conf (first match wins)
cat > /etc/ssh/sshd_config.d/01-custom.conf <<EOF
# Приоритетная конфигурация SSH (OpenSSH first match wins)
Port $CURRENT_PORT
PermitRootLogin $CURRENT_ROOT
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
KbdInteractiveAuthentication no
EOF

# 5. Нейтрализуем параметры в остальных drop-in файлах
for conf in /etc/ssh/sshd_config.d/*.conf; do
    [ -f "$conf" ] || continue
    [ "$conf" = "/etc/ssh/sshd_config.d/01-custom.conf" ] && continue
    sed -i "s/^[# ]*PasswordAuthentication .*/PasswordAuthentication no/" "$conf"
    sed -i "s/^[# ]*KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/" "$conf"
done

# 6. Синхронизируем основной /etc/ssh/sshd_config
if [ -f /etc/ssh/sshd_config ]; then
    sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
    sed -i "s/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/" /etc/ssh/sshd_config
fi

# 7. Защита от перезаписи cloud-init
if [ -d /etc/cloud/cloud.cfg.d ]; then
    echo "ssh_pwauth: false" > /etc/cloud/cloud.cfg.d/99-disable-ssh-pwauth.cfg
fi

# 8. Проверка синтаксиса
mkdir -p /run/sshd
if ! sshd -t; then
    echo "ERROR:sshd -t показал ошибку синтаксиса! Откат..."
    rm -rf /etc/ssh/*
    cp -r "$BACKUP_DIR"/ssh/* /etc/ssh/
    exit 1
fi

# 9. Перезапуск демона SSH
if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-enabled --quiet ssh 2>/dev/null; then
    systemctl restart ssh
elif systemctl is-active --quiet sshd 2>/dev/null || systemctl is-enabled --quiet sshd 2>/dev/null; then
    systemctl restart sshd
else
    service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
fi

# 10. Финальная проверка через sshd -T
FINAL_PW=$(sshd -T 2>/dev/null | grep -Ei '^passwordauthentication ' | awk '{print $2}' || echo "unknown")
if [ "$FINAL_PW" = "no" ]; then
    echo "RESULT:FIXED"
    echo "BACKUP:$BACKUP_DIR"
    echo "PORT:$CURRENT_PORT"
else
    echo "RESULT:FAILED"
    echo "FINAL_VALUE:$FINAL_PW"
    exit 1
fi
PAYLOAD_EOF
)

# ==============================================================================
# Режим 1: Запуск непосредственно на текущем сервере (локальный режим)
# ==============================================================================
run_local() {
    echo -e "${CYAN}=== Проверка конфигурации SSH на текущем сервере ===${NC}"
    local mode="apply"
    if [ "$CHECK_ONLY" = true ]; then
        mode="check"
    fi

    if [ "$mode" = "apply" ] && [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Ошибка: для применения исправлений требуются права root (sudo).${NC}"
        echo "Запустите: sudo $0"
        exit 1
    fi

    local output
    output=$(bash -c "$REMOTE_PAYLOAD" _ "$mode")
    local exit_code=$?

    if echo "$output" | grep -q "^RESULT:OK"; then
        echo -e "${GREEN}✅ Всё в порядке! Вход по паролю уже надёжно отключен, конфликтов нет.${NC}"
        echo "   sshd -T: PasswordAuthentication no"
        exit 0
    fi

    if echo "$output" | grep -q "^RESULT:OK_WITH_WARNINGS"; then
        echo -e "${GREEN}✅ Вход по паролю отключен.${NC}"
        echo "$output" | grep "^WARNING:" | sed 's/^WARNING:/   ℹ️  /'
        exit 0
    fi

    if [ "$mode" = "check" ]; then
        echo -e "${YELLOW}⚠️  Обнаружены проблемы, требующие исправления:${NC}"
        echo "$output" | grep "^ISSUE:" | sed 's/^ISSUE:/   - /'
        echo ""
        echo "Для исправления запустите: sudo $0"
        exit 0
    fi

    if echo "$output" | grep -q "^RESULT:FIXED"; then
        local bkp
        bkp=$(echo "$output" | grep "^BACKUP:" | cut -d: -f2- || echo "")
        echo -e "${GREEN}✅ УСПЕШНО ИСПРАВЛЕНО!${NC}"
        echo "   - Приоритетный конфиг /etc/ssh/sshd_config.d/01-custom.conf создан (first match wins)."
        echo "   - Конфликты cloud-init устранены."
        echo "   - Активная конфигурация подтверждена (sshd -T: PasswordAuthentication no)."
        [ -n "$bkp" ] && echo "   - Резервная копия сохранена в: $bkp"
        exit 0
    else
        echo -e "${RED}❌ Не удалось автоматически исправить конфигурацию!${NC}"
        echo "$output"
        exit 1
    fi
}

# ==============================================================================
# Режим 2: Удалённый запуск по списку серверов
# ==============================================================================
parse_target() {
    local raw="$1"
    local user="$DEFAULT_USER"
    local host=""
    local port="$DEFAULT_PORT"

    # Извлекаем пользователя, если есть (user@host...)
    if [[ "$raw" =~ ^(.*)@(.*)$ ]]; then
        user="${BASH_REMATCH[1]}"
        raw="${BASH_REMATCH[2]}"
    fi

    # Извлекаем порт, если есть (host:port)
    if [[ "$raw" =~ ^(.*):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        host="$raw"
    fi

    echo "$user" "$host" "$port"
}

run_remote_target() {
    local target="$1"
    read -r user host port < <(parse_target "$target")

    # Пробуем подключиться (сначала на указанный порт, при неудаче — на fallback порт 22)
    local active_port="$port"
    local ssh_opts=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

    if ! ssh "${ssh_opts[@]}" -p "$active_port" "$user@$host" "true" 2>/dev/null; then
        if [ "$active_port" != "$FALLBACK_PORT" ] && ssh "${ssh_opts[@]}" -p "$FALLBACK_PORT" "$user@$host" "true" 2>/dev/null; then
            active_port="$FALLBACK_PORT"
        else
            echo -e "${RED}[ОШИБКА]${NC}      $user@$host:$port — нет подключения по SSH (таймаут или отклонён ключ)"
            return 2
        fi
    fi

    # ШАГ 1: Всегда сначала запускаем проверку БЕЗ root/sudo
    local check_out
    check_out=$(ssh "${ssh_opts[@]}" -p "$active_port" "$user@$host" "bash -s -- check" <<EOF 2>/dev/null
$REMOTE_PAYLOAD
EOF
    ) || true

    if echo "$check_out" | grep -q "^RESULT:OK"; then
        echo -e "${GREEN}[OK]${NC}          $user@$host:$active_port — вход по паролю уже надёжно отключен (sshd -T: no)"
        return 0
    fi

    if echo "$check_out" | grep -q "^RESULT:OK_WITH_WARNINGS"; then
        if [ "$CHECK_ONLY" = true ]; then
            echo -e "${GREEN}[OK]${NC}          $user@$host:$active_port — вход по паролю отключен (sshd -T: no)"
            echo "$check_out" | grep "^WARNING:" | sed 's/^WARNING:/              ℹ️  /'
            return 0
        fi
        # Если не только проверка, а режим apply — продолжаем для создания 01-custom.conf
    fi

    # Если мы в режиме CHECK_ONLY — выводим найденные проблемы и не меняем ничего
    if [ "$CHECK_ONLY" = true ]; then
        echo -e "${YELLOW}[НУЖЕН ФИКС]${NC}  $user@$host:$active_port — ТРЕБУЕТСЯ ИСПРАВЛЕНИЕ:"
        echo "$check_out" | grep "^ISSUE:" | sed 's/^ISSUE:/              - /'
        return 1
    fi

    # ШАГ 2: В режиме apply требуется root. Передаём скрипт во временный файл
    local remote_tmp="/tmp/fix_ssh_run_$$.sh"
    ssh "${ssh_opts[@]}" -p "$active_port" "$user@$host" "cat > '$remote_tmp' && chmod 700 '$remote_tmp'" <<EOF 2>/dev/null
$REMOTE_PAYLOAD
EOF

    local apply_out=""
    if [ "$user" = "root" ]; then
        apply_out=$(ssh "${ssh_opts[@]}" -p "$active_port" "$user@$host" "bash '$remote_tmp' apply 2>&1; rm -f '$remote_tmp'" 2>&1) || true
    else
        # Запускаем через sudo
        if [ -n "$SUDO_PASS" ]; then
            apply_out=$(printf '%s\n' "$SUDO_PASS" | ssh "${ssh_opts[@]}" -p "$active_port" "$user@$host" "sudo -S -p '' bash '$remote_tmp' apply 2>&1; rm -f '$remote_tmp'" 2>&1) || true
        else
            apply_out=$(ssh "${ssh_opts[@]}" -p "$active_port" "$user@$host" "sudo -n bash '$remote_tmp' apply 2>&1; rm -f '$remote_tmp'" 2>&1) || true
        fi
    fi

    if echo "$apply_out" | grep -q "^RESULT:FIXED"; then
        echo -e "${CYAN}[ИСПРАВЛЕНО]${NC}  $user@$host:$active_port — конфликт устранён, вход по паролю отключен"
        return 1
    else
        echo -e "${RED}[СБОЙ]${NC}        $user@$host:$active_port — не удалось применить исправление:"
        echo "$apply_out" | sed 's/^/              /'
        return 3
    fi
}

main() {
    # Собираем список хостов из файла, если указан
    if [ -n "$SERVERS_FILE" ]; then
        if [ ! -f "$SERVERS_FILE" ]; then
            echo -e "${RED}Ошибка: файл '$SERVERS_FILE' не найден.${NC}"
            exit 1
        fi
        while IFS= read -r line || [ -n "$line" ]; do
            # Убираем пробелы и комментарии
            line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/#.*$//')
            [ -n "$line" ] && TARGETS+=("$line")
        done < "$SERVERS_FILE"
    fi

    # Если аргументов и файлов нет — запускаем локальную проверку текущего сервера
    if [ ${#TARGETS[@]} -eq 0 ]; then
        run_local
        exit 0
    fi

    # Если не только проверка, а применение исправлений не под root — спрашиваем пароль sudo один раз
    if [ "$CHECK_ONLY" = false ] && [ "$DEFAULT_USER" != "root" ]; then
        echo -e "${CYAN}Для применения исправлений на серверах требуются права sudo.${NC}"
        read -s -p "🔑 Введите пароль sudo для пользователя '$DEFAULT_USER' (Enter если NOPASSWD): " SUDO_PASS || true
        echo ""
        echo ""
    fi

    # Удалённая проверка по списку
    echo -e "${BLUE}================================================================${NC}"
    if [ "$CHECK_ONLY" = true ]; then
        echo -e "${BLUE}🔍 Режим АУДИТА (проверка БЕЗ sudo) для ${#TARGETS[@]} серверов...${NC}"
    else
        echo -e "${BLUE}🚀 Запуск проверки и исправления для ${#TARGETS[@]} серверов...${NC}"
    fi
    echo -e "${BLUE}================================================================${NC}"

    local count_ok=0
    local count_fixed=0
    local count_needs_fix=0
    local count_error=0

    for target in "${TARGETS[@]}"; do
        set +e
        run_remote_target "$target"
        local res=$?
        set -e

        case $res in
            0) ((count_ok++)) ;;
            1)
                if [ "$CHECK_ONLY" = true ]; then
                    ((count_needs_fix++))
                else
                    ((count_fixed++))
                fi
                ;;
            *) ((count_error++)) ;;
        esac
    done

    echo -e "${BLUE}================================================================${NC}"
    echo -e "📊 ИТОГИ:"
    echo -e "   Всего проверено: ${#TARGETS[@]}"
    echo -e "   ${GREEN}Уже были в порядке:${NC} $count_ok"
    if [ "$CHECK_ONLY" = true ]; then
        echo -e "   ${YELLOW}Требуют исправления:${NC} $count_needs_fix"
    else
        echo -e "   ${CYAN}Успешно исправлено:${NC} $count_fixed"
    fi
    if [ $count_error -gt 0 ]; then
        echo -e "   ${RED}Ошибок подключения/выполнения:${NC} $count_error"
    fi
    echo -e "${BLUE}================================================================${NC}"
}

main "$@"
