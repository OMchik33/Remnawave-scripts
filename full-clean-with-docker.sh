#!/bin/bash
set -e

echo "===== ПОЛНАЯ ОЧИСТКА VPS (Docker сохранён) ====="

echo "=== Остановка контейнеров ==="
docker rm -f $(docker ps -aq) 2>/dev/null || true

echo "=== Очистка Docker: volumes / images / networks / build cache ==="
docker volume rm $(docker volume ls -q) 2>/dev/null || true
docker network prune -f || true
docker image prune -af || true
docker builder prune -af || true
docker system prune -af --volumes || true

echo "=== Проверка Docker (должен быть пуст) ==="
docker ps -a || true
docker volume ls || true
docker images || true

echo "=== Удаление рабочих каталогов Remna ==="
rm -rf /opt/remnawave
rm -rf /opt/remnanode

echo "=== Удаление docker-compose / Dockerfile / .env ==="
find /opt -type f \( \
  -name "docker-compose.yml" -o \
  -name "docker-compose.yaml" -o \
  -name "Dockerfile" -o \
  -name ".env" \
\) -delete

echo "=== Очистка systemd логов ==="
journalctl --rotate || true
journalctl --vacuum-time=1s || true

echo "=== Очистка /var/log ==="
find /var/log -type f -exec truncate -s 0 {} \;
rm -rf /var/log/*.[0-9] /var/log/*.gz /var/log/*-????????

echo "=== Очистка временных файлов ==="
rm -rf /tmp/*
rm -rf /var/tmp/*

echo "=== Очистка apt ==="
apt-get clean
apt-get autoclean -y
apt-get autoremove --purge -y

echo "=== Удаление старых ядер ==="
CURRENT_KERNEL=$(uname -r | sed 's/-generic//')
dpkg --list | awk '/linux-image-[0-9]/{print $2}' | grep -v "$CURRENT_KERNEL" | xargs -r apt-get purge -y

echo "=== Очистка кешей памяти ==="
sync
echo 3 > /proc/sys/vm/drop_caches

echo "=== Итоговое свободное место ==="
df -h /

echo "===== ГОТОВО. Docker сохранён, Remna-окружение очищено ====="
