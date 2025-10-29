# Remnawave-scripts


## remnanode_analyzer.sh

Подключается к контейнеру ноды, смотрит лог xray (последнюю 1000 записей), либо realtime

![image](https://github.com/user-attachments/assets/44b3e7c1-a577-4ead-a1c1-c169a7f4b12a)

Установка/Запуск

```
curl -L -o /root/remnanode_analyzer.sh https://raw.githubusercontent.com/OMchik33/Remnawave-scripts/refs/heads/main/remnanode_analyzer.sh && chmod +x /root/remnanode_analyzer.sh && bash /root/remnanode_analyzer.sh
```

## Установка Докера

```
curl -L -o /root/docker_install.sh https://raw.githubusercontent.com/OMchik33/Remnawave-scripts/refs/heads/main/docker_install.sh && chmod +x /root/docker_install.sh && bash /root/docker_install.sh
```


## remna-update-manager.sh

Можно запланировать одноразовое обновление контейнеров по Московскому времени c помощью **at**

Обновляются командой `cd /opt/remnawave && docker compose down && docker compose pull && docker compose up -d`

Лог запуска идет в телеграм чат через бот, указанные в /opt/remnawave/.env

![image](https://github.com/user-attachments/assets/0c33c20f-a120-456b-bdea-d7039c30e0be)


## Remnawave_backup.sh:

останавливает контейнеры, затем делает бэкап volumes БД и Редис, и затем запускает контейнеры

![image](https://github.com/user-attachments/assets/8f0c7183-56ab-4337-afad-0a785f1daae7)


## ssh.sh:

Скрипт для первичной настройки SSH на сервере.

Добавляет SSH ключ доступа (нужно вставить из буфера), настраивает SSH на работу только по ключам. Пользователя не меняет, работает из-под `root`

![image](https://github.com/user-attachments/assets/47ea81de-9c52-4021-b988-c6b83a2fca56)


Запуск скрипта:

```
curl -L -o /root/ssh.sh https://raw.githubusercontent.com/OMchik33/Remnawave-scripts/refs/heads/main/ssh.sh && chmod +x /root/ssh.sh && bash /root/ssh.sh
```
<img width="660" height="509" alt="image" src="https://github.com/user-attachments/assets/81f83fae-3d5c-4178-b5a8-490e5b685306" />

## fail2ban на ssh
Скрипт установит fail2ban и настроет его тюрьму на ssh, автоматически определяя источник логов - `journalctl` или `/var/log/auth.log`

```
curl -L -o /root/inst_fail2ban_ssh.sh https://raw.githubusercontent.com/OMchik33/Remnawave-scripts/refs/heads/main/inst_fail2ban_ssh.sh && chmod +x /root/inst_fail2ban_ssh.sh && bash /root/inst_fail2ban_ssh.sh
```
