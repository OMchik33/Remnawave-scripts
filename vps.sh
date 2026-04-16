#!/usr/bin/env bash
set -uo pipefail

APP_NAME="VPS Bootstrap"
APP_SLUG="vps-bootstrap"
STATE_DIR="/var/lib/${APP_SLUG}"
LOG_DIR="/var/log/${APP_SLUG}"
MANAGED_SSH_FILE="/etc/ssh/sshd_config.d/00-${APP_SLUG}.conf"
MANAGED_DNS_FILE="/etc/systemd/resolved.conf.d/90-${APP_SLUG}.conf"
MANAGED_BBR_FILE="/etc/sysctl.d/90-${APP_SLUG}-bbr.conf"
MANAGED_IPV6_FILE="/etc/sysctl.d/90-${APP_SLUG}-ipv6.conf"
MANAGED_MODULES_FILE="/etc/modules-load.d/${APP_SLUG}.conf"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/${RUN_ID}.log"
DRY_RUN=0
SELF_TEST=0

RECOMMENDED_PACKAGES=(dialog mc htop curl wget unzip nano jq git mtr-tiny ca-certificates gnupg lsb-release bash-completion ncdu iperf3)

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue() { printf '\033[36m%s\033[0m\n' "$*"; }

clear_screen() {
  if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then
    clear
  fi
}


log() {
  local level="$1"; shift
  mkdir -p "$LOG_DIR" >/dev/null 2>&1 || true
  printf '[%s] %s\n' "$level" "$*" >>"$LOG_FILE"
  case "$level" in
    OK) green "[$level] $*" ;;
    INFO) blue "[$level] $*" ;;
    WARN) yellow "[$level] $*" ;;
    ERR) red "[$level] $*" ;;
    *) echo "[$level] $*" ;;
  esac
}

pause() {
  echo
  read -r -p "Нажми Enter для продолжения..." _
}

ensure_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    red "Скрипт нужно запускать от root."
    exit 1
  fi
}

prepare_runtime() {
  mkdir -p "$STATE_DIR" "$LOG_DIR"
  : >"$LOG_FILE"
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
  mkdir -p "$(dirname "$file")"
  if (( DRY_RUN )); then
    log INFO "[dry-run] append line to ${file}: ${line}"
    return 0
  fi
  touch "$file"
  grep -Fxq "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >>"$file"
}

confirm() {
  local prompt="$1" ans
  while true; do
    read -r -p "$prompt [y/n]: " ans
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
    read -r -p "$prompt" value
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    echo "Поле не может быть пустым."
  done
}

prompt_default() {
  local prompt="$1" def="$2" value
  read -r -p "$prompt [$def]: " value
  printf '%s' "${value:-$def}"
}

is_valid_pubkey() {
  local key="$1"
  [[ "$key" =~ ^ssh-(rsa|ed25519|ecdsa)\ [A-Za-z0-9+/=]+(\ .*)?$ ]]
}

os_id() { . /etc/os-release && echo "$ID"; }
os_version() { . /etc/os-release && echo "$VERSION_ID"; }
os_codename() {
  . /etc/os-release
  if [[ -n "${VERSION_CODENAME:-}" ]]; then
    echo "$VERSION_CODENAME"
  else
    lsb_release -cs 2>/dev/null || true
  fi
}

track_created_user() {
  append_unique_line "$STATE_DIR/created_users.list" "$1"
}


track_key_for_user() {
  local username="$1" pubkey="$2"
  append_unique_line "$STATE_DIR/keys/${username}.list" "$pubkey"
}

list_regular_users() {
  while IFS=: read -r user _ uid _ _ home shell; do
    if [[ "$user" == "root" ]]; then
      printf '%s:%s:%s:%s\n' "$user" "0" "/root" "$(getent passwd root | cut -d: -f7)"
      continue
    fi
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    (( uid >= 1000 )) || continue
    [[ "$shell" == */nologin || "$shell" == */false ]] && continue
    printf '%s:%s:%s:%s\n' "$user" "$uid" "$home" "$shell"
  done < /etc/passwd
}

print_regular_users() {
  local found=0 user uid home shell sudo_state
  while IFS=: read -r user uid home shell; do
    found=1
    sudo_state="нет"
    if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx 'sudo'; then
      sudo_state="да"
    fi
    printf '%-16s | UID: %-5s | HOME: %-22s | SHELL: %-16s | sudo: %s\n' "$user" "$uid" "$home" "$shell" "$sudo_state"
  done < <(list_regular_users)
  (( found )) || echo "Обычные пользователи не найдены."
}

get_effective_ssh() {
  sshd -T 2>/dev/null | awk -v k="$1" '$1==k{print $2; exit}'
}

ssh_control_unit() {
  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx 'ssh.socket'; then
    echo "ssh.socket"
  elif systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx 'ssh.service'; then
    echo "ssh.service"
  elif systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx 'sshd.service'; then
    echo "sshd.service"
  else
    echo ""
  fi
}

restart_ssh() {
  local unit
  unit="$(ssh_control_unit)"
  [[ -n "$unit" ]] || { log ERR "Не удалось определить unit SSH."; return 1; }
  run_cmd systemctl daemon-reload || return 1
  run_cmd systemctl restart "$unit" || return 1
  if (( DRY_RUN )); then
    log OK "[dry-run] SSH был бы перезапущен через $unit."
    return 0
  fi
  if systemctl is-active --quiet "$unit"; then
    log OK "SSH успешно проверен и перезапущен через $unit."
    return 0
  fi
  log ERR "После перезапуска unit $unit не активен."
  return 1
}

has_any_admin_key() {
  if [[ -s /root/.ssh/authorized_keys ]]; then
    return 0
  fi
  local user home
  while IFS=: read -r user _ _ _ _ home shell; do
    [[ "$user" == root ]] && continue
    [[ "$home" == /home/* ]] || continue
    [[ "$shell" == */nologin || "$shell" == */false ]] && continue
    if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx 'sudo'; then
      [[ -s "$home/.ssh/authorized_keys" ]] && return 0
    fi
  done </etc/passwd
  return 1
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
  mkdir -p "$ssh_dir" || return 1
  touch "$auth_file" || return 1
  chmod 700 "$ssh_dir" || return 1
  chmod 600 "$auth_file" || return 1
  grep -Fxq "$pubkey" "$auth_file" 2>/dev/null || printf '%s\n' "$pubkey" >>"$auth_file"
  chown -R "$owner" "$ssh_dir" || return 1
  append_unique_line "$STATE_DIR/keys/${username}.list" "$pubkey"
  log OK "Ключ добавлен пользователю ${username}."
}

show_windows_key_help() {
  clear_screen
  cat <<'TXT'
Современная команда для генерации SSH-ключа в Windows 10/11:

  ssh-keygen -t ed25519 -C "my-vps"

Обычно файлы будут тут:
  Публичный ключ: C:\Users\ИМЯ\.ssh\id_ed25519.pub
  Приватный ключ: C:\Users\ИМЯ\.ssh\id_ed25519

На сервер вставляется только содержимое файла .pub.
TXT
  pause
}

show_system_info() {
  clear_screen
  local os kernel host tz uptime_txt ip4 pub4 ssh_port ssh_pass ssh_root ufw_state f2b_state docker_state
  os="$(. /etc/os-release; echo "${PRETTY_NAME:-$ID $VERSION_ID}")"
  kernel="$(uname -r)"
  host="$(hostname)"
  tz="$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo 'неизвестно')"
  uptime_txt="$(uptime -p 2>/dev/null || uptime)"
  ip4="$(hostname -I 2>/dev/null | awk '{print $1}')"
  pub4="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo 'не удалось определить')"
  ssh_port="$(get_effective_ssh port || true)"
  ssh_pass="$(get_effective_ssh passwordauthentication || true)"
  ssh_root="$(get_effective_ssh permitrootlogin || true)"
  ufw_state="$(ufw status 2>/dev/null | head -n1 || echo 'ufw не установлен')"
  f2b_state="$(systemctl is-active fail2ban 2>/dev/null || echo 'not-installed/inactive')"
  docker_state="$(systemctl is-active docker 2>/dev/null || echo 'not-installed/inactive')"

  echo
  echo "========== Информация о системе =========="
  echo "ОС:                $os"
  echo "Ядро:              $kernel"
  echo "Хост:              $host"
  echo "Часовой пояс:      $tz"
  echo "Uptime:            $uptime_txt"
  echo "Локальный IP:      ${ip4:-неизвестно}"
  echo "Публичный IP:      $pub4"
  echo "SSH порт:          ${ssh_port:-неизвестно}"
  echo "SSH пароль:        ${ssh_pass:-неизвестно}"
  echo "Root login:        ${ssh_root:-неизвестно}"
  echo "UFW:               $ufw_state"
  echo "Fail2Ban:          $f2b_state"
  echo "Docker:            $docker_state"
  echo "Лог запуска:       $LOG_FILE"
  echo "=========================================="
  echo
  echo "Пользователи сервера:"
  print_regular_users
  echo "=========================================="
  pause
}

self_test() {
  local errors=0
  local funcs=(track_key_for_user list_regular_users print_regular_users create_user_interactive delete_user_interactive add_key_interactive set_password_interactive change_sudo_mode_interactive configure_ssh_interactive configure_dns_interactive configure_bbr_interactive configure_ipv6_interactive install_docker_interactive configure_unattended_interactive show_system_info rollback_menu cleanup_node_interactive)
  for f in "${funcs[@]}"; do
    declare -F "$f" >/dev/null || { echo "Отсутствует функция: $f"; ((errors++)); }
  done
  [[ -f /etc/os-release ]] || { echo "Нет /etc/os-release"; ((errors++)); }
  [[ -n "$(ssh_control_unit)" ]] || echo "Предупреждение: SSH unit не определён"
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
    # shellcheck disable=SC2206
    packages+=( $extra )
  fi
  run_cmd apt-get update || return 1
  run_cmd apt-get install -y "${packages[@]}" || return 1
  log OK "Рекомендуемые пакеты обработаны."
}

updates_menu() {
  while true; do
    clear_screen
    echo
    echo "===== Обновления и пакеты ====="
    echo "1) apt update"
    echo "2) apt upgrade -y"
    echo "3) apt full-upgrade -y"
    echo "4) autoremove --purge и autoclean"
    echo "5) Установить / обновить рекомендуемые пакеты"
    echo "6) Обновить Ubuntu до следующего релиза"
    echo "0) Назад"
    read -r -p "> " choice
    case "$choice" in
      1) run_cmd apt-get update; pause ;;
      2) run_cmd apt-get update && run_cmd apt-get upgrade -y; pause ;;
      3) run_cmd apt-get update && run_cmd apt-get full-upgrade -y; pause ;;
      4) run_cmd apt-get autoremove --purge -y && run_cmd apt-get autoclean -y; pause ;;
      5)
        echo "Базовый список: ${RECOMMENDED_PACKAGES[*]}"
        read -r -p "Дополнительные пакеты через пробел (или Enter): " extra
        install_or_update_recommended "$extra"
        pause
        ;;
      6)
        if [[ "$(os_id)" != "ubuntu" ]]; then
          log WARN "Release upgrade доступен только для Ubuntu."
        else
          echo "Внимание: переход на новый релиз — это отдельная и потенциально рискованная операция."
          echo "Для серверов чаще предпочтительнее LTS-релизы."
          if confirm "Продолжить к do-release-upgrade?"; then
            run_cmd apt-get update && run_cmd apt-get full-upgrade -y
            run_cmd do-release-upgrade
          fi
        fi
        pause
        ;;
      0) return 0 ;;
      *) echo "Неверный пункт." ;;
    esac
  done
}

create_user_interactive() {
  clear_screen
  local username sudo_mode key_mode pubkey pass1 pass2 rootkeys_file sudoers
  username="$(prompt_nonempty 'Введите имя нового пользователя: ')"
  [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || { log ERR "Некорректное имя пользователя."; pause; return 1; }
  if getent passwd "$username" >/dev/null 2>&1; then
    log ERR "Пользователь '$username' уже существует."
    pause
    return 1
  fi

  echo "Режим sudo:"
  echo "1) Без sudo"
  echo "2) Обычный sudo (понадобится пароль пользователя)"
  echo "3) Sudo без пароля (NOPASSWD)"
  read -r -p "> " sudo_mode

  echo "Как добавить SSH-ключ?"
  echo "1) Вставить новый публичный ключ"
  echo "2) Скопировать все ключи root"
  echo "3) Пока не добавлять ключ"
  read -r -p "> " key_mode

  if [[ "$sudo_mode" == "2" ]]; then
    read -r -s -p "Задай пароль для нового пользователя: " pass1; echo
    read -r -s -p "Повтори пароль: " pass2; echo
    [[ "$pass1" == "$pass2" ]] || { log ERR "Пароли не совпадают."; pause; return 1; }
  fi

  case "$key_mode" in
    1)
      pubkey="$(prompt_nonempty 'Вставь строку публичного SSH-ключа (.pub): ')"
      is_valid_pubkey "$pubkey" || { log ERR "Строка не похожа на корректный публичный SSH-ключ."; pause; return 1; }
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
      visudo -cf "$sudoers" >>"$LOG_FILE" 2>&1 || { log ERR "Файл sudoers не прошёл проверку."; pause; return 1; }
    fi
  fi

  if [[ "$sudo_mode" == "2" ]]; then
    if (( DRY_RUN )); then
      log INFO "[dry-run] set password for $username"
    else
      printf '%s:%s\n' "$username" "$pass1" | chpasswd >>"$LOG_FILE" 2>&1 || { log ERR "Не удалось задать пароль пользователю."; pause; return 1; }
    fi
  fi

  case "$key_mode" in
    1)
      add_public_key_to_user "$username" "$pubkey" || { pause; return 1; }
      ;;
    2)
      while IFS= read -r pubkey; do
        [[ -n "$pubkey" ]] || continue
        add_public_key_to_user "$username" "$pubkey" || { pause; return 1; }
      done < "$rootkeys_file"
      ;;
    3) ;;
  esac

  log OK "Пользователь $username создан."
  pause
}

delete_user_interactive() {
  clear_screen
  local username mode
  echo "Доступные обычные пользователи:"
  print_regular_users
  echo
  username="$(prompt_nonempty 'Введите имя пользователя для удаления: ')"
  if ! getent passwd "$username" >/dev/null 2>&1; then
    log ERR "Пользователь '$username' не найден."
    pause
    return 1
  fi
  echo "1) Удалить пользователя без домашней директории"
  echo "2) Удалить пользователя вместе с домашней директорией (-r)"
  read -r -p "> " mode
  if [[ "$username" == "root" ]]; then
    log ERR "Пользователя root удалять нельзя."
    pause
    return 1
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
  username="$(prompt_nonempty 'Кому добавить ключ (имя пользователя или root): ')"
  getent passwd "$username" >/dev/null 2>&1 || [[ "$username" == root ]] || { log ERR "Пользователь не найден."; pause; return 1; }
  echo "1) Вставить новый публичный ключ"
  echo "2) Скопировать все ключи root"
  read -r -p "> " mode
  case "$mode" in
    1)
      pubkey="$(prompt_nonempty 'Вставь строку публичного SSH-ключа (.pub): ')"
      is_valid_pubkey "$pubkey" || { log ERR "Некорректный публичный SSH-ключ."; pause; return 1; }
      add_public_key_to_user "$username" "$pubkey"
      ;;
    2)
      src="/root/.ssh/authorized_keys"
      [[ -s "$src" ]] || { log ERR "У root нет ключей для копирования."; pause; return 1; }
      while IFS= read -r pubkey; do
        [[ -n "$pubkey" ]] || continue
        add_public_key_to_user "$username" "$pubkey" || { pause; return 1; }
      done < "$src"
      ;;
    *) log ERR "Неверный вариант." ;;
  esac
  pause
}

set_password_interactive() {
  clear_screen
  local username pass1 pass2
  username="$(prompt_nonempty 'Введите имя пользователя (или root): ')"
  getent passwd "$username" >/dev/null 2>&1 || [[ "$username" == root ]] || { log ERR "Пользователь не найден."; pause; return 1; }
  read -r -s -p "Новый пароль: " pass1; echo
  read -r -s -p "Повтори пароль: " pass2; echo
  [[ "$pass1" == "$pass2" ]] || { log ERR "Пароли не совпадают."; pause; return 1; }
  if (( DRY_RUN )); then
    log INFO "[dry-run] set password for $username"
  else
    printf '%s:%s\n' "$username" "$pass1" | chpasswd >>"$LOG_FILE" 2>&1 || { log ERR "Не удалось изменить пароль."; pause; return 1; }
  fi
  log OK "Пароль пользователя $username обновлён."
  pause
}

change_sudo_mode_interactive() {
  clear_screen
  local username mode sudoers
  username="$(prompt_nonempty 'Введите имя пользователя: ')"
  getent passwd "$username" >/dev/null 2>&1 || { log ERR "Пользователь не найден."; pause; return 1; }
  sudoers="/etc/sudoers.d/90-${APP_SLUG}-${username}"
  echo "1) Без sudo"
  echo "2) Обычный sudo"
  echo "3) Sudo без пароля (NOPASSWD)"
  read -r -p "> " mode
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
        visudo -cf "$sudoers" >>"$LOG_FILE" 2>&1 || { log ERR "Файл sudoers не прошёл проверку."; pause; return 1; }
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
    echo "1) Создать нового пользователя"
    echo "2) Удалить пользователя"
    echo "3) Добавить SSH-ключ пользователю/root"
    echo "4) Задать или сменить пароль"
    echo "5) Изменить режим sudo"
    echo "6) Краткая инструкция по ключу для Windows"
    echo "0) Назад"
    read -r -p "> " choice
    case "$choice" in
      1) create_user_interactive ;;
      2) delete_user_interactive ;;
      3) add_key_interactive ;;
      4) set_password_interactive ;;
      5) change_sudo_mode_interactive ;;
      6) show_windows_key_help ;;
      0) return 0 ;;
      *) echo "Неверный пункт." ;;
    esac
  done
}

configure_ssh_interactive() {
  clear_screen
  local port pass_auth root_login current_root_login temp root_change_choice
  port="$(prompt_default 'SSH порт' "$(get_effective_ssh port 2>/dev/null || echo 22)")"
  [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || { log ERR "Некорректный порт."; pause; return 1; }

  echo "Разрешить вход по паролю?"
  echo "1) Да"
  echo "2) Нет"
  read -r -p "> " temp
  case "$temp" in
    1) pass_auth="yes" ;;
    2) pass_auth="no" ;;
    *) log ERR "Неверный вариант."; pause; return 1 ;;
  esac

  current_root_login="$(get_effective_ssh permitrootlogin 2>/dev/null || true)"
  [[ -n "$current_root_login" ]] || current_root_login="yes"

  echo
  echo "Настройка доступа root по SSH:"
  echo "- создание нового пользователя само по себе НЕ меняет доступ root"
  echo "- режим root изменится только если ты явно выберешь это ниже"
  echo "- сначала лучше проверить вход под новым пользователем в отдельной сессии"
  echo
  echo "1) Не менять текущий режим root (${current_root_login})"
  echo "2) yes — root может входить по паролю и по ключу"
  echo "3) prohibit-password — root только по ключу"
  echo "4) no — root login полностью запрещён"
  read -r -p "> " root_change_choice
  case "$root_change_choice" in
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

  if [[ "$root_login" == "no" || "$root_login" == "prohibit-password" ]]; then
    echo
    echo "Важно:"
    echo "- не закрывай текущую root-сессию, пока не проверишь новый вход"
    echo "- сначала проверь вход под новым пользователем в отдельной сессии"
    echo "- только после этого оставляй ограничение для root"
    confirm "Применить этот режим для root?" || { log WARN "Изменение режима root отменено пользователем. Оставляю текущий режим: ${current_root_login}."; root_login="$current_root_login"; }
  fi

  if (( DRY_RUN )); then
    log INFO "[dry-run] write $MANAGED_SSH_FILE"
    log INFO "[dry-run] validate sshd config"
    log INFO "[dry-run] restart SSH"
    pause
    return 0
  fi

  mkdir -p /etc/ssh/sshd_config.d || { log ERR "Не удалось создать /etc/ssh/sshd_config.d"; pause; return 1; }
  cat >"$MANAGED_SSH_FILE" <<EOFSSH
# Управляется ${APP_NAME}
Port ${port}
PubkeyAuthentication yes
PasswordAuthentication ${pass_auth}
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin ${root_login}
UsePAM yes
EOFSSH

  sshd -t >>"$LOG_FILE" 2>&1 || { log ERR "sshd -t не прошёл. Конфиг не применён."; pause; return 1; }
  restart_ssh || { pause; return 1; }
  log OK "SSH-настройки применены. Новый порт: ${port}. Режим root: ${root_login}."
  pause
}

rollback_ssh() {
  if (( DRY_RUN )); then
    log INFO "[dry-run] remove $MANAGED_SSH_FILE and restart SSH"
    return 0
  fi
  rm -f "$MANAGED_SSH_FILE"
  sshd -t >>"$LOG_FILE" 2>&1 || { log ERR "После удаления SSH drop-in проверка sshd -t не прошла."; return 1; }
  restart_ssh
}

install_or_enable_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    run_cmd apt-get update || return 1
    run_cmd apt-get install -y ufw || return 1
  fi
  local port
  port="$(get_effective_ssh port 2>/dev/null || echo 22)"
  run_cmd ufw allow "${port}/tcp" || return 1
  if command -v ufw >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      log INFO "[dry-run] ufw enable"
    else
      yes | ufw enable >>"$LOG_FILE" 2>&1 || true
    fi
  fi
  log OK "UFW настроен. Разрешён SSH порт ${port}/tcp."
}

apply_ufw_limit() {
  local port
  port="$(get_effective_ssh port 2>/dev/null || echo 22)"
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
    drop) sed -i '/-A ufw-before-input -p icmp --icmp-type echo-request/s/ACCEPT/DROP/' "$file" ;;
    accept) sed -i '/-A ufw-before-input -p icmp --icmp-type echo-request/s/DROP/ACCEPT/' "$file" ;;
    *) return 1 ;;
  esac
  ufw reload >>"$LOG_FILE" 2>&1 || true
}

install_fail2ban_interactive() {
  local backend="auto" logpath="" ssh_port jail_file
  ssh_port="$(get_effective_ssh port 2>/dev/null || echo 22)"
  run_cmd apt-get update || return 1
  run_cmd apt-get install -y fail2ban || return 1
  if [[ -f /var/log/auth.log ]]; then
    logpath="/var/log/auth.log"
    backend="auto"
  else
    backend="systemd"
  fi
  jail_file="/etc/fail2ban/jail.d/sshd.local"
  if (( DRY_RUN )); then
    log INFO "[dry-run] write $jail_file"
  else
    mkdir -p /etc/fail2ban/jail.d
    cat >"$jail_file" <<EOFF2B
[sshd]
enabled = true
port = ${ssh_port}
backend = ${backend}
maxretry = 5
findtime = 10m
bantime = 12h
EOFF2B
    if [[ -n "$logpath" ]]; then
      printf 'logpath = %s\n' "$logpath" >>"$jail_file"
    fi
  fi
  run_cmd systemctl enable fail2ban || return 1
  run_cmd systemctl restart fail2ban || return 1
  log OK "Fail2Ban настроен для SSH."
}

remove_fail2ban_interactive() {
  if confirm "Удалить fail2ban полностью?"; then
    run_cmd systemctl disable --now fail2ban || true
    run_cmd apt-get purge -y fail2ban || true
    run_cmd apt-get autoremove --purge -y || true
    log OK "Fail2Ban удалён."
  fi
}

firewall_menu() {
  while true; do
    clear_screen
    echo
    echo "===== Фаервол и защита ====="
    echo "1) Установить / включить UFW и разрешить текущий SSH-порт"
    echo "2) Включить ufw limit для SSH"
    echo "3) Отключить ответы на ICMP ping"
    echo "4) Включить ответы на ICMP ping"
    echo "5) Установить / настроить Fail2Ban для SSH"
    echo "6) Удалить Fail2Ban"
    echo "7) Отключить UFW"
    echo "0) Назад"
    read -r -p "> " choice
    case "$choice" in
      1) install_or_enable_ufw; pause ;;
      2) apply_ufw_limit; pause ;;
      3) toggle_icmp drop && log OK "ICMP ping отключён."; pause ;;
      4) toggle_icmp accept && log OK "ICMP ping включён."; pause ;;
      5) install_fail2ban_interactive; pause ;;
      6) remove_fail2ban_interactive; pause ;;
      7) run_cmd ufw disable; pause ;;
      0) return 0 ;;
      *) echo "Неверный пункт." ;;
    esac
  done
}

configure_dns_interactive() {
  clear_screen
  local dns fallback
  systemctl list-unit-files | awk '{print $1}' | grep -qx 'systemd-resolved.service' || { log ERR "systemd-resolved не найден."; pause; return 1; }
  dns="$(prompt_nonempty 'Основные DNS через пробел: ')"
  read -r -p "Fallback DNS через пробел (можно пусто): " fallback
  if (( DRY_RUN )); then
    log INFO "[dry-run] write $MANAGED_DNS_FILE"
  else
    mkdir -p /etc/systemd/resolved.conf.d || { log ERR "Не удалось создать каталог resolved.conf.d"; pause; return 1; }
    {
      echo '[Resolve]'
      echo "DNS=${dns}"
      [[ -n "$fallback" ]] && echo "FallbackDNS=${fallback}"
    } >"$MANAGED_DNS_FILE"
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

configure_timezone_interactive() {
  clear_screen
  local current tz
  current="$(timedatectl show --property=Timezone --value 2>/dev/null || echo 'неизвестно')"
  echo "Текущий часовой пояс: $current"
  echo "1) Europe/Berlin"
  echo "2) Europe/Moscow"
  echo "3) UTC"
  echo "4) Ввести вручную"
  read -r -p "> " choice
  case "$choice" in
    1) tz="Europe/Berlin" ;;
    2) tz="Europe/Moscow" ;;
    3) tz="UTC" ;;
    4) tz="$(prompt_nonempty 'Введи timezone (например Europe/Berlin): ')" ;;
    *) log ERR "Неверный вариант."; pause; return 1 ;;
  esac
  timedatectl list-timezones 2>/dev/null | grep -Fxq "$tz" || { log ERR "Timezone '$tz' не найден."; pause; return 1; }
  run_cmd timedatectl set-timezone "$tz" || return 1
  log OK "Часовой пояс установлен: $tz"
  pause
}

configure_bbr_interactive() {
  clear_screen
  if ! modinfo tcp_bbr >/dev/null 2>&1; then
    log ERR "Модуль tcp_bbr не найден в системе."
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
  modprobe tcp_bbr >>"$LOG_FILE" 2>&1 || { log ERR "Не удалось загрузить модуль tcp_bbr."; pause; return 1; }
  if ! sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    log ERR "Алгоритм bbr не найден даже после загрузки модуля tcp_bbr."
    pause
    return 1
  fi
  printf 'tcp_bbr\n' >"$MANAGED_MODULES_FILE"
  cat >"$MANAGED_BBR_FILE" <<EOFBBR
# Управляется ${APP_NAME}
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOFBBR
  sysctl -p "$MANAGED_BBR_FILE" >>"$LOG_FILE" 2>&1 || { log ERR "Не удалось применить BBR через sysctl."; pause; return 1; }
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
  echo "1) Отключить IPv6"
  echo "2) Включить IPv6 обратно"
  read -r -p "> " choice
  case "$choice" in
    1)
      if (( DRY_RUN )); then
        log INFO "[dry-run] write $MANAGED_IPV6_FILE"
      else
        cat >"$MANAGED_IPV6_FILE" <<EOFIPV6
# Управляется ${APP_NAME}
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOFIPV6
        sysctl -p "$MANAGED_IPV6_FILE" >>"$LOG_FILE" 2>&1 || { log ERR "Не удалось отключить IPv6."; pause; return 1; }
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
    echo "1) Настроить DNS через systemd-resolved"
    echo "2) Настроить timezone"
    echo "3) Включить BBR"
    echo "4) Включить/выключить IPv6"
    echo "0) Назад"
    read -r -p "> " choice
    case "$choice" in
      1) configure_dns_interactive ;;
      2) configure_timezone_interactive ;;
      3) configure_bbr_interactive ;;
      4) configure_ipv6_interactive ;;
      0) return 0 ;;
      *) echo "Неверный пункт." ;;
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
  run_cmd apt-get remove -y docker docker-engine docker.io containerd runc docker-compose docker-compose-v2 docker-doc podman-docker containerd.io || true
  run_cmd apt-get update || return 1
  run_cmd apt-get install -y ca-certificates curl gnupg lsb-release || return 1
  keyring="/etc/apt/keyrings/docker.gpg"
  repo_url="https://download.docker.com/linux/${id}"
  if (( DRY_RUN )); then
    log INFO "[dry-run] install Docker repo for ${id} ${codename}"
  else
    install -m 0755 -d /etc/apt/keyrings || return 1
    curl -fsSL "${repo_url}/gpg" | gpg --dearmor -o "$keyring" >>"$LOG_FILE" 2>&1 || { log ERR "Не удалось скачать GPG-ключ Docker."; pause; return 1; }
    chmod a+r "$keyring" || return 1
    echo "deb [arch=${arch} signed-by=${keyring}] ${repo_url} ${codename} stable" >/etc/apt/sources.list.d/docker.list
  fi
  run_cmd apt-get update || return 1
  run_cmd apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
  run_cmd systemctl enable --now docker || true
  log OK "Docker установлен. Используй 'docker compose'."
  pause
}

add_user_to_docker_group() {
  clear_screen
  local username
  username="$(prompt_nonempty 'Какого пользователя добавить в группу docker: ')"
  getent passwd "$username" >/dev/null 2>&1 || { log ERR "Пользователь не найден."; pause; return 1; }
  run_cmd usermod -aG docker "$username" || return 1
  log OK "Пользователь $username добавлен в группу docker. Для новой сессии нужно перелогиниться."
  pause
}

docker_menu() {
  while true; do
    clear_screen
    echo
    echo "===== Docker ====="
    echo "1) Установить Docker из официального репозитория"
    echo "2) Добавить пользователя в группу docker"
    echo "0) Назад"
    read -r -p "> " choice
    case "$choice" in
      1) install_docker_interactive ;;
      2) add_user_to_docker_group ;;
      0) return 0 ;;
      *) echo "Неверный пункт." ;;
    esac
  done
}

configure_unattended_interactive() {
  clear_screen
  local auto_file="/etc/apt/apt.conf.d/20auto-upgrades"
  local unattended_file="/etc/apt/apt.conf.d/50unattended-upgrades"
  echo "1) Включить только security updates"
  echo "2) Включить security updates и обычные updates"
  echo "3) Отключить автоматические обновления"
  read -r -p "> " choice
  case "$choice" in
    1|2)
      run_cmd apt-get update || return 1
      run_cmd apt-get install -y unattended-upgrades || return 1
      if (( DRY_RUN )); then
        log INFO "[dry-run] write $auto_file and $unattended_file"
      else
        cat >"$auto_file" <<'EOFAUTO'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOFAUTO
        if [[ "$choice" == "1" ]]; then
          sed -i '/-updates/d' "$unattended_file" 2>/dev/null || true
        else
          grep -q '"\${distro_id}:\${distro_codename}-updates"' "$unattended_file" 2>/dev/null || \
            sed -i '/Allowed-Origins {/a\t"${distro_id}:${distro_codename}-updates";' "$unattended_file"
        fi
      fi
      log OK "Автоматические обновления настроены."
      ;;
    3)
      if (( DRY_RUN )); then
        log INFO "[dry-run] disable unattended-upgrades"
      else
        cat >"$auto_file" <<'EOFAUTO'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOFAUTO
      fi
      log OK "Автоматические обновления отключены."
      ;;
    *) log ERR "Неверный вариант." ;;
  esac
  pause
}

show_status() {
  show_system_info
}

rollback_menu() {
  while true; do
    clear_screen
    echo
    echo "===== Откат и удаление настроек ====="
    echo "1) Удалить управляемые SSH-настройки"
    echo "2) Удалить управляемые DNS-настройки"
    echo "3) Откатить BBR"
    echo "4) Откатить IPv6-настройки"
    echo "5) Отключить UFW"
    echo "6) Удалить Fail2Ban"
    echo "7) Очистить служебный state скрипта"
    echo "8) Выполнить полный откат управляемых настроек"
    echo "0) Назад"
    read -r -p "> " choice
    case "$choice" in
      1) rollback_ssh; pause ;;
      2) rollback_dns; pause ;;
      3) rollback_bbr; log OK "BBR откатан."; pause ;;
      4)
        if (( DRY_RUN )); then log INFO "[dry-run] remove $MANAGED_IPV6_FILE"; else rm -f "$MANAGED_IPV6_FILE"; fi
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
        rollback_ssh || true
        rollback_dns || true
        rollback_bbr || true
        if (( ! DRY_RUN )); then rm -f "$MANAGED_IPV6_FILE"; fi
        run_cmd ufw disable || true
        log OK "Полный откат управляемых настроек выполнен."
        pause
        ;;
      0) return 0 ;;
      *) echo "Неверный пункт." ;;
    esac
  done
}

cleanup_node_interactive() {
  clear_screen
  echo "Внимание: этот раздел удаляет все контейнеры Docker, volumes, образы, временные файлы и каталоги /opt/remnawave /opt/remnanode."
  confirm "Продолжить?" || return 0
  confirm "Точно продолжить? Действие разрушительное." || return 0

  if command -v docker >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      log INFO "[dry-run] docker rm -f \\$(docker ps -aq)"
      log INFO "[dry-run] docker system prune -af --volumes"
    elif docker info >/dev/null 2>&1; then
      local containers
      containers="$(docker ps -aq 2>/dev/null || true)"
      if [[ -n "${containers// }" ]]; then
        docker rm -f ${containers} >>"$LOG_FILE" 2>&1 || true
      fi
      docker system prune -af --volumes >>"$LOG_FILE" 2>&1 || true
    fi
  fi

  for dir in /opt/remnawave /opt/remnanode; do
    if (( DRY_RUN )); then
      log INFO "[dry-run] rm -rf $dir"
    else
      rm -rf --one-file-system "$dir" 2>/dev/null || true
    fi
  done

  if (( DRY_RUN )); then
    log INFO "[dry-run] cleanup logs and temp files"
  else
    command -v journalctl >/dev/null 2>&1 && { journalctl --rotate || true; journalctl --vacuum-time=7d || true; }
    find /var/log -xdev -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.[0-9].gz' -o -name '*.old' \) -delete 2>/dev/null || true
    find /tmp -mindepth 1 -xdev -exec rm -rf -- {} + 2>/dev/null || true
    find /var/tmp -mindepth 1 -xdev -exec rm -rf -- {} + 2>/dev/null || true
    apt-get clean >>"$LOG_FILE" 2>&1 || true
    apt-get autoremove --purge -y >>"$LOG_FILE" 2>&1 || true
  fi
  log OK "Очистка завершена."
  pause
}

quick_start_menu() {
  clear_screen
  echo
  echo "Быстрая первичная настройка выполнит:"
  echo "- обновление пакетов"
  echo "- установку рекомендуемых программ"
  echo "- создание пользователя"
  echo "- настройку SSH"
  echo "- настройку UFW"
  echo "- установку Fail2Ban"
  echo "- настройки DNS, часового пояса, BBR и IPv6"
  echo "- установку Docker"
  echo "- root не будет ограничен автоматически: режим root по SSH спросится отдельно"
  confirm "Продолжить?" || return 0
  run_cmd apt-get update || true
  run_cmd apt-get upgrade -y || true
  install_or_update_recommended "" || true
  create_user_interactive || true
  configure_ssh_interactive || true
  install_or_enable_ufw || true
  install_fail2ban_interactive || true
  configure_dns_interactive || true
  configure_timezone_interactive || true
  configure_bbr_interactive || true
  configure_ipv6_interactive || true
  install_docker_interactive || true
}

main_menu() {
  while true; do
    clear_screen
    echo
    echo "========== ${APP_NAME} =========="
    echo "1) Быстрая первичная настройка"
    echo "2) Обновления и пакеты"
    echo "3) Пользователи и SSH-ключи"
    echo "4) SSH и доступ"
    echo "5) Фаервол и защита"
    echo "6) Сеть, DNS, время и ядро"
    echo "7) Docker"
    echo "8) Автообновления безопасности"
    echo "9) Информация о системе"
    echo "10) Откат и удаление настроек"
    echo "11) Очистка ноды"
    echo "0) Выход"
    read -r -p "> " choice
    case "$choice" in
      1) quick_start_menu ;;
      2) updates_menu ;;
      3) manage_users_menu ;;
      4) configure_ssh_interactive ;;
      5) firewall_menu ;;
      6) network_menu ;;
      7) docker_menu ;;
      8) configure_unattended_interactive ;;
      9) show_status ;;
      10) rollback_menu ;;
      11) cleanup_node_interactive ;;
      0) return 0 ;;
      *) echo "Неверный пункт." ;;
    esac
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --self-test) SELF_TEST=1 ;;
      -h|--help)
        cat <<EOFHELP
${APP_NAME}

Опции:
  --dry-run    Показать, что было бы сделано, без применения изменений.
  --self-test  Выполнить встроенную самопроверку функций.
EOFHELP
        exit 0
        ;;
      *) red "Неизвестный аргумент: $1"; exit 1 ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"
  ensure_root
  prepare_runtime
  if (( SELF_TEST )); then
    self_test
    return $?
  fi
  main_menu
  log OK "Работа завершена."
}

main "$@"
