#!/usr/bin/env bash
#
# Focus-TV Installer (Lampac NextGen)
# Установка из репозитория bolshik/lampac-my
#

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly INSTALL_ROOT="${LAMPAC_INSTALL_ROOT:-/opt/lampac}"
readonly LAMPAC_USER="${LAMPAC_USER:-lampac}"
readonly SERVICE_NAME="${LAMPAC_SERVICE_NAME:-lampac}"
readonly SYSTEMD_UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
readonly GITHUB_REPO="${LAMPAC_GITHUB_REPO:-bolshik/lampac-my}"
readonly DOTNET_INSTALL_DIR="${LAMPAC_DOTNET_ROOT:-/usr/share/dotnet}"
readonly DOTNET_CHANNEL="${LAMPAC_DOTNET_CHANNEL:-10.0}"
readonly LISTEN_PORT="${LAMPAC_PORT:-9118}"

REMOVE=0; UPDATE=0; VERBOSE=0

_tty_escape() { printf '\033[%sm' "$1"; }
if [[ -t 1 ]]; then
  C_RESET=$(_tty_escape 0); C_GREEN=$(_tty_escape "1;32"); C_RED=$(_tty_escape "1;31")
  C_YELLOW=$(_tty_escape "1;33"); C_BLUE=$(_tty_escape "1;34"); C_DIM=$(_tty_escape 2)
else
  C_RESET=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
fi

log_info()  { printf '  %s→%s  %s\n'     "$C_BLUE"  "$C_RESET" "$*"; }
log_ok()    { printf '  %s✓%s  %s\n'     "$C_GREEN" "$C_RESET" "$*"; }
log_err()   { printf '  %s✗%s  %s\n'     "$C_RED"   "$C_RESET" "$*" >&2; }
log_skip()  { printf '  %s·%s  %s%s%s\n' "$C_DIM"   "$C_RESET" "$C_DIM" "$*" "$C_RESET"; }

print_banner() {
  printf '\n'
  printf '███████╗ ██████╗  ██████╗██╗   ██╗███████╗   ████████╗██╗   ██╗\n'
  printf '██╔════╝██╔═══██╗██╔════╝██║   ██║██╔════╝   ╚══██╔══╝██║   ██║\n'
  printf '█████╗  ██║   ██║██║     ██║   ██║███████╗█████╗██║   ██║   ██║\n'
  printf '██╔══╝  ██║   ██║██║     ██║   ██║╚════██║╚════╝██║   ╚██╗ ██╔╝\n'
  printf '██║     ╚██████╔╝╚██████╗╚██████╔╝███████║      ██║    ╚████╔╝ \n'
  printf '╚═╝      ╚═════╝  ╚═════╝ ╚═════╝ ╚══════╝      ╚═╝     ╚═══╝  \n'
  printf '\n'
}

detect_arch() {
  case "$(uname -m)" in
    x86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) log_err "Unsupported arch: $(uname -m)"; exit 1 ;;
  esac
}

is_ubuntu() {
  [[ -r /etc/os-release ]] && { . /etc/os-release; [[ "${ID:-}" == "ubuntu" ]]; }
}

install_os_packages() {
  log_info "Обновление пакетов..."
  apt-get update -qq
  
  local packages="ca-certificates curl git unzip fontconfig libnspr4"
  
  if is_ubuntu; then
    apt-get install -y -qq software-properties-common 2>/dev/null || true
    add-apt-repository -y ppa:xtradeb/apps -qq 2>/dev/null || true
    apt-get update -qq
  fi
  
  local icu_pkg=""
  for p in libicu78 libicu76 libicu74 libicu72 libicu70 libicu67; do
    if apt-cache show "$p" &>/dev/null; then
      icu_pkg="$p"
      break
    fi
  done
  [[ -n "$icu_pkg" ]] && packages="$packages $icu_pkg"
  
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $packages
  apt-get clean -qq; rm -rf /var/lib/apt/lists/*
  log_ok "Системные пакеты установлены"
}

install_dotnet_sdk_and_runtime() {
  log_info "Установка .NET SDK и Runtime 10.0..."
  
  # Устанавливаем SDK (нужен для сборки)
  local sdk_installer="/tmp/dotnet-sdk-$$.sh"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$sdk_installer"
  chmod +x "$sdk_installer"
  bash "$sdk_installer" --channel "$DOTNET_CHANNEL" --install-dir "$DOTNET_INSTALL_DIR"
  rm -f "$sdk_installer"
  
  # Устанавливаем ASP.NET Core Runtime (для запуска)
  local runtime_installer="/tmp/dotnet-runtime-$$.sh"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$runtime_installer"
  chmod +x "$runtime_installer"
  bash "$runtime_installer" --channel "$DOTNET_CHANNEL" --runtime aspnetcore --install-dir "$DOTNET_INSTALL_DIR"
  rm -f "$runtime_installer"
  
  # Добавляем dotnet в PATH для текущей сессии
  export DOTNET_ROOT="$DOTNET_INSTALL_DIR"
  export PATH="$PATH:$DOTNET_INSTALL_DIR"
  
  # Проверяем установку
  if ! "$DOTNET_INSTALL_DIR/dotnet" --version &>/dev/null; then
    log_err "Ошибка установки .NET SDK"
    exit 1
  fi
  
  log_ok ".NET SDK и Runtime $DOTNET_CHANNEL установлены"
}

ensure_service_user() {
  getent group "$LAMPAC_USER" &>/dev/null || groupadd -r "$LAMPAC_USER"
  getent passwd "$LAMPAC_USER" &>/dev/null || useradd -r -g "$LAMPAC_USER" -d "$INSTALL_ROOT" -s /usr/sbin/nologin "$LAMPAC_USER"
  log_ok "Пользователь $LAMPAC_USER создан"
}

install_app() {
  log_info "Клонирование репозитория ${GITHUB_REPO}..."
  rm -rf "$INSTALL_ROOT"
  git clone --depth 1 "https://github.com/${GITHUB_REPO}.git" "$INSTALL_ROOT"
  
  log_info "Сборка приложения..."
  export DOTNET_ROOT="$DOTNET_INSTALL_DIR"
  export PATH="$PATH:$DOTNET_INSTALL_DIR"
  cd "$INSTALL_ROOT"
  
  # Восстанавливаем зависимости и публикуем
  "$DOTNET_INSTALL_DIR/dotnet" restore
  "$DOTNET_INSTALL_DIR/dotnet" publish -c Release -o "$INSTALL_ROOT/publish"
  
  if [[ ! -f "$INSTALL_ROOT/publish/Core.dll" ]]; then
    log_err "Сборка не удалась — файл Core.dll не найден"
    exit 1
  fi
  
  log_ok "Приложение собрано"
}

install_systemd_unit() {
  cat << EOF > "$SYSTEMD_UNIT_PATH"
[Unit]
Description=Focus-TV (Lampac NextGen)
After=network.target

[Service]
Type=simple
User=$LAMPAC_USER
Group=$LAMPAC_USER
WorkingDirectory=$INSTALL_ROOT/publish
Environment=DOTNET_ROOT=$DOTNET_INSTALL_DIR
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$DOTNET_INSTALL_DIR
ExecStart=$DOTNET_INSTALL_DIR/dotnet $INSTALL_ROOT/publish/Core.dll
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$SYSTEMD_UNIT_PATH"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
  log_ok "systemd сервис создан"
}

configure_focus_tv() {
  log_info "Настройка конфигурации..."
  
  echo -n "Vfhifk1981@" > "${INSTALL_ROOT}/passwd"
  
  cat > "${INSTALL_ROOT}/init.conf" << 'INITEOF'
{
  "WebLog": {
    "enable": false,
    "password": "Vfhifk1981@"
  },
  "BaseModule": {
    "SkipModules": [
      "DLNA", "Catalog",
      "Tracks", "Transcoding", "WebLog",
      "TelegramAuth", "TelegramAuthBot"
    ],
    "LoadModules": [ "AdminPanel", ".*" ]
  },
  "AdminPanel": {
    "enable": true,
    "password": "Vfhifk1981@"
  },
  "WAF": {
    "enable": true
  },
  "accsdb": {
    "enable": true,
    "autoreg": true
  },
  "online": {
    "name": "Focus-TV",
    "version": true,
    "btn_priority_forced": true
  },
  "LampaWeb": {
    "initPlugins": {
      "online": true,
      "sisi": true,
      "torrserver": true,
      "timecode": true,
      "jacred": true,
      "tmdbProxy": true,
      "cubProxy": true,
      "sync": true
    }
  },
  "listen": {
    "port": 9118
  }
}
INITEOF

  cat > "${INSTALL_ROOT}/users.json" << 'USERSEOF'
[
  {
    "id": "112233",
    "ids": ["112233"],
    "IsPasswd": false,
    "expires": "2099-12-31T23:59:59",
    "group": 1,
    "ban": false,
    "ban_msg": null
  }
]
USERSEOF

  if [[ -d "${INSTALL_ROOT}/module/AdminPanel" ]]; then
    mkdir -p "${INSTALL_ROOT}/mods"
    cp -r "${INSTALL_ROOT}/module/AdminPanel" "${INSTALL_ROOT}/mods/AdminPanel"
    if [[ -f "${INSTALL_ROOT}/mods/AdminPanel/manifest.json" ]]; then
      sed -i 's/"enable": false/"enable": true/' "${INSTALL_ROOT}/mods/AdminPanel/manifest.json"
    fi
  fi

  if [[ -f "${INSTALL_ROOT}/wwwroot/lampa-main/app.min.js" ]]; then
    sed -i "s/+ ' - ' + Storage.field('source').toUpperCase()//g" "${INSTALL_ROOT}/wwwroot/lampa-main/app.min.js"
  fi

  chown -R "${LAMPAC_USER}:${LAMPAC_USER}" "$INSTALL_ROOT"
  log_ok "Конфигурация настроена"
}

start_service() {
  systemctl start "$SERVICE_NAME"
  log_ok "Сервис запущен"
}

print_success() {
  local ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -z "$ip" ]] && ip="<your-ip>"
  
  printf '\n%s  ─── Focus-TV установлен! ───%s\n' "$C_GREEN" "$C_RESET"
  printf '  URL:    http://%s:%s\n' "$ip" "$LISTEN_PORT"
  printf '  Admin:  http://%s:%s/adminpanel/  (пароль: Vfhifk1981@)\n' "$ip" "$LISTEN_PORT"
  printf '  Test UID: 112233\n'
  printf '  Конфиг: %s/init.conf\n' "$INSTALL_ROOT"
  printf '  Логи:   journalctl -u %s -f\n\n' "$SERVICE_NAME"
}

main() {
  if [[ ${EUID} -ne 0 ]]; then
    exec sudo -E "$0" "$@"
  fi
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remove) REMOVE=1; shift ;;
      --update) UPDATE=1; shift ;;
      -h|--help) 
        printf "Usage: $0 [--remove] [--update]\n"
        exit 0
        ;;
      *) log_err "Неизвестная опция: $1"; exit 1 ;;
    esac
  done

  if [[ "$REMOVE" -eq 1 ]]; then
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SYSTEMD_UNIT_PATH"
    systemctl daemon-reload
    rm -rf "$INSTALL_ROOT"
    userdel "$LAMPAC_USER" 2>/dev/null || true
    groupdel "$LAMPAC_USER" 2>/dev/null || true
    log_ok "Focus-TV удалён"
    exit 0
  fi

  print_banner
  printf '  Режим:  %s\n' "$([[ $UPDATE -eq 1 ]] && echo "Обновление" || echo "Установка")"
  printf '  Архив:  %s\n' "$(detect_arch)"
  printf '  Папка:  %s\n' "$INSTALL_ROOT"
  printf '\n'

  install_os_packages
  install_dotnet_sdk_and_runtime

  if [[ "$UPDATE" -eq 1 ]]; then
    install_app
    chown -R "${LAMPAC_USER}:${LAMPAC_USER}" "$INSTALL_ROOT"
    systemctl restart "$SERVICE_NAME"
    log_ok "Обновление завершено"
    exit 0
  fi

  ensure_service_user
  install_app
  install_systemd_unit
  configure_focus_tv
  start_service
  print_success
}

main "$@"
