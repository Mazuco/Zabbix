#!/usr/bin/env bash
set -euo pipefail

# ===============================
# Zabbix 7.0 LTS (Server + Agent) All-in-One
# Supported OSes in this script: Debian 11/12, Ubuntu 22.04/24.04, RHEL/Rocky 9/10
# Database: MariaDB v10 (official repository mirror.mariadb.org)
# Web server: Apache
# ===============================

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run this script as root." >&2
    exit 1
  fi
}

# Detects distribution (ID) and version (VERSION_ID)
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID,,}"  # lowercase force

    # rocky-linux -> rocky
    if [[ "$OS_ID" == "rocky-linux" ]]; then
      OS_ID="rocky"
    fi

    OS_VERSION_ID="${VERSION_ID%%.*}"  # takes only the part before the period, ex: 10.0 -> 10
  else
    echo "[ERROR] Unable to detect operating system." >&2
    exit 1
  fi
}

# Ensures only supported distros proceed
check_supported() {
  case "$OS_ID" in
    debian)
      [[ "$OS_VERSION_ID" =~ ^(11|12)$ ]] || { echo "[ERRO] Only Debian 11 and 12 are supported here." >&2; exit 1; }
      ;;
    ubuntu)
      [[ "$OS_VERSION_ID" =~ ^(22|24)$ ]] || { echo "[ERRO] Only Ubuntu 22.04 and 24.04 are supported here." >&2; exit 1; }
      ;;
    rocky|rhel)
      [[ "$OS_VERSION_ID" =~ ^(9|10)$ ]] || { echo "[ERRO] Only RHEL/Rocky 9 and 10 are supported here." >&2; exit 1; }
      ;;
    *)
      echo "[ERRO] Unsupported system. Use Debian 11/12, Ubuntu 22.04/24.04, or RHEL/Rocky 9/10." >&2
      exit 1
      ;;
  esac
}

# MariaDB 10 base packages and repository
setup_base_and_mariadb_repo() {
  echo "[INFO] Installing prerequisites and adding MariaDB 10 repository..."

  case "$OS_ID" in
    debian|ubuntu)
      apt update
      apt install -y wget lsb-release gnupg apache2 software-properties-common dirmngr ca-certificates apt-transport-https curl locales

      curl -fsSL https://mariadb.org/mariadb_release_signing_key.asc \
        | gpg --dearmor | tee /usr/share/keyrings/mariadb.gpg > /dev/null

      if [[ "$OS_ID" == "ubuntu" ]]; then
        echo "deb [arch=amd64,arm64,ppc64el signed-by=/usr/share/keyrings/mariadb.gpg] http://mirror.mariadb.org/repo/10.11/ubuntu/ $(lsb_release -cs) main" \
          > /etc/apt/sources.list.d/mariadb.list
        echo 'en_US.UTF-8 UTF-8' | tee -a /etc/locale.gen
        locale-gen
      else
        echo "deb [arch=amd64,arm64,ppc64el signed-by=/usr/share/keyrings/mariadb.gpg] http://mirror.mariadb.org/repo/10.11/debian/ $(lsb_release -cs) main" \
          > /etc/apt/sources.list.d/mariadb.list
        export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen
        locale-gen
      fi

      apt update
      DEBIAN_FRONTEND=noninteractive apt install -y mariadb-server mariadb-client
      ;;

    rocky|rhel)
      dnf install -y dnf-utils curl wget gnupg2 ca-certificates policycoreutils-python-utils
      dnf install -y mariadb mariadb-server httpd php php-mysqlnd php-gd php-xml php-bcmath php-mbstring php-ldap php-json php-opcache
      systemctl enable --now httpd mariadb
      ;;
  esac

  systemctl enable --now mariadb || true
}

# Configure Zabbix 7.0 repository according to system
setup_zabbix_repo() {
  echo "[INFO] Setting up the official Zabbix 7.0 repository..."
  local base_url pkg

  case "$OS_ID" in
    debian)
      base_url="https://repo.zabbix.com/zabbix/7.0/debian/pool/main/z/zabbix-release"
      case "$OS_VERSION_ID" in
        11) pkg="zabbix-release_latest_7.0+debian11_all.deb" ;;
        12) pkg="zabbix-release_latest_7.0+debian12_all.deb" ;;
      esac
      ;;
    ubuntu)
      base_url="https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release"
      case "$OS_VERSION_ID" in
        22.04) pkg="zabbix-release_latest_7.0+ubuntu22.04_all.deb" ;;
        24.04) pkg="zabbix-release_latest_7.0+ubuntu24.04_all.deb" ;;
      esac
      ;;
    rocky|rhel)
      rpm -Uvh https://repo.zabbix.com/zabbix/7.0/rhel/${OS_VERSION_ID}/x86_64/zabbix-release-latest-7.0.el${OS_VERSION_ID}.noarch.rpm
      dnf clean all
      return
      ;;
  esac

  echo "[INFO] Downloading $pkg ..."
  rm -f /tmp/zabbix-release*.deb
  wget -qO "/tmp/$pkg" "$base_url/$pkg"
  dpkg -i "/tmp/$pkg"
  apt update
}

# Install server + frontend + agent and PHP prerequisites via package meta
install_zabbix_packages() {
  echo "[INFO] Installing Zabbix packages..."

  case "$OS_ID" in
    debian|ubuntu)
      DEBIAN_FRONTEND=noninteractive apt install -y \
        zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent
      ;;
    rocky|rhel)
      dnf install -y zabbix-server-mysql zabbix-web-mysql zabbix-apache-conf zabbix-sql-scripts zabbix-agent
      ;;
  esac
}

# Creates base, user and imports initial schema
setup_db_schema() {
  echo "[INFO] Creating base 'zabbix' and user 'zabbix'..."
  mariadb -uroot <<SQL
CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY 'zabbix123';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
FLUSH PRIVILEGES;
SQL

  echo "[INFO] Importing initial schema... (may take a few minutes)"
  zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mariadb -uzabbix -pzabbix123 zabbix
}

# Adjust Zabbix Server configuration and Apache timezone
final_tuning() {
  echo "[INFO] Adjusting Zabbix and Apache configuration..."

  sed -i \
    -e "s/^#\?\s*DBUser=.*/DBUser=zabbix/" \
    -e "s/^#\?\s*DBPassword=.*/DBPassword=zabbix123/" \
    -e "s/^#\?\s*DBName=.*/DBName=zabbix/" \
    /etc/zabbix/zabbix_server.conf

  if grep -q "date.timezone" /etc/zabbix/apache.conf 2>/dev/null; then
    sed -i 's#^[;#]\s*php_value\s\+date.timezone\s\+.*#php_value date.timezone America/Sao_Paulo#' /etc/zabbix/apache.conf
  else
    echo "php_value date.timezone America/Sao_Paulo" >> /etc/zabbix/apache.conf
  fi

  case "$OS_ID" in
    debian|ubuntu)
      systemctl enable --now zabbix-server zabbix-agent apache2
      systemctl restart zabbix-server zabbix-agent apache2
      ;;
    rocky|rhel)
      systemctl enable --now zabbix-server zabbix-agent httpd
      systemctl restart zabbix-server zabbix-agent httpd
      ;;
  esac


}

print_summary() {
  echo ""
  echo "==============================================="
  echo "Installation complete!"
  echo "Access the frontend: http://<IP_DO_SERVIDOR>/zabbix"
  echo "Default login: Admin / zabbix"
  echo "Database: MariaDB v10  |  DB: zabbix  |  User: zabbix  |  Password: zabbix123"
  echo "(Change passwords in production.)"
  echo "==============================================="
}

main() {
  require_root
  detect_distro
  check_supported
  setup_base_and_mariadb_repo
  setup_zabbix_repo
  install_zabbix_packages
  setup_db_schema
  final_tuning
  print_summary
}

main "$@"

