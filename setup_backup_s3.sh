#!/bin/bash

# --- НАСТРОЙКИ ---
DB_NAME="mydb"                        # Имя базы данных для бэкапа
S3_BUCKET="your-s3-bucket-name"       # Название вашего S3 бакета

# Опционально: Путь внутри бакета (например, "backups/postgres")
S3_PATH="postgres_backups"

# Опционально: URL эндпоинта для S3-совместимых хранилищ.
# Если используете Amazon S3, оставьте пустым: ""
# Пример для Yandex Cloud: "https://storage.yandexcloud.net"
ENDPOINT_URL=""

# Директория для временного хранения локального файла бэкапа
BACKUP_DIR="/var/backups/postgres"

# --- ОСНОВНОЙ КОД ---

# Создаем директорию, если она не существует
mkdir -p "$BACKUP_DIR"

# Формируем имя файла с датой и временем
DATE_FORMAT=$(date "+%Y-%m-%d_%H-%M-%S")
BACKUP_FILENAME="${DB_NAME}_${DATE_FORMAT}.dump"
LOCAL_BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILENAME}"

echo "Создание бэкапа базы данных '${DB_NAME}'..."

# Создаем бэкап с помощью pg_dump от имени пользователя postgres
# Используем сжатый custom-формат (-Fc)
sudo -u postgres pg_dump -Fc -f "$LOCAL_BACKUP_PATH" "$DB_NAME"

# Проверяем, что бэкап успешно создан
if [ $? -ne 0 ]; then
    echo "Ошибка: Не удалось создать бэкап."
    exit 1
fi

echo "Бэкап создан: ${LOCAL_BACKUP_PATH}"
echo "Загрузка в S3 бакет '${S3_BUCKET}'..."

# Формируем команду для AWS CLI, добавляя эндпоинт, если он указан
AWS_CMD="aws s3 cp"
if [ -n "$ENDPOINT_URL" ]; then
    AWS_CMD="$AWS_CMD --endpoint-url=$ENDPOINT_URL"
fi

# Загружаем файл в S3
$AWS_CMD "$LOCAL_BACKUP_PATH" "s3://${S3_BUCKET}/${S3_PATH}/${BACKUP_FILENAME}"

# Проверяем, что загрузка прошла успешно
if [ $? -eq 0 ]; then
    echo "Загрузка в S3 успешно завершена."
    # Удаляем локальный файл бэкапа после успешной загрузки
    rm "$LOCAL_BACKUP_PATH"
    echo "Локальный файл бэкапа удален."
else
    echo "Ошибка: Не удалось загрузить бэкап в S3."
    exit 1
fi

echo "Работа скрипта успешно завершена."