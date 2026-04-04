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

Или:

```bash
dig +short your-domain.com
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

Если раньше ставились конфликтующие docker-пакеты:

```bash
sudo apt remove -y docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc || true
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
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
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

Создай рабочий `.env` на основе шаблона:

```bash
cp .env.example .env
nano .env
```

### 3.1. Что обязательно заполнить

Сгенерируй UUID:

```bash
cat /proc/sys/kernel/random/uuid
```

Проверь и задай:

- `DOMAIN` — твой домен
- `EMAIL` — email для Let's Encrypt
- `XRAY_UUID` — UUID клиента
- `XRAY_PATH` — секретный HTTP path
- `XRAY_PORT` — внутренний порт Xray

```

### 3.2. Пример ключевых значений

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

## 5. Что делает `init.sh`

Скрипт выполняет две разные роли в зависимости от того, есть ли уже сертификат.

### Если сертификата еще нет

`init.sh`:

- проверяет `.env`
- генерирует конфиги
- включает **bootstrap-конфиг nginx только по HTTP**
- поднимает `xray` и `nginx`
- подготавливает сервер к выпуску сертификата через `certbot --webroot`

### Если сертификат уже есть

`init.sh`:

- генерирует полноценный TLS-конфиг
- включает:
  - HTTPS
  - HTTP/3
  - HTTP/2 fallback
- перезапускает сервисы в нужном состоянии

То есть `init.sh` можно безопасно запускать и **до**, и **после** выпуска сертификата.

---

## 6. Первый запуск

Запусти:

```bash
./init.sh
```

После этого должны стартовать контейнеры `xray` и `nginx` в bootstrap-режиме.

Проверь:

```bash
docker compose ps
sudo ss -ltnp | grep ':80'
sudo ss -ltnp | grep ':443'
sudo ss -lunp | grep ':443'
sudo ufw status
```

Если всё нормально, сайт по HTTP должен открываться, а `/.well-known/acme-challenge/` должен обслуживаться nginx.

Можно проверить так:

```bash
curl.exe -I http://your-domain.com
```

Обычно здесь будет редирект или HTTP-ответ bootstrap-конфига в зависимости от шаблона.

---

## 7. Выпуск сертификата Let's Encrypt

После первого запуска выпусти сертификат:

```bash
docker compose run --rm certbot certonly \
  --webroot -w /var/www/certbot \
  -d your-domain.com \
  --email you@example.com \
  --agree-tos \
  --no-eff-email
```

### Важно

Здесь:

- `your-domain.com` замени на свой домен
- `you@example.com` замени на свой email

Если сертификат выпустился успешно, файлы появятся в каталоге:

```bash
ls ./certbot/conf/live/your-domain.com/
```

Обычно там будут:

```
- `fullchain.pem`
- `privkey.pem`
```

---

## 8. Переключение в боевой режим HTTPS + H3 + H2

После успешного выпуска сертификата **еще раз** запусти:

```bash
./init.sh
```

Теперь скрипт увидит готовый сертификат и переключит nginx на полноценный конфиг:

- `443/tcp` для HTTPS/H2
- `443/udp` для HTTP/3/QUIC
- proxy до Xray

Проверь, что контейнеры подняты:

```bash
docker compose ps
```

Если всё нормально, сайт по HTTPS должен открываться.

Можно проверить так:

```bash
curl.exe -I https://your-domain.com
```

Проверить H3:

```bash
py .\check_h3.py https://your-domain.com
```

---

## 9. Полная проверка

Запусти встроенный скрипт проверки:

```bash
./check-h3.sh
```

Он проверяет:

1. наличие `--with-http_v3_module` в образе nginx
2. синтаксис runtime-конфига nginx
3. нужные директивы в сгенерированном конфиге
4. прослушивание TCP/443 и UDP/443
5. состояние контейнеров
6. обычный HTTPS
7. HTTP/3
8. заголовок `QUIC-Status`

---

## 10. Проверки вручную

### 10.1. Проверка поддержки HTTP/3 в образе nginx

```bash
docker run --rm "${NGINX_IMAGE}" nginx -V 2>&1 | grep -- --with-http_v3_module
```

### 10.2. Полная строка сборки nginx

```bash
docker run --rm "${NGINX_IMAGE}" nginx -V 2>&1
```

### 10.3. Проверка синтаксиса nginx

```bash
docker compose exec nginx nginx -t
```

### 10.4. Проверка активных директив

```bash
grep -nE 'listen 443|http2|http3|Alt-Svc|QUIC-Status' nginx/conf.d/default.conf
```

### 10.5. Проверка сокетов на хосте

```bash
sudo ss -ltnp | grep ':443'
sudo ss -lunp | grep ':443'
```

### 10.6. Проверка HTTPS

```bash
curl -I https://your-domain.com
```

### 10.7. Проверка HTTP/3

```bash
py .\check_h3.py https://your-domain.com
```

---

## 11. Что указывать в клиенте Xray/VLESS

Используй следующие параметры:

- `address` = `DOMAIN`
- `port` = `443`
- `uuid` = `XRAY_UUID`
- `network` = `xhttp`
- `path` = `XRAY_PATH`
- `security` = `tls`
- `serverName / SNI` = `DOMAIN`
- `ALPN` = можно пробовать `h3`

Сгенерировать клиентский конфиг:

```bash
python generate_client_config.py DOMAIN XRAY_UUID /XRAY_PATH
```

---

## 12. Что значит fallback в этой схеме

Здесь fallback — это не отдельная функция Xray.

Смысл такой:

- основной путь: `client -> UDP/443 -> QUIC -> nginx -> xray`
- запасной путь: `client -> TCP/443 -> TLS/H2 -> nginx -> xray`

То есть если HTTP/3 у клиента или в сети не работает, соединение всё равно может пройти через обычный HTTPS/HTTP2.

---

## 13. Что делать после развертывания

После успешного запуска стоит выполнить несколько практических шагов.

### 13.1. Проверить доступность снаружи

Проверь сайт и H3 не только с сервера, но и с другой машины или устройства.

### 13.2. Проверить firewall/провайдера

Если HTTPS работает, а HTTP/3 нет, чаще всего проблема в одном из пунктов:

- не открыт `443/udp`
- облачный firewall режет UDP
- провайдер/VPS-панель не пропускает QUIC

### 13.3. Проверить логи

```bash
docker compose logs --tail=200 nginx
docker compose logs --tail=200 xray
```

### 13.4. Убедиться, что домен действительно указывает на этот сервер

Если сертификат не выпускается, первое, что надо проверить — DNS и доступность `http://DOMAIN/.well-known/acme-challenge/...`

---

## 14. Обновление сертификатов

Для ручного продления предусмотрен скрипт:

```bash
./renew.sh
```

Он:

- запускает `certbot renew`
- затем обновляет состояние nginx

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

## 15. Полезные команды эксплуатации

### Поднять сервисы

```bash
docker compose up -d
```

### Перезапустить сервисы

```bash
docker compose restart
```

### Остановить сервисы

```bash
docker compose down
```

### Посмотреть статус

```bash
docker compose ps
```

### Логи nginx

```bash
docker compose logs -f nginx
```

### Логи xray

```bash
docker compose logs -f xray
```

---

## 16. Самый короткий сценарий

Если всё уже подготовлено, минимальная последовательность такая:

```bash
cp .env.example .env
nano .env
chmod +x init.sh renew.sh check-h3.sh
./init.sh

docker compose run --rm certbot certonly \
  --webroot -w /var/www/certbot \
  -d your-domain.com \
  --email you@example.com \
  --agree-tos \
  --no-eff-email

./init.sh
./check-h3.sh
```

---

## 17. Если что-то не работает

### Симптом: `certbot` не может выпустить сертификат

Проверь:

- домен указывает на VPS
- порт `80/tcp` открыт
- nginx уже запущен в bootstrap-режиме
- нет другого процесса, который занял 80 порт

Проверка:

```bash
docker compose ps
sudo ss -ltnp | grep ':80'
```

### Симптом: HTTPS работает, а `curl --http3` нет

Проверь:

- открыт ли `443/udp`
- слушает ли система UDP/443
- реально ли образ nginx собран с `--with-http_v3_module`

### Симптом: nginx не стартует после выпуска сертификата

Проверь:

- существуют ли файлы `fullchain.pem` и `privkey.pem`
- совпадает ли домен в `.env` с фактическим путем сертификата
- проходит ли `nginx -t`

### Симптом: Xray не принимает трафик

Проверь:

- правильный ли `XRAY_PATH`
- совпадает ли `uuid`
- корректен ли клиентский профиль
- жив ли контейнер `xray`

---

## 18. Итоговая логика развертывания

Весь процесс выглядит так:

1. подготовить сервер, DNS и порты
2. установить Docker
3. положить файлы проекта в каталог
4. создать `.env`
5. сделать скрипты исполняемыми
6. выполнить `./init.sh` для bootstrap-режима
7. выпустить сертификат через `certbot`
8. снова выполнить `./init.sh`
9. проверить работу через `./check-h3.sh`
10. настроить клиент Xray
11. добавить регулярное продление сертификата

---

## 19. Рекомендуемый порядок команд целиком

```bash
mkdir -p ~/xray-stack-h3-fallback
cd ~/xray-stack-h3-fallback

cp .env.example .env
nano .env

chmod +x init.sh renew.sh check-h3.sh
./init.sh

docker compose run --rm certbot certonly \
  --webroot -w /var/www/certbot \
  -d your-domain.com \
  --email you@example.com \
  --agree-tos \
  --no-eff-email

./init.sh
./check-h3.sh
```
