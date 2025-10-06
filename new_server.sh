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

# === Настройка часового пояса ===
echo "🕒 Настройка часового пояса на $TIMEZONE..."
timedatectl set-timezone "$TIMEZONE"

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
#mkdir -p /home/$NEW_USER/.ssh
#touch /home/www/.ssh/authorized_keys
#chown -R www:www /home/www/.ssh
#chmod 700 /home/$NEW_USER/.ssh
#chmod 600 /home/www/.ssh/authorized_keys
# надо доработать. созать папку юыыр

# Настройка конфигурации SSHD
systemctl disable ssh.service
systemctl stop ssh
pkill -f /usr/sbin/sshd
sed -i "s/#Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
#sed -i "s/#PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
#sed -i "s/PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config # Дополнительно для уже раскомментированных строк

systemctl restart ssh.socket


echo "🛡️ Сервер SSH настроен: вход под root отключен, порт изменен на $SSH_PORT."

# === Настройка Firewall (UFW) ===
echo "🔥 Настройка файрвола UFW..."
# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   echo "Запустите скрипт с sudo: sudo bash $0"
   exit 1
fi

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
echo "Отключи вход по паролю!"
echo "sudo su"
echo "vim /etc/ssh/sshd_config"
echo "PasswordAuthentication no"
echo "reboot"