#!/usr/bin/env bash
set -e

echo "Starting full installation of Zabbix 7.0 LTS with MariaDB 11 and Apache..."

# Detect distribution and version
detect_distro() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
    OS_VERSION_ID="$VERSION_ID"
  else
    echo "Unable to detect operating system."
    exit 1
  fi
}

check_supported() {
  case "$OS_ID" in
    debian)
      if [[ "$OS_VERSION_ID" == "11" || "$OS_VERSION_ID" == "12" ]]; then
        return 0
      fi
      ;;
    ubuntu)
      if [[ "$OS_VERSION_ID" == "22.04" || "$OS_VERSION_ID" == "24.04" ]]; then
        return 0
      fi
      ;;
    rhel)
      if [[ "$OS_VERSION_ID" == "9" || "$OS_VERSION_ID" == "10.0" ]]; then
        return 0
      fi
      ;;
    rocky)
      if [[ "$OS_VERSION_ID" == "9" || "$OS_VERSION_ID" == "10.0" ]]; then
        return 0
      fi
      ;;
  esac

  echo "Unsupported system or version not allowed:"
  echo "  Supported distributions:"
  echo "    - Debian: 11, 12"
  echo "    - Ubuntu: 22.04, 24.04"
  echo "    - RHEL: 9, 10"
  echo "    - Rocky Linux: 9, 10"
  exit 1
}

install_on_debian_ubuntu() {
  echo "Installing on Debian/Ubuntu..."
  apt update
  apt install -y wget lsb-release gnupg apache2 software-properties-common

  # Adicionar repositórios MariaDB 10.11
  wget -O /usr/share/keyrings/mariadb.gpg https://mariadb.org/mariadb_release_signing_key.asc
  if [[ "$OS_ID" == "ubuntu" ]]; then
    echo "deb [arch=amd64,arm64,ppc64el signed-by=/usr/share/keyrings/mariadb.gpg] http://mirror.mariadb.org/repo/10.11/ubuntu/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/mariadb.list
  else
    echo "deb [arch=amd64,arm64,ppc64el signed-by=/usr/share/keyrings/mariadb.gpg] http://mirror.mariadb.org/repo/10.11/debian/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/mariadb.list
  fi

  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y mariadb-server mariadb-client

  # Add Zabbix 7.0 LTS repository
  wget -qO /etc/apt/trusted.gpg.d/zabbix.gpg https://repo.zabbix.com/zabbix-official-repo.key
  echo "deb [signed-by=/etc/apt/trusted.gpg.d/zabbix.gpg] https://repo.zabbix.com/zabbix/7.0/$(lsb_release -sc) main" \
    > /etc/apt/sources.list.d/zabbix.list

  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-agent

  systemctl enable --now apache2 zabbix-server zabbix-agent mariadb
}

install_on_rhel_rocky() {
  echo "Instalando no RHEL/Rocky..."
  yum install -y wget

  # Repositório MariaDB 11
  cat > /etc/yum.repos.d/MariaDB.repo <<EOF
[mariadb]
name=MariaDB
baseurl=http://yum.mariadb.org/11.0/rhel$(echo $OS_VERSION_ID)/\$basearch
gpgkey=https://mariadb.org/mariadb_release_signing_key.asc
gpgcheck=1
EOF

  yum makecache fast
  yum install -y MariaDB-server MariaDB-client

  # Zabbix 7.0 LTS Repository
  rpm --import https://repo.zabbix.com/zabbix-official-repo.key
  cat > /etc/yum.repos.d/zabbix.repo <<EOF
[zabbix]
name=Zabbix Official Repository - \$basearch
baseurl=https://repo.zabbix.com/zabbix/7.0/rhel$(echo $OS_VERSION_ID)/\$basearch
enabled=1
gpgcheck=1
gpgkey=https://repo.zabbix.com/zabbix-official-repo.key
EOF

  yum makecache fast
  yum install -y zabbix-server-mysql zabbix-web-mysql zabbix-apache-conf zabbix-agent httpd

  systemctl enable --now httpd zabbix-server zabbix-agent mariadb
}

setup_mariadb_and_zabbix_schema() {
  echo "Configuring MariaDB and Zabbix database..."
  mysql -u root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY 'zabbix123';
CREATE DATABASE zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER 'zabbix'@'localhost' IDENTIFIED BY 'zabbix123';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
FLUSH PRIVILEGES;
SQL

  echo "Importing initial Zabbix schema..."
  zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | mysql -u zabbix -pzabbix123 zabbix
}

finalize() {
  echo "Adjusting Zabbix configuration..."
  sed -i "s/^# DBPassword=.*/DBPassword=zabbix123/" /etc/zabbix/zabbix_server.conf
  if systemctl is-active --quiet apache2; then
    # Debian/Ubuntu
    sed -i "s/; php_value date.timezone.*/php_value date.timezone America\/Sao_Paulo/" /etc/zabbix/apache.conf
  else
    # RHEL/Rocky
    sed -i "s/# php_value date.timezone.*/php_value date.timezone America\/Sao_Paulo/" /etc/httpd/conf.d/zabbix.conf
  fi

  systemctl restart zabbix-server zabbix-agent
  systemctl restart apache2 2>/dev/null || systemctl restart httpd

  echo "Installation complete!"
  echo "Access Zabbix Frontend via browser at the address: http://<IP_do_servidor>/zabbix"
  echo "Use default credentials (Admin / zabbix) and don't forget to change passwords after logging in."
}

main() {
  detect_distro
  check_supported

  case "$OS_ID" in
    debian|ubuntu)
      install_on_debian_ubuntu
      ;;
    rhel|rocky)
      install_on_rhel_rocky
      ;;
  esac

  setup_mariadb_and_zabbix_schema
  finalize
}

main "$@"

