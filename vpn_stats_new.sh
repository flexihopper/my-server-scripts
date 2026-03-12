#!/bin/bash

LOG_FILE="/usr/local/x-ui/access.log"
PORT=443

# Временный файл для обработки данных
TMP_DATA="/tmp/vpn_processed.txt"
> $TMP_DATA

echo "Сбор данных из соединений и логов... Подождите."

# 1. Получаем активные IP и кол-во сокетов
connections=$(sudo ss -atn sport = :$PORT | grep ESTAB | awk '{print $5}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort | uniq -c)

if [ -z "$connections" ]; then
    echo "Активных соединений на порту $PORT не найдено."
    exit 0
fi

while read -r line; do
    count=$(echo $line | awk '{print $1}')
    ip=$(echo $line | awk '{print $2}')
    
    # Ищем пользователя в логе
    user=$(grep "$ip" "$LOG_FILE" | tail -n 1 | awk '{print $NF}' | sed 's/]//g')
    if [ -z "$user" ]; then user="Unknown"; fi
    
    # Сохраняем во временный файл: Пользователь IP Сокеты
    echo "$user $ip $count" >> $TMP_DATA
done <<< "$connections"

echo -e "\n=== СВОДКА ПО ПОЛЬЗОВАТЕЛЯМ ==="
printf "%-20s | %-13s | %-10s | %s\n" "Пользователь" "Всего сокетов" "Кол-во IP" "Список IP"
echo "--------------------------------------------------------------------------------"

# 2. Группируем данные, считаем итоги
# Сортируем по количеству сокетов (вторая колонка) в основном блоке
result=$(sort $TMP_DATA | awk '{
    user=$1; ip=$2; count=$3;
    sockets[user] += count;
    ips[user] = ips[user] (ips[user] ? ", " : "") ip;
    ip_count[user]++;
    total_sockets += count;
} 
END {
    user_count = 0;
    for (u in sockets) {
        user_count++;
        printf "%-12s | %-13s | %-9s | %s\n", u, sockets[u], ip_count[u], ips[u]
    }
    # Передаем итоги через спец-префикс для отделения от сортировки
    print "TOTAL_DATA " user_count " " total_sockets
}')

# Выводим таблицу (кроме итоговой строки) с сортировкой по сокетам
echo "$result" | grep -v "TOTAL_DATA" | sort -k3 -nr

# Вытаскиваем итоги и выводим красиво внизу
final_stats=$(echo "$result" | grep "TOTAL_DATA")
u_total=$(echo $final_stats | awk '{print $2}')
s_total=$(echo $final_stats | awk '{print $3}')

echo "--------------------------------------------------------------------------------"
printf "%-17s | %-13s | (Уникальных пользователей: %s)\n" "ИТОГО:" "$s_total" "$u_total"
echo "--------------------------------------------------------------------------------"

# Удаляем временный файл
rm $TMP_DATA
