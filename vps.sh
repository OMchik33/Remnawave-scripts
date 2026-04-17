#!/usr/bin/env bash
# Light VPS — первичная настройка Ubuntu/Debian VPS
set -uo pipefail

# Принудительно устанавливаем английскую локаль для корректного парсинга вывода команд (apt, grep, awk)
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

APP_NAME="Light VPS"
APP_SLUG="lightvps"
STATE_DIR="/var/lib/${APP_SLUG}"
LOG_DIR="/var/log/${APP_SLUG}"
MANAGED_SSH_FILE="/etc/ssh/sshd_config.d/00-${APP_SLUG}.conf"
MANAGED_SSH_SOCKET_DIR="/etc/systemd/system/ssh.socket.d"
MANAGED_SSH_SOCKET_FILE="${MANAGED_SSH_SOCKET_DIR}/00-${APP_SLUG}.conf"
MANAGED_DNS_FILE="/etc/systemd/resolved.conf.d/90-${APP_SLUG}.conf"
MANAGED_BBR_FILE="/etc/sysctl.d/90-${APP_SLUG}-bbr.conf"
MANAGED_IPV6_FILE="/etc/sysctl.d/90-${APP_SLUG}-ipv6.conf"
MANAGED_MODULES_FILE="/etc/modules-load.d/${APP_SLUG}.conf"
MANAGED_UNATTENDED_FILE="/etc/apt/apt.conf.d/51-${APP_SLUG}-unattended"
MANAGED_AUTO_FILE="/etc/apt/apt.conf.d/52-${APP_SLUG}-auto-upgrades"

RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/${RUN_ID}.log"
DRY_RUN=0
SELF_TEST=0
NON_INTERACTIVE=0

RECOMMENDED_PACKAGES=(mc htop curl wget unzip nano jq git mtr-tiny ca-certificates gnupg bash-completion ncdu)

OS_ID=""
OS_VERSION_ID=""
OS_VERSION_CODENAME=""
OS_PRETTY_NAME=""

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[36m%s\033[0m\n' "$*"; }

clear_screen() {
  if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then
    clear
  fi
}

log() {
  local level="$1"; shift
  install -d -m 0750 "$LOG_DIR" >/dev/null 2>&1 || true
  printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$level" "$*" >>"$LOG_FILE" 2>/dev/null || true
  case "$level" in
    OK)   green  "[$level] $*" ;;
    INFO) blue   "[$level] $*" ;;
    WARN) yellow "[$level] $*" ;;
    ERR)  red    "[$level] $*" ;;
    *)    echo   "[$level] $*" ;;
  esac
}

on_error() {
  local exit_code=$? line="${1:-?}"
  log ERR "Необработанная ошибка в строке ${line} (код ${exit_code})."
}
trap 'on_error $LINENO' ERR

pause() {
  (( NON_INTERACTIVE )) && return 0
  echo
  read -r -p "Нажми Enter для продолжения..." _ </dev/tty || true
}

ensure_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    red "Скрипт нужно запускать от root."
    exit 1
  fi
}

ensure_tty() {
  if [[ ! -t 0 ]]; then
    if [[ -r /dev/tty ]]; then
      exec </dev/tty
    else
      NON_INTERACTIVE=1
      log WARN "stdin не привязан к терминалу — интерактив недоступен."
    fi
  fi
}

load_os_release() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
    OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
    OS_PRETTY_NAME="${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-}}"
  fi
}

os_id()       { echo "$OS_ID"; }
os_version()  { echo "$OS_VERSION_ID"; }
os_codename() {
  if [[ -n "$OS_VERSION_CODENAME" ]]; then
    echo "$OS_VERSION_CODENAME"
  else
    command -v lsb_release >/dev/null 2>&1 && lsb_release -cs 2>/dev/null || echo ""
  fi
}

prepare_runtime() {
  install -d -m 0750 "$STATE_DIR"
  install -d -m 0750 "$LOG_DIR"
  : >"$LOG_FILE"
  chmod 0640 "$LOG_FILE" || true
  log OK "Запуск ${APP_NAME}. Лог: ${LOG_FILE}"
}

run_cmd() {
  if (( DRY_RUN )); then
    log INFO "[dry-run] $*"
    return 0
  fi
  log INFO "Выполняю: $*"
  "$@" >>"$LOG_FILE" 2>&1
}

append_unique_line() {
  local file="$1" line="$2"
  if (( DRY_RUN )); then
    log INFO "[dry-run] append line to ${file}: ${line}"
    return 0
  fi
  install -d -m 0750 "$(dirname "$file")"
  touch "$file"
  grep -Fxq "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >>"$file"
}

confirm() {
  (( NON_INTERACTIVE )) && return 0
  local prompt="$1" ans
  while true; do
    read -r -p "$prompt [y/n]: " ans </dev/tty
    case "${ans,,}" in
      y|yes|д|да) return 0 ;;
      n|no|н|нет) return 1 ;;
      *) echo "Введите y или n." ;;
    esac
  done
}

prompt_nonempty() {
  local prompt="$1" value
  while true; do
    read -r -p "$prompt" value </dev/tty
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    echo "Поле не может быть пустым." >&2
  done
}

prompt_optional() {
  local prompt="$1" value
  read -r -p "$prompt" value </dev/tty
  printf '%s' "$value"
}

prompt_default() {
  local prompt="$1" def="$2" value
  read -r -p "$prompt [$def]: " value </dev/tty
  printf '%s' "${value:-$def}"
}

is_valid_pubkey() {
  local key="$1"
  [[ "$key" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)\ [A-Za-z0-9+/=]+(\ .*)?$ ]]
}

validate_pubkey_strict() {
  local key="$1"
  if command -v ssh-keygen >/dev/null 2>&1; then
    ssh-keygen -l -f <(printf '%s\n' "$key") >/dev/null 2>&1 && return 0
  fi
  is_valid_pubkey "$key"
}

track_created_user() {
  append_unique_line "$STATE_DIR/created_users.list" "$1"
}

track_key_for_user() {
  local username="$1" pubkey="$2"
  append_unique_line "$STATE_DIR/keys/${username}.list" "$pubkey"
}

list_regular_users() {
  local user uid home shell
  while IFS=: read -r user _ uid _ _ home shell; do
    if [[ "$user" == "root" ]]; then
      printf '%s:%s:%s:%s\n' "$user" "0" "/root" "$(getent passwd root | cut -d: -f7)"
      continue
    fi
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    (( uid >= 1000 )) || continue
    [[ "$shell" == */nologin || "$shell" == */false ]] && continue
    printf '%s:%s:%s:%s\n' "$user" "$uid" "$home" "$shell"
  done </etc/passwd
}

print_regular_users() {
  local found=0 user uid home shell sudo_state
  while IFS=: read -r user uid home shell; do
    found=1
    sudo_state="нет"
    if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx 'sudo'; then
      sudo_state="да"
    fi
    printf '%-16s | UID: %-5s | HOME: %-22s | SHELL: %-16s | sudo: %s\n' \
      "$user" "$uid" "$home" "$shell" "$sudo_state"
  done < <(list_regular_users)
  (( found )) || echo "Обычные пользователи не найдены."
}

show_users_brief() {
  echo "Пользователи сервера:"
  print_regular_users
  echo
}

get_effective_ssh() {
  sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1)==tolower(k){print $2; exit}'
}

ssh_control_unit() {
  local list
  list="$(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}')"
  if grep -qx 'ssh.socket' <<<"$list" && systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    echo "ssh.socket"; return
  fi
  if grep -qx 'ssh.service' <<<"$list"; then
    echo "ssh.service"; return
  fi
  if grep -qx 'sshd.service' <<<"$list"; then
    echo "sshd.service"; return
  fi
  echo ""
}

ssh_is_socket_activated() {
  systemctl is-active ssh.socket >/dev/null 2>&1
}

get_display_ssh_port() {
  local ports="" value=""
  if ssh_is_socket_activated; then
    if [[ -f "$MANAGED_SSH_SOCKET_FILE" ]]; then
      ports="$({
        awk -F= '/^[[:space:]]*ListenStream=/{val=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", val); if (val != "") print val}' "$MANAGED_SSH_SOCKET_FILE"
      } | sed -E 's/^\[::\]://; s/^0\.0\.0\.0://; s/^.*://;' | awk 'NF' | sort -u | paste -sd"," -)"
      if [[ -n "$ports" ]]; then
        printf '%s\n' "$ports"
        return 0
      fi
    fi
    ports="$(systemctl cat ssh.socket 2>/dev/null | awk -F= '/^[[:space:]]*ListenStream=/{val=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", val); if (val != "") print val}' | sed -E 's/^\[::\]://; s/^0\.0\.0\.0://; s/^.*://;' | awk 'NF' | sort -u | paste -sd"," -)"
    if [[ -n "$ports" ]]; then
      printf '%s\n' "$ports"
      return 0
    fi
  fi
  value="$(get_effective_ssh port 2>/dev/null || true)"
  [[ -n "$value" ]] || value="неизвестно"
  printf '%s\n' "$value"
}

get_ssh_firewall_port() {
  local port=""

  if ssh_is_socket_activated; then
    if [[ -f "$MANAGED_SSH_SOCKET_FILE" ]]; then
      port="$({
        awk -F= '/^[[:space:]]*ListenStream=/{val=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", val); if (val != "") print val}' "$MANAGED_SSH_SOCKET_FILE"
      } | sed -E 's/^\[::\]://; s/^0\.0\.0\.0://; s/^.*://;' | awk '/^[0-9]+$/ { print; exit }')"
    fi
    if [[ -z "$port" ]]; then
      port="$(systemctl cat ssh.socket 2>/dev/null | awk -F= '/^[[:space:]]*ListenStream=/{val=$2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", val); if (val != "") print val}' | sed -E 's/^\[::\]://; s/^0\.0\.0\.0://; s/^.*://;' | awk '/^[0-9]+$/ { print; exit }')"
    fi
  fi

  if [[ -z "$port" ]]; then
    port="$(get_effective_ssh port 2>/dev/null | awk '/^[0-9]+$/ { print; exit }')"
  fi

  [[ -n "$port" ]] || port="22"
  printf '%s\n' "$port"
}

apply_ssh_port_via_socket() {
  local port="$1"
  if (( DRY_RUN )); then
    log INFO "[dry-run] write $MANAGED_SSH_SOCKET_FILE with port ${port}"
    return 0
  fi
  install -d -m 0755 "$MANAGED_SSH_SOCKET_DIR"
  cat >"$MANAGED_SSH_SOCKET_FILE" <<EOF1
# Управляется ${APP_NAME}
[Socket]
ListenStream=
ListenStream=0.0.0.0:${port}
ListenStream=[::]:${port}
EOF1
  chmod 0644 "$MANAGED_SSH_SOCKET_FILE"
}

restart_ssh() {
  local unit
  unit="$(ssh_control_unit)"
  [[ -n "$unit" ]] || { log ERR "Не удалось определить unit SSH."; return 1; }
  run_cmd systemctl daemon-reload || return 1
  if ssh_is_socket_activated; then
    run_cmd systemctl restart ssh.socket || return 1
    run_cmd systemctl restart ssh.service || true
  else
    run_cmd systemctl restart "$unit" || return 1
  fi
  if (( DRY_RUN )); then
    log OK "[dry-run] SSH был бы перезапущен."
    return 0
  fi
  if systemctl is-active --quiet ssh.service || systemctl is-active --quiet sshd.service || systemctl is-active --quiet ssh.socket; then
    log OK "SSH успешно перезапущен."
    return 0
  fi
  log ERR "SSH не активен после перезапуска."
  return 1
}

has_any_admin_key() {
  if [[ -s /root/.ssh/authorized_keys ]]; then
    return 0
  fi
  local user home shell
  while IFS=: read -r user _ _ _ _ home shell; do
    [[ "$user" == root ]] && continue
    [[ "$shell" == */nologin || "$shell" == */false ]] && continue
    if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx 'sudo'; then
      [[ -s "$home/.ssh/authorized_keys" ]] && return 0
    fi
  done </etc/passwd
  return 1
}

root_has_key() {
  [[ -s /root/.ssh/authorized_keys ]]
}

copy_user_keys_to_root() {
  local username="$1" home src pubkey
  home="$(getent passwd "$username" | cut -d: -f6)"
  [[ -n "$home" ]] || { log ERR "Не удалось определить home пользователя $username"; return 1; }
  src="$home/.ssh/authorized_keys"
  [[ -s "$src" ]] || { log ERR "У пользователя $username нет ключей для копирования."; return 1; }
  while IFS= read -r pubkey || [[ -n "$pubkey" ]]; do
    [[ -n "$pubkey" ]] || continue
    [[ "$pubkey" =~ ^# ]] && continue
    add_public_key_to_user root "$pubkey" || return 1
  done <"$src"
  return 0
}

add_public_key_to_user() {
  local username="$1" pubkey="$2" home ssh_dir auth_file owner
  if [[ "$username" == root ]]; then
    home="/root"
    owner="root:root"
  else
    home="$(getent passwd "$username" | cut -d: -f6)"
    [[ -n "$home" ]] || { log ERR "Не удалось определить home для $username"; return 1; }
    owner="${username}:${username}"
  fi
  ssh_dir="$home/.ssh"
  auth_file="$ssh_dir/authorized_keys"
  if (( DRY_RUN )); then
    log INFO "[dry-run] добавить ключ пользователю $username"
    append_unique_line "$STATE_DIR/keys/${username}.list" "$pubkey"
    return 0
  fi
  install -d -m 0700 -o "${owner%%:*}" -g "${owner##*:}" "$ssh_dir" 2>/dev/null || mkdir -p "$ssh_dir"
  touch "$auth_file"
  chmod 700 "$ssh_dir"
  chmod 600 "$auth_file"
  grep -Fxq "$pubkey" "$auth_file" 2>/dev/null || printf '%s\n' "$pubkey" >>"$auth_file"
  chown -R "$owner" "$ssh_dir" || return 1
  track_key_for_user "$username" "$pubkey"
  log OK "Ключ добавлен пользователю ${username}."
}

show_windows_key_help() {
  clear_screen
  cat <<'TXT'
Современная команда для генерации SSH-ключа в Windows 10/11 (PowerShell):

  ssh-keygen -t ed25519 -C "my-vps"

Файлы по умолчанию:
  Публичный ключ:  C:\Users\ИМЯ\.ssh\id_ed25519.pub
  Приватный ключ:  C:\Users\ИМЯ\.ssh\id_ed25519

На сервер вставляется только содержимое файла .pub (одной строкой).
TXT
  pause
}

get_public_ip() {
  local ip="" ep
  local endpoints=("https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com")
  for ep in "${endpoints[@]}"; do
    ip="$(curl -fsS --max-time 4 "$ep" 2>/dev/null | tr -d '\r\n ' || true)"
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      echo "$ip"; return 0
    fi
  done
  echo "не удалось определить"
}

show_system_info() {
  clear_screen
  local kernel host tz uptime_txt ip4 pub4 ssh_port ssh_pass ssh_root ufw_state f2b_state docker_state resolv_link
  kernel="$(uname -r)"
  host="$(hostname)"
  tz="$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 'неизвестно')"
  uptime_txt="$(uptime -p 2>/dev/null || uptime)"
  ip4="$(hostname -I 2>/dev/null | awk '{print $1}')"
  pub4="$(get_public_ip)"
  ssh_port="$(get_display_ssh_port)"
  ssh_pass="$(get_effective_ssh passwordauthentication || true)"
  ssh_root="$(get_effective_ssh permitrootlogin || true)"
  ufw_state="$(ufw status 2>/dev/null | head -n1 || echo 'ufw не установлен')"
  if command -v fail2ban-client >/dev/null 2>&1; then
    f2b_state="$(systemctl is-active fail2ban 2>/dev/null || echo 'not-installed/inactive')"
  else
    f2b_state="not-installed/inactive"
  fi
  docker_state="$(systemctl is-active docker 2>/dev/null || echo 'not-installed/inactive')"
  resolv_link="$(readlink -f /etc/resolv.conf 2>/dev/null || echo '')"

  echo
  echo "========== Информация о системе =========="
  echo "ОС:                $OS_PRETTY_NAME"
  echo "Ядро:              $kernel"
  echo "Хост:              $host"
  echo "Часовой пояс:      $tz"
  echo "Uptime:            $uptime_txt"
  echo "Локальный IP:      ${ip4:-неизвестно}"
  echo "Публичный IP:      $pub4"
  echo "SSH порт:          ${ssh_port:-неизвестно}"
  echo "SSH пароль:        ${ssh_pass:-неизвестно}"
  echo "Root login:        ${ssh_root:-неизвестно}"
  echo "SSH активация:     $(ssh_is_socket_activated && echo 'socket (ssh.socket)' || echo 'service')"
  echo "UFW:               $ufw_state"
  echo "Fail2Ban:          $f2b_state"
  echo "Docker:            $docker_state"
  echo "resolv.conf →      ${resolv_link:-?}"
  echo "Лог запуска:       $LOG_FILE"
  echo "=========================================="
  echo
  show_users_brief
  pause
}

show_update_summary() {
  local label="$1"
  echo
  echo "Итог: $label"
  local line
  line="$(grep -E '^[0-9]+ upgraded, [0-9]+ newly installed, [0-9]+ to remove' "$LOG_FILE" | tail -n1 || true)"
  [[ -n "$line" ]] && echo "- $line"
  if grep -q 'deferred due to phasing' "$LOG_FILE"; then
    echo "- Есть отложенные phased updates"
    grep -A3 'deferred due to phasing' "$LOG_FILE" | tail -n3 | sed 's/^/  /'
  fi
  echo "- Полный лог: $LOG_FILE"
  pause
}

self_test() {
  local errors=0 f
  local funcs=(
    track_key_for_user list_regular_users print_regular_users show_users_brief
    create_user_interactive delete_user_interactive add_key_interactive
    set_password_interactive change_sudo_mode_interactive
    configure_ssh_interactive configure_dns_interactive
    configure_bbr_interactive configure_ipv6_interactive
    install_docker_interactive configure_unattended_interactive
    show_system_info rollback_menu cleanup_node_interactive
    is_valid_pubkey validate_pubkey_strict has_any_admin_key apply_ssh_port_via_socket
    get_display_ssh_port get_ssh_firewall_port install_or_enable_ufw apply_ufw_limit
  )
  for f in "${funcs[@]}"; do
    declare -F "$f" >/dev/null || { echo "Отсутствует функция: $f"; ((errors++)); }
  done
  [[ -f /etc/os-release ]] || { echo "Нет /etc/os-release"; ((errors++)); }
  [[ -n "$(ssh_control_unit)" ]] || echo "Предупреждение: SSH unit не определён"
  is_valid_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample comment" || { echo "is_valid_pubkey: ed25519 fail"; ((errors++)); }
  is_valid_pubkey "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY= user@host" || { echo "is_valid_pubkey: ecdsa fail"; ((errors++)); }
  is_valid_pubkey "random-garbage" && { echo "is_valid_pubkey: ложно-положительный"; ((errors++)); }
  if (( errors > 0 )); then
    echo "Self-test: FAIL ($errors)"
    return 1
  fi
  echo "Self-test: OK"
  return 0
}

install_or_update_recommended() {
  local extra="$1"
  local packages=("${RECOMMENDED_PACKAGES[@]}")
  if [[ -n "$extra" ]]; then
    local extra_arr=()
    read -ra extra_arr <<<"$extra"
    packages+=("${extra_arr[@]}")
  fi
  run_cmd apt-get update || return 1
  DEBIAN_FRONTEND=noninteractive run_cmd apt-get install -y "${packages[@]}" || return 1
  echo
  echo "Рекомендуемые программы:"
  echo "- mc — файловый менеджер"
  echo "- htop — просмотр нагрузки"
  echo "- curl / wget — загрузка и проверка URL"
  echo "- unzip — распаковка zip"
  echo "- nano — простой редактор"
  echo "- jq — работа с JSON"
  echo "- git — работа с репозиториями"
  echo "- mtr-tiny — диагностика сети"
  echo "- bash-completion — автодополнение команд"
  echo "- ncdu — просмотр занятого места"
  log OK "Рекомендуемые пакеты обработаны."
}

updates_menu() {
  while true; do
    clear_screen
    echo
    echo "===== Обновления и пакеты ====="
    echo "Этот раздел нужен для обновления системы и установки базовых программ."
    echo "- Здесь можно обновить списки пакетов"
    echo "- Обновить установленное ПО"
    echo "- Поставить полезные утилиты для администрирования"
    echo
    echo "1) apt update"
    echo "2) apt upgrade -y"
    echo "3) apt full-upgrade -y"
    echo "4) autoremove --purge и autoclean"
    echo "5) Установить / обновить рекомендуемые пакеты"
    echo "6) Обновить Ubuntu до следующего релиза"
    echo "0) Назад"
    read -r -p "> " choice </dev/tty
    case "$choice" in
      1) run_cmd apt-get update; show_update_summary "apt update" ;;
      2) run_cmd apt-get update && DEBIAN_FRONTEND=noninteractive run_cmd apt-get upgrade -y; show_update_summary "apt upgrade -y" ;;
      3) run_cmd apt-get update && DEBIAN_FRONTEND=noninteractive run_cmd apt-get full-upgrade -y; show_update_summary "apt full-upgrade -y" ;;
      4) run_cmd apt-get autoremove --purge -y && run_cmd apt-get autoclean -y; pause ;;
      5)
        echo
        echo "Будут установлены или обновлены:"
        echo "- mc, htop, curl, wget, unzip, nano"
        echo "- jq, git, mtr-tiny, bash-completion, ncdu"
        read -r -p "Дополнительные пакеты через пробел (или Enter): " extra </dev/tty
        install_or_update_recommended "$extra"
        pause
        ;;
      6)
        if [[ "$(os_id)" != "ubuntu" ]]; then
          log WARN "Release upgrade доступен только для Ubuntu."
        else
          echo
          echo "Внимание: переход на новый релиз — это отдельная и потенциально рискованная операция."
          echo "- Для серверов чаще предпочтительнее LTS-релизы"
          echo "- Перед началом желательно иметь резервную копию"
          if confirm "Продолжить к do-release-upgrade?"; then
            run_cmd apt-get update && DEBIAN_FRONTEND=noninteractive run_cmd apt-get full-upgrade -y
            run_cmd do-release-upgrade
          fi
        fi
        pause
        ;;
      0) return 0 ;;
      *) echo "Неверный пункт."; pause ;;
    esac
  done
}

create_user_interactive() {
  clear_screen
  local username sudo_mode key_mode pubkey pass1 pass2 rootkeys_file sudoers
  show_users_brief
  username="$(prompt_optional 'Введите имя нового пользователя (Enter = назад): ')"
  [[ -z "$username" ]] && return 0
  [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || { log ERR "Некорректное имя пользователя."; pause; return 1; }
  if getent passwd "$username" >/dev/null 2>&1; then
    log ERR "Пользователь '$username' уже существует."
    pause
    return 1
  fi

  echo "Режим sudo:"
  echo "- Обычный sudo просит пароль пользователя"
  echo "- Sudo без пароля удобнее, но риск выше"
  echo "0) Назад"
  echo "1) Без sudo"
  echo "2) Обычный sudo"
  echo "3) Sudo без пароля"
  read -r -p "> " sudo_mode </dev/tty
  [[ "$sudo_mode" == "0" ]] && return 0

  echo
  echo "Как добавить SSH-ключ?"
  echo "- Можно вставить новый публичный ключ"
  echo "- Или скопировать все ключи root"
  echo "0) Назад"
  echo "1) Вставить новый публичный ключ"
  echo "2) Скопировать все ключи root"
  echo "3) Пока не добавлять ключ"
  read -r -p "> " key_mode </dev/tty
  [[ "$key_mode" == "0" ]] && return 0

  if [[ "$sudo_mode" == "2" ]]; then
    read -r -s -p "Задай пароль для нового пользователя: " pass1 </dev/tty; echo
    read -r -s -p "Повтори пароль: " pass2 </dev/tty; echo
    [[ "$pass1" == "$pass2" ]] || { log ERR "Пароли не совпадают."; pause; return 1; }
  fi

  case "$key_mode" in
    1)
      pubkey="$(prompt_nonempty 'Вставь строку публичного SSH-ключа (.pub): ')"
      validate_pubkey_strict "$pubkey" || { log ERR "Строка не похожа на корректный публичный SSH-ключ."; pause; return 1; }
      ;;
    2)
      rootkeys_file="/root/.ssh/authorized_keys"
      [[ -s "$rootkeys_file" ]] || { log ERR "У root нет ключей в /root/.ssh/authorized_keys."; pause; return 1; }
      ;;
    3) ;;
    *) log ERR "Неверный вариант ключа."; pause; return 1 ;;
  esac

  run_cmd adduser --disabled-password --gecos "" "$username" || { pause; return 1; }
  track_created_user "$username"

  case "$sudo_mode" in
    2|3) run_cmd usermod -aG sudo "$username" || { pause; return 1; } ;;
    1) ;;
    *) log ERR "Неверный режим sudo."; pause; return 1 ;;
  esac

  if [[ "$sudo_mode" == "3" ]]; then
    sudoers="/etc/sudoers.d/90-${APP_SLUG}-${username}"
    if (( DRY_RUN )); then
      log INFO "[dry-run] write $sudoers"
    else
      printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$username" >"$sudoers" || { pause; return 1; }
      chmod 440 "$sudoers" || { pause; return 1; }
      visudo -cf "$sudoers" >>"$LOG_FILE" 2>&1 || { log ERR "Файл sudoers не прошёл проверку."; rm -f "$sudoers"; pause; return 1; }
    fi
  fi

  if [[ "$sudo_mode" == "2" ]]; then
    if (( DRY_RUN )); then
      log INFO "[dry-run] set password for $username"
    else
      printf '%s:%s\n' "$username" "$pass1" | chpasswd 2>>"$LOG_FILE" >/dev/null || { log ERR "Не удалось задать пароль пользователю."; pause; return 1; }
    fi
  fi

  case "$key_mode" in
    1)
      add_public_key_to_user "$username" "$pubkey" || { pause; return 1; }
      ;;
    2)
      while IFS= read -r pubkey || [[ -n "$pubkey" ]]; do
        [[ -n "$pubkey" ]] || continue
        [[ "$pubkey" =~ ^# ]] && continue
        add_public_key_to_user "$username" "$pubkey" || { pause; return 1; }
      done <"$rootkeys_file"
      ;;
    3) ;;
  esac

  log OK "Пользователь $username создан."
  pause
}

delete_user_interactive() {
  clear_screen
  local username mode
  show_users_brief
  username="$(prompt_optional 'Введите имя пользователя для удаления (Enter = назад): ')"
  [[ -z "$username" ]] && return 0
  if ! getent passwd "$username" >/dev/null 2>&1; then
    log ERR "Пользователь '$username' не найден."
    pause
    return 1
  fi
  if [[ "$username" == "root" ]]; then
    log ERR "Пользователя root удалять нельзя."
    pause
    return 1
  fi
  echo "Режим удаления:"
  echo "0) Назад"
  echo "1) Удалить пользователя без домашней директории"
  echo "2) Удалить пользователя вместе с домашней директорией (-r)"
  read -r -p "> " mode </dev/tty
  [[ "$mode" == "0" ]] && return 0

  if (( ! DRY_RUN )); then
    pkill -KILL -u "$username" 2>/dev/null || true
    sleep 1
  fi

  rm -f "/etc/sudoers.d/90-${APP_SLUG}-${username}"
  case "$mode" in
    1) run_cmd userdel "$username" ;;
    2) run_cmd userdel -r "$username" ;;
    *) log ERR "Неверный режим удаления."; pause; return 1 ;;
  esac
  log OK "Пользователь $username удалён."
  pause
}

add_key_interactive() {
  clear_screen
  local username mode pubkey src
  show_users_brief
  username="$(prompt_optional 'Кому добавить ключ (имя пользователя или root, Enter = назад): ')"
  [[ -z "$username" ]] && return 0
  getent passwd "$username" >/dev/null 2>&1 || { log ERR "Пользователь не найден."; pause; return 1; }
  echo "Какой режим нужен?"
  echo "0) Назад"
  echo "1) Вставить новый публичный ключ"
  echo "2) Скопировать все ключи root"
  read -r -p "> " mode </dev/tty
  [[ "$mode" == "0" ]] && return 0
  case "$mode" in
    1)
      pubkey="$(prompt_nonempty 'Вставь строку публичного SSH-ключа (.pub): ')"
      validate_pubkey_strict "$pubkey" || { log ERR "Некорректный публичный SSH-ключ."; pause; return 1; }
      add_public_key_to_user "$username" "$pubkey"
      ;;
    2)
      src="/root/.ssh/authorized_keys"
      [[ -s "$src" ]] || { log ERR "У root нет ключей для копирования."; pause; return 1; }
      while IFS= read -r pubkey || [[ -n "$pubkey" ]]; do
        [[ -n "$pubkey" ]] || continue
        [[ "$pubkey" =~ ^# ]] && continue
        add_public_key_to_user "$username" "$pubkey" || { pause; return 1; }
      done <"$src"
      ;;
    *) log ERR "Неверный вариант." ;;
  esac
  pause
}

set_password_interactive() {
  clear_screen
  local username pass1 pass2
  show_users_brief
  username="$(prompt_optional 'Введите имя пользователя (или root, Enter = назад): ')"
  [[ -z "$username" ]] && return 0
  getent passwd "$username" >/dev/null 2>&1 || { log ERR "Пользователь не найден."; pause; return 1; }
  read -r -s -p "Новый пароль: " pass1 </dev/tty; echo
  read -r -s -p "Повтори пароль: " pass2 </dev/tty; echo
  [[ "$pass1" == "$pass2" ]] || { log ERR "Пароли не совпадают."; pause; return 1; }
  if (( DRY_RUN )); then
    log INFO "[dry-run] set password for $username"
  else
    printf '%s:%s\n' "$username" "$pass1" | chpasswd 2>>"$LOG_FILE" >/dev/null || { log ERR "Не удалось изменить пароль."; pause; return 1; }
  fi
  log OK "Пароль пользователя $username обновлён."
  pause
}

change_sudo_mode_interactive() {
  clear_screen
  local username mode sudoers
  echo "Этот пункт меняет режим sudo для существующего пользователя."
  echo "- Без sudo: пользователь теряет административные права"
  echo "- Обычный sudo: будет запрашиваться пароль пользователя"
  echo "- Sudo без пароля: удобно, но риск выше"
  echo
  show_users_brief
  username="$(prompt_optional 'Введите имя пользователя (Enter = назад): ')"
  [[ -z "$username" ]] && return 0
  getent passwd "$username" >/dev/null 2>&1 || { log ERR "Пользователь не найден."; pause; return 1; }
  sudoers="/etc/sudoers.d/90-${APP_SLUG}-${username}"
  echo "0) Назад"
  echo "1) Без sudo"
  echo "2) Обычный sudo"
  echo "3) Sudo без пароля (NOPASSWD)"
  read -r -p "> " mode </dev/tty
  [[ "$mode" == "0" ]] && return 0
  case "$mode" in
    1)
      run_cmd gpasswd -d "$username" sudo || true
      if (( ! DRY_RUN )); then rm -f "$sudoers"; fi
      ;;
    2)
      run_cmd usermod -aG sudo "$username" || { pause; return 1; }
      if (( ! DRY_RUN )); then rm -f "$sudoers"; fi
      ;;
    3)
      run_cmd usermod -aG sudo "$username" || { pause; return 1; }
      if (( DRY_RUN )); then
        log INFO "[dry-run] write $sudoers"
      else
        printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$username" >"$sudoers" || { pause; return 1; }
        chmod 440 "$sudoers" || { pause; return 1; }
        visudo -cf "$sudoers" >>"$LOG_FILE" 2>&1 || { log ERR "Файл sudoers не прошёл проверку."; rm -f "$sudoers"; pause; return 1; }
      fi
      ;;
    *) log ERR "Неверный режим."; pause; return 1 ;;
  esac
  log OK "Режим sudo для $username обновлён."
  pause
}

manage_users_menu() {
  while true; do
    clear_screen
    echo
    echo "===== Пользователи и SSH-ключи ====="
    echo "Этот раздел нужен для работы с учётными записями и ключами."
    echo "- Создание и удаление пользователей"
    echo "- Добавление ключей"
    echo "- Смена пароля и режима sudo"
    echo
    echo "1) Создать нового пользователя"
    echo "2) Удалить пользователя"
    echo "3) Добавить SSH-ключ пользователю/root"
    echo "4) Задать или сменить пароль"
    echo "5) Изменить режим sudo"
    echo "6) Краткая инструкция по ключу для Windows"
    echo "0) Назад"
    read -r -p "> " choice </dev/tty
    case "$choice" in
      1) create_user_interactive ;;
      2) delete_user_interactive ;;
      3) add_key_interactive ;;
      4) set_password_interactive ;;
      5) change_sudo_mode_interactive ;;
      6) show_windows_key_help ;;
      0) return 0 ;;
      *) echo "Неверный пункт."; pause ;;
    esac
  done
}

configure_ssh_interactive() {
  clear_screen
  local current_port port pass_auth_choice pass_auth current_root_login root_choice root_login admin_user pubkey
  current_port="$(get_display_ssh_port)"
  current_root_login="$(get_effective_ssh permitrootlogin 2>/dev/null || true)"
  [[ -n "$current_root_login" ]] || current_root_login="yes"

  echo "===== SSH и доступ ====="
  echo "Этот раздел меняет порт SSH, вход по паролю и режим root."
  echo "- Сначала убедись, что у тебя есть рабочий SSH-ключ"
  echo "- Не закрывай текущую сессию, пока не проверишь новую"
  echo
  echo "Текущий SSH-порт: $current_port"
  port="$(prompt_default 'Новый SSH-порт' "$current_port")"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { log ERR "Некорректный порт."; pause; return 1; }

  echo
  echo "Закрыть вход по паролю для всех пользователей SSH?"
  echo "0) Назад"
  echo "1) Нет — оставить вход по паролю"
  echo "2) Да — разрешить только вход по ключу"
  read -r -p "> " pass_auth_choice </dev/tty
  [[ "$pass_auth_choice" == "0" ]] && return 0
  case "$pass_auth_choice" in
    1) pass_auth="yes" ;;
    2) pass_auth="no" ;;
    *) log ERR "Неверный вариант."; pause; return 1 ;;
  esac

  echo
  echo "Настройка доступа root по SSH:"
  echo "- Текущий режим: ${current_root_login}"
  echo "0) Назад"
  echo "1) Не менять текущий режим root"
  echo "2) key+pass — root может входить по ключу и по паролю"
  echo "3) key — root только по ключу"
  echo "4) block — root вход по SSH запрещён"
  read -r -p "> " root_choice </dev/tty
  [[ "$root_choice" == "0" ]] && return 0
  case "$root_choice" in
    1) root_login="$current_root_login" ;;
    2) root_login="yes" ;;
    3) root_login="prohibit-password" ;;
    4) root_login="no" ;;
    *) log ERR "Неверный вариант."; pause; return 1 ;;
  esac

  if [[ "$pass_auth" == "no" ]]; then
    if ! has_any_admin_key; then
      log ERR "Нельзя отключить парольный вход: не найден ни один админский SSH-ключ. Сначала добавь ключ root или пользователя из группы sudo."
      pause
      return 1
    fi
  fi

  if [[ "$root_login" == "prohibit-password" ]]; then
    echo
    if root_has_key; then
      echo "У root уже найден SSH-ключ. Режим 'только по ключу' можно применить."
    else
      echo "У root сейчас нет SSH-ключа."
      echo "Чтобы перевести root в режим 'только по ключу', сначала выбери один из вариантов."
      echo "0) Отмена настройки SSH"
      echo "1) Вставить новый публичный ключ для root"
      echo "2) Скопировать ключи выбранного пользователя в root"
      echo "3) Оставить root без изменений"
      read -r -p "> " root_missing_choice </dev/tty
      case "$root_missing_choice" in
        0) return 0 ;;
        1)
          pubkey="$(prompt_nonempty 'Вставь публичный SSH-ключ для root: ')"
          validate_pubkey_strict "$pubkey" || { log ERR "Некорректный публичный SSH-ключ."; pause; return 1; }
          add_public_key_to_user root "$pubkey" || { pause; return 1; }
          ;;
        2)
          show_users_brief
          admin_user="$(prompt_nonempty 'Из какого пользователя скопировать ключи в root: ')"
          getent passwd "$admin_user" >/dev/null 2>&1 || { log ERR "Пользователь не найден."; pause; return 1; }
          copy_user_keys_to_root "$admin_user" || { pause; return 1; }
          ;;
        3)
          log WARN "Режим root оставлен без изменений: ${current_root_login}."
          root_login="$current_root_login"
          ;;
        *) log ERR "Неверный вариант."; pause; return 1 ;;
      esac
    fi
  fi

  if [[ "$root_login" == "no" || "$root_login" == "prohibit-password" ]]; then
    echo
    echo "Важно:"
    echo "- не закрывай текущую root-сессию, пока не проверишь новый вход"
    echo "- сначала проверь вход в отдельной сессии"
    confirm "Применить этот режим для root?" || {
      log WARN "Изменение режима root отменено пользователем. Оставляю текущий режим: ${current_root_login}."
      root_login="$current_root_login"
    }
  fi

  if (( DRY_RUN )); then
    log INFO "[dry-run] write $MANAGED_SSH_FILE"
    if ssh_is_socket_activated; then
      log INFO "[dry-run] write $MANAGED_SSH_SOCKET_FILE with port ${port}"
    fi
    log INFO "[dry-run] validate sshd config"
    log INFO "[dry-run] restart SSH"
    pause
    return 0
  fi

  install -d -m 0755 /etc/ssh/sshd_config.d
  if ssh_is_socket_activated; then
    apply_ssh_port_via_socket "$port"
    cat >"$MANAGED_SSH_FILE" <<EOF2
# Управляется ${APP_NAME}
# Порт для socket-активации задаётся в ${MANAGED_SSH_SOCKET_FILE}
PubkeyAuthentication yes
PasswordAuthentication ${pass_auth}
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin ${root_login}
UsePAM yes
EOF2
  else
    rm -f "$MANAGED_SSH_SOCKET_FILE"
    cat >"$MANAGED_SSH_FILE" <<EOF2
# Управляется ${APP_NAME}
Port ${port}
PubkeyAuthentication yes
PasswordAuthentication ${pass_auth}
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin ${root_login}
UsePAM yes
EOF2
  fi
  chmod 0644 "$MANAGED_SSH_FILE"

  if ! sshd -t >>"$LOG_FILE" 2>&1; then
    log ERR "sshd -t не прошёл. Конфиг содержит ошибки. Отменяю изменения."
    rm -f "$MANAGED_SSH_FILE" "$MANAGED_SSH_SOCKET_FILE"
    restart_ssh || true
    pause
    return 1
  fi

  restart_ssh || { pause; return 1; }

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    run_cmd ufw allow "$(get_ssh_firewall_port)/tcp" || true
  fi

  log OK "SSH-настройки применены. Порт: ${port}. Режим root: ${root_login}."
  pause
}

rollback_ssh() {
  if (( DRY_RUN )); then
    log INFO "[dry-run] remove $MANAGED_SSH_FILE and $MANAGED_SSH_SOCKET_FILE, restart SSH"
    return 0
  fi
  rm -f "$MANAGED_SSH_FILE" "$MANAGED_SSH_SOCKET_FILE"
  rmdir "$MANAGED_SSH_SOCKET_DIR" 2>/dev/null || true
  sshd -t >>"$LOG_FILE" 2>&1 || { log ERR "После удаления SSH drop-in проверка sshd -t не прошла."; return 1; }
  restart_ssh
}

install_or_enable_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    run_cmd apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive run_cmd apt-get install -y ufw || return 1
  fi

  local port
  port="$(get_ssh_firewall_port)"
  [[ "$port" =~ ^[0-9]+$ ]] || { log ERR "Не удалось корректно определить SSH-порт для UFW."; return 1; }

  run_cmd ufw allow "${port}/tcp" || return 1

  if (( DRY_RUN )); then
    log INFO "[dry-run] ufw --force enable"
  else
    run_cmd ufw --force enable || return 1
  fi

  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    log OK "UFW включён. Разрешён SSH порт ${port}/tcp."
    return 0
  fi

  log ERR "UFW не стал active после включения."
  return 1
}

apply_ufw_limit() {
  local port
  port="$(get_ssh_firewall_port)"
  [[ "$port" =~ ^[0-9]+$ ]] || { log ERR "Не удалось корректно определить SSH-порт для UFW."; return 1; }

  run_cmd ufw limit "${port}/tcp" || return 1
  log OK "Для SSH-порта ${port}/tcp включён ufw limit."
}

toggle_icmp() {
  local mode="$1" file="/etc/ufw/before.rules"
  [[ -f "$file" ]] || { log ERR "Файл $file не найден."; return 1; }
  if (( DRY_RUN )); then
    log INFO "[dry-run] change ICMP echo-request to ${mode} in $file"
    return 0
  fi
  case "$mode" in
    drop)   sed -i -E 's|(-A ufw-before-input -p icmp --icmp-type echo-request -j )ACCEPT|\1DROP|' "$file" ;;
    accept) sed -i -E 's|(-A ufw-before-input -p icmp --icmp-type echo-request -j )DROP|\1ACCEPT|' "$file" ;;
    *) return 1 ;;
  esac
  if ! grep -q "icmp-type echo-request -j ${mode^^}" "$file" 2>/dev/null; then
    log WARN "ICMP-правило могло не измениться. Проверь $file вручную."
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw reload >>"$LOG_FILE" 2>&1 || true
  fi
  return 0
}

install_fail2ban_interactive() {
  local backend logpath ssh_port jail_file
  ssh_port="$(get_ssh_firewall_port)"
  run_cmd apt-get update || return 1
  DEBIAN_FRONTEND=noninteractive run_cmd apt-get install -y fail2ban || return 1
  if [[ -f /var/log/auth.log ]]; then
    backend="auto"
    logpath="/var/log/auth.log"
  else
    backend="systemd"
    logpath=""
  fi
  jail_file="/etc/fail2ban/jail.d/sshd.local"
  if (( DRY_RUN )); then
    log INFO "[dry-run] write $jail_file (backend=${backend}, logpath=${logpath:-none})"
  else
    install -d -m 0755 /etc/fail2ban/jail.d
    {
      echo "[sshd]"
      echo "enabled = true"
      echo "port = ${ssh_port}"
      echo "backend = ${backend}"
      [[ -n "$logpath" ]] && echo "logpath = ${logpath}"
      echo "maxretry = 5"
      echo "findtime = 10m"
      echo "bantime = 12h"
    } >"$jail_file"
    chmod 0644 "$jail_file"
  fi
  run_cmd systemctl enable --now fail2ban || return 1
  run_cmd systemctl restart fail2ban || return 1
  if systemctl is-active --quiet fail2ban; then
    log OK "Fail2Ban настроен для SSH (backend=${backend})."
    return 0
  fi
  log ERR "Fail2Ban не перешёл в active. Проверь: systemctl status fail2ban"
  return 1
}

remove_fail2ban_interactive() {
  if confirm "Удалить fail2ban полностью?"; then
    run_cmd systemctl disable --now fail2ban || true
    DEBIAN_FRONTEND=noninteractive run_cmd apt-get purge -y fail2ban || true
    run_cmd apt-get autoremove --purge -y || true
    log OK "Fail2Ban удалён."
  fi
}

firewall_menu() {
  while true; do
    clear_screen
    echo
    echo "===== Фаервол и защита ====="
    echo "Этот раздел нужен для базовой защиты сервера."
    echo "- Включение UFW"
    echo "- Ограничение частоты SSH через ufw limit"
    echo "- Fail2Ban для SSH"
    echo "- Отключение/включение ответа на ping"
    echo
    echo "1) Установить / включить UFW и разрешить текущий SSH-порт"
    echo "2) Включить ufw limit для SSH"
    echo "3) Отключить ответы на ICMP ping"
    echo "4) Включить ответы на ICMP ping"
    echo "5) Установить / настроить Fail2Ban для SSH"
    echo "6) Удалить Fail2Ban"
    echo "7) Отключить UFW"
    echo "0) Назад"
    read -r -p "> " choice </dev/tty
    case "$choice" in
      1) install_or_enable_ufw; pause ;;
      2) apply_ufw_limit; pause ;;
      3) toggle_icmp drop   && log OK "ICMP ping отключён."; pause ;;
      4) toggle_icmp accept && log OK "ICMP ping включён.";  pause ;;
      5) install_fail2ban_interactive; pause ;;
      6) remove_fail2ban_interactive; pause ;;
      7) run_cmd ufw disable; pause ;;
      0) return 0 ;;
      *) echo "Неверный пункт."; pause ;;
    esac
  done
}

configure_dns_interactive() {
  clear_screen
  local dns fallback choice resolv_link
  systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx 'systemd-resolved.service' || { log ERR "systemd-resolved не найден."; pause; return 1; }
  resolv_link="$(readlink -f /etc/resolv.conf 2>/dev/null || echo '')"
  if [[ "$resolv_link" != /run/systemd/resolve/* ]]; then
    log WARN "/etc/resolv.conf не указывает на systemd-resolved (${resolv_link:-нет}). Настройки могут игнорироваться."
    confirm "Продолжить всё равно?" || return 0
  fi

  echo "Настройка DNS:"
  echo "- Можно выбрать готовый набор DNS"
  echo "- Или ввести свои адреса вручную"
  echo "0) Назад"
  echo "1) Quad9 + Google, fallback AdGuard"
  echo "2) Cloudflare + Google"
  echo "3) AdGuard + Cloudflare"
  echo "4) Ввести свои DNS вручную"
  read -r -p "> " choice </dev/tty
  [[ "$choice" == "0" ]] && return 0
  case "$choice" in
    1)
      dns="9.9.9.9 8.8.8.8"
      fallback="94.140.14.14 1.1.1.1"
      ;;
    2)
      dns="1.1.1.1 8.8.8.8"
      fallback="1.0.0.1 8.8.4.4"
      ;;
    3)
      dns="94.140.14.14 1.1.1.1"
      fallback="94.140.15.15 1.0.0.1"
      ;;
    4)
      dns="$(prompt_nonempty 'Основные DNS через пробел: ')"
      fallback="$(prompt_optional 'Fallback DNS через пробел (можно пусто): ')"
      ;;
    *) log ERR "Неверный вариант."; pause; return 1 ;;
  esac

  if (( DRY_RUN )); then
    log INFO "[dry-run] write $MANAGED_DNS_FILE"
  else
    install -d -m 0755 /etc/systemd/resolved.conf.d
    {
      echo '[Resolve]'
      echo "DNS=${dns}"
      [[ -n "$fallback" ]] && echo "FallbackDNS=${fallback}"
    } >"$MANAGED_DNS_FILE"
    chmod 0644 "$MANAGED_DNS_FILE"
  fi
  run_cmd systemctl restart systemd-resolved || return 1
  log OK "DNS-настройки применены."
  pause
}

rollback_dns() {
  if (( DRY_RUN )); then
    log INFO "[dry-run] remove $MANAGED_DNS_FILE"
    return 0
  fi
  rm -f "$MANAGED_DNS_FILE"
  run_cmd systemctl restart systemd-resolved || return 1
}

offset_to_timezone() {
  local off="$1" sign hours mins
  off="${off// /}"
  if [[ "$off" =~ ^([+-])([0-9]{1,2})(:([0-9]{2}))?$ ]]; then
    sign="${BASH_REMATCH[1]}"
    hours="${BASH_REMATCH[2]}"
    mins="${BASH_REMATCH[4]:-00}"
    (( 10#$hours <= 14 )) || return 1
    [[ "$mins" == "00" ]] || return 1
    # В Etc/GMT знак обратный
    if [[ "$sign" == "+" ]]; then
      echo "Etc/GMT-${hours#0}"
    else
      echo "Etc/GMT+${hours#0}"
    fi
    return 0
  fi
  return 1
}

configure_timezone_interactive() {
  clear_screen
  local current tz choice offset
  current="$(timedatectl show --property=Timezone --value 2>/dev/null || echo 'неизвестно')"
  echo "Текущий часовой пояс: $current"
  echo "Выбери вариант:"
  echo "0) Назад"
  echo "1) Europe/Berlin"
  echo "2) Europe/Moscow"
  echo "3) UTC"
  echo "4) Ввести смещение UTC (например +3 или +03:00)"
  echo "5) Ввести имя зоны вручную"
  read -r -p "> " choice </dev/tty
  [[ "$choice" == "0" ]] && return 0
  case "$choice" in
    1) tz="Europe/Berlin" ;;
    2) tz="Europe/Moscow" ;;
    3) tz="UTC" ;;
    4)
      offset="$(prompt_nonempty 'Введи смещение UTC (например +3 или +03:00): ')"
      tz="$(offset_to_timezone "$offset")" || { log ERR "Поддерживаются только целые часы, например +3 или -5."; pause; return 1; }
      ;;
    5) tz="$(prompt_nonempty 'Введи имя зоны (например Europe/Berlin): ')" ;;
    *) log ERR "Неверный вариант."; pause; return 1 ;;
  esac
  timedatectl list-timezones 2>/dev/null | grep -Fxq "$tz" || { log ERR "Timezone '$tz' не найден."; pause; return 1; }
  run_cmd timedatectl set-timezone "$tz" || return 1
  log OK "Часовой пояс установлен: $tz"
  pause
}

configure_bbr_interactive() {
  clear_screen
  local bbr_supported=0

  if modinfo tcp_bbr >/dev/null 2>&1; then
    bbr_supported=1
  elif sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    bbr_supported=1
  fi

  if (( ! bbr_supported )); then
    log ERR "Алгоритм bbr не поддерживается ядром (модуль не найден и не встроен)."
    pause
    return 1
  fi

  if (( DRY_RUN )); then
    log INFO "[dry-run] modprobe tcp_bbr"
    log INFO "[dry-run] write $MANAGED_MODULES_FILE"
    log INFO "[dry-run] write $MANAGED_BBR_FILE"
    pause
    return 0
  fi

  modprobe tcp_bbr >>"$LOG_FILE" 2>&1 || true # Может завершиться с ошибкой, если модуль вшит в ядро, это нормально

  if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    log ERR "Алгоритм bbr не найден даже после попытки загрузки модуля tcp_bbr."
    pause
    return 1
  fi

  printf 'tcp_bbr\n' >"$MANAGED_MODULES_FILE"
  chmod 0644 "$MANAGED_MODULES_FILE"
  cat >"$MANAGED_BBR_FILE" <<EOF3
# Управляется ${APP_NAME}
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF3
  chmod 0644 "$MANAGED_BBR_FILE"
  sysctl --system >>"$LOG_FILE" 2>&1 || { log ERR "Не удалось применить sysctl."; pause; return 1; }
  log OK "BBR включён."
  pause
}

rollback_bbr() {
  if (( DRY_RUN )); then
    log INFO "[dry-run] remove BBR managed files"
    return 0
  fi
  rm -f "$MANAGED_BBR_FILE" "$MANAGED_MODULES_FILE"
  sysctl -w net.ipv4.tcp_congestion_control=cubic >>"$LOG_FILE" 2>&1 || true
}

configure_ipv6_interactive() {
  clear_screen
  echo "Настройка IPv6:"
  echo "- Некоторые VPN/Proxy-сценарии используют только IPv4"
  echo "- Но IPv6 лучше не отключать без необходимости"
  echo "0) Назад"
  echo "1) Отключить IPv6"
  echo "2) Включить IPv6 обратно"
  read -r -p "> " choice </dev/tty
  [[ "$choice" == "0" ]] && return 0
  case "$choice" in
    1)
      if (( DRY_RUN )); then
        log INFO "[dry-run] write $MANAGED_IPV6_FILE"
      else
        cat >"$MANAGED_IPV6_FILE" <<EOF4
# Управляется ${APP_NAME}
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF4
        chmod 0644 "$MANAGED_IPV6_FILE"
        sysctl --system >>"$LOG_FILE" 2>&1 || { log ERR "Не удалось отключить IPv6."; pause; return 1; }
      fi
      log OK "IPv6 отключён."
      ;;
    2)
      if (( DRY_RUN )); then
        log INFO "[dry-run] remove $MANAGED_IPV6_FILE"
      else
        rm -f "$MANAGED_IPV6_FILE"
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >>"$LOG_FILE" 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >>"$LOG_FILE" 2>&1 || true
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >>"$LOG_FILE" 2>&1 || true
      fi
      log OK "IPv6 включён."
      ;;
    *) log ERR "Неверный вариант."; pause; return 1 ;;
  esac
  pause
}

network_menu() {
  while true; do
    clear_screen
    echo
    echo "===== Сеть, DNS, время и ядро ====="
    echo "Этот раздел нужен для сетевых и системных настроек."
    echo "- DNS через systemd-resolved"
    echo "- Часовой пояс"
    echo "- BBR"
    echo "- IPv6"
    echo
    echo "1) Настроить DNS через systemd-resolved"
    echo "2) Настроить часовой пояс"
    echo "3) Включить BBR"
    echo "4) Включить/выключить IPv6"
    echo "0) Назад"
    read -r -p "> " choice </dev/tty
    case "$choice" in
      1) configure_dns_interactive ;;
      2) configure_timezone_interactive ;;
      3) configure_bbr_interactive ;;
      4) configure_ipv6_interactive ;;
      0) return 0 ;;
      *) echo "Неверный пункт."; pause ;;
    esac
  done
}

install_docker_interactive() {
  clear_screen
  local id codename arch keyring repo_url
  id="$(os_id)"
  codename="$(os_codename)"
  arch="$(dpkg --print-architecture)"
  case "$id" in
    ubuntu|debian) ;;
    *) log ERR "Docker-установка поддерживается только для Ubuntu/Debian."; pause; return 1 ;;
  esac
  [[ -n "$codename" ]] || { log ERR "Не удалось определить codename."; pause; return 1; }

  DEBIAN_FRONTEND=noninteractive run_cmd apt-get remove -y docker docker-engine docker.io containerd runc docker-compose docker-compose-v2 docker-doc podman-docker || true
  run_cmd apt-get update || return 1
  DEBIAN_FRONTEND=noninteractive run_cmd apt-get install -y ca-certificates curl gnupg || return 1

  keyring="/etc/apt/keyrings/docker.gpg"
  repo_url="https://download.docker.com/linux/${id}"
  if (( DRY_RUN )); then
    log INFO "[dry-run] install Docker repo for ${id} ${codename}"
  else
    install -m 0755 -d /etc/apt/keyrings
    if ! curl -fsSL "${repo_url}/gpg" | gpg --dearmor --yes -o "$keyring" 2>>"$LOG_FILE"; then
      log ERR "Не удалось скачать GPG-ключ Docker."
      pause
      return 1
    fi
    chmod a+r "$keyring"
    echo "deb [arch=${arch} signed-by=${keyring}] ${repo_url} ${codename} stable" >/etc/apt/sources.list.d/docker.list
  fi
  run_cmd apt-get update || return 1
  DEBIAN_FRONTEND=noninteractive run_cmd apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
  run_cmd systemctl enable --now docker || true
  echo
  echo "Важно: опубликованные порты Docker могут обходить правила UFW."
  echo "Если планируешь использовать Docker с открытыми портами, проверь это отдельно."
  log OK "Docker установлен. Используй 'docker compose'."
  pause
}

add_user_to_docker_group() {
  clear_screen
  show_users_brief
  local username
  username="$(prompt_optional 'Какого пользователя добавить в группу docker (Enter = назад): ')"
  [[ -z "$username" ]] && return 0
  getent passwd "$username" >/dev/null 2>&1 || { log ERR "Пользователь не найден."; pause; return 1; }
  run_cmd usermod -aG docker "$username" || return 1
  log OK "Пользователь $username добавлен в группу docker. Нужно перелогиниться."
  pause
}

docker_menu() {
  while true; do
    clear_screen
    echo
    echo "===== Docker ====="
    echo "Этот раздел нужен для установки Docker и базовой подготовки пользователей."
    echo "- Установка из официального репозитория"
    echo "- Добавление пользователя в группу docker"
    echo
    echo "1) Установить Docker из официального репозитория"
    echo "2) Добавить пользователя в группу docker"
    echo "0) Назад"
    read -r -p "> " choice </dev/tty
    case "$choice" in
      1) install_docker_interactive ;;
      2) add_user_to_docker_group ;;
      0) return 0 ;;
      *) echo "Неверный пункт."; pause ;;
    esac
  done
}

configure_unattended_interactive() {
  clear_screen
  echo "===== Автообновления безопасности ====="
  echo "Этот раздел управляет unattended-upgrades."
  echo "- Можно включить только security updates"
  echo "- Или security + обычные updates"
  echo "- Или отключить автоприменение"
  echo
  echo "0) Назад"
  echo "1) Включить только security updates"
  echo "2) Включить security updates и обычные updates"
  echo "3) Отключить автоматические обновления"
  read -r -p "> " choice </dev/tty
  [[ "$choice" == "0" ]] && return 0
  case "$choice" in
    1|2)
      run_cmd apt-get update || return 1
      DEBIAN_FRONTEND=noninteractive run_cmd apt-get install -y unattended-upgrades || return 1
      if (( DRY_RUN )); then
        log INFO "[dry-run] write $MANAGED_AUTO_FILE and $MANAGED_UNATTENDED_FILE"
      else
        cat >"$MANAGED_AUTO_FILE" <<'EOFAUTO'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOFAUTO
        chmod 0644 "$MANAGED_AUTO_FILE"
        if [[ "$choice" == "1" ]]; then
          cat >"$MANAGED_UNATTENDED_FILE" <<'EOFUU'
// Управляется VPS Bootstrap
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Ubuntu,codename=${distro_codename}-security,label=Ubuntu";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOFUU
        else
          cat >"$MANAGED_UNATTENDED_FILE" <<'EOFUU'
// Управляется VPS Bootstrap
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-updates";
    "origin=Ubuntu,codename=${distro_codename}-security,label=Ubuntu";
    "origin=Ubuntu,codename=${distro_codename}-updates,label=Ubuntu";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOFUU
        fi
        chmod 0644 "$MANAGED_UNATTENDED_FILE"
      fi
      log OK "Автоматические обновления настроены."
      ;;
    3)
      if (( DRY_RUN )); then
        log INFO "[dry-run] disable unattended-upgrades"
      else
        cat >"$MANAGED_AUTO_FILE" <<'EOFAUTO'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOFAUTO
        chmod 0644 "$MANAGED_AUTO_FILE"
        rm -f "$MANAGED_UNATTENDED_FILE"
      fi
      log OK "Автоматические обновления отключены."
      ;;
    *) log ERR "Неверный вариант." ;;
  esac
  pause
}

rollback_menu() {
  while true; do
    clear_screen
    echo
    echo "===== Откат и удаление настроек ====="
    echo "Этот раздел отменяет только те изменения, которыми управляет скрипт."
    echo "0) Назад"
    echo "1) Удалить управляемые SSH-настройки"
    echo "2) Удалить управляемые DNS-настройки"
    echo "3) Откатить BBR"
    echo "4) Откатить IPv6-настройки"
    echo "5) Отключить UFW"
    echo "6) Удалить Fail2Ban"
    echo "7) Очистить служебный state скрипта"
    echo "8) Удалить unattended-upgrades drop-in"
    echo "9) Выполнить полный откат управляемых настроек"
    read -r -p "> " choice </dev/tty
    case "$choice" in
      1) rollback_ssh; pause ;;
      2) rollback_dns; pause ;;
      3) rollback_bbr; log OK "BBR откатан."; pause ;;
      4)
        if (( DRY_RUN )); then log INFO "[dry-run] remove $MANAGED_IPV6_FILE"; else rm -f "$MANAGED_IPV6_FILE"; sysctl --system >>"$LOG_FILE" 2>&1 || true; fi
        log OK "IPv6-настройки откатаны."
        pause
        ;;
      5) run_cmd ufw disable; pause ;;
      6) remove_fail2ban_interactive ;;
      7)
        if (( DRY_RUN )); then log INFO "[dry-run] rm -rf $STATE_DIR"; else rm -rf "$STATE_DIR"; fi
        log OK "Служебный state очищен."
        pause
        ;;
      8)
        if (( DRY_RUN )); then log INFO "[dry-run] rm $MANAGED_UNATTENDED_FILE $MANAGED_AUTO_FILE"; else rm -f "$MANAGED_UNATTENDED_FILE" "$MANAGED_AUTO_FILE"; fi
        log OK "unattended-upgrades drop-in удалён."
        pause
        ;;
      9)
        rollback_ssh || true
        rollback_dns || true
        rollback_bbr || true
        if (( ! DRY_RUN )); then
          rm -f "$MANAGED_IPV6_FILE" "$MANAGED_UNATTENDED_FILE" "$MANAGED_AUTO_FILE"
          sysctl --system >>"$LOG_FILE" 2>&1 || true
        fi
        run_cmd ufw disable || true
        log OK "Полный откат управляемых настроек выполнен."
        pause
        ;;
      0) return 0 ;;
      *) echo "Неверный пункт."; pause ;;
    esac
  done
}

cleanup_node_interactive() {
  clear_screen
  echo "ВНИМАНИЕ: этот раздел удаляет все Docker-контейнеры, volumes, образы,"
  echo "временные файлы и каталоги /opt/remnawave /opt/remnanode."
  echo "Операция разрушительная и не подлежит откату."
  confirm "Продолжить?" || return 0
  confirm "Точно продолжить?" || return 0

  if command -v docker >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      log INFO "[dry-run] docker rm -f (все контейнеры)"
      log INFO "[dry-run] docker system prune -af --volumes"
    elif docker info >/dev/null 2>&1; then
      local containers=()
      mapfile -t containers < <(docker ps -aq 2>/dev/null || true)
      if (( ${#containers[@]} > 0 )); then
        docker rm -f "${containers[@]}" >>"$LOG_FILE" 2>&1 || true
      fi
      docker system prune -af --volumes >>"$LOG_FILE" 2>&1 || true
    else
      log WARN "Docker установлен, но демон не отвечает. Пропускаю."
    fi
  fi

  local dir
  for dir in /opt/remnawave /opt/remnanode; do
    [[ -n "$dir" && "$dir" != "/" ]] || continue
    if (( DRY_RUN )); then
      log INFO "[dry-run] rm -rf $dir"
    else
      rm -rf --one-file-system -- "$dir" 2>/dev/null || rm -rf -- "$dir" 2>/dev/null || true
    fi
  done

  if (( DRY_RUN )); then
    log INFO "[dry-run] rotate journal, clean old logs, clean /tmp safely"
  else
    if command -v journalctl >/dev/null 2>&1; then
      journalctl --rotate >>"$LOG_FILE" 2>&1 || true
      journalctl --vacuum-time=7d >>"$LOG_FILE" 2>&1 || true
    fi
    find /var/log -xdev -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.[0-9].gz' -o -name '*.old' \) -delete 2>/dev/null || true
    find /tmp -mindepth 1 -xdev ! -path '/tmp/.X11-unix*' ! -path '/tmp/.ICE-unix*' ! -path '/tmp/systemd-private-*' ! -path '/tmp/snap-private-tmp*' -exec rm -rf -- {} + 2>/dev/null || true
    find /var/tmp -mindepth 1 -xdev ! -path '/var/tmp/systemd-private-*' -exec rm -rf -- {} + 2>/dev/null || true
    apt-get clean >>"$LOG_FILE" 2>&1 || true
    apt-get autoremove --purge -y >>"$LOG_FILE" 2>&1 || true
  fi
  log OK "Очистка завершена."
  pause
}

quick_start_menu() {
  clear_screen
  echo
  echo "Быстрая первичная настройка выполнит по шагам:"
  echo "- обновление пакетов"
  echo "- установку рекомендуемых программ"
  echo "- создание пользователя"
  echo "- настройку SSH"
  echo "- настройку UFW"
  echo "- установку Fail2Ban"
  echo "- настройки DNS, часового пояса, BBR, IPv6"
  echo "- установку Docker"
  echo
  echo "Режим root по SSH НЕ будет ограничен автоматически."
  confirm "Продолжить?" || return 0

  confirm "Обновить систему сейчас?"                    && { run_cmd apt-get update || true; DEBIAN_FRONTEND=noninteractive run_cmd apt-get upgrade -y || true; }
  confirm "Установить рекомендуемые пакеты?"            && install_or_update_recommended "" || true
  confirm "Создать нового пользователя?"                && create_user_interactive || true
  confirm "Настроить SSH (порт/пароль/root)?"           && configure_ssh_interactive || true
  confirm "Включить UFW и пропустить текущий SSH-порт?" && install_or_enable_ufw || true
  confirm "Установить и настроить Fail2Ban?"            && install_fail2ban_interactive || true
  confirm "Настроить DNS через systemd-resolved?"       && configure_dns_interactive || true
  confirm "Настроить часовой пояс?"                     && configure_timezone_interactive || true
  confirm "Включить BBR?"                               && configure_bbr_interactive || true
  confirm "Настроить IPv6 (вкл/выкл)?"                  && configure_ipv6_interactive || true
  confirm "Установить Docker?"                          && install_docker_interactive || true
  log OK "Быстрая первичная настройка завершена."
  pause
}

main_menu() {
  while true; do
    clear_screen
    echo
    echo "========== ${APP_NAME} =========="
    echo "ОС: ${OS_PRETTY_NAME}"
    echo "--------------------------------"
    echo "1)  Быстрая первичная настройка"
    echo "2)  Обновления и пакеты"
    echo "3)  Пользователи и SSH-ключи"
    echo "4)  SSH и доступ"
    echo "5)  Фаервол и защита"
    echo "6)  Сеть, DNS, время и ядро"
    echo "7)  Docker"
    echo "8)  Автообновления безопасности"
    echo "9)  Информация о системе"
    echo "10) Откат и удаление настроек"
    echo "11) Очистка ноды"
    echo "0)  Выход"
    read -r -p "> " choice </dev/tty
    case "$choice" in
      1) quick_start_menu ;;
      2) updates_menu ;;
      3) manage_users_menu ;;
      4) configure_ssh_interactive ;;
      5) firewall_menu ;;
      6) network_menu ;;
      7) docker_menu ;;
      8) configure_unattended_interactive ;;
      9) show_system_info ;;
      10) rollback_menu ;;
      11) cleanup_node_interactive ;;
      0) return 0 ;;
      *) echo "Неверный пункт."; pause ;;
    esac
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --self-test) SELF_TEST=1 ;;
      --non-interactive) NON_INTERACTIVE=1 ;;
      -h|--help)
        cat <<EOF5
${APP_NAME}

Опции:
  --dry-run          Показать, что было бы сделано, без применения изменений.
  --self-test        Выполнить встроенную самопроверку функций.
  --non-interactive  Не задавать подтверждений (использует значения по умолчанию).
  -h, --help         Показать эту справку.
EOF5
        exit 0
        ;;
      *) red "Неизвестный аргумент: $1"; exit 1 ;;
    esac
    shift
  done
}

check_os_supported() {
  case "$OS_ID" in
    ubuntu|debian) ;;
    *) log WARN "ОС ${OS_ID:-unknown} не заявлена в списке поддерживаемых. Возможны нюансы." ;;
  esac
}

main() {
  parse_args "$@"
  ensure_root
  load_os_release
  ensure_tty
  prepare_runtime
  check_os_supported
  if (( SELF_TEST )); then
    self_test
    return $?
  fi
  main_menu
  log OK "Работа завершена."
}

main "$@"
