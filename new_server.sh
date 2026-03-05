#!/bin/bash
# Строгий режим: выход при любой ошибке
set -e

# Перенаправляем весь вывод (stdout и stderr) в файл лога и одновременно на экран
exec > >(tee -a /var/log/server-setup.log) 2>&1

echo "🚀 Начало настройки сервера: $(date)"

# === Переменные ===
NEW_USER="www"
SSH_PORT="2244"
TIMEZONE="Europe/Moscow"
PYTHON_VERSION="3.12"

# === Обновление системы ===
echo "🔄 Обновление пакетов системы..."
apt update && apt upgrade -y

# === Установка пакетов (без fail2ban) ===
echo "📦 Установка необходимых пакетов..."
apt install -y \
  sudo curl wget git ufw htop unzip mc ncdu \
  software-properties-common apt-transport-https \
  ca-certificates build-essential psmisc vim

# === Настройка hostname ===
echo "🏷️ Текущий hostname: $(hostname)"
read -p "Введите новый hostname (Enter для пропуска): " NEW_HOSTNAME
if [ -n "$NEW_HOSTNAME" ]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    sed -i "s/127.0.1.1.*/127.0.1.1       $NEW_HOSTNAME/" /etc/hosts
    echo "✅ Hostname изменён на: $NEW_HOSTNAME"
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
    systemctl enable docker
    echo "✅ Docker установлен."
fi

# === Установка Python ===
read -p "Установить Python $PYTHON_VERSION? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🐍 Установка Python..."
    add-apt-repository ppa:deadsnakes/ppa -y
    apt update
    apt install -y python${PYTHON_VERSION} python${PYTHON_VERSION}-venv python${PYTHON_VERSION}-dev
fi

# === Создание пользователя ===
if ! id -u "$NEW_USER" >/dev/null 2>&1; then
    echo "👤 Создание пользователя '$NEW_USER'..."
    adduser --disabled-password --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    # Добавляем в группу docker, если он установлен
    [ -f /usr/bin/docker ] && usermod -aG docker "$NEW_USER"
    echo "✅ Пользователь '$NEW_USER' создан."
else
    echo "👤 Пользователь '$NEW_USER' уже существует."
fi
echo "🔑 Задай пароль для $NEW_USER (нужен для sudo):"
passwd "$NEW_USER"

# === Настройка SSH (Классический режим без сокетов) ===
echo "🔐 Настройка SSH на порту $SSH_PORT..."

# 1. Полное отключение ssh.socket (решение для Ubuntu 24.04+)
if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
    echo "⚙️ Деактивация ssh.socket..."
    systemctl stop ssh.socket || true
    systemctl disable ssh.socket || true
    systemctl mask ssh.socket || true
fi

# 2. Правка конфигурации sshd_config
# Используем безопасные настройки: без паролей, без root, кастомный порт
sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config
sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitEmptyPasswords .*/PermitEmptyPasswords no/" /etc/ssh/sshd_config
sed -i 's/^ *AcceptEnv.*/# &/' /etc/ssh/sshd_config

# 3. Перезапуск классического сервиса
systemctl daemon-reload
systemctl enable ssh
systemctl restart ssh

# === Настройка Firewall (UFW) ===
echo "🔥 Настройка UFW..."
ufw allow "$SSH_PORT"/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# === Очистка системы ===
echo "🧹 Очистка системы от временных файлов..."
apt autoremove -y  # Удаляет неиспользуемые зависимости
apt autoclean -y   # Удаляет устаревшие архивы пакетов
rm -rf /var/lib/apt/lists/* # Очищает кэш списков пакетов (уменьшает размер /var)
rm -f get-docker.sh # Удаляет скрипт установки Docker, если он остался

# === Финал ===
SERVER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "🎉 Базовая настройка завершена!"
echo "----------------------------------------------------"
echo "СЛЕДУЮЩИЕ ШАГИ:"
echo "1. Со своего ПК скопируй ключ:"
echo "   ssh-copy-id -p $SSH_PORT $NEW_USER@$SERVER_IP"
echo ""
echo "2. Проверь вход по ключу:"
echo "   ssh -p $SSH_PORT $NEW_USER@$SERVER_IP"
echo "----------------------------------------------------"

read -p "🔐 Отключить вход по паролю прямо сейчас? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
    systemctl restart ssh
    echo "✅ Готово! Вход по паролю отключен. Доступ только по SSH-ключам."
else
    echo "⚠️ Вход по паролю ОСТАВЛЕН ВКЛЮЧЕННЫМ. Не забудьте отключить его позже!"
fi

echo "🚀 Настройка завершена: $(date)"
