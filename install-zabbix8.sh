#!/usr/bin/env bash
# =============================================================================
#  Zabbix 8.0 LTS - All-in-One automated installer
#  Server + Frontend + Agent2 + MariaDB + Apache (or Nginx)
#
#  Supported platforms (amd64 / arm64, armhf on Raspberry Pi OS 32-bit):
#    - Debian 12 (bookworm), 13 (trixie)
#    - Ubuntu Server 22.04, 24.04, 26.04 LTS  (+ derivatives via ID_LIKE)
#    - Raspberry Pi OS 12/13 (32-bit "raspbian" and 64-bit)
#    - RHEL, Rocky Linux, AlmaLinux, Oracle Linux, CentOS Stream 9 and 10
#
#  Zabbix 8.0 minimums handled automatically:
#    - PHP >= 8.2      (Ubuntu 22.04 -> ondrej PPA, EL9 -> php:8.2 module)
#    - MariaDB >= 10.11 (Ubuntu 22.04 -> official MariaDB repo, EL9 -> module)
#
#  Usage:   sudo ./install-zabbix8.sh [options]      (see --help)
#  Log:     /var/log/zabbix-install.log
#  Secrets: /root/zabbix-credentials.txt (mode 600)
#  Autor - Vitor Mazuco - vmzsolutions.com.br
# =============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="2.0.0"

# ----------------------------- Defaults --------------------------------------
# Every value can be overridden by an environment variable or a CLI option.
ZBX_VERSION="${ZBX_VERSION:-8.0}"
ZBX_REPO_BASE="${ZBX_REPO_BASE:-https://repo.zabbix.com/zabbix}"
ZBX_RELEASE_URL="${ZBX_RELEASE_URL:-}"          # force a specific zabbix-release package URL

DB_NAME="${DB_NAME:-zabbix}"
DB_USER="${DB_USER:-zabbix}"
DB_PASS="${DB_PASS:-}"                          # empty = random password
ADMIN_PASS="${ADMIN_PASS:-}"                    # empty = keep Zabbix default (Admin/zabbix)

WEB_SERVER="${WEB_SERVER:-apache}"              # apache | nginx
NGINX_PORT="${NGINX_PORT:-8080}"
AGENT="${AGENT:-2}"                             # 1 = zabbix-agent, 2 = zabbix-agent2
TIMEZONE="${TIMEZONE:-}"                        # empty = system timezone (fallback America/Sao_Paulo)
FRONTEND_LANG="${FRONTEND_LANG:-en_US}"         # en_US, pt_BR, es_ES, ...

USE_UNSTABLE="${USE_UNSTABLE:-0}"               # 1 = enable Zabbix "unstable" repo (RC builds)
FORCE_MARIADB_REPO="${FORCE_MARIADB_REPO:-0}"   # 1 = always use the official MariaDB repo (Debian/Ubuntu)
MARIADB_REPO_VERSION="${MARIADB_REPO_VERSION:-11.4}"
EL_PHP_STREAM="${EL_PHP_STREAM:-8.2}"
EL_MARIADB_STREAM="${EL_MARIADB_STREAM:-10.11}"
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-1}"
TUNE_DB="${TUNE_DB:-1}"
FORCE="${FORCE:-0}"                             # 1 = skip OS version support check

LOG_FILE="${LOG_FILE:-/var/log/zabbix-install.log}"
CRED_FILE="${CRED_FILE:-/root/zabbix-credentials.txt}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

MIN_PHP="8.2"
MIN_MARIADB="10.11"

# Filled in at runtime
OS_ID="" OS_NAME="" OS_VERSION="" OS_MAJOR="" OS_CODENAME="" FAMILY="" ARCH=""
ZBX_TREES=() IS_RPI=0 DB_CLI="" AGENT_PKG="" AGENT_SVC="" WEB_SVC="" PHP_FPM_SVC=""
TMP_DIR=""

# ----------------------------- Output helpers --------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YLW=$'\e[33m' C_BLU=$'\e[34m' C_BLD=$'\e[1m' C_RST=$'\e[0m'
else
  C_RED="" C_GRN="" C_YLW="" C_BLU="" C_BLD="" C_RST=""
fi

ts()   { date '+%H:%M:%S'; }
info() { printf '%s %s[INFO]%s %s\n'  "$(ts)" "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s %s[ OK ]%s %s\n'  "$(ts)" "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s %s[WARN]%s %s\n'  "$(ts)" "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s %s[FAIL]%s %s\n'  "$(ts)" "$C_RED" "$C_RST" "$*" >&2; exit 1; }
step() { printf '\n%s==> %s%s\n' "$C_BLD" "$*" "$C_RST"; }

on_error() {
  local rc=$1 line=$2 cmd=$3
  printf '\n%s[FAIL]%s Command failed (exit %s) at line %s:\n       %s\n' "$C_RED" "$C_RST" "$rc" "$line" "$cmd" >&2
  printf '       Full log: %s\n' "$LOG_FILE" >&2
  exit "$rc"
}

cleanup() { [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"; return 0; }

# version_ge A B  ->  true if A >= B (dotted versions)
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | awk 'NR==1')" == "$2" ]]
}

# "1:10.11.6-0+deb12u1" -> "10.11" ; "2:8.2+93" -> "8.2"
major_minor() {
  local v="${1#*:}"
  if [[ "$v" =~ ^([0-9]+)\.([0-9]+) ]]; then
    printf '%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
  return 0
}

# Escape a value for a single-quoted SQL or PHP string
quote_sq() {
  local s="${1//\\/\\\\}"
  printf '%s' "${s//\'/\\\'}"
}

gen_password() {
  local p=""
  if command -v openssl >/dev/null 2>&1; then
    p="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')"
  fi
  if (( ${#p} < 24 )); then
    p="$(head -c 512 /dev/urandom | tr -dc 'A-Za-z0-9')"
  fi
  printf '%s' "${p:0:24}"
}

svc_exists() { [[ -n "$(systemctl list-unit-files "$1.service" --no-legend 2>/dev/null)" ]]; }

# ----------------------------- CLI -------------------------------------------
usage() {
  cat <<EOF
Zabbix ${ZBX_VERSION} All-in-One installer v${SCRIPT_VERSION}

Usage: sudo $0 [options]

  -p, --db-password PASS     Password for the '${DB_USER}' database user (default: random)
  -a, --admin-password PASS  New password for the frontend 'Admin' user (default: zabbix)
  -t, --timezone TZ          Frontend/PHP timezone (default: system TZ or America/Sao_Paulo)
  -l, --lang LOCALE          Default frontend language, e.g. en_US, pt_BR, es_ES (default: en_US)
  -w, --web apache|nginx     Web server (default: apache)
      --nginx-port PORT      Nginx listen port (default: 8080)
      --agent 1|2            Zabbix agent (1) or agent 2 (2) (default: 2)
      --unstable             Also enable the Zabbix 'unstable' repo (release candidates)
      --mariadb-official     Always install MariaDB ${MARIADB_REPO_VERSION} from mirror.mariadb.org (Debian/Ubuntu)
      --no-firewall          Do not touch firewalld/ufw
      --no-db-tuning         Do not write the MariaDB tuning file
      --force                Continue on an untested OS version
  -h, --help                 Show this help

All options can also be set by environment variables, e.g.:
  sudo DB_PASS='S3cret' TIMEZONE=America/Sao_Paulo FRONTEND_LANG=pt_BR $0
EOF
}

parse_args() {
  while (( $# )); do
    case "$1" in
      -p|--db-password)    DB_PASS="${2:?missing value for $1}"; shift ;;
      -a|--admin-password) ADMIN_PASS="${2:?missing value for $1}"; shift ;;
      -t|--timezone)       TIMEZONE="${2:?missing value for $1}"; shift ;;
      -l|--lang)           FRONTEND_LANG="${2:?missing value for $1}"; shift ;;
      -w|--web)            WEB_SERVER="${2:?missing value for $1}"; shift ;;
      --nginx-port)        NGINX_PORT="${2:?missing value for $1}"; shift ;;
      --agent)             AGENT="${2:?missing value for $1}"; shift ;;
      --unstable)          USE_UNSTABLE=1 ;;
      --mariadb-official)  FORCE_MARIADB_REPO=1 ;;
      --no-firewall)       CONFIGURE_FIREWALL=0 ;;
      --no-db-tuning)      TUNE_DB=0 ;;
      --force)             FORCE=1 ;;
      -h|--help)           usage; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
  done

  [[ "$WEB_SERVER" =~ ^(apache|nginx)$ ]] || die "--web must be 'apache' or 'nginx'"
  [[ "$AGENT" =~ ^[12]$ ]]                 || die "--agent must be 1 or 2"
  [[ "$NGINX_PORT" =~ ^[0-9]+$ ]] && (( NGINX_PORT > 0 && NGINX_PORT < 65536 )) || die "Invalid --nginx-port"
  [[ "$FRONTEND_LANG" =~ ^[a-z]{2}_[A-Z]{2}$ ]] || die "--lang must look like pt_BR or en_US"
  [[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ && "$DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || die "DB_NAME/DB_USER may only contain letters, digits and _"
  local p
  for p in "$DB_PASS" "$ADMIN_PASS"; do
    [[ "$p" != *$'\n'* ]] || die "Passwords cannot contain line breaks"
  done
  return 0
}

# ----------------------------- Platform detection ----------------------------
detect_platform() {
  [[ -r "$OS_RELEASE_FILE" ]] || die "Cannot read $OS_RELEASE_FILE - unable to detect the OS."

  local ID="" ID_LIKE="" VERSION_ID="" VERSION_CODENAME="" UBUNTU_CODENAME="" PRETTY_NAME=""
  # shellcheck disable=SC1090
  . "$OS_RELEASE_FILE"

  OS_ID="${ID,,}"
  OS_NAME="${PRETTY_NAME:-$OS_ID}"
  OS_VERSION="${VERSION_ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"

  # Architecture: prefer dpkg (detects 32-bit userland on 64-bit Pi kernels)
  if [[ -n "${ARCH_OVERRIDE:-}" ]]; then
    ARCH="$ARCH_OVERRIDE"
  elif command -v dpkg >/dev/null 2>&1; then
    ARCH="$(dpkg --print-architecture)"
  else
    case "$(uname -m)" in
      x86_64) ARCH="amd64" ;; aarch64|arm64) ARCH="arm64" ;; armv7l|armv6l) ARCH="armhf" ;; *) ARCH="$(uname -m)" ;;
    esac
  fi

  if [[ -r /proc/device-tree/model && "$(tr -d '\0' </proc/device-tree/model)" == *"Raspberry"* ]]; then
    IS_RPI=1
  fi

  case "$OS_ID" in
    debian)
      FAMILY="deb"
      OS_MAJOR="${OS_VERSION%%.*}"
      if [[ -z "$OS_MAJOR" ]]; then          # testing/sid have no VERSION_ID
        case "$OS_CODENAME" in bookworm) OS_MAJOR=12 ;; trixie) OS_MAJOR=13 ;; esac
      fi
      if [[ "$ARCH" == "armhf" ]]; then
        ZBX_TREES=(raspbian)
      else
        ZBX_TREES=(debian debian-arm64 raspbian)
      fi
      ;;
    raspbian)
      FAMILY="deb"; OS_MAJOR="${OS_VERSION%%.*}"
      ZBX_TREES=(raspbian debian)
      ;;
    ubuntu)
      FAMILY="deb"; OS_MAJOR="$OS_VERSION"
      ZBX_TREES=(ubuntu ubuntu-arm64)
      ;;
    rhel|rocky|almalinux|centos|ol)
      FAMILY="rpm"; OS_MAJOR="${OS_VERSION%%.*}"
      case "$OS_ID" in
        rhel) ZBX_TREES=(rhel) ;;
        rocky) ZBX_TREES=(rocky rhel) ;;
        almalinux) ZBX_TREES=(alma rhel) ;;
        centos) ZBX_TREES=(centos rhel) ;;
        ol) ZBX_TREES=(oracle rhel) ;;
      esac
      ;;
    *)
      # Derivatives (Linux Mint, Pop!_OS, Zorin, MX, EuroLinux, ...)
      if [[ " ${ID_LIKE,,} " == *" ubuntu "* && -n "$UBUNTU_CODENAME" ]]; then
        FAMILY="deb"; OS_CODENAME="$UBUNTU_CODENAME"
        case "$UBUNTU_CODENAME" in
          jammy) OS_MAJOR="22.04" ;; noble) OS_MAJOR="24.04" ;; resolute) OS_MAJOR="26.04" ;; *) OS_MAJOR="" ;;
        esac
        warn "$OS_NAME detected - treating it as Ubuntu ${OS_MAJOR:-?} (${UBUNTU_CODENAME})."
        OS_ID="ubuntu"; ZBX_TREES=(ubuntu ubuntu-arm64)
      elif [[ " ${ID_LIKE,,} " == *" debian "* && -r /etc/debian_version ]]; then
        FAMILY="deb"
        OS_MAJOR="$(cut -d. -f1 /etc/debian_version)"
        case "$OS_MAJOR" in 12) OS_CODENAME=bookworm ;; 13) OS_CODENAME=trixie ;; esac
        warn "$OS_NAME detected - treating it as Debian ${OS_MAJOR}."
        OS_ID="debian"; ZBX_TREES=(debian debian-arm64 raspbian)
      elif [[ " ${ID_LIKE,,} " =~ \ (rhel|centos|fedora)\  ]]; then
        FAMILY="rpm"; OS_MAJOR="${OS_VERSION%%.*}"
        warn "$OS_NAME detected - treating it as RHEL ${OS_MAJOR}."
        OS_ID="rhel"; ZBX_TREES=(rhel)
      else
        die "Unsupported distribution: ${OS_NAME}. Supported: Debian, Ubuntu, Raspberry Pi OS, RHEL/Rocky/Alma/Oracle/CentOS Stream."
      fi
      ;;
  esac

  # Debian-family codename fallback
  if [[ "$FAMILY" == "deb" && -z "$OS_CODENAME" ]] && command -v lsb_release >/dev/null 2>&1; then
    OS_CODENAME="$(lsb_release -sc 2>/dev/null || true)"
  fi
}

check_supported() {
  local supported=0
  case "$OS_ID" in
    debian|raspbian) [[ "$OS_MAJOR" =~ ^(12|13)$ ]] && supported=1 ;;
    ubuntu)          [[ "$OS_MAJOR" =~ ^(22\.04|24\.04|26\.04)$ ]] && supported=1 ;;
    *)               [[ "$FAMILY" == "rpm" && "$OS_MAJOR" =~ ^(9|10)$ ]] && supported=1 ;;
  esac

  case "$ARCH" in
    amd64|x86_64|arm64|aarch64) ;;
    armhf)
      [[ "$OS_ID" == "raspbian" || "$OS_ID" == "debian" ]] \
        || die "32-bit ARM (armhf) is only supported on Raspberry Pi OS."
      ;;
    *) die "Unsupported CPU architecture: $ARCH" ;;
  esac

  if (( ! supported )); then
    local msg="${OS_NAME} (version '${OS_MAJOR:-unknown}') is not supported by this installer for Zabbix ${ZBX_VERSION}."
    case "$OS_ID" in
      debian|raspbian) msg+=" Debian 11 and older ship PHP < 8.2 / MariaDB < 10.11; upgrade to Debian 12+." ;;
      ubuntu)          msg+=" Use Ubuntu 22.04, 24.04 or 26.04." ;;
      *)               msg+=" Use EL 9 or 10 (EL 8 lacks a supported frontend stack)." ;;
    esac
    if (( FORCE )); then warn "$msg Continuing because --force was given."; else die "$msg (use --force to try anyway)"; fi
  fi
  ok "Platform: ${OS_NAME} | family=${FAMILY} | version=${OS_MAJOR} | arch=${ARCH}$( (( IS_RPI )) && printf ' | Raspberry Pi')"
}

# ----------------------------- Pre-flight ------------------------------------
require_root() {
  [[ $EUID -eq 0 ]] || die "Run this script as root (sudo $0)."
}

preflight() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] \
    || die "systemd is required (containers without systemd are not supported)."

  local mem_mb disk_mb
  mem_mb=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
  disk_mb=$(df -Pm /var | awk 'NR==2{print $4}')
  if (( mem_mb < 1500 )); then
    warn "Only ${mem_mb} MB RAM. Zabbix + MariaDB + PHP work best with 2 GB or more."
  fi
  if (( disk_mb < 3072 )); then
    warn "Only ${disk_mb} MB free in /var. Allow several GB for history data."
  fi

  # Refuse to touch an existing Zabbix server from another major version
  local installed=""
  if [[ "$FAMILY" == "deb" ]]; then
    installed="$(dpkg-query -W -f='${Version}' zabbix-server-mysql 2>/dev/null || true)"
  else
    installed="$(rpm -q --qf '%{VERSION}' zabbix-server-mysql 2>/dev/null || true)"
    [[ "$installed" == *"not installed"* ]] && installed=""
  fi
  if [[ -n "$installed" ]]; then
    if [[ "$(major_minor "$installed")" != "$ZBX_VERSION" ]]; then
      die "Zabbix server ${installed} is already installed. This script does fresh installs only; follow the official upgrade guide to go to ${ZBX_VERSION}."
    fi
    warn "Zabbix ${installed} is already installed - re-running in idempotent mode."
  fi

  # Reuse a previously generated DB password on re-runs
  if [[ -z "$DB_PASS" && -r "$CRED_FILE" ]]; then
    DB_PASS="$(awk '/^DB password: /{sub(/^DB password: /, ""); print; exit}' "$CRED_FILE")"
    [[ -n "$DB_PASS" ]] && info "Reusing database password from $CRED_FILE"
  fi
  [[ -n "$DB_PASS" ]] || DB_PASS="$(gen_password)"

  # Timezone
  if [[ -z "$TIMEZONE" ]]; then
    TIMEZONE="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    [[ -z "$TIMEZONE" || "$TIMEZONE" == "Etc/UTC" || "$TIMEZONE" == "UTC" ]] && TIMEZONE="America/Sao_Paulo"
  fi
  [[ -e "/usr/share/zoneinfo/$TIMEZONE" ]] || die "Unknown timezone: $TIMEZONE"
  ok "Pre-flight checks passed (RAM ${mem_mb} MB, /var free ${disk_mb} MB, TZ ${TIMEZONE})"
}

# ----------------------------- Package manager wrappers ----------------------
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1

apt_install() {
  apt-get install -y -q \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}
apt_update() { apt-get update -q; }
dnf_install() { dnf install -y "$@"; }

download() {  # download URL DEST -> 0 on success
  curl -fsSL --retry 3 --connect-timeout 15 -o "$2" "$1" 2>/dev/null
}

# ----------------------------- Base packages / locales -----------------------
install_base_packages() {
  step "Installing base packages"
  if [[ "$FAMILY" == "deb" ]]; then
    apt_update
    apt_install ca-certificates curl wget gnupg locales openssl procps
  else
    # EL9+ ships curl-minimal, which conflicts with the full 'curl' package
    command -v curl >/dev/null 2>&1 || dnf_install curl
    dnf_install wget tar gzip openssl ca-certificates policycoreutils-python-utils \
                procps-ng glibc-langpack-en
  fi
  ok "Base packages installed"
}

setup_locales() {
  step "Generating locales (en_US.UTF-8 and ${FRONTEND_LANG}.UTF-8)"
  local locs=("en_US.UTF-8")
  [[ "$FRONTEND_LANG" != "en_US" ]] && locs+=("${FRONTEND_LANG}.UTF-8")

  if [[ "$FAMILY" == "deb" ]]; then
    if [[ "$OS_ID" == "ubuntu" ]]; then
      locale-gen "${locs[@]}" >/dev/null
    else
      local l
      touch /etc/locale.gen
      for l in "${locs[@]}"; do
        sed -i -E "s/^#[[:space:]]*(${l//./\\.} UTF-8)/\1/" /etc/locale.gen
        grep -qE "^${l//./\\.} UTF-8" /etc/locale.gen || echo "$l UTF-8" >>/etc/locale.gen
      done
      locale-gen >/dev/null
    fi
  else
    dnf_install "glibc-langpack-${FRONTEND_LANG%%_*}" >/dev/null 2>&1 \
      || warn "Could not install glibc-langpack-${FRONTEND_LANG%%_*}"
  fi
  ok "Locales ready"
}

# ----------------------------- Zabbix repository -----------------------------
# Lists candidate URLs for the zabbix-release package of one repository tree.
release_candidates() {
  local tree="$1" base names=() n tag listing
  if [[ "$FAMILY" == "deb" ]]; then
    base="${ZBX_REPO_BASE}/${ZBX_VERSION}/release/${tree}/pool/main/z/zabbix-release"
    case "$tree" in
      ubuntu*)   tag="ubuntu${OS_MAJOR}" ;;
      raspbian)  tag="debian${OS_MAJOR}" ;;
      *)         tag="debian${OS_MAJOR}" ;;
    esac
    names=("zabbix-release_latest_${ZBX_VERSION}+${tag}_all.deb"
           "zabbix-release_latest+${tag}_all.deb")
    [[ "$tree" == "raspbian" ]] && names+=("zabbix-release_latest_${ZBX_VERSION}+raspbian${OS_MAJOR}_all.deb")
    for n in "${names[@]}"; do printf '%s/%s\n' "$base" "$n"; done
    # Fallback: scrape the directory index for the newest matching package
    listing="$(curl -fsSL --connect-timeout 15 "$base/" 2>/dev/null || true)"
    grep -oE "zabbix-release_[A-Za-z0-9._~+-]*\+(${tag}|raspbian${OS_MAJOR})_all\.deb" <<<"$listing" \
      | sort -uV | tac | sed "s|^|$base/|" || true
  else
    base="${ZBX_REPO_BASE}/${ZBX_VERSION}/release/${tree}/${OS_MAJOR}/noarch"
    printf '%s\n' "$base/zabbix-release-latest-${ZBX_VERSION}.el${OS_MAJOR}.noarch.rpm" \
                  "$base/zabbix-release-latest.el${OS_MAJOR}.noarch.rpm"
    listing="$(curl -fsSL --connect-timeout 15 "$base/" 2>/dev/null || true)"
    grep -oE "zabbix-release-[A-Za-z0-9._-]*\.el${OS_MAJOR}\.noarch\.rpm" <<<"$listing" \
      | sort -uV | tac | sed "s|^|$base/|" || true
  fi
}

enable_unstable_repo() {
  (( USE_UNSTABLE )) || return 0
  local f
  if [[ "$FAMILY" == "deb" ]]; then
    for f in /etc/apt/sources.list.d/zabbix*.sources; do
      [[ -f "$f" ]] || continue
      grep -qi 'unstable' "$f" && sed -i -E 's/^Enabled:[[:space:]]*no/Enabled: yes/I' "$f"
    done
    for f in /etc/apt/sources.list.d/zabbix*.list; do
      [[ -f "$f" ]] && sed -i -E 's|^#[[:space:]]*(deb(-src)? .*/unstable/.*)|\1|' "$f"
    done
  else
    for f in /etc/yum.repos.d/zabbix*.repo; do
      [[ -f "$f" ]] || continue
      awk 'BEGIN{s=0} /^\[/{s=($0 ~ /unstable/)} s && /^enabled=/{$0="enabled=1"} {print}' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
    done
  fi
  warn "Zabbix 'unstable' repository enabled (release candidates). Not recommended for production."
}

# Checks that apt sees a ZBX_VERSION candidate for the server package
apt_has_zabbix_candidate() {
  local cand
  cand="$(apt-cache policy zabbix-server-mysql 2>/dev/null | awk '/Candidate:/{print $2}')"
  [[ -n "$cand" && "$cand" != "(none)" && "$(major_minor "$cand")" == "$ZBX_VERSION" ]]
}

setup_zabbix_repo() {
  step "Configuring the official Zabbix ${ZBX_VERSION} repository"

  if [[ "$FAMILY" == "deb" ]]; then
    # Remove a zabbix-release package from another major version
    local cur
    cur="$(dpkg-query -W -f='${Version}' zabbix-release 2>/dev/null || true)"
    if [[ -n "$cur" && "$cur" != *"${ZBX_VERSION}"* ]]; then
      warn "Removing zabbix-release ${cur} (other major version)"
      dpkg -P zabbix-release >/dev/null || true
      rm -f /etc/apt/sources.list.d/zabbix*.list /etc/apt/sources.list.d/zabbix*.sources
    fi

    # Prefer packages from repo.zabbix.com over the distro's own (older) zabbix packages
    cat >/etc/apt/preferences.d/99-zabbix <<'EOF'
Package: zabbix*
Pin: origin repo.zabbix.com
Pin-Priority: 990
EOF

    local tree url pkg="$TMP_DIR/zabbix-release.deb" urls=()
    if [[ -n "$ZBX_RELEASE_URL" ]]; then
      urls=("$ZBX_RELEASE_URL")
    else
      for tree in "${ZBX_TREES[@]}"; do
        mapfile -t -O "${#urls[@]}" urls < <(release_candidates "$tree")
      done
    fi

    for url in "${urls[@]}"; do
      download "$url" "$pkg" || continue
      info "Trying $url"
      dpkg -i --force-confnew "$pkg" >/dev/null
      enable_unstable_repo
      apt_update >/dev/null
      if apt_has_zabbix_candidate; then
        ok "Zabbix repository configured ($(basename "$url"))"
        return 0
      fi
      warn "No Zabbix ${ZBX_VERSION} packages for ${OS_CODENAME:-$OS_MAJOR}/${ARCH} in that tree, trying next..."
      dpkg -P zabbix-release >/dev/null || true
    done
    die "Could not find Zabbix ${ZBX_VERSION} packages for ${OS_NAME} (${ARCH}). Check ${ZBX_REPO_BASE}/${ZBX_VERSION}/ or try --unstable."

  else
    # EPEL ships its own zabbix packages: exclude them
    if [[ -f /etc/yum.repos.d/epel.repo ]] && ! grep -q '^excludepkgs=.*zabbix' /etc/yum.repos.d/epel.repo; then
      sed -i '/^\[epel\]/a excludepkgs=zabbix*' /etc/yum.repos.d/epel.repo
      info "Excluded zabbix* from EPEL"
    fi

    local cur
    cur="$(rpm -q --qf '%{VERSION}' zabbix-release 2>/dev/null || true)"
    if [[ -n "$cur" && "$cur" != *"not installed"* && "$cur" != "${ZBX_VERSION}"* ]]; then
      warn "Removing zabbix-release ${cur} (other major version)"
      rpm -e zabbix-release || true
    fi

    local tree url pkg="$TMP_DIR/zabbix-release.rpm" urls=()
    if [[ -n "$ZBX_RELEASE_URL" ]]; then
      urls=("$ZBX_RELEASE_URL")
    else
      for tree in "${ZBX_TREES[@]}"; do
        mapfile -t -O "${#urls[@]}" urls < <(release_candidates "$tree")
      done
    fi
    for url in "${urls[@]}"; do
      download "$url" "$pkg" || continue
      info "Using $url"
      rpm -Uvh --replacepkgs "$pkg"
      enable_unstable_repo
      dnf clean all >/dev/null
      ok "Zabbix repository configured ($(basename "$url"))"
      return 0
    done
    die "Could not download the zabbix-release package for EL${OS_MAJOR}. Check ${ZBX_REPO_BASE}/${ZBX_VERSION}/release/"
  fi
}

# ----------------------------- PHP (>= 8.2) ----------------------------------
setup_php_stack() {
  step "Ensuring PHP >= ${MIN_PHP}"
  if [[ "$FAMILY" == "deb" ]]; then
    local cand
    cand="$(major_minor "$(apt-cache policy php 2>/dev/null | awk '/Candidate:/{print $2}')" || true)"
    if [[ -n "$cand" ]] && version_ge "$cand" "$MIN_PHP"; then
      ok "Distribution PHP ${cand} is fine"
      return 0
    fi
    warn "Distribution PHP is ${cand:-unknown} (< ${MIN_PHP}) - adding a newer PHP repository"
    if [[ "$OS_ID" == "ubuntu" ]]; then
      apt_install software-properties-common
      add-apt-repository -y ppa:ondrej/php
    else
      download https://packages.sury.org/php/apt.gpg /usr/share/keyrings/sury-php.gpg \
        || die "Could not download the packages.sury.org key"
      echo "deb [signed-by=/usr/share/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${OS_CODENAME} main" \
        >/etc/apt/sources.list.d/sury-php.list
    fi
    apt_update
    ok "Third-party PHP repository added"
  else
    if [[ "$OS_MAJOR" == "9" ]]; then
      local mods
      mods="$(dnf -q module list php 2>/dev/null || true)"
      if grep -qE "^php[[:space:]]+${EL_PHP_STREAM//./\\.}[[:space:]]" <<<"$mods"; then
        if rpm -q php-common >/dev/null 2>&1; then
          dnf -y module switch-to "php:${EL_PHP_STREAM}"
        else
          dnf -y module reset php
          dnf -y module enable "php:${EL_PHP_STREAM}"
        fi
        ok "Enabled PHP module stream php:${EL_PHP_STREAM}"
      else
        die "PHP module stream php:${EL_PHP_STREAM} not available. Update the system (dnf update) and retry."
      fi
    else
      ok "EL${OS_MAJOR} ships PHP >= 8.3 by default"
    fi
  fi
}

# ----------------------------- MariaDB (>= 10.11) ----------------------------
installed_mariadb_version() {
  local cli
  cli="$(command -v mariadb || command -v mysql || true)"
  [[ -n "$cli" ]] || return 0
  major_minor "$("$cli" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-MariaDB' || true)" || true
}

add_mariadb_official_repo() {
  info "Adding the official MariaDB ${MARIADB_REPO_VERSION} repository (mirror.mariadb.org)"
  download https://mariadb.org/mariadb_release_signing_key.asc "$TMP_DIR/mariadb.asc" \
    || die "Could not download the MariaDB signing key"
  gpg --dearmor <"$TMP_DIR/mariadb.asc" >/usr/share/keyrings/mariadb-keyring.gpg
  local distro="$OS_ID"; [[ "$distro" == "raspbian" ]] && distro="debian"
  echo "deb [signed-by=/usr/share/keyrings/mariadb-keyring.gpg] https://mirror.mariadb.org/repo/${MARIADB_REPO_VERSION}/${distro} ${OS_CODENAME} main" \
    >/etc/apt/sources.list.d/mariadb.list
  apt_update
}

setup_mariadb() {
  step "Installing MariaDB (>= ${MIN_MARIADB})"

  if command -v mysqld >/dev/null 2>&1 && ! mysqld --version 2>/dev/null | grep -qi mariadb; then
    die "Oracle MySQL server is already installed. This installer uses MariaDB; remove MySQL or install manually."
  fi

  local have
  have="$(installed_mariadb_version)"
  if [[ -n "$have" ]] && ! version_ge "$have" "$MIN_MARIADB"; then
    die "MariaDB ${have} is already installed, Zabbix ${ZBX_VERSION} needs >= ${MIN_MARIADB}. Upgrade it first (back up your data!)."
  fi

  if [[ "$FAMILY" == "deb" ]]; then
    if [[ -z "$have" ]]; then
      local cand
      cand="$(major_minor "$(apt-cache policy mariadb-server 2>/dev/null | awk '/Candidate:/{print $2}')" || true)"
      if (( FORCE_MARIADB_REPO )) || [[ -z "$cand" ]] || ! version_ge "$cand" "$MIN_MARIADB"; then
        (( FORCE_MARIADB_REPO )) || warn "Distribution MariaDB is ${cand:-unavailable} (< ${MIN_MARIADB})"
        [[ "$ARCH" == "armhf" ]] && die "The official MariaDB repository has no armhf builds; use Raspberry Pi OS 12+."
        add_mariadb_official_repo
      fi
    fi
    apt_install mariadb-server mariadb-client
  else
    if [[ "$OS_MAJOR" == "9" && -z "$have" ]]; then
      local mods
      mods="$(dnf -q module list mariadb 2>/dev/null || true)"
      if grep -qE "^mariadb[[:space:]]+${EL_MARIADB_STREAM//./\\.}[[:space:]]" <<<"$mods"; then
        dnf -y module reset mariadb
        dnf -y module enable "mariadb:${EL_MARIADB_STREAM}"
        ok "Enabled MariaDB module stream mariadb:${EL_MARIADB_STREAM}"
      else
        die "MariaDB module stream mariadb:${EL_MARIADB_STREAM} not available. Update the system (dnf update) and retry."
      fi
    fi
    dnf_install mariadb-server mariadb
  fi

  (( TUNE_DB )) && tune_mariadb
  systemctl enable --now mariadb
  systemctl restart mariadb

  DB_CLI="$(command -v mariadb || command -v mysql)"
  local _
  for _ in {1..30}; do
    "$DB_CLI" -uroot -e 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
  done
  "$DB_CLI" -uroot -e 'SELECT 1' >/dev/null 2>&1 \
    || die "Cannot connect to MariaDB as root through the unix socket."

  # Equivalent of mysql_secure_installation (root keeps unix_socket auth)
  "$DB_CLI" -uroot <<'SQL'
DROP USER IF EXISTS ''@'localhost';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
SQL

  local ver
  ver="$("$DB_CLI" -uroot -N -B -e 'SELECT VERSION()')"
  version_ge "$(major_minor "$ver")" "$MIN_MARIADB" \
    || die "MariaDB ${ver} is below the Zabbix ${ZBX_VERSION} minimum (${MIN_MARIADB})."
  ok "MariaDB ${ver} running"
}

tune_mariadb() {
  local dir mem_mb pool
  if [[ "$FAMILY" == "deb" ]]; then dir=/etc/mysql/mariadb.conf.d; else dir=/etc/my.cnf.d; fi
  mkdir -p "$dir"
  mem_mb=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
  pool=$(( mem_mb / 4 ))                       # 25% of RAM: DB shares the box with Zabbix/PHP
  (( pool < 128 )) && pool=128
  (( pool > 8192 )) && pool=8192
  cat >"$dir/90-zabbix.cnf" <<EOF
# Written by the Zabbix installer - adjust to your workload
[mysqld]
innodb_buffer_pool_size = ${pool}M
innodb_file_per_table   = 1
max_connections         = 300
EOF
  info "MariaDB tuning written to $dir/90-zabbix.cnf (buffer pool ${pool}M)"
}

# ----------------------------- Zabbix packages -------------------------------
install_zabbix_packages() {
  step "Installing Zabbix ${ZBX_VERSION} packages"
  local web_pkg="zabbix-apache-conf"
  [[ "$WEB_SERVER" == "nginx" ]] && web_pkg="zabbix-nginx-conf"

  if [[ "$FAMILY" == "deb" ]]; then
    apt_install zabbix-server-mysql zabbix-frontend-php "$web_pkg" zabbix-sql-scripts \
                zabbix-get zabbix-sender php-cli
  else
    dnf_install zabbix-server-mysql zabbix-web-mysql "$web_pkg" zabbix-sql-scripts \
                zabbix-selinux-policy zabbix-get zabbix-sender php-cli php-fpm
  fi

  # Agent: agent 2 by default, fall back to the classic agent if unavailable
  AGENT_PKG="zabbix-agent"; AGENT_SVC="zabbix-agent"
  if [[ "$AGENT" == "2" ]]; then
    if { [[ "$FAMILY" == "deb" ]] && apt_install zabbix-agent2; } \
       || { [[ "$FAMILY" == "rpm" ]] && dnf_install zabbix-agent2; }; then
      AGENT_PKG="zabbix-agent2"; AGENT_SVC="zabbix-agent2"
    else
      warn "zabbix-agent2 not available for this platform - installing zabbix-agent"
    fi
  fi
  if [[ "$AGENT_PKG" == "zabbix-agent" ]]; then
    if [[ "$FAMILY" == "deb" ]]; then apt_install zabbix-agent; else dnf_install zabbix-agent; fi
  fi

  local zver
  zver="$(zabbix_server -V 2>/dev/null | awk 'NR==1{print $NF}')"
  [[ "$(major_minor "$zver")" == "$ZBX_VERSION" ]] \
    || die "Installed zabbix_server reports '${zver}', expected ${ZBX_VERSION}.x"
  ok "Zabbix server ${zver} + ${AGENT_PKG} installed"

  local phpv
  phpv="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
  [[ -n "$phpv" ]] && ! version_ge "$phpv" "$MIN_PHP" \
    && die "PHP ${phpv} installed, Zabbix ${ZBX_VERSION} needs >= ${MIN_PHP}."
  ok "PHP ${phpv:-?} OK"
}

# ----------------------------- Database schema -------------------------------
find_schema() {
  local f
  for f in /usr/share/zabbix/sql-scripts/mysql/server.sql.gz \
           /usr/share/zabbix-sql-scripts/mysql/server.sql.gz; do
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  find /usr/share -path '*sql-scripts/mysql/server.sql*' -print -quit 2>/dev/null
}

setup_database() {
  step "Creating database '${DB_NAME}' and user '${DB_USER}'"
  local qpass
  qpass="$(quote_sq "$DB_PASS")"
  "$DB_CLI" -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${qpass}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${qpass}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

  local tables
  tables="$("$DB_CLI" -uroot -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}'")"
  if (( tables > 0 )); then
    warn "Database '${DB_NAME}' already has ${tables} tables - skipping schema import."
  else
    local schema
    schema="$(find_schema)"
    [[ -n "$schema" ]] || die "Zabbix MySQL schema (server.sql.gz) not found - is zabbix-sql-scripts installed?"
    info "Importing schema from ${schema} (may take a few minutes, longer on a Raspberry Pi)..."
    "$DB_CLI" -uroot -e 'SET GLOBAL log_bin_trust_function_creators = 1;'
    if [[ "$schema" == *.gz ]]; then
      zcat "$schema" | "$DB_CLI" -uroot --default-character-set=utf8mb4 "$DB_NAME"
    else
      "$DB_CLI" -uroot --default-character-set=utf8mb4 "$DB_NAME" <"$schema"
    fi
    "$DB_CLI" -uroot -e 'SET GLOBAL log_bin_trust_function_creators = 0;'
    ok "Schema imported"
  fi

  # Frontend defaults: timezone and language (columns exist since Zabbix 5.2)
  local has_cols
  has_cols="$("$DB_CLI" -uroot -N -B -e "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='${DB_NAME}' AND table_name='config' AND column_name IN ('default_timezone','default_lang')")"
  if [[ "$has_cols" == "2" ]]; then
    "$DB_CLI" -uroot "$DB_NAME" -e "UPDATE config SET default_timezone='$(quote_sq "$TIMEZONE")', default_lang='$(quote_sq "$FRONTEND_LANG")';"
    ok "Frontend defaults: timezone=${TIMEZONE}, language=${FRONTEND_LANG}"
  fi

  if [[ -n "$ADMIN_PASS" ]]; then
    local hash
    hash="$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT, ["cost" => 10]);' -- "$ADMIN_PASS")"
    [[ "$hash" == '$2y$'* ]] || die "Could not hash the Admin password with PHP"
    "$DB_CLI" -uroot "$DB_NAME" -e "UPDATE users SET passwd='${hash}' WHERE username='Admin';"
    ok "Frontend 'Admin' password changed"
  fi
}

# ----------------------------- Configuration ---------------------------------
configure_server() {
  step "Configuring zabbix_server.conf"
  local conf=/etc/zabbix/zabbix_server.conf
  [[ -f "$conf" ]] || die "$conf not found"
  [[ -f "$conf.orig" ]] || cp -p "$conf" "$conf.orig"
  sed -i -E '/^(DBHost|DBName|DBUser|DBPassword|DBSocket)=/d; /^# --- installer managed ---$/d' "$conf"
  {
    echo "# --- installer managed ---"
    echo "DBName=${DB_NAME}"
    echo "DBUser=${DB_USER}"
    echo "DBPassword=${DB_PASS}"
  } >>"$conf"
  chmod 640 "$conf"
  chown root:zabbix "$conf" 2>/dev/null || true
  ok "zabbix_server.conf updated (backup: $conf.orig)"
}

configure_frontend() {
  step "Configuring the web frontend (${WEB_SERVER})"

  # 1) PHP settings required by Zabbix, applied to every PHP SAPI present
  local ini_content d
  ini_content="; Written by the Zabbix installer
date.timezone = ${TIMEZONE}
max_execution_time = 300
max_input_time = 300
memory_limit = 256M
post_max_size = 16M
upload_max_filesize = 2M
max_input_vars = 10000
"
  if [[ "$FAMILY" == "deb" ]]; then
    for d in /etc/php/*/fpm/conf.d /etc/php/*/apache2/conf.d /etc/php/*/cli/conf.d; do
      [[ -d "$d" ]] && printf '%s' "$ini_content" >"$d/99-zabbix.ini"
    done
  else
    printf '%s' "$ini_content" >/etc/php.d/99-zabbix.ini
  fi

  # 2) Frontend config file -> skips the setup wizard
  local web_group="www-data"
  [[ "$FAMILY" == "rpm" ]] && web_group="apache"
  mkdir -p /etc/zabbix/web
  local qpass
  qpass="$(quote_sq "$DB_PASS")"
  cat >/etc/zabbix/web/zabbix.conf.php <<EOF
<?php
// Zabbix GUI configuration file - generated by the installer.

\$DB['TYPE']            = 'MYSQL';
\$DB['SERVER']          = 'localhost';
\$DB['PORT']            = '0';
\$DB['DATABASE']        = '${DB_NAME}';
\$DB['USER']            = '${DB_USER}';
\$DB['PASSWORD']        = '${qpass}';
\$DB['SCHEMA']          = '';

\$DB['ENCRYPTION']      = false;
\$DB['KEY_FILE']        = '';
\$DB['CERT_FILE']       = '';
\$DB['CA_FILE']         = '';
\$DB['VERIFY_HOST']     = false;
\$DB['CIPHER_LIST']     = '';

\$DB['VAULT']           = '';
\$DB['VAULT_URL']       = '';
\$DB['VAULT_PREFIX']    = '';
\$DB['VAULT_DB_PATH']   = '';
\$DB['VAULT_TOKEN']     = '';
\$DB['VAULT_CERT_FILE'] = '';
\$DB['VAULT_KEY_FILE']  = '';

\$DB['DOUBLE_IEEE754']  = true;

\$ZBX_SERVER_NAME       = '$(quote_sq "$(hostname -s)")';

\$IMAGE_FORMAT_DEFAULT  = IMAGE_FORMAT_PNG;
EOF
  chown "root:${web_group}" /etc/zabbix/web/zabbix.conf.php 2>/dev/null || true
  chmod 640 /etc/zabbix/web/zabbix.conf.php

  # 3) Web server specifics
  if [[ "$FAMILY" == "deb" ]]; then
    PHP_FPM_SVC="$(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}' | sed 's/\.service$//' | sort -V | tail -n1)"
  else
    PHP_FPM_SVC="php-fpm"
  fi

  if [[ "$WEB_SERVER" == "apache" ]]; then
    if [[ "$FAMILY" == "deb" ]]; then
      WEB_SVC="apache2"
      # If Apache has no mod_php, hand .php files to PHP-FPM
      local mods
      mods="$(apache2ctl -M 2>/dev/null || true)"
      if [[ "${mods,,}" != *php* ]]; then
        if [[ -n "$PHP_FPM_SVC" ]]; then
          a2enmod -q proxy_fcgi setenvif >/dev/null
          a2enconf -q "${PHP_FPM_SVC}" >/dev/null 2>&1 || true
        else
          apt_install libapache2-mod-php
        fi
      fi
    else
      WEB_SVC="httpd"
    fi
  else
    WEB_SVC="nginx"
    local nconf=/etc/nginx/conf.d/zabbix.conf
    [[ "$FAMILY" == "deb" && -f /etc/zabbix/nginx.conf ]] && nconf=/etc/zabbix/nginx.conf
    [[ -f "$nconf" ]] || die "Nginx config $nconf not found"
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*listen[[:space:]]+[0-9]+;|        listen          ${NGINX_PORT};|; s|^[[:space:]]*#?[[:space:]]*server_name[[:space:]]+[^;]+;|        server_name     _;|" "$nconf"
    if [[ "$NGINX_PORT" == "80" ]]; then
      if [[ "$FAMILY" == "deb" ]]; then
        rm -f /etc/nginx/sites-enabled/default
      else
        warn "Port 80 on EL: the default server block in /etc/nginx/nginx.conf may answer first; edit it if needed."
      fi
    fi
    nginx -t
  fi
  ok "Frontend configured (setup wizard skipped, config in /etc/zabbix/web/zabbix.conf.php)"
}

configure_security() {
  step "SELinux and firewall"
  if [[ "$FAMILY" == "rpm" ]] && command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
    setsebool -P httpd_can_connect_zabbix on || true
    setsebool -P httpd_can_network_connect_db on || true
    if [[ "$WEB_SERVER" == "nginx" && "$NGINX_PORT" != "80" ]]; then
      semanage port -a -t http_port_t -p tcp "$NGINX_PORT" 2>/dev/null \
        || semanage port -m -t http_port_t -p tcp "$NGINX_PORT" 2>/dev/null || true
    fi
    ok "SELinux booleans set (httpd_can_connect_zabbix, httpd_can_network_connect_db)"
  fi

  (( CONFIGURE_FIREWALL )) || { info "Firewall configuration skipped"; return 0; }
  local web_port=80
  [[ "$WEB_SERVER" == "nginx" ]] && web_port="$NGINX_PORT"

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    firewall-cmd --quiet --permanent --add-port="${web_port}/tcp" --add-service=https \
                 --add-port=10050/tcp --add-port=10051/tcp
    firewall-cmd --quiet --reload
    ok "firewalld: opened ${web_port}, 443, 10050, 10051/tcp"
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${web_port}/tcp" >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow 10050/tcp >/dev/null
    ufw allow 10051/tcp >/dev/null
    ok "ufw: opened ${web_port}, 443, 10050, 10051/tcp"
  else
    info "No active firewalld/ufw found - nothing to open"
  fi
}

# ----------------------------- Services & checks -----------------------------
start_services() {
  step "Starting services"
  local svcs=(zabbix-server "$AGENT_SVC" "$WEB_SVC")
  [[ -n "$PHP_FPM_SVC" ]] && svc_exists "$PHP_FPM_SVC" && svcs+=("$PHP_FPM_SVC")
  systemctl daemon-reload
  systemctl enable "${svcs[@]}" >/dev/null 2>&1
  systemctl restart "${svcs[@]}"
  ok "Enabled and started: ${svcs[*]}"
}

health_check() {
  step "Health check"
  local failed=0 s
  sleep 5
  for s in mariadb zabbix-server "$AGENT_SVC" "$WEB_SVC"; do
    if systemctl is-active --quiet "$s"; then ok "$s is running"; else warn "$s is NOT running"; failed=1; fi
  done

  local log=/var/log/zabbix/zabbix_server.log errs=""
  [[ -f "$log" ]] && errs="$(grep -E 'cannot|Unable to start|unsupported' "$log" | tail -n 5 || true)"
  if [[ -n "$errs" ]]; then
    warn "Recent messages in $log:"
    printf '%s\n' "$errs" >&2
  fi

  local url code
  if [[ "$WEB_SERVER" == "nginx" ]]; then url="http://127.0.0.1:${NGINX_PORT}/"; else url="http://127.0.0.1/zabbix/"; fi
  code="$(curl -s -o /dev/null -w '%{http_code}' -L "$url" || true)"
  if [[ "$code" == "200" ]]; then ok "Frontend answers HTTP 200 at $url"; else warn "Frontend returned HTTP ${code:-none} at $url"; failed=1; fi

  (( failed )) && warn "Some checks failed - see $LOG_FILE and /var/log/zabbix/."
  return 0
}

save_credentials() {
  local url="$1"
  ( umask 077
    cat >"$CRED_FILE" <<EOF
# Zabbix ${ZBX_VERSION} installation - $(date '+%F %T')
Frontend URL: ${url}
Frontend login: Admin
Frontend password: ${ADMIN_PASS:-zabbix (CHANGE IT!)}
DB name: ${DB_NAME}
DB user: ${DB_USER}
DB password: ${DB_PASS}
EOF
  )
}

print_summary() {
  local ip url zver admin_label="zabbix   <-- change it now!"
  [[ -n "$ADMIN_PASS" ]] && admin_label="(the password you supplied, also in ${CRED_FILE})"
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -n "$ip" ]] || ip="<server-ip>"
  if [[ "$WEB_SERVER" == "nginx" ]]; then url="http://${ip}:${NGINX_PORT}/"; else url="http://${ip}/zabbix"; fi
  zver="$(zabbix_server -V 2>/dev/null | awk 'NR==1{print $NF}')"
  save_credentials "$url"

  cat <<EOF

${C_GRN}${C_BLD}=================================================================
 Zabbix ${zver} installed successfully
=================================================================${C_RST}
 Frontend : ${url}
 Login    : Admin / ${admin_label}
 Database : MariaDB $("$DB_CLI" -uroot -N -B -e 'SELECT VERSION()' 2>/dev/null | cut -d- -f1) | DB ${DB_NAME} | user ${DB_USER}
 Agent    : ${AGENT_PKG}
 Timezone : ${TIMEZONE} | Language: ${FRONTEND_LANG}
 Secrets  : ${CRED_FILE} (root only)
 Log      : ${LOG_FILE}
=================================================================
EOF
}

# ----------------------------- Main ------------------------------------------
main() {
  parse_args "$@"
  require_root

  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
  trap cleanup EXIT
  TMP_DIR="$(mktemp -d)"

  printf '%sZabbix %s All-in-One installer v%s%s  (%s)\n' "$C_BLD" "$ZBX_VERSION" "$SCRIPT_VERSION" "$C_RST" "$(date '+%F %T')"

  detect_platform
  check_supported
  preflight
  install_base_packages
  setup_locales
  setup_zabbix_repo
  setup_php_stack
  setup_mariadb
  install_zabbix_packages
  setup_database
  configure_server
  configure_frontend
  configure_security
  start_services
  health_check
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
