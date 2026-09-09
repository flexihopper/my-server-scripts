#!/bin/bash
# Строгий режим: выход при любой ошибке
set -e

# === Защита от обрыва соединения ===
if [ -z "$STY" ] && [ -z "$TMUX" ]; then
    echo "⚠️  Скрипт не запущен в screen/tmux!"
    echo "Для защиты от обрыва SSH установим screen и перезапустим скрипт."
    read -p "Продолжить? (Y/n): " -n 1 -r || REPLY="y"
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        apt-get update -qq && apt-get install -y screen
        echo "🔄 Перезапуск в screen..."
        exec screen -S setup bash "$0" "$@"
    fi
fi

# Перенаправляем весь вывод (stdout и stderr) в файл лога и одновременно на экран
exec > >(tee -a /var/log/server-setup.log) 2>&1

echo "========================================"
echo "🚀 Начало настройки сервера: $(date)"
echo "📺 Запущено в: ${STY:-${TMUX:-terminal}}"
echo "========================================"

# === Переменные ===
NEW_USER="www"
SSH_PORT="2244"
TIMEZONE="Europe/Moscow"
PYTHON_VERSION="3.12"
NODE_MAJOR="22"

# === Обновление системы ===
echo "🔄 Обновление пакетов системы..."
apt-get update && apt-get upgrade -y

# === Установка пакетов (с fail2ban) ===
echo "📦 Установка необходимых пакетов..."
apt-get install -y \
  sudo curl wget git ufw htop unzip mc ncdu \
  software-properties-common apt-transport-https \
  ca-certificates build-essential psmisc vim fail2ban

# Запуск fail2ban
systemctl enable fail2ban
systemctl start fail2ban
echo "✅ fail2ban установлен и запущен"

# === Настройка hostname ===
echo "🏷️ Текущий hostname: $(hostname)"
read -p "Введите новый hostname (Enter для пропуска): " NEW_HOSTNAME || true
if [ -n "$NEW_HOSTNAME" ]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    sed -i "s/127.0.1.1.*/127.0.1.1       $NEW_HOSTNAME/" /etc/hosts
    echo "✅ Hostname изменён на: $NEW_HOSTNAME"
fi

# === Настройка часового пояса ===
echo "🕒 Настройка часового пояса на $TIMEZONE..."
timedatectl set-timezone "$TIMEZONE"

# === Настройка Docker ===
read -p "Установить Docker? (y/N): " -n 1 -r || REPLY="n"
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🐳 Установка Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    systemctl enable docker
    rm -f /tmp/get-docker.sh
    echo "✅ Docker установлен."
    echo "⚠️  ВАЖНО: Docker пишет правила в iptables в обход UFW!"
    echo "   Контейнеры с -p будут доступны извне даже без разрешения UFW."
fi

# === Установка Node.js ===
read -p "❓ Установить Node.js v$NODE_MAJOR? (y/N): " -n 1 -r || REPLY="n"
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🟢 Установка Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_$NODE_MAJOR.x | bash -
    apt-get install -y nodejs
    echo "✅ Node.js $(node -v) установлен."
fi

# === Установка Redis ===
read -p "❓ Установить Redis? (y/N): " -n 1 -r || REPLY="n"
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🟥 Установка Redis..."
    apt-get install -y redis-server
    systemctl enable redis-server
    echo "✅ Redis установлен и запущен (слушает только localhost)."
fi

# === Установка PostgreSQL ===
read -p "❓ Установить PostgreSQL? (y/N): " -n 1 -r || REPLY="n"
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🐘 Установка PostgreSQL..."
    apt-get install -y postgresql postgresql-contrib
    systemctl enable postgresql
    echo "✅ PostgreSQL установлен (слушает только localhost)."
fi

# === Установка Python ===
read -p "Установить Python $PYTHON_VERSION? (y/N): " -n 1 -r || REPLY="n"
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🐍 Установка Python..."
    # Для Ubuntu 24.04+ Python 3.12 есть в стандартных репозиториях
    if ! apt-cache show python${PYTHON_VERSION} >/dev/null 2>&1; then
        add-apt-repository ppa:deadsnakes/ppa -y
        apt-get update
    fi
    apt-get install -y python${PYTHON_VERSION} python${PYTHON_VERSION}-venv python${PYTHON_VERSION}-dev
    echo "✅ Python ${PYTHON_VERSION} установлен."
fi

# === Создание пользователя ===
if ! id -u "$NEW_USER" >/dev/null 2>&1; then
    echo "👤 Создание пользователя '$NEW_USER'..."
    adduser --disabled-password --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    echo "✅ Пользователь '$NEW_USER' создан."
    echo "🔑 Задай пароль для $NEW_USER (нужен для sudo):"
    passwd "$NEW_USER"
else
    echo "👤 Пользователь '$NEW_USER' уже существует."
    read -p "Изменить пароль? (y/N): " -n 1 -r || REPLY="n"
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        passwd "$NEW_USER"
    fi
fi

# Добавляем в группу docker, если он установлен и пользователь ещё не в группе
if [ -f /usr/bin/docker ]; then
    if ! id -nG "$NEW_USER" | grep -qw docker; then
        usermod -aG docker "$NEW_USER"
        echo "✅ Пользователь '$NEW_USER' добавлен в группу docker."
    fi
fi

# === Настройка SSH (Классический режим без сокетов) ===
echo ""
echo "========================================"
echo "🔐 Настройка SSH на порту $SSH_PORT..."
echo "========================================"

# Сохраняем оригинальные значения для отката
ORIGINAL_PORT=$(grep -E "^#?Port " /etc/ssh/sshd_config | awk '{print $2}' | head -1)
ORIGINAL_PORT=${ORIGINAL_PORT:-22}
ORIGINAL_ROOT_LOGIN=$(grep -E "^#?PermitRootLogin " /etc/ssh/sshd_config | awk '{print $2}' | head -1)
ORIGINAL_ROOT_LOGIN=${ORIGINAL_ROOT_LOGIN:-yes}

# 1. Полное отключение ssh.socket (решение для Ubuntu 24.04+)
if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
    echo "⚙️ Деактивация ssh.socket..."
    systemctl stop ssh.socket || true
    systemctl disable ssh.socket || true
    systemctl mask ssh.socket || true
fi

# 2. Удаляем конфликтующие drop-in конфиги (cloud-init и др.)
echo "🧹 Очистка drop-in конфигов SSH..."
if [ -d /etc/ssh/sshd_config.d ]; then
    # Бэкап на всякий случай (путь вычисляем один раз)
    BACKUP_DIR="/root/ssh-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp -r /etc/ssh/sshd_config.d "$BACKUP_DIR"/ 2>/dev/null || true

    # Удаляем проблемные конфиги
    rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf
    rm -f /etc/ssh/sshd_config.d/*cloud*.conf
    echo "✅ Drop-in конфиги очищены (бэкап сохранён в $BACKUP_DIR)"
fi

# 3. Правка конфигурации sshd_config
echo "📝 Изменение основного конфига SSH..."
SSH_BACKUP="/etc/ssh/sshd_config.backup-$(date +%Y%m%d-%H%M%S)"
cp /etc/ssh/sshd_config "$SSH_BACKUP"

sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config
sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitEmptyPasswords .*/PermitEmptyPasswords no/" /etc/ssh/sshd_config
sed -i 's/^ *AcceptEnv.*/# &/' /etc/ssh/sshd_config

# 4. Проверка конфига перед применением
echo "🔍 Проверка синтаксиса SSH конфига..."
if ! sshd -t; then
    echo "❌ ОШИБКА в конфигурации SSH! Откатываем..."
    cp "$SSH_BACKUP" /etc/ssh/sshd_config
    echo "✅ Конфиг откачен. SSH остался на прежних настройках."
    exit 1
fi

# Показываем эффективные настройки — то, что sshd реально будет использовать.
# Ловит переопределения из drop-in конфигов, которые не попали в очистку.
echo "🔍 Эффективные настройки SSH:"
sshd -T | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|permitemptypasswords) ' || true

# 5. Настройка fail2ban для нового порта SSH
echo "🛡️ Настройка fail2ban для SSH..."
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = $SSH_PORT
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF

systemctl restart fail2ban
echo "✅ fail2ban настроен для SSH на порту $SSH_PORT"

# 6. Перезапуск SSH
systemctl daemon-reload
systemctl enable ssh
systemctl restart ssh

echo ""
echo "========================================"
echo "⚠️  КРИТИЧЕСКИ ВАЖНО!"
echo "========================================"
echo "SSH теперь на порту $SSH_PORT"
echo "Root-вход отключён, но вход по паролю ещё работает."
echo ""
echo "НЕ ЗАКРЫВАЙТЕ это окно!"
echo "Откройте НОВЫЙ терминал и проверьте подключение:"
echo ""
echo "  ssh -p $SSH_PORT $NEW_USER@$(curl -s https://api.ipify.org || echo 'YOUR_IP')"
echo ""
echo "Если не получается — НЕ продолжайте, иначе потеряете доступ!"
echo "========================================"
echo ""
read -p "✅ Подключение работает? Продолжить? (y/N): " -n 1 -r || REPLY="n"
echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "❌ Откатываем изменения SSH..."

    # Восстанавливаем порт и PermitRootLogin
    sed -i "s/^#\?Port .*/Port $ORIGINAL_PORT/" /etc/ssh/sshd_config
    sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin $ORIGINAL_ROOT_LOGIN/" /etc/ssh/sshd_config

    # Восстанавливаем fail2ban
    sed -i "s/port = $SSH_PORT/port = $ORIGINAL_PORT/" /etc/fail2ban/jail.local

    # Проверяем и применяем
    if sshd -t; then
        systemctl restart ssh
        systemctl restart fail2ban

        # Открываем старый порт в UFW
        ufw allow "$ORIGINAL_PORT"/tcp

        echo "✅ SSH восстановлен:"
        echo "   Порт: $ORIGINAL_PORT"
        echo "   PermitRootLogin: $ORIGINAL_ROOT_LOGIN"
        echo ""
        echo "Скрипт остановлен. Разберитесь с SSH и запустите снова."
    else
        echo "❌ КРИТИЧЕСКАЯ ОШИБКА при откате конфига!"
        echo "Восстановите вручную из /etc/ssh/sshd_config.backup-*"
    fi

    exit 1
fi

# === Настройка Firewall (UFW) ===
echo ""
echo "🔥 Настройка UFW..."
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp

# Блокируем исходящий SMTP (защита от спама)
# ВНИМАНИЕ: это заблокирует отправку почты напрямую (в т.ч. уведомления fail2ban)
read -p "❓ Заблокировать исходящий порт 25 (SMTP)? (y/N): " -n 1 -r || REPLY="n"
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    ufw reject out 25/tcp
    echo "✅ Исходящий SMTP заблокирован (для отправки почты используйте relay через 587/465)"
fi

ufw --force enable
echo "✅ Firewall настроен"

# === Очистка системы ===
echo ""
echo "🧹 Очистка системы от временных файлов..."
apt-get autoremove -y
apt-get autoclean -y
rm -rf /var/lib/apt/lists/*
rm -f /tmp/get-docker.sh

# === Финал ===
SERVER_IP=$(curl -s https://api.ipify.org || echo "UNKNOWN")
echo ""
echo "========================================"
echo "🎉 Базовая настройка завершена!"
echo "========================================"
echo ""
echo "СЛЕДУЮЩИЕ ШАГИ:"
echo ""
echo "1️⃣ Со своего ПК скопируй SSH-ключ:"
echo "   ssh-copy-id -p $SSH_PORT $NEW_USER@$SERVER_IP"
echo ""
echo "2️⃣ Проверь вход по ключу в НОВОМ окне терминала:"
echo "   ssh -p $SSH_PORT $NEW_USER@$SERVER_IP"
echo ""
echo "3️⃣ Только после успешной проверки отключай вход по паролю!"
echo ""
echo "========================================"
echo ""

read -p "🔐 Отключить вход по паролю прямо сейчас? (y/N): " -n 1 -r || REPLY="n"
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "⚠️  ПОСЛЕДНЕЕ ПРЕДУПРЕЖДЕНИЕ!"
    echo "Если у вас нет рабочего SSH-ключа для пользователя $NEW_USER,"
    echo "вы НАВСЕГДА потеряете доступ к серверу!"
    echo ""
    read -p "Вы уверены? Введите 'yes' для подтверждения: " CONFIRMATION

    if [ "$CONFIRMATION" = "yes" ]; then
        sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config

        if sshd -t; then
            systemctl restart ssh
            echo ""
            echo "✅ Готово! Вход по паролю отключен."
            echo "   Доступ только по SSH-ключам."
        else
            echo "❌ Ошибка в конфигурации! Изменения не применены."
        fi
    else
        echo "❌ Отменено. Вход по паролю оставлен включённым."
    fi
else
    echo ""
    echo "⚠️  ВАЖНО: Вход по паролю ОСТАВЛЕН ВКЛЮЧЕННЫМ!"
    echo "   Не забудьте отключить его позже вручную."
    echo "   (PasswordAuthentication no в /etc/ssh/sshd_config)"
fi

echo ""
echo "========================================"
echo "📋 Информация"
echo "========================================"
echo "Лог: /var/log/server-setup.log"
echo "Бэкапы SSH: /root/ssh-backup-* и /etc/ssh/sshd_config.backup-*"
echo ""
echo "💡 Работа со screen:"
echo "   Выход без закрытия: Ctrl+A затем D"
echo "   Возврат в сессию: screen -r setup"
echo ""
echo "🚀 Настройка завершена: $(date)"
echo "========================================"
