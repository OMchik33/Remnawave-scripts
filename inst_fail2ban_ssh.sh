#!/bin/bash
set -e

echo "=== Установка Fail2Ban ==="
apt update -y
apt install -y fail2ban

echo "=== Определяем источник логов ==="
if [ -f /var/log/auth.log ]; then
    LOGPATH="/var/log/auth.log"
    echo "Используем $LOGPATH"
    BACKEND="auto"
else
    echo "Файл /var/log/auth.log не найден — используем journald"
    LOGPATH=""
    BACKEND="systemd"
fi

echo "=== Создание локальной конфигурации ==="
mkdir -p /etc/fail2ban/jail.d

cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port    = ssh
backend = $BACKEND
maxretry = 5
findtime = 10m
bantime  = 12h
EOF

if [ -n "$LOGPATH" ]; then
    echo "logpath = $LOGPATH" >> /etc/fail2ban/jail.d/sshd.local
fi

echo "=== Проверка конфигурации ==="
fail2ban-client -d | grep '\[sshd\]' || echo "(ok) jail sshd parsed"

echo "=== Запуск и автозапуск Fail2Ban ==="
systemctl enable fail2ban
systemctl restart fail2ban
systemctl status fail2ban --no-pager

echo
echo "=== Проверка работы ==="
echo "1. Проверить активные тюрьмы:   fail2ban-client status"
echo "2. Проверить блокировки SSH:    fail2ban-client status sshd"
echo "3. Проверить логи:              journalctl -u fail2ban | tail -n 30"
echo
echo "Готово."
