#!/bin/bash
# Перед запуском скрипта задайте переменную с именем вашего домена
# Замените vstavit-domen на ваш домен
# export domain=vstavit-domen
apt update
apt install curl wget nginx qrencode jq -y

# Получаем сертификат
wget -O - https://get.acme.sh | sh
~/.acme.sh/acme.sh --upgrade --auto-upgrade
~/.acme.sh/acme.sh --issue --server letsencrypt -d $domain -w /var/www/html --keylength ec-256 --force
~/.acme.sh/acme.sh --installcert -d $domain --cert-file ~/.acme.sh/${domain}_ecc/${domain}.cer --key-file ~/.acme.sh/${domain}_ecc/${domain}.key --fullchain-file ~/.acme.sh/${domain}_ecc/fullchain.cer --ecc

# Копируем сертификаты в другую папку для Xray
mkdir -p /usr/local/etc/xray/xray_cert
~/.acme.sh/acme.sh --install-cert -d $domain --ecc \
           --fullchain-file /usr/local/etc/xray/xray_cert/xray.crt \
           --key-file /usr/local/etc/xray/xray_cert/xray.key
chmod +r /usr/local/etc/xray/xray_cert/xray.key

# Создаем файл установки в папку обновленного сертификата
# Проверить добавление выполнения этого скрипта в cron
# 0 1 1 * * * bash /usr/local/etc/xray/xray_cert/xray-cert-renew

touch /usr/local/etc/xray/xray_cert/xray-cert-renew
cat << EOF > /usr/local/etc/xray/xray_cert/xray-cert-renew
#!/bin/bash
$PWD/.acme.sh --install-cert -d $domain --ecc --fullchain-file /usr/local/etc/xray/xray_cert/xray.crt --key-file /usr/local/etc/xray/xray_cert/xray.key
chmod +r /usr/local/etc/xray/xray_cert/xray.key
sudo systemctl restart xray
EOF

chmod +x /usr/local/etc/xray/xray_cert/xray-cert-renew

crontab -l | grep -q xray-cert-renew || (crontab -l; echo "0 1 1 * * * bash /usr/local/etc/xray/xray_cert/xray-cert-renew") | crontab -



# Включаем bbr
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
touch /usr/local/etc/xray/config.json
cat << EOF > /usr/local/etc/xray/config.json
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
EOF

# Исполняемый файл для списка клиентов
touch /usr/local/bin/userlist
cat << 'EOF' > /usr/local/bin/userlist
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
EOF
chmod +x /usr/local/bin/userlist

# исполняемый файл для ссылки основного пользователя
touch /usr/local/bin/mainuser
cat << 'EOF' > /usr/local/bin/mainuser
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
EOF
chmod +x /usr/local/bin/mainuser

# Исполняемый файл для создания новых клиентов
# Добавить сюда level 0,
touch /usr/local/bin/newuser
cat << 'EOF' > /usr/local/bin/newuser
#!/bin/bash
read -p "Введите имя пользователя (email): " email

    if [[ -z "$email" || "$email" == *" "* ]]; then
    echo "Имя пользователя не может быть пустым или содержать пробелы. Попробуйте снова."
    exit 1
    fi
user_json=$(jq --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email)' /usr/local/etc/xray/config.json)

if [[ -z "$user_json" ]]; then
uuid=$(xray uuid)
jq --arg email "$email" --arg uuid "$uuid" '.inbounds[0].settings.clients += [{"email": $email, "id": $uuid, "flow": "xtls-rprx-vision"}]' /usr/local/etc/xray/config.json > tmp.json && mv tmp.json /usr/local/etc/xray/config.json
systemctl restart xray
index=$(jq --arg email "$email" '.inbounds[0].settings.clients | to_entries[] | select(.value.email == $email) | .key' < /usr/local/etc/xray/config.json)
protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json)
uuid=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].id' /usr/local/etc/xray/config.json)
username=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].email' /usr/local/etc/xray/config.json)
domain=$(cat /usr/local/etc/xray.keys | awk -F' ' '/domain/ {print $2}')
fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint' /usr/local/etc/xray/config.json)
link="$protocol://$uuid@$domain:$port?security=tls&alpn=http%2F1.1&fp=$fp&spx=&type=tcp&flow=xtls-rprx-vision&headerType=none&encryption=none#$username"
echo ""
echo "Ссылка для подключения"
echo "$link"
echo ""
echo "QR-код"
echo "${link}" | qrencode -t ansiutf8
else
echo "Пользователь с таким именем уже существует. Попробуйте снова." 
fi
EOF
chmod +x /usr/local/bin/newuser

# Исполняемый файл для удаления клиентов
touch /usr/local/bin/rmuser
cat << 'EOF' > /usr/local/bin/rmuser
#!/bin/bash
emails=($(jq -r '.inbounds[0].settings.clients[].email' /usr/local/etc/xray/config.json))

if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Нет клиентов для удаления."
    exit 1
fi

echo "Список клиентов"
for i in ${!emails[@]}; do
    echo "$((i+1)). ${emails[$i]}"
done

read -p "Введите номер клиента для удаления: " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
    echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
    exit 1
fi

selected_email=${emails[$((choice - 1))]}

jq --arg email "$selected_email" \
   '(.inbounds[0].settings.clients) |= map(select(.email != $email))' \
   /usr/local/etc/xray/config.json > tmp && mv tmp /usr/local/etc/xray/config.json

systemctl restart xray

echo "Клиент $selected_email удалён."
EOF
chmod +x /usr/local/bin/rmuser

# Исполняемый файл для вывода списка пользователей и создания ссылкок
touch /usr/local/bin/sharelink
cat << 'EOF' > /usr/local/bin/sharelink
#!/bin/bash
emails=($(jq -r '.inbounds[0].settings.clients[].email' /usr/local/etc/xray/config.json))

for i in ${!emails[@]}; do
   echo "$((i + 1)). ${emails[$i]}"
done

read -p "Выберите клиента: " client

if ! [[ "$client" =~ ^[0-9]+$ ]] || (( client < 1 || client > ${#emails[@]} )); then
    echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
    exit 1
fi

selected_email=${emails[$((client - 1))]}


index=$(jq --arg email "$selected_email" '.inbounds[0].settings.clients | to_entries[] | select(.value.email == $email) | .key' < /usr/local/etc/xray/config.json)
protocol=$(jq -r '.inbounds[0].protocol' /usr/local/etc/xray/config.json)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json) 
uuid=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].id' /usr/local/etc/xray/config.json)
username=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].email' /usr/local/etc/xray/config.json)
sni=$(cat /usr/local/etc/xray.keys | awk -F' ' '/domain/ {print $2}')
domain=$(cat /usr/local/etc/xray.keys | awk -F' ' '/domain/ {print $2}')
fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint' /usr/local/etc/xray/config.json)
link="$protocol://$uuid@$domain:$port?security=tls&alpn=http%2F1.1&fp=$fp&spx=&type=tcp&flow=xtls-rprx-vision&headerType=none&encryption=none#$username"
echo ""
echo "Ссылка для подключения"
echo "$link"
echo ""
echo "QR-код"
echo "${link}" | qrencode -t ansiutf8
EOF
chmod +x /usr/local/bin/sharelink

# Исполняемый файл для создания временного пользователя с ограничением устройств
touch /usr/local/bin/newtempuser
cat << 'EOF' > /usr/local/bin/newtempuser
#!/bin/bash

DB_FILE=/usr/local/etc/xray/users_db.json
CONFIG_FILE=/usr/local/etc/xray/config.json

read -p "Введите имя пользователя (email): " email

if [[ -z "$email" || "$email" == *" "* ]]; then
    echo "Имя пользователя не может быть пустым или содержать пробелы."
    exit 1
fi

user_json=$(jq --arg email "$email" '.inbounds[0].settings.clients[] | select(.email == $email)' $CONFIG_FILE)

if [[ -n "$user_json" ]]; then
    echo "Пользователь с таким именем уже существует."
    exit 1
fi

read -p "Введите срок действия ключа в днях (оставьте пустым для постоянного): " days
read -p "Ограничить одним устройством (y/n) [n]: " limit_device

if [[ -z "$limit_device" ]]; then
    limit_device=n
fi

max_devices=0
if [[ "$limit_device" == "y" || "$limit_device" == "Y" ]]; then
    max_devices=1
fi

uuid=$(xray uuid)
jq --arg email "$email" --arg uuid "$uuid" '.inbounds[0].settings.clients += [{"email": $email, "id": $uuid, "flow": "xtls-rprx-vision"}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE

if [[ -n "$days" ]]; then
    expire_date=$(date -d "+$days days" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -v+${days}d +%Y-%m-%dT%H:%M:%S 2>/dev/null)
else
    expire_date="null"
fi

jq --arg email "$email" --arg uuid "$uuid" --arg expire "$expire_date" --argjson max_dev $max_devices '.users += [{"email": $email, "uuid": $uuid, "expire_date": $expire, "max_devices": $max_dev, "created_at": (now | strftime("%Y-%m-%dT%H:%M:%S"))}]' $DB_FILE > tmp_db.json && mv tmp_db.json $DB_FILE

systemctl restart xray

index=$(jq --arg email "$email" '.inbounds[0].settings.clients | to_entries[] | select(.value.email == $email) | .key' < $CONFIG_FILE)
protocol=$(jq -r '.inbounds[0].protocol' $CONFIG_FILE)
port=$(jq -r '.inbounds[0].port' $CONFIG_FILE)
uuid=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].id' $CONFIG_FILE)
username=$(jq --argjson index "$index" -r '.inbounds[0].settings.clients[$index].email' $CONFIG_FILE)
domain=$(cat /usr/local/etc/xray.keys | awk -F' ' '/domain/ {print $2}')
fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint' $CONFIG_FILE)
link="$protocol://$uuid@$domain:$port?security=tls&alpn=http%2F1.1&fp=$fp&spx=&type=tcp&flow=xtls-rprx-vision&headerType=none&encryption=none#$username"

echo ""
echo "================================"
echo "Временный пользователь создан"
echo "================================"
echo "Email: $username"
if [[ "$expire_date" != "null" ]]; then
    echo "Срок действия до: $expire_date"
else
    echo "Срок действия: Постоянный"
fi
if [[ $max_devices -eq 1 ]]; then
    echo "Ограничение: Одно устройство"
else
    echo "Ограничение: Без ограничений"
fi
echo ""
echo "Ссылка для подключения"
echo "$link"
echo ""
echo "QR-код"
echo "${link}" | qrencode -t ansiutf8
EOF
chmod +x /usr/local/bin/newtempuser

# Исполняемый файл для очистки истекших временных ключей
touch /usr/local/bin/cleanup-expired
cat << 'EOF' > /usr/local/bin/cleanup-expired
#!/bin/bash

DB_FILE=/usr/local/etc/xray/users_db.json
CONFIG_FILE=/usr/local/etc/xray/config.json
LOG_FILE=/usr/local/etc/xray/expired_cleanup.log

current_time=$(date +%s)

echo "$(date) - Starting cleanup of expired users" >> $LOG_FILE

expired_users=$(jq -r --argjson now $current_time '.users[] | select(.expire_date != null and .expire_date != "null") | select((.expire_date | fromdateiso8601) < $now) | .email' $DB_FILE 2>/dev/null)

if [[ -z "$expired_users" ]]; then
    echo "$(date) - No expired users found" >> $LOG_FILE
    exit 0
fi

for email in $expired_users; do
    echo "$(date) - Removing expired user: $email" >> $LOG_FILE
    
    jq --arg email "$email" '(.inbounds[0].settings.clients) |= map(select(.email != $email))' $CONFIG_FILE > tmp_config.json && mv tmp_config.json $CONFIG_FILE
    
    jq --arg email "$email" '.users |= map(select(.email != $email))' $DB_FILE > tmp_db.json && mv tmp_db.json $DB_FILE
    
    echo "$(date) - User $email removed successfully" >> $LOG_FILE
done

systemctl restart xray
echo "$(date) - Xray service restarted" >> $LOG_FILE
echo "$(date) - Cleanup completed" >> $LOG_FILE
EOF
chmod +x /usr/local/bin/cleanup-expired

# Исполняемый файл для мониторинга активных подключений
touch /usr/local/bin/monitor-connections
cat << 'EOF' > /usr/local/bin/monitor-connections
#!/bin/bash

DB_FILE=/usr/local/etc/xray/users_db.json
LOG_FILE=/usr/local/etc/xray/connections.log

while true; do
    current_time=$(date +%s)
    
    users_with_limit=$(jq -r '.users[] | select(.max_devices == 1) | .email' $DB_FILE 2>/dev/null)
    
    if [[ -z "$users_with_limit" ]]; then
        sleep 30
        continue
    fi
    
    for email in $users_with_limit; do
        uuid=$(jq -r --arg email "$email" '.users[] | select(.email == $email) | .uuid' $DB_FILE)
        
        if [[ -z "$uuid" ]]; then
            continue
        fi
        
        connection_count=$(xray api statsquery --server=127.0.0.1:443 pattern "user>>>$uuid>>>downlink" | grep -c "user" 2>/dev/null || echo 0)
        
        if [[ $connection_count -gt 1 ]]; then
            echo "$(date) - User $email ($uuid) has $connection_count active connections. Limit: 1." >> $LOG_FILE
        fi
    done
    
    sleep 30
done
EOF
chmod +x /usr/local/bin/monitor-connections

# Исполняемый файл для просмотра информации о пользователе
touch /usr/local/bin/userinfo
cat << 'EOF' > /usr/local/bin/userinfo
#!/bin/bash

DB_FILE=/usr/local/etc/xray/users_db.json
CONFIG_FILE=/usr/local/etc/xray/config.json

emails=($(jq -r '.inbounds[0].settings.clients[].email' $CONFIG_FILE))

if [[ ${#emails[@]} -eq 0 ]]; then
    echo "Нет пользователей."
    exit 1
fi

for i in ${!emails[@]}; do
   echo "$((i + 1)). ${emails[$i]}"
done

read -p "Выберите пользователя: " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
    echo "Ошибка: номер должен быть от 1 до ${#emails[@]}"
    exit 1
fi

selected_email=${emails[$((choice - 1))]}

user_data=$(jq --arg email "$selected_email" '.users[] | select(.email == $email)' $DB_FILE)

echo ""
echo "================================"
echo "Информация о пользователе"
echo "================================"
echo "Email: $selected_email"

if [[ -n "$user_data" ]]; then
    expire_date=$(echo "$user_data" | jq -r '.expire_date')
    max_devices=$(echo "$user_data" | jq -r '.max_devices')
    created_at=$(echo "$user_data" | jq -r '.created_at')
    
    echo "Создан: $created_at"
    
    if [[ "$expire_date" != "null" ]]; then
        echo "Срок действия до: $expire_date"
    else
        echo "Срок действия: Постоянный"
    fi
    
    if [[ $max_devices -eq 1 ]]; then
        echo "Ограничение устройств: Одно устройство"
    else
        echo "Ограничение устройств: Без ограничений"
    fi
else
    echo "Тип: Постоянный пользователь (без ограничений)"
fi
EOF
chmod +x /usr/local/bin/userinfo

# Создаем базу данных пользователей для временных ключей и ограничения устройств
touch /usr/local/etc/xray/users_db.json
cat << 'EOF' > /usr/local/etc/xray/users_db.json
{
  "users": []
}
EOF

# Добавляем cron задачи для автоматической очистки истекших ключей
# Запускается каждый час
crontab -l | grep -q cleanup-expired || (crontab -l; echo "0 * * * * /usr/local/bin/cleanup-expired") | crontab -

systemctl restart xray

echo "Xray-core успешно установлен"
mainuser

# Создаем файл с подсказками
touch $HOME/help
cat << 'EOF' > $HOME/help

Команды для управления пользователями Xray

    mainuser - выводит ссылку для подключения основного пользователя
    newuser - создает нового пользователя (постоянный)
    newtempuser - создает временного пользователя с ограничением устройств
    rmuser - удаление пользователей
    sharelink - выводит список пользователей и позволяет создать для них ссылки для подключения
    userlist - выводит список клиентов
    userinfo - показывает детальную информацию о пользователе
    cleanup-expired - вручную запустить очистку истекших ключей



Файл конфигурации находится по адресу

    /usr/local/etc/xray/config.json

Команда для перезагрузки ядра Xray

    systemctl restart xray

Команда для перезагрузки Nginx

    systemctl restart nginx

Адрес папки с сайтом
    /var/www/html

EOF


# Заменяем стандартный файл конфигурации nginx
cat << EOF > /etc/nginx/sites-available/default
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
EOF
mv /var/www/html/index.nginx-debian.html /var/www/html/index.html
systemctl restart nginx
