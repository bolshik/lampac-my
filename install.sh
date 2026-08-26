#!/usr/bin/env bash
set -euo pipefail

INSTALL_ROOT="/opt/lampac"
LAMPAC_USER="lampac"
SERVICE_NAME="lampac"
DOTNET_DIR="/usr/share/dotnet"
GITHUB_REPO="bolshik/lampac-my"

C_RESET="\033[0m"; C_GREEN="\033[1;32m"; C_BLUE="\033[1;34m"
log_info() { printf "  ${C_BLUE}→${C_RESET}  %s\n" "$*"; }
log_ok() { printf "  ${C_GREEN}✓${C_RESET}  %s\n" "$*"; }

if [[ ${EUID} -ne 0 ]]; then exec sudo -E "$0" "$@"; fi

log_info "Очистка системы..."
apt-get clean && apt-get autoclean -y && apt-get autoremove -y
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

log_info "Установка пакетов..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates curl git unzip fontconfig libnspr4 libicu74

log_info "Установка .NET SDK..."
rm -rf "$DOTNET_DIR"
curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
chmod +x /tmp/dotnet-install.sh
bash /tmp/dotnet-install.sh --channel 10.0 --install-dir "$DOTNET_DIR"
rm -f /tmp/dotnet-install.sh
export DOTNET_ROOT="$DOTNET_DIR"
export PATH="$PATH:$DOTNET_DIR"

log_info "Клонирование репозитория..."
rm -rf "$INSTALL_ROOT"
git clone --depth 1 "https://github.com/${GITHUB_REPO}.git" "$INSTALL_ROOT"
cd "$INSTALL_ROOT"

log_info "Удаление тяжёлых модулей..."
rm -rf Modules/Adult Modules/Community/TelegramAuth* Modules/WebLog
rm -rf Modules/Transcoding Modules/Tracks Modules/DLNA Modules/Catalog
rm -rf Modules/Potok Modules/NextHUB Modules/Music Modules/PidTor
rm -rf Modules/GStreamer Modules/ExternalBind Modules/DatabaseEditor
rm -rf Modules/Telemetry Modules/Kit Modules/MsxNative Modules/CacheMedia
rm -rf Modules/TimeCode Modules/TorrServer SISI Tests
find . -type d -name "obj" -exec rm -rf {} + 2>/dev/null || true
find . -type d -name "bin" -exec rm -rf {} + 2>/dev/null || true

log_info "Сборка Core..."
"$DOTNET_DIR/dotnet" restore Core/Core.csproj
"$DOTNET_DIR/dotnet" publish Core/Core.csproj -c Release -o "$INSTALL_ROOT/publish"

log_info "Копирование модулей..."
mkdir -p "$INSTALL_ROOT/publish/modules"
for mod in AdminPanel JacRed LampaWeb Sync; do
  [[ -d "Modules/$mod" ]] && cp -r "Modules/$mod" "$INSTALL_ROOT/publish/modules/"
done

log_info "Настройка конфигурации..."
cat > "$INSTALL_ROOT/init.conf" << 'EOF'
{
  "AdminPanel": { "enable": true, "password": "Vfhifk1981@" },
  "accsdb": { "enable": true, "autoreg": true },
  "online": { "name": "Focus-TV", "version": true },
  "LampaWeb": {
    "initPlugins": {
      "online": true, "sisi": true, "torrserver": true,
      "timecode": true, "jacred": true, "sync": true
    }
  },
  "listen": { "port": 9118 }
}
EOF

cat > "$INSTALL_ROOT/users.json" << 'EOF'
[{"id":"112233","ids":["112233"],"expires":"2099-12-31T23:59:59","group":1}]
EOF

log_info "Настройка сервиса..."
useradd -r -s /bin/false "$LAMPAC_USER" 2>/dev/null || true
chown -R "$LAMPAC_USER":"$LAMPAC_USER" "$INSTALL_ROOT/publish"
chown "$LAMPAC_USER":"$LAMPAC_USER" "$INSTALL_ROOT/init.conf" "$INSTALL_ROOT/users.json"

cat > /etc/systemd/system/lampac.service << 'EOF'
[Unit]
Description=Focus-TV (Lampac)
After=network.target

[Service]
Type=simple
User=lampac
WorkingDirectory=/opt/lampac/publish
Environment=DOTNET_ROOT=/usr/share/dotnet
ExecStart=/usr/share/dotnet/dotnet /opt/lampac/publish/Core.dll
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable lampac
systemctl start lampac

IP=$(hostname -I | awk '{print $1}')
echo -e "\n${C_GREEN}  ─── Focus-TV установлен! ───${C_RESET}"
echo "  URL:    http://$IP:9118"
echo "  Admin:  http://$IP:9118/adminpanel/  (пароль: Vfhifk1981@)"
echo "  Test UID: 112233"
echo "  Логи:   journalctl -u lampac -f"
