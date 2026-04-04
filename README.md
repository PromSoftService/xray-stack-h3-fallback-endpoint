# Xray + Nginx + HTTP/3 (H3) + H2 fallback на Ubuntu 22.04

Это пошаговый мануал для развертывания связки:

- **Xray** как backend
- **Nginx** как reverse proxy
- **HTTP/3 (QUIC)** как основной современный транспорт для HTTPS
- **HTTP/2** как fallback
- **Let's Encrypt** для TLS-сертификата
- **Docker Compose** для запуска сервисов

> Ниже предполагается, что у тебя уже есть подготовленный проект со следующими файлами:
>
> - `.env.example`
> - `docker-compose.yml`
> - `init.sh`
> - `renew.sh`
> - `check-h3.sh`
> - `nginx/conf.d/bootstrap.conf.template`
> - `nginx/conf.d/default.conf.template`
> - `xray/config.json.template`
> - `site/index.html`

---

## 1. Что нужно подготовить заранее

До начала развертывания должны быть выполнены следующие условия.

### 1.1. VPS

Нужен сервер с:

- **Ubuntu 22.04**
- публичным IPv4-адресом
- root-доступом или пользователем с `sudo`

### 1.2. Домен

Нужен домен, который уже указывает на этот VPS.

Проверь это заранее:

```bash
ping your-domain.com
```

IP должен совпадать с адресом твоего сервера.

### 1.3. Открытые порты

На VPS должны быть доступны:

- `80/tcp`
- `443/tcp`
- `443/udp`

Если включен UFW:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 443/udp
sudo ufw status
```

### 1.4. Docker

Если Docker еще не установлен, установи его из официального репозитория.

Обновление системы и базовые пакеты:

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y ca-certificates curl gnupg lsb-release openssl unzip jq
```

Установка Docker Engine:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
```

```bash
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

```bash
cat > install-docker.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "==> remove old docker packages if present"
sudo apt remove -y docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc || true

echo "==> install dependencies"
sudo apt install -y ca-certificates curl

echo "==> prepare keyrings"
sudo install -m 0755 -d /etc/apt/keyrings

echo "==> remove old docker repo files"
sudo rm -f /etc/apt/sources.list.d/docker.list
sudo rm -f /etc/apt/sources.list.d/docker.sources
sudo rm -f /etc/apt/keyrings/docker.asc

echo "==> download docker gpg key"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
sudo chmod a+r /etc/apt/keyrings/docker.asc

ARCH="$(dpkg --print-architecture)"
. /etc/os-release
CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}"

echo "==> create docker.sources"
cat <<EOT | sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOT

echo "==> apt update"
sudo apt update

echo "==> install docker"
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> enable and start docker"
sudo systemctl enable docker
sudo systemctl start docker

echo "==> docker version"
docker --version
docker compose version

echo "==> done"
EOF
chmod +x install-docker.sh
./install-docker.sh
```

Проверка:

```bash
docker --version
docker compose version
```

Включение сервиса:

```bash
sudo systemctl enable docker
sudo systemctl start docker
sudo usermod -aG docker "$USER"
newgrp docker
```

Проверка:

```bash
sudo systemctl status docker --no-pager
systemctl is-enabled docker
```

---

## 2. Подготовка каталога проекта

Установи Git:

```bash
sudo apt update
sudo apt install -y git
```

Клонируй репозиторий:

```bash
git clone https://github.com/PromSoftService/xray-stack-h3-fallback-endpoint.git ~/xray-stack-h3-fallback-endpoint
cd ~/xray-stack-h3-fallback-endpoint
```

Ожидаемая структура:

```text
xray-stack-h3-fallback/
  .env.example
  docker-compose.yml
  init.sh
  renew.sh
  check-h3.sh
  nginx/
    conf.d/
      bootstrap.conf.template
      default.conf.template
  xray/
    config.json.template
  site/
    index.html
  certbot/
    www/
    conf/
```

Создай каталоги:

```bash
mkdir -p nginx/conf.d xray site certbot/www certbot/conf
```

---

## 3. Подготовка `.env`

Сгенерируй UUID:

```bash
cat /proc/sys/kernel/random/uuid
```

Создай рабочий `.env` на основе шаблона:

```bash
cp .env.example .env
nano .env
```

### Что обязательно заполнить

Проверь и задай:

- `DOMAIN` — твой домен
- `EMAIL` — email для Let's Encrypt
- `XRAY_UUID` — UUID клиента
- `XRAY_PATH` — секретный HTTP path
- `XRAY_PORT` — внутренний порт Xray

### Пример ключевых значений

```env
DOMAIN=your-domain.com
EMAIL=you@example.com
XRAY_UUID=11111111-2222-3333-4444-555555555555
XRAY_PATH=/secretxhttp
XRAY_PORT=10000
```

---

## 4. Подготовка скриптов

Сделай скрипты исполняемыми:

```bash
chmod +x init.sh renew.sh check-h3.sh
```

---

## 5. Что делают скрипты

В проекте теперь используются **3 основных скрипта**:

- `./init.sh` — основной сценарий развертывания
- `./renew.sh` — выпуск или продление сертификатов
- `./check-h3.sh` — глубокая диагностика

---

## 6. Первый запуск

для полного первого развертывания достаточно выполнить:

```bash
./init.sh
```

Что произойдет:

1. будут сгенерированы конфиги Xray и nginx
2. если сертификата нет, будет поднят bootstrap nginx по HTTP
3. будет автоматически вызван `./renew.sh issue`
4. будет выпущен сертификат Let's Encrypt
5. nginx будет переведен в боевой TLS/H3/H2 режим
6. весь стек будет запущен

То есть отдельная ручная команда `certbot certonly ...` больше не нужна.

---

## 7. Глубокая проверка после запуска

После `./init.sh` для полной runtime-проверки выполни:

```bash
./check-h3.sh
```

---

## 8. Ручной перевыпуск или продление сертификатов

Если нужно вручную заново заняться сертификатами, используй:

### Выпуск, если сертификата еще нет

```bash
./renew.sh issue
```

### Продление существующего сертификата

```bash
./renew.sh renew
```

После ручного продления рекомендуется снова привести стек в рабочее состояние:

```bash
./init.sh
```

И затем, при необходимости, выполнить глубокую диагностику:

```bash
./check-h3.sh
```

---

## 9. Рекомендуемый практический сценарий

### Первый запуск с нуля

```bash
chmod +x init.sh renew.sh check-h3.sh
./init.sh
./check-h3.sh
```

### Обычный повторный запуск после правок `.env` или шаблонов

```bash
./init.sh
```

### Глубокая диагностика

```bash
./check-h3.sh
```

### Ручное продление сертификатов

```bash
./renew.sh renew
./init.sh
```

---

## 10. Краткая логика использования

- `./init.sh` — **развернуть и запустить всё**
- `./renew.sh` — **заняться сертификатами**
- `./check-h3.sh` — **глубоко проверить и смотреть логи**


---

### 10.1. Проверка HTTPS

```bash
curl -I https://your-domain.com
```

### 10.2. Проверка HTTP/3

```bash
py .\check_h3.py https://your-domain.com
```

---

## 11. Что значит fallback в этой схеме

Здесь fallback — это не отдельная функция Xray.

Смысл такой:

- основной путь: `client -> UDP/443 -> QUIC -> nginx -> xray`
- запасной путь: `client -> TCP/443 -> TLS/H2 -> nginx -> xray`

То есть если HTTP/3 у клиента или в сети не работает, соединение всё равно может пройти через обычный HTTPS/HTTP2.

---

## 12. Обновление сертификатов

Для ручного продления предусмотрен скрипт:

```bash
./renew.sh
```

Рекомендуется добавить это в cron.

Пример cron-задачи:

```bash
crontab -e
```

И строка, например:

```cron
0 4 * * * cd /home/USERNAME/xray-stack-h3-fallback && ./renew.sh >> /var/log/xray-stack-renew.log 2>&1
```

Заменить `USERNAME` на имя пользователя.

---

