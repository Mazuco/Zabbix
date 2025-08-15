#!/usr/bin/env bash
set -euo pipefail

# ===============================
# Zabbix 7.0 LTS (Server + Agent) All‑in‑One
# SOs suportados neste script: Debian 11/12, Ubuntu 22.04/24.04, RHEL/Rocky 9/10
# Banco de dados: MariaDB v10 (repositório oficial mirror.mariadb.org)
# Servidor Web: Apache
# ===============================

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "[ERRO] Execute este script como root." >&2
    exit 1
  fi
}

# Detecta distribuição (ID) e versão (VERSION_ID)
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID,,}"  # força lowercase

    # Normaliza: rocky-linux -> rocky
    if [[ "$OS_ID" == "rocky-linux" ]]; then
      OS_ID="rocky"
    fi

    OS_VERSION_ID="${VERSION_ID%%.*}"  # pega só a parte antes do ponto, ex: 10.0 -> 10
  else
    echo "[ERRO] Não foi possível detectar o sistema operacional." >&2
    exit 1
  fi
}

# Garante que apenas distros suportadas prossigam
check_supported() {
  case "$OS_ID" in
    debian)
      [[ "$OS_VERSION_ID" =~ ^(11|12)$ ]] || { echo "[ERRO] Apenas Debian 11 e 12 são suportados aqui." >&2; exit 1; }
      ;;
    ubuntu)
      [[ "$OS_VERSION_ID" =~ ^(22|24)$ ]] || { echo "[ERRO] Apenas Ubuntu 22.04 e 24.04 são suportados aqui." >&2; exit 1; }
      ;;
    rocky|rhel)
      [[ "$OS_VERSION_ID" =~ ^(9|10)$ ]] || { echo "[ERRO] Apenas RHEL/Rocky 9 e 10 são suportados aqui." >&2; exit 1; }
      ;;
    *)
      echo "[ERRO] Sistema não suportado. Use Debian 11/12, Ubuntu 22.04/24.04, ou RHEL/Rocky 9/10." >&2
      exit 1
      ;;
  esac
}

# Pacotes base e repositório do MariaDB 10.11
setup_base_and_mariadb_repo() {
  echo "[INFO] Instalando pré‑requisitos e adicionando repositório do MariaDB 10.11..."

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

# Configura repositório do Zabbix 7.0 conforme sistema
setup_zabbix_repo() {
  echo "[INFO] Configurando repositório oficial do Zabbix 7.0..."
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

  echo "[INFO] Baixando $pkg ..."
  rm -f /tmp/zabbix-release*.deb
  wget -qO "/tmp/$pkg" "$base_url/$pkg"
  dpkg -i "/tmp/$pkg"
  apt update
}

# Instala servidor + frontend + agent e pré‑requisitos PHP via meta do pacote
install_zabbix_packages() {
  echo "[INFO] Instalando pacotes Zabbix..."

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

# Cria base, usuário e importa esquema inicial
setup_db_schema() {
  echo "[INFO] Criando base 'zabbix' e usuário 'zabbix'..."
  mariadb -uroot <<SQL
CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY 'zabbix123';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
FLUSH PRIVILEGES;
SQL

  echo "[INFO] Importando esquema inicial... (pode levar alguns minutos)"
  zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mariadb -uzabbix -pzabbix123 zabbix
}

# Ajusta configuração do Zabbix Server e timezone do Apache
final_tuning() {
  echo "[INFO] Ajustando configuração do Zabbix e Apache..."

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
  echo "Instalação concluída!"
  echo "Acesse o frontend: http://<IP_DO_SERVIDOR>/zabbix"
  echo "Login padrão: Admin / zabbix"
  echo "Banco: MariaDB v10  |  DB: zabbix  |  User: zabbix  |  Senha: zabbix123"
  echo "(Altere as senhas em produção.)"
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

