#!/bin/bash
# Строгий режим: выход при любой ошибке
set -e

# Перенаправляем весь вывод (stdout и stderr) в файл лога и одновременно на экран
exec > >(tee -a /var/log/server-setup.log) 2>&1

echo "🚀 Начало настройки сервера: $(date)"

# === Переменные (замени на свои) ===
NEW_USER="www"
SSH_PORT="2244"   # можно поменять на нестандартный, напр. 2222
TIMEZONE="Europe/Moscow" # Укажи свой часовой пояс (список: timedatectl list-timezones)
PYTHON_VERSION="3.12" # Версия Python для установки

# === Обновление системы ===
echo "🔄 Обновление пакетов системы..."
apt update && apt upgrade -y

# === Установка базовых и дополнительных пакетов ===
echo "📦 Установка необходимых пакетов..."
apt install -y \
  sudo \
  curl \
  wget \
  git \
  ufw \
  htop \
  unzip \
  mc \
  ncdu \
  software-properties-common \
  apt-transport-https \
  ca-certificates \
  fail2ban \
  build-essential

# === Настройка hostname ===
echo "🏷️  Текущий hostname: $(hostname)"
read -p "Введите новый hostname (Enter для пропуска): " NEW_HOSTNAME

if [ -n "$NEW_HOSTNAME" ]; then
  hostnamectl set-hostname "$NEW_HOSTNAME"
  sed -i "s/127.0.1.1.*/127.0.1.1       $NEW_HOSTNAME/" /etc/hosts
  grep -q "127.0.1.1" /etc/hosts || echo "127.0.1.1       $NEW_HOSTNAME" >> /etc/hosts
  echo "✅ Hostname изменён на: $NEW_HOSTNAME"
else
  echo "⏭️  Hostname не изменён."
fi
# === Настройка Docker ===
read -p "Установить Docker? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🐳 Установка Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    usermod -aG docker $NEW_USER
    systemctl enable docker
    echo "✅ Docker установлен."
fi

# === Настройка часового пояса ===
echo "🕒 Настройка часового пояса на $TIMEZONE..."
timedatectl set-timezone "$TIMEZONE"

# === Настройка Docker ===
read -p "Установить Docker? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🐳 Установка Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    usermod -aG docker $NEW_USER
    systemctl enable docker
    echo "✅ Docker установлен."
fi

# === Установка свежей версии Python ===
echo "🐍 Установка Python $PYTHON_VERSION из PPA deadsnakes..."
add-apt-repository ppa:deadsnakes/ppa -y
apt update
apt install -y python${PYTHON_VERSION} python${PYTHON_VERSION}-venv python${PYTHON_VERSION}-dev

# === Создание нового пользователя ===
if ! id -u "$NEW_USER" >/dev/null 2>&1; then
  echo "👤 Создание нового пользователя '$NEW_USER'..."
  adduser --disabled-password --gecos "" "$NEW_USER"
  usermod -aG sudo "$NEW_USER"
  echo "✅ Пользователь '$NEW_USER' создан и добавлен в группу sudo."
else
  echo "👤 Пользователь '$NEW_USER' уже существует. Пропускаем создание."
fi

# === Настройка SSH ===
echo "🔐 Настройка безопасного доступа по SSH..."

# Настройка конфигурации SSHD
sed -i "s/#Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/.*Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config  # Если уже раскомментирован
sed -i "s/.*PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/.*PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config  # Временно
sed -i "s/.*PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
sed -i "s/.*PermitEmptyPasswords .*/PermitEmptyPasswords no/" /etc/ssh/sshd_config
sed -i "s/.*MaxAuthTries .*/MaxAuthTries 3/" /etc/ssh/sshd_config
sed -i "s/.*X11Forwarding .*/X11Forwarding no/" /etc/ssh/sshd_config
# Чтобы локали нормально работали
sed -i 's/^ *AcceptEnv.*/# &/' /etc/ssh/sshd_config

if systemctl list-units --type=service | grep -q "ssh.service"; then
    SSH_SERVICE="ssh"
elif systemctl list-units --type=service | grep -q "sshd.service"; then
    SSH_SERVICE="sshd"
else
    echo "❌ SSH-сервис не найден!"
    exit 1
fi

systemctl restart "$SSH_SERVICE"
echo "🛡️ Сервер SSH настроен: вход под root отключен, порт изменен на $SSH_PORT."

# === Настройка Firewall (UFW) ===
echo "🔥 Настройка файрвола UFW..."

UFW_FILE="/etc/default/ufw"
BACKUP_FILE="${UFW_FILE}.backup.$(date +%Y%m%d_%H%M%S)"

echo "Создаём бэкап UFW-конфига..."
cp "$UFW_FILE" "$BACKUP_FILE"
echo "Бэкап сохранён: $BACKUP_FILE"

ufw allow $SSH_PORT/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
echo "✅ Файрвол активирован. Открыты порты: $SSH_PORT (SSH), 80 (HTTP), 443 (HTTPS)."

# === Настройка Fail2Ban ===
echo "🚫 Настройка Fail2Ban для защиты SSH..."
cat <<EOF >/etc/fail2ban/jail.local
[sshd]
enabled = true
port    = $SSH_PORT
filter  = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
EOF

systemctl enable fail2ban
systemctl restart fail2ban
echo "✅ Fail2Ban настроен и запущен."

# === Финальное сообщение ===
echo ""
echo " Задай пароль для $NEW_USER:"
passwd $NEW_USER
echo "🎉 === Настройка сервера успешно завершена! === 🎉"
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "Не забудьте проверить лог выполнения в файле: /var/log/server-setup.log"
echo "Скопируй SSH ключ на сервер:"
echo "ssh-copy-id -p $SSH_PORT $NEW_USER@$SERVER_IP"
echo "Для подключения используйте команду:"
echo "ssh -p $SSH_PORT $NEW_USER@$SERVER_IP"
echo ""
echo "🔐 Хотите отключить парольную аутентификацию SSH? (рекомендуется после копирования ключа)"
echo "Убедитесь, что вы скопировали SSH-ключ командой:"
echo "  ssh-copy-id -p $SSH_PORT $NEW_USER@$SERVER_IP"
echo ""
read -p "Отключить вход по паролю? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    sed -i "s/.*PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
    systemctl restart "$SSH_SERVICE"
    echo "✅ Парольная аутентификация отключена!"
else
    echo "⚠️  Парольная аутентификация оставлена включенной."
    echo "Отключите её позже командой:"
    echo "sudo sed -i 's/.*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config"
    echo "sudo systemctl restart ssh"
fi
echo "🚀 Настройка завершена: $(date)"