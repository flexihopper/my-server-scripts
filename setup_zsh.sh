#!/bin/bash

# --- Скрипт для полной автоматической установки Zsh + Oh My Zsh + Powerlevel10k + плагины ---

echo "Шаг 1: Установка необходимых пакетов (zsh, git, curl, bat)..."
sudo apt update
sudo apt install -y zsh git curl bat

# На Ubuntu пакет 'bat' может установиться как 'batcat' из-за конфликта имен.
# Создаем символическую ссылку, чтобы команда 'bat' работала как надо.
if ! command -v bat &> /dev/null; then
    if command -v batcat &> /dev/null; then
        echo "Создание символической ссылки для bat -> batcat..."
        sudo ln -s /usr/bin/batcat /usr/local/bin/bat
    fi
fi

echo "------------------------------------------------------------"
echo "Шаг 2: Установка Oh My Zsh..."
if [ -d "$HOME/.oh-my-zsh" ]; then
    echo "Oh My Zsh уже установлен. Пропускаем."
else
    # Установка без запуска zsh и без смены оболочки (сделаем это в конце)
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

echo "------------------------------------------------------------"
echo "Шаг 3: Установка темы Powerlevel10k..."
P10K_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
if [ -d "$P10K_DIR" ]; then
    echo "Тема Powerlevel10k уже установлена. Пропускаем."
else
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
fi

echo "------------------------------------------------------------"
echo "Шаг 4: Установка кастомных плагинов..."
PLUGINS_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins"

# Список плагинов для установки (URL репозитория и имя папки)
declare -A plugins
plugins=(
    ["zsh-syntax-highlighting"]="https://github.com/zsh-users/zsh-syntax-highlighting.git"
    ["zsh-autosuggestions"]="https://github.com/zsh-users/zsh-autosuggestions.git"
    ["zsh-history-substring-search"]="https://github.com/zsh-users/zsh-history-substring-search.git"
    ["you-should-use"]="https://github.com/MichaelAquilina/zsh-you-should-use.git"
    ["zsh-bat"]="https://github.com/fdellwing/zsh-bat.git"
)

for name in "${!plugins[@]}"; do
    if [ -d "$PLUGINS_DIR/$name" ]; then
        echo "Плагин $name уже установлен. Пропускаем."
    else
        echo "Установка плагина $name..."
        git clone "${plugins[$name]}" "$PLUGINS_DIR/$name"
    fi
done

echo "------------------------------------------------------------"
echo "Шаг 5: Настройка файла ~/.zshrc..."

# Установка темы Powerlevel10k
sed -i '/^ZSH_THEME=/c\ZSH_THEME="powerlevel10k/powerlevel10k"' ~/.zshrc

# Установка списка плагинов
sed -i '/^plugins=/c\plugins=(\n  git\n  zsh-syntax-highlighting\n  zsh-autosuggestions\n  zsh-history-substring-search\n  you-should-use\n  zsh-bat\n)' ~/.zshrc

echo "Файл ~/.zshrc успешно настроен."

echo "------------------------------------------------------------"
echo "Шаг 6: Смена оболочки по умолчанию на Zsh..."
if [ "$SHELL" != "/usr/bin/zsh" ]; then
    sudo chsh -s $(which zsh) $USER
    echo "Оболочка по умолчанию изменена на Zsh. Изменения вступят в силу после перезахода в систему."
else
    echo "Zsh уже является вашей оболочкой по умолчанию."
fi

echo "------------------------------------------------------------"
echo "Установка успешно завершена!"
echo ""
echo "ВАЖНЫЕ СЛЕДУЮЩИЕ ШАГИ:"
echo "1. ПОЛНОСТЬЮ ПЕРЕЗАЙДИТЕ НА СЕРВЕР (закройте SSH-соединение и подключитесь снова)."
echo "2. Установите Nerd Font на ВАШЕМ ЛОКАЛЬНОМ компьютере и выберите его в настройках вашего терминала."
echo "3. При первом входе автоматически запустится мастер настройки Powerlevel10k ('p10k configure'). Следуйте его инструкциям."
echo "   Если он не запустился, введите команду 'p10k configure' вручную."
echo "------------------------------------------------------------"