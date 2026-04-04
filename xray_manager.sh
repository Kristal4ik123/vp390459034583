#!/bin/bash
# Xray Universal Installer + Manager API
# Использование: 
#   ./xray_manager.sh install         - Установка Xray с нуля
#   ./xray_manager.sh <api_command>   - API команды для управления

set -e

DB_FILE=/usr/local/etc/xray/users_db.json
CONFIG_FILE=/usr/local/etc/xray/config.json
LOG_FILE=/usr/local/etc/xray/manager.log

# Логирование
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> $LOG_FILE
}

# Безопасная установка crontab (не должна ломать install)
safe_set_crontab() {
    local tmp_file=$1
    if crontab "$tmp_file" 2>/dev/null; then
        return 0
    fi
    log "WARN: failed to install crontab from $tmp_file"
    return 0
}

# ============================================
# ФУНКЦИЯ УСТАНОВКИ XRAY (ПОЛНАЯ ВЕРСИЯ)
# ============================================
api_install() {
    echo "Starting full Xray installation..."
    
    # Проверка домена
    if [[ -z "$domain" ]]; then
        echo '{"success": false, "error": "Domain not set. Use: export domain=your-domain.com"}'
        return 1
    fi
    
    # Обновление системы и установка пакетов
    apt update
    apt install curl wget nginx qrencode jq -y
    
    # Получаем сертификат (Let's Encrypt) / или используем уже установленный
    mkdir -p /usr/local/etc/xray/xray_cert
    if [[ -n "${XRAY_SKIP_CERT_ISSUE:-}" ]]; then
        echo "XRAY_SKIP_CERT_ISSUE is set. Skipping certificate issuance."
    elif [[ -s /usr/local/etc/xray/xray_cert/xray.crt && -s /usr/local/etc/xray/xray_cert/xray.key ]]; then
        echo "Existing certificate found in /usr/local/etc/xray/xray_cert. Skipping issuance to avoid rate limits."
    else
        wget -O - https://get.acme.sh | sh
        ~/.acme.sh/acme.sh --upgrade --auto-upgrade
        ~/.acme.sh/acme.sh --issue --server letsencrypt -d "$domain" -w /var/www/html --keylength ec-256
        ~/.acme.sh/acme.sh --installcert -d "$domain" --cert-file ~/.acme.sh/${domain}_ecc/${domain}.cer --key-file ~/.acme.sh/${domain}_ecc/${domain}.key --fullchain-file ~/.acme.sh/${domain}_ecc/fullchain.cer --ecc

        # Копируем сертификаты в папку для Xray
        ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
                   --fullchain-file /usr/local/etc/xray/xray_cert/xray.crt \
                   --key-file /usr/local/etc/xray/xray_cert/xray.key
        chmod +r /usr/local/etc/xray/xray_cert/xray.key
    fi

    if [[ ! -s /usr/local/etc/xray/xray_cert/xray.crt || ! -s /usr/local/etc/xray/xray_cert/xray.key ]]; then
        echo '{"success": false, "error": "Certificate files not found at /usr/local/etc/xray/xray_cert/xray.(crt|key). Provide them or unset XRAY_SKIP_CERT_ISSUE."}'
        return 1
    fi
    
    # Создаем скрипт обновления сертификата
    cat > /usr/local/etc/xray/xray_cert/xray-cert-renew <<'EOFRENEW'
#!/bin/bash
~/.acme.sh/acme.sh --install-cert -d "$1" --ecc --fullchain-file /usr/local/etc/xray/xray_cert/xray.crt --key-file /usr/local/etc/xray/xray_cert/xray.key
chmod +r /usr/local/etc/xray/xray_cert/xray.key
systemctl restart xray
EOFRENEW
    
    chmod +x /usr/local/etc/xray/xray_cert/xray-cert-renew
    
    # Добавление в crontab (фильтруем возможные сообщения/мусор от crontab -l)
    if ! crontab -l 2>/dev/null | grep -q "xray-cert-renew"; then
        cron_tmp=/tmp/cron_tmp
        { crontab -l 2>/dev/null || true; } \
            | sed 's/\r$//' \
            | grep -E '^\s*(#|$|@|[0-9*])' \
            > "$cron_tmp"
        echo "0 1 1 * * * /usr/local/etc/xray/xray_cert/xray-cert-renew $domain" >> "$cron_tmp"
        safe_set_crontab "$cron_tmp"
        rm -f "$cron_tmp"
    fi
    
    # Включаем BBR
    bbr=$(sysctl -a | grep net.ipv4.tcp_congestion_control)
    if [ "$bbr" = "net.ipv4.tcp_congestion_control = bbr" ]; then
        echo "bbr уже включен"
    else
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        echo "bbr включен"
    fi
    
    # Устанавливаем ядро Xray
    bash -c "$(curl -4 -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    [ -f /usr/local/etc/xray.keys ] && rm /usr/local/etc/xray.keys
    touch /usr/local/etc/xray.keys
    echo "shortsid $(openssl rand -hex 8)" >> /usr/local/etc/xray.keys
    echo "uuid $(xray uuid)" >> /usr/local/etc/xray.keys
    echo "domain $domain" >> /usr/local/etc/xray.keys
    
    export uuid=$(cat /usr/local/etc/xray.keys | awk -F' ' '/uuid/ {print $2}')
    
    # Создаем файл конфигурации Xray
    touch $CONFIG_FILE
    cat << EOFCONFIG > $CONFIG_FILE
{
    "dns": {
      "servers": [
        "https+local://1.1.1.1/dns-query",
        "localhost"
      ]
    },
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "domain": [
                    "geosite:category-ads-all"
                ],
                "outboundTag": "block"
            }
        ]
    },
    "inbounds": [
        {
            "port": 443,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "email": "main",
                        "id": "$uuid",
                        "flow": "xtls-rprx-vision",
                        "level": 0
                    }
                ],
                "decryption": "none",
                "fallbacks": [
                  {
                    "dest": 8080
                  }
                ]
            },
            "streamSettings": {
                "network": "tcp",
                "security": "tls",
                "tlsSettings": {
                  "fingerprint": "chrome",
                  "alpn": "http/1.1",
                  "certificates": [
                    {
                      "certificateFile": "/usr/local/etc/xray/xray_cert/xray.crt",
                      "keyFile": "/usr/local/etc/xray/xray_cert/xray.key"
                    }
                  ]
                }
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}
EOFCONFIG
    
    # Создаем базу данных пользователей
    touch $DB_FILE
    cat << 'EOFDB' > $DB_FILE
{
  "users": []
}
EOFDB
    
    # Создаем вспомогательные утилиты (userlist, mainuser, etc)
    # Эти утилиты НЕ нужны для бота, но полезны для ручного управления
    
    # userlist
    touch /usr/local/bin/userlist
    cat << 'EOFUTIL' > /usr/local/bin/userlist
#!/bin/bash
emails=($(jq -r '.inbounds[0].settings.clients[].email' /usr/local/etc/xray/config.json))
if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Список клиентов пуст"
    exit 1
fi
echo "Список клиентов"
for i in ${!emails[@]}; do
    echo "$((i+1)). ${emails[$i]}"
done
EOFUTIL
    chmod +x /usr/local/bin/userlist
    
    # mainuser
    touch /usr/local/bin/mainuser
    cat << 'EOFUTIL' > /usr/local/bin/mainuser
#!/bin/bash
protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
uuid=$(cat /usr/local/etc/xray.keys | awk -F' ' '/uuid/ {print $2}')
domain=$(cat /usr/local/etc/xray.keys | awk -F' ' '/domain/ {print $2}')
fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint' /usr/local/etc/xray/config.json)
link="$protocol://$uuid@$domain:$port?security=tls&alpn=http%2F1.1&fp=$fp&spx=&type=tcp&flow=xtls-rprx-vision&headerType=none&encryption=none#mainuser"
echo ""
echo "Ссылка для подключения"
echo "$link"
echo ""
echo "QR-код"
echo "${link}" | qrencode -t ansiutf8
EOFUTIL
    chmod +x /usr/local/bin/mainuser
    
    # Добавляем cron для автоматической очистки истекших ключей
    if ! crontab -l 2>/dev/null | grep -q "cleanup_expired"; then
        cron_tmp=/tmp/cron_tmp_2
        { crontab -l 2>/dev/null || true; } \
            | sed 's/\r$//' \
            | grep -E '^\s*(#|$|@|[0-9*])' \
            > "$cron_tmp"
        echo "0 * * * * /usr/local/bin/xray_manager.sh cleanup_expired" >> "$cron_tmp"
        safe_set_crontab "$cron_tmp"
        rm -f "$cron_tmp"
    fi
    
    # Настройка Nginx
    cat << EOFNGINX > /etc/nginx/sites-available/default
server {
        listen 80;
        server_name $domain;
        return 301 https\$http_host\$request_uri;
}

server {
        listen 127.0.0.1:8080;
        server_name $domain;
        root /var/www/html;
        index index.html;
        add_header Strict-Transport-Security max-age=63072000 always;
}
EOFNGINX
    
    mv /var/www/html/index.nginx-debian.html /var/www/html/index.html 2>/dev/null || true
    systemctl restart nginx
    
    # Запускаем Xray
    systemctl enable xray
    systemctl restart xray
    
    # Создаем файл с подсказками
    cat > /root/help <<'EOFHELP'

Команды для управления Xray:

    API команды (для бота):
    /usr/local/bin/xray_manager.sh create_user <email> <days> <devices>
    /usr/local/bin/xray_manager.sh delete_user <email>
    /usr/local/bin/xray_manager.sh get_link <email>
    /usr/local/bin/xray_manager.sh list_users
    /usr/local/bin/xray_manager.sh cleanup_expired
    
    Ручные утилиты:
    mainuser - ссылка основного пользователя
    userlist - список клиентов

Файл конфигурации: /usr/local/etc/xray/config.json
База данных пользователей: /usr/local/etc/xray/users_db.json

Перезагрузка:
    systemctl restart xray
    systemctl restart nginx

EOFHELP
    
    # Получаем ссылку админа
    protocol=$(jq -r '.inbounds[0].protocol' $CONFIG_FILE)
    port=$(jq -r '.inbounds[0].port' $CONFIG_FILE)
    fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint' $CONFIG_FILE)
    admin_link="$protocol://$uuid@$domain:$port?security=tls&alpn=http%2F1.1&fp=$fp&spx=&type=tcp&flow=xtls-rprx-vision&headerType=none&encryption=none#main"
    
    echo '{"success": true, "message": "Xray installed successfully", "admin_uuid": "'$uuid'", "admin_link": "'$admin_link'", "domain": "'$domain'"}'
    
    log "Xray installation completed for domain: $domain"
    
    echo ""
    echo "================================"
    echo "Установка завершена!"
    echo "================================"
    echo "Домен: $domain"
    echo "Главная ссылка:"
    echo "$admin_link"
    echo ""
    echo "Справка: cat ~/help"
    echo "================================"
}

# Получение UUID из конфига по email
get_uuid_by_email() {
    local email=$1
    jq -r --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email) | .id' $CONFIG_FILE
}

# Генерация VLESS ссылки
generate_link() {
    local email=$1
    local uuid=$(get_uuid_by_email "$email")
    
    if [[ -z "$uuid" ]]; then
        echo "ERROR: User not found"
        return 1
    fi
    
    local protocol=$(jq -r '.inbounds[0].protocol' $CONFIG_FILE)
    local port=$(jq -r '.inbounds[0].port' $CONFIG_FILE)
    local domain=$(cat /usr/local/etc/xray.keys | awk -F' ' '/domain/ {print $2}')
    local fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint' $CONFIG_FILE)
    
    echo "$protocol://$uuid@$domain:$port?security=tls&alpn=http%2F1.1&fp=$fp&spx=&type=tcp&flow=xtls-rprx-vision&headerType=none&encryption=none#$email"
}

# API: Создание пользователя
# Использование: ./xray_manager.sh create_user <email> <expire_days> <max_devices>
api_create_user() {
    local email=$1
    local expire_days=$2
    local max_devices=${3:-0}
    
    log "Creating user: $email (expire: $expire_days days, devices: $max_devices)"
    
    # Проверка существования пользователя
    if jq -e --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email)' $CONFIG_FILE > /dev/null 2>&1; then
        echo '{"success": false, "error": "User already exists"}'
        return 1
    fi
    
    # Генерация UUID
    local uuid=$(xray uuid)
    
    # Добавление в конфиг
    jq --arg email "$email" --arg uuid "$uuid" \
        '.inbounds[0].settings.clients += [{"email": $email, "id": $uuid, "flow": "xtls-rprx-vision"}]' \
        $CONFIG_FILE > /tmp/config.tmp && mv /tmp/config.tmp $CONFIG_FILE
    
    # Вычисление даты истечения
    if [[ "$expire_days" -gt 0 ]]; then
        expire_date=$(date -d "+$expire_days days" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -v+${expire_days}d +%Y-%m-%dT%H:%M:%S 2>/dev/null)
    else
        expire_date="null"
    fi
    
    # Добавление в БД пользователей
    jq --arg email "$email" \
       --arg uuid "$uuid" \
       --arg expire "$expire_date" \
       --argjson max_dev "$max_devices" \
       '.users += [{
           "email": $email,
           "uuid": $uuid,
           "expire_date": $expire,
           "max_devices": $max_dev,
           "created_at": (now | strftime("%Y-%m-%dT%H:%M:%S"))
       }]' $DB_FILE > /tmp/db.tmp && mv /tmp/db.tmp $DB_FILE
    
    # Перезагрузка Xray (reload без разрыва соединений)
    systemctl reload xray 2>/dev/null || systemctl restart xray
    
    # Генерация ссылки
    local link=$(generate_link "$email")
    
    # JSON ответ
    echo "{\"success\": true, \"email\": \"$email\", \"uuid\": \"$uuid\", \"link\": \"$link\", \"expire_date\": \"$expire_date\"}"
    log "User created successfully: $email"
}

# API: Удаление пользователя
# Использование: ./xray_manager.sh delete_user <email>
api_delete_user() {
    local email=$1
    
    log "Deleting user: $email"
    
    # Проверка существования
    if ! jq -e --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email)' $CONFIG_FILE > /dev/null 2>&1; then
        echo '{"success": false, "error": "User not found"}'
        return 1
    fi
    
    # Удаление из конфига
    jq --arg email "$email" \
        '(.inbounds[0].settings.clients) |= map(select(.email != $email))' \
        $CONFIG_FILE > /tmp/config.tmp && mv /tmp/config.tmp $CONFIG_FILE
    
    # Удаление из БД
    jq --arg email "$email" \
        '.users |= map(select(.email != $email))' \
        $DB_FILE > /tmp/db.tmp && mv /tmp/db.tmp $DB_FILE
    
    # Перезагрузка Xray (reload без разрыва соединений)
    systemctl reload xray 2>/dev/null || systemctl restart xray
    
    echo '{"success": true, "message": "User deleted"}'
    log "User deleted: $email"
}

# API: Получение ссылки пользователя
# Использование: ./xray_manager.sh get_link <email>
api_get_link() {
    local email=$1
    
    local link=$(generate_link "$email")
    
    if [[ $? -eq 0 ]]; then
        echo "{\"success\": true, \"email\": \"$email\", \"link\": \"$link\"}"
    else
        echo '{"success": false, "error": "User not found"}'
        return 1
    fi
}

# API: Обновление срока действия
# Использование: ./xray_manager.sh update_expiry <email> <new_expire_date>
api_update_expiry() {
    local email=$1
    local new_expire=$2  # Формат: 2026-04-10T12:00:00
    
    log "Updating expiry for $email to $new_expire"
    
    # Обновление в БД
    jq --arg email "$email" --arg expire "$new_expire" \
        '(.users[] | select(.email == $email) | .expire_date) = $expire' \
        $DB_FILE > /tmp/db.tmp && mv /tmp/db.tmp $DB_FILE
    
    echo '{"success": true, "message": "Expiry updated"}'
    log "Expiry updated for $email"
}

# API: Получение информации о пользователе
# Использование: ./xray_manager.sh get_user_info <email>
api_get_user_info() {
    local email=$1
    
    # Получение из БД
    local user_data=$(jq --arg email "$email" '.users[] | select(.email == $email)' $DB_FILE)
    
    if [[ -n "$user_data" ]]; then
        local uuid=$(echo "$user_data" | jq -r '.uuid')
        local expire_date=$(echo "$user_data" | jq -r '.expire_date')
        local max_devices=$(echo "$user_data" | jq -r '.max_devices')
        local created_at=$(echo "$user_data" | jq -r '.created_at')
        
        echo "{\"success\": true, \"email\": \"$email\", \"uuid\": \"$uuid\", \"expire_date\": \"$expire_date\", \"max_devices\": $max_devices, \"created_at\": \"$created_at\"}"
    else
        # Проверяем в конфиге (постоянный пользователь)
        local uuid=$(get_uuid_by_email "$email")
        if [[ -n "$uuid" ]]; then
            echo "{\"success\": true, \"email\": \"$email\", \"uuid\": \"$uuid\", \"expire_date\": null, \"max_devices\": 0, \"created_at\": null}"
        else
            echo '{"success": false, "error": "User not found"}'
            return 1
        fi
    fi
}

# API: Список всех пользователей
# Использование: ./xray_manager.sh list_users
api_list_users() {
    local emails=$(jq -r '.inbounds[0].settings.clients[].email' $CONFIG_FILE | tr '\n' ',' | sed 's/,$//')
    echo "{\"success\": true, \"users\": [\"$emails\"]}"
}

# API: Блокировка пользователя (удаление из конфига, но оставление в БД)
# Использование: ./xray_manager.sh block_user <email>
api_block_user() {
    local email=$1
    
    log "Blocking user: $email"
    
    # Удаление из конфига, но оставляем в БД с пометкой
    jq --arg email "$email" \
        '(.inbounds[0].settings.clients) |= map(select(.email != $email))' \
        $CONFIG_FILE > /tmp/config.tmp && mv /tmp/config.tmp $CONFIG_FILE
    
    # Пометка в БД
    jq --arg email "$email" \
        '(.users[] | select(.email == $email) | .blocked) = true' \
        $DB_FILE > /tmp/db.tmp && mv /tmp/db.tmp $DB_FILE
    
    systemctl reload xray 2>/dev/null || systemctl restart xray
    
    echo '{"success": true, "message": "User blocked"}'
    log "User blocked: $email"
}

# API: Разблокировка пользователя
# Использование: ./xray_manager.sh unblock_user <email>
api_unblock_user() {
    local email=$1
    
    log "Unblocking user: $email"
    
    # Получение UUID из БД
    local uuid=$(jq -r --arg email "$email" '.users[] | select(.email == $email) | .uuid' $DB_FILE)
    
    if [[ -z "$uuid" ]]; then
        echo '{"success": false, "error": "User not found in database"}'
        return 1
    fi
    
    # Добавление обратно в конфиг
    jq --arg email "$email" --arg uuid "$uuid" \
        '.inbounds[0].settings.clients += [{"email": $email, "id": $uuid, "flow": "xtls-rprx-vision"}]' \
        $CONFIG_FILE > /tmp/config.tmp && mv /tmp/config.tmp $CONFIG_FILE
    
    # Снятие пометки в БД
    jq --arg email "$email" \
        '(.users[] | select(.email == $email) | .blocked) = false' \
        $DB_FILE > /tmp/db.tmp && mv /tmp/db.tmp $DB_FILE
    
    systemctl reload xray 2>/dev/null || systemctl restart xray
    
    echo '{"success": true, "message": "User unblocked"}'
    log "User unblocked: $email"
}

# API: Очистка истекших пользователей
# Использование: ./xray_manager.sh cleanup_expired
api_cleanup_expired() {
    log "Starting cleanup of expired users"
    
    local current_time=$(date +%s)
    local deleted_count=0
    
    # Получение списка истекших пользователей
    local expired_users=$(jq -r --argjson now $current_time \
        '.users[] | select(.expire_date != null and .expire_date != "null") | 
        select((.expire_date | fromdateiso8601) < $now) | .email' $DB_FILE 2>/dev/null)
    
    if [[ -z "$expired_users" ]]; then
        echo '{"success": true, "deleted_count": 0, "message": "No expired users"}'
        return 0
    fi
    
    # Удаление каждого истекшего пользователя
    for email in $expired_users; do
        # Удаление из конфига
        jq --arg email "$email" \
            '(.inbounds[0].settings.clients) |= map(select(.email != $email))' \
            $CONFIG_FILE > /tmp/config.tmp && mv /tmp/config.tmp $CONFIG_FILE
        
        # Удаление из БД
        jq --arg email "$email" \
            '.users |= map(select(.email != $email))' \
            $DB_FILE > /tmp/db.tmp && mv /tmp/db.tmp $DB_FILE
        
        deleted_count=$((deleted_count + 1))
        log "Expired user deleted: $email"
    done
    
    # Перезагрузка Xray (reload без разрыва соединений)
    systemctl reload xray 2>/dev/null || systemctl restart xray
    
    echo "{\"success\": true, \"deleted_count\": $deleted_count, \"message\": \"Cleanup completed\"}"
    log "Cleanup completed: $deleted_count users deleted"
}

# API: Проверка статуса сервиса
# Использование: ./xray_manager.sh check_status
api_check_status() {
    if systemctl is-active --quiet xray; then
        echo '{"success": true, "status": "running"}'
    else
        echo '{"success": false, "status": "stopped"}'
    fi
}

# Главная функция роутинга
main() {
    local command=$1
    shift
    
    case $command in
        install)
            api_install
            ;;
        create_user)
            api_create_user "$@"
            ;;
        delete_user)
            api_delete_user "$@"
            ;;
        get_link)
            api_get_link "$@"
            ;;
        update_expiry)
            api_update_expiry "$@"
            ;;
        get_user_info)
            api_get_user_info "$@"
            ;;
        list_users)
            api_list_users
            ;;
        block_user)
            api_block_user "$@"
            ;;
        unblock_user)
            api_unblock_user "$@"
            ;;
        cleanup_expired)
            api_cleanup_expired
            ;;
        check_status)
            api_check_status
            ;;
        *)
            echo '{"success": false, "error": "Unknown command"}'
            echo "Usage: $0 <command> [args...]"
            echo ""
            echo "Installation:"
            echo "  install                                      - Install Xray from scratch (needs: export domain=your-domain.com)"
            echo ""
            echo "API Commands:"
            echo "  create_user <email> <expire_days> <max_devices>"
            echo "  delete_user <email>"
            echo "  get_link <email>"
            echo "  update_expiry <email> <new_expire_date>"
            echo "  get_user_info <email>"
            echo "  list_users"
            echo "  block_user <email>"
            echo "  unblock_user <email>"
            echo "  cleanup_expired"
            echo "  check_status"
            exit 1
            ;;
    esac
}

# Запуск
main "$@"
