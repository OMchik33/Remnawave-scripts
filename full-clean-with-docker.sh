#!/usr/bin/env bash
set -Eeuo pipefail

echo "===== БЕЗОПАСНАЯ ОЧИСТКА VPS (Docker установлен, данные очищаются) ====="

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Ошибка: скрипт нужно запускать от root."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "=== Проверка Docker ==="
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    echo "=== Остановка и удаление всех контейнеров ==="
    CONTAINERS="$(docker ps -aq || true)"
    if [[ -n "${CONTAINERS// }" ]]; then
      docker rm -f ${CONTAINERS}
    else
      echo "Контейнеров нет."
    fi

    echo "=== Полная очистка данных Docker ==="
    docker system prune -af --volumes
  else
    echo "Docker установлен, но daemon недоступен. Блок Docker пропущен."
  fi
else
  echo "Docker не найден. Блок Docker пропущен."
fi

echo "=== Проверка Docker после очистки ==="
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker ps -a || true
  docker volume ls || true
  docker images || true
fi

echo "=== Удаление рабочих каталогов Remna ==="
for dir in /opt/remnawave /opt/remnanode; do
  if [[ -e "$dir" ]]; then
    rm -rf --one-file-system "$dir"
    echo "Удалено: $dir"
  else
    echo "Не найдено: $dir"
  fi
done

echo "=== Очистка архивных journal-логов ==="
if command -v journalctl >/dev/null 2>&1; then
  journalctl --rotate || true
  journalctl --vacuum-time=7d || true
fi

echo "=== Очистка архивных файлов в /var/log ==="
find /var/log -xdev -type f \
  \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.[0-9].gz' -o -name '*.old' \) \
  -delete 2>/dev/null || true

echo "=== Очистка временных файлов ==="
find /tmp -mindepth 1 -xdev -exec rm -rf -- {} + 2>/dev/null || true
find /var/tmp -mindepth 1 -xdev -exec rm -rf -- {} + 2>/dev/null || true

echo "=== Очистка apt ==="
apt-get clean
apt-get autoremove --purge -y

echo "=== Итоговое свободное место ==="
df -h /

echo "===== ГОТОВО. Docker остаётся установленным, данные Docker и Remna-окружение очищены ====="
