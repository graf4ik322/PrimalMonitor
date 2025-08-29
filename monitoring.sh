#!/bin/bash

# Настройки Telegram
TELEGRAM_BOT_TOKEN="8336743350:AAGmtaR9_LIv9yE9c874cKDnfFmL_yHSpJg"
TELEGRAM_CHAT_ID="-4919582560"

# Функция отправки сообщения в Telegram с проверкой ошибок
send_to_telegram() {
    local message="$1"
    
    echo "Отправка сообщения в Telegram..."
    
    # Используем простой текстовый режим вместо Markdown для избежания проблем с экранированием
    response=$(curl -s -w "HTTPSTATUS:%{http_code}" -X POST \
        "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode "text=$message")
    
    # Извлекаем HTTP статус и тело ответа
    http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    body=$(echo "$response" | sed -e 's/HTTPSTATUS:.*//g')
    
    echo "HTTP Status: $http_code"
    echo "Response: $body"
    
    if [ "$http_code" -eq 200 ]; then
        echo "Сообщение успешно отправлено!"
        return 0
    else
        echo "Ошибка отправки сообщения!"
        return 1
    fi
}

# Тест соединения с Telegram API
test_telegram_connection() {
    echo "Тестирование соединения с Telegram API..."
    
    response=$(curl -s -w "HTTPSTATUS:%{http_code}" \
        "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getMe")
    
    http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    body=$(echo "$response" | sed -e 's/HTTPSTATUS:.*//g')
    
    echo "HTTP Status: $http_code"
    echo "Bot info: $body"
    
    if [ "$http_code" -eq 200 ]; then
        echo "✅ Бот токен валидный"
    else
        echo "❌ Проблема с токеном бота"
        exit 1
    fi
}

# Тест отправки в чат
test_chat_access() {
    echo "Тестирование доступа к чату..."
    
    test_message="🤖 Тестовое сообщение от бота мониторинга"
    
    response=$(curl -s -w "HTTPSTATUS:%{http_code}" -X POST \
        "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "chat_id=$TELEGRAM_CHAT_ID" \
        -d "text=$test_message")
    
    http_code=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    body=$(echo "$response" | sed -e 's/HTTPSTATUS:.*//g')
    
    echo "HTTP Status: $http_code"
    echo "Response: $body"
    
    if [ "$http_code" -eq 200 ]; then
        echo "✅ Доступ к чату есть"
    else
        echo "❌ Нет доступа к чату или неверный chat_id"
        exit 1
    fi
}

# Функция получения CPU usage без создания нагрузки
get_cpu_usage() {
    # Метод 1: Использование /proc/stat с небольшой задержкой
    if [ -f /proc/stat ]; then
        # Читаем два снимка с интервалом в 1 секунду
        read cpu1 < <(grep '^cpu ' /proc/stat)
        sleep 1
        read cpu2 < <(grep '^cpu ' /proc/stat)
        
        # Парсим данные
        cpu1_arr=($cpu1)
        cpu2_arr=($cpu2)
        
        # Вычисляем разности
        user_diff=$((${cpu2_arr[1]} - ${cpu1_arr[1]}))
        nice_diff=$((${cpu2_arr[2]} - ${cpu1_arr[2]}))
        system_diff=$((${cpu2_arr[3]} - ${cpu1_arr[3]}))
        idle_diff=$((${cpu2_arr[4]} - ${cpu1_arr[4]}))
        iowait_diff=$((${cpu2_arr[5]} - ${cpu1_arr[5]}))
        irq_diff=$((${cpu2_arr[6]} - ${cpu1_arr[6]}))
        softirq_diff=$((${cpu2_arr[7]} - ${cpu1_arr[7]}))
        
        # Общее время
        total_diff=$((user_diff + nice_diff + system_diff + idle_diff + iowait_diff + irq_diff + softirq_diff))
        used_diff=$((total_diff - idle_diff))
        
        if [ $total_diff -gt 0 ]; then
            cpu_usage=$(echo "scale=1; $used_diff * 100 / $total_diff" | bc)
            # Исправляем формат: добавляем 0 перед точкой если нужно
            if [[ $cpu_usage == .* ]]; then
                cpu_usage="0$cpu_usage"
            fi
            echo "$cpu_usage"
            return 0
        fi
    fi
    
    # Метод 2: Использование vmstat
    if command -v vmstat >/dev/null 2>&1; then
        # vmstat дает средние значения, менее нагружает систему
        idle=$(vmstat 1 2 | tail -1 | awk '{print $15}')
        if [ -n "$idle" ] && [ "$idle" -ge 0 ] && [ "$idle" -le 100 ]; then
            cpu_usage=$(echo "100 - $idle" | bc)
            # Исправляем формат: добавляем 0 перед точкой если нужно
            if [[ $cpu_usage == .* ]]; then
                cpu_usage="0$cpu_usage"
            fi
            echo "$cpu_usage"
            return 0
        fi
    fi
    
    # Метод 3: Использование sar (если доступен)
    if command -v sar >/dev/null 2>&1; then
        idle=$(sar -u 1 1 | grep "Average" | awk '{print $8}')
        if [ -n "$idle" ]; then
            cpu_usage=$(echo "100 - $idle" | bc)
            # Исправляем формат: добавляем 0 перед точкой если нужно
            if [[ $cpu_usage == .* ]]; then
                cpu_usage="0$cpu_usage"
            fi
            echo "$cpu_usage"
            return 0
        fi
    fi
    
    # Если все методы не сработали, возвращаем N/A
    echo "N/A"
    return 1
}

# Функция получения Load Average с интерпретацией
get_load_average() {
    if [ -f /proc/loadavg ]; then
        read load1 load5 load15 processes last_pid < /proc/loadavg
        cores=$(nproc)
        
        # Вычисляем процент нагрузки относительно количества ядер
        load_percent=$(echo "scale=1; $load1 * 100 / $cores" | bc)
        # Исправляем формат: добавляем 0 перед точкой если нужно
        if [[ $load_percent == .* ]]; then
            load_percent="0$load_percent"
        fi
        
        echo "$load1 $load5 $load15 ($load_percent%)"
    else
        echo "N/A"
    fi
}

# Сбор данных о системе
collect_system_data() {
    # Используем printf для правильного форматирования
    printf "🖥️ Мониторинг ресурсов системы\n"
    printf "📅 %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"

    # Имя сервера
    hostname="AdminPanel #AdminPanel"
    printf "🏷️ Сервер: %s\n\n" "$hostname"

    # 1. CPU
    printf "⚡ CPU Usage:\n"
    
    # Получаем количество ядер
    cores=$(nproc)
    printf "├ CPU Cores: %s\n" "$cores"
    
    # Load Average с интерпретацией
    load_info=$(get_load_average)
    printf "├ Load Average: %s\n" "$load_info"
    
    # Получаем CPU usage безопасным методом
    cpu_usage=$(get_cpu_usage)
    printf "└ Current CPU Usage: %s%%\n" "$cpu_usage"
    
    # Анализ нагрузки
    if [ "$cpu_usage" != "N/A" ]; then
        if (( $(echo "$cpu_usage > 85" | bc -l 2>/dev/null || echo 0) )); then
            printf "  ⚠️ CPU Warning: High load (>85%%)\n"
        elif (( $(echo "$cpu_usage > 70" | bc -l 2>/dev/null || echo 0) )); then
            printf "  ⚡ CPU Notice: Moderate load (>70%%)\n"
        else
            printf "  ✅ CPU Reserve: OK\n"
        fi
    else
        printf "  ⚠️ CPU data unavailable\n"
    fi
    printf "\n"

    # 2. RAM
    printf "💾 Memory Usage:\n"
    
    # Получаем детальную информацию о памяти
    mem_info=$(free -h | awk '/^Mem:/ {
        total=$2; used=$3; free=$4; available=$7
        if (available == "") available = free
        printf "├ Total: %s, Used: %s, Available: %s\n", total, used, available
    }')
    printf "%s" "$mem_info"
    
    # Используем available память для более точного расчета
    mem_percent=$(free | awk '/^Mem:/ {
        if ($7 != "") {
            # Если есть колонка available, используем её
            printf "%.1f", ($2-$7)/$2 * 100
        } else {
            # Если нет available, используем used
            printf "%.1f", $3/$2 * 100
        }
    }')
    
    # Исправляем формат: добавляем 0 перед точкой если нужно
    if [[ $mem_percent == .* ]]; then
        mem_percent="0$mem_percent"
    fi
    # Показываем available память
    available_mem=$(free -h | awk '/^Mem:/ {print ($7 != "") ? $7 : $4}')
    printf "└ Memory Usage: %s%% (Available: %s)\n" "$mem_percent" "$available_mem"
    
    if (( $(echo "$mem_percent > 85" | bc -l 2>/dev/null || echo 0) )); then
        printf "  ⚠️ Memory Warning: High usage (>85%%)\n"
    elif (( $(echo "$mem_percent > 70" | bc -l 2>/dev/null || echo 0) )); then
        printf "  ⚡ Memory Notice: Moderate usage (>70%%)\n"
    else
        printf "  ✅ Memory Reserve: OK\n"
    fi
    printf "\n"
    
    # 3. Disk
    printf "💿 Disk Usage:\n"
    
    # Исправленный вывод дисков
    df -h | grep -E '^/dev/' | awk '{printf "├ %s: %s/%s (%s)\n", $1, $3, $2, $5}'
    
    disk_usage=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    printf "└ Root Usage: %s%%\n" "$disk_usage"
    
    if [ "$disk_usage" -gt 85 ]; then
        printf "  ⚠️ Disk Warning: Root filesystem >85%%\n"
    elif [ "$disk_usage" -gt 70 ]; then
        printf "  ⚡ Disk Notice: Root filesystem >70%%\n"
    else
        printf "  ✅ Disk Reserve: OK\n"
    fi
    printf "\n"

    # 4. Общая оценка
    printf "📊 System Status:\n"
    
    warnings=0
    notices=0
    
    if [ "$cpu_usage" != "N/A" ]; then
        if (( $(echo "$cpu_usage > 85" | bc -l 2>/dev/null || echo 0) )); then
            ((warnings++))
        elif (( $(echo "$cpu_usage > 70" | bc -l 2>/dev/null || echo 0) )); then
            ((notices++))
        fi
    fi
    
    if (( $(echo "$mem_percent > 85" | bc -l 2>/dev/null || echo 0) )); then
        ((warnings++))
    elif (( $(echo "$mem_percent > 70" | bc -l 2>/dev/null || echo 0) )); then
        ((notices++))
    fi
    
    if [ "$disk_usage" -gt 85 ]; then
        ((warnings++))
    elif [ "$disk_usage" -gt 70 ]; then
        ((notices++))
    fi
    
    if [ $warnings -gt 0 ]; then
        printf "⚠️ Warning: System under high load (%d critical issues)\n" "$warnings"
    elif [ $notices -gt 0 ]; then
        printf "⚡ Notice: Moderate system load (%d minor issues)\n" "$notices"
    else
        printf "✅ All systems operating normally"
    fi
}

# Основная функция
main() {
    echo "=== Запуск скрипта мониторинга ==="
    
    # Проверяем наличие необходимых команд
    for cmd in curl bc; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "❌ Команда '$cmd' не найдена. Установите пакет."
            exit 1
        fi
    done
    
    # Если передан параметр --test, выполняем только тесты
    if [ "$1" = "--test" ]; then
        test_telegram_connection
        test_chat_access
        echo "Тесты завершены успешно!"
        exit 0
    fi
    
    # Собираем данные о системе и сохраняем в временный файл
    temp_file=$(mktemp)
    collect_system_data > "$temp_file"
    
    # Выводим в консоль
    cat "$temp_file"
    
    # Читаем данные для отправки в Telegram
    system_data=$(cat "$temp_file")
    rm "$temp_file"
    
    echo ""
    echo "=== Отправка в Telegram ==="
    
    # Отправляем в Telegram
    if send_to_telegram "$system_data"; then
        echo "✅ Мониторинг завершен успешно!"
    else
        echo "❌ Ошибка при отправке данных в Telegram"
        exit 1
    fi
}

# Запуск основной функции
main "$@"