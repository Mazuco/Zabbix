#!/bin/sh

# Sumário: Script de instalação fácil em Debian 11 com o Zabbix 6 e MySQL 8
# Autor: Vitor Mazuco
# Contato: contato@vmzsolutions.com.br
# Data: 19/05/2022

# Correção de PATH
export PATH="/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin:/usr/local/sbin:/usr/games"

rm /etc/apt/sources.list

cat <<EOF | tee /etc/apt/sources.list
deb http://deb.debian.org/debian/ bullseye main non-free contrib
# deb-src http://deb.debian.org/debian/ bullseye main non-free contrib

deb http://security.debian.org/debian-security bullseye-security/updates main contrib non-free
# deb-src http://security.debian.org/debian-security bullseye/updates main contrib non-free

# bullseye-updates, previously known as ‘volatile’
deb http://deb.debian.org/debian/ bullseye-updates main contrib non-free
# deb-src http://deb.debian.org/debian/ bullseye-updates main contrib non-free

# bullseye-backports, previously on backports.debian.org
deb http://deb.debian.org/debian/ bullseye-backports main contrib non-free
# deb-src http://deb.debian.org/debian/ bullseye-backports main contrib non-free
EOF

apt update

# Instalando os repositórios atuais:
apt-get install sudo gnupg -y 

sudo a2dismod php8.1 php5.6

sudo a2enmod php7.4

set -e

wget https://dev.mysql.com/get/mysql-apt-config_0.8.20-1_all.deb

dpkg -i mysql-apt-config_*_all.deb

apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 467B942D3A79BD29

apt update

wget https://repo.zabbix.com/zabbix/6.0/debian/pool/main/z/zabbix-release/zabbix-release_6.0-1+debian11_all.deb

apt install -y mysql-community-server 

dpkg -i zabbix-release_6.0-1+debian11_all.deb 

apt update

# Versão 8.0 do MySQL
MYSQL_VERSION=8.0
MYSQL_PASSWD=zabbix123 # ALTERE ESSA SENHA DO ROOT!!
ZABBIX_PASSWD=zabbix123 # ALTERE ESSA SENHA DO USUÁRIO ZABBIX!!
[ -z "${MYSQL_PASSWD}" ] && MYSQL_PASSWD=mysql
[ -z "${ZABBIX_PASSWD}" ] && ZABBIX_PASSWD=zabbix

# Bloco de instalação do Zabbix 6 com MySQL 8
zabbix_server_install()
{
  cat <<EOF | sudo debconf-set-selections mysql-server-${MYSQL_VERSION} mysql-server/root_password password ${MYSQL_PASSWD} mysql-server-${MYSQL_VERSION} mysql-server/root_password_again password ${MYSQL_PASSWD} 
EOF

  sudo apt install zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent 

  #sudo a2enconf zabbix-frontend-php

  timezone=$(cat /etc/timezone)
  sudo sed -e 's/^post_max_size = .*/post_max_size = 16M/g' \
       -e 's/^max_execution_time = .*/max_execution_time = 300/g' \
       -e 's/^max_input_time = .*/max_input_time = 300/g' \
       -e "s:^;date.timezone =.*:date.timezone = \"${timezone}\":g" \
       -i /etc/php/*/apache2/php.ini

  cat <<EOF | mysql -uroot -p${MYSQL_PASSWD}
create database zabbix character set utf8 collate utf8_bin;
use mysql;
create user 'zabbix'@'localhost' identified by '${ZABBIX_PASSWD}';
ALTER USER 'zabbix'@'localhost' IDENTIFIED WITH mysql_native_password BY '${ZABBIX_PASSWD}';
GRANT ALL ON zabbix.* to 'zabbix'@'localhost';
flush privileges;
exit
EOF

  zcat /usr/share/doc/zabbix-sql-scripts/mysql/server.sql.gz |mysql -uroot -p${MYSQL_PASSWD} zabbix;

  sudo sed -e 's/# ListenPort=.*/ListenPort=10051/g' \
       -e "s/# DBPassword=.*/DBPassword=${ZABBIX_PASSWD}/g" \
       -i /etc/zabbix/zabbix_server.conf

  # Pula a etapa do setup.php do Zabbix
  cat <<EOF | sudo tee /etc/zabbix/zabbix.conf.php
<?php
// Arquivo de configuração do Zabbix.
global \$DB;

\$DB['TYPE']     = 'MYSQL';
\$DB['SERVER']   = 'localhost';
\$DB['PORT']     = '0';
\$DB['DATABASE'] = 'zabbix';
\$DB['USER']     = 'zabbix';
\$DB['PASSWORD'] = '${ZABBIX_PASSWD}';

// Schema name. Used for IBM DB2 and PostgreSQL.
\$DB['SCHEMA'] = '';

\$ZBX_SERVER      = 'localhost';
\$ZBX_SERVER_PORT = '10051';
\$ZBX_SERVER_NAME = '';

\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
?>
EOF

  sudo a2enmod ssl
  sudo a2ensite default-ssl

  sudo systemctl enable zabbix-server zabbix-agent apache2
  sudo systemctl restart zabbix-server zabbix-agent apache2
}

zabbix_agent_install()
{
# Este nome de host é usado para o nome de host em
# Configuração -> Hosts -> Criar Host.
  sudo apt install -y zabbix-agent
  sudo sed -e "s/^Hostname=.*/Hostname=localhost/g" \
       -i /etc/zabbix/zabbix_agentd.conf
  systemctl enable zabbix-agent
}

zabbix_main()
{
  zabbix_server_install
  zabbix_agent_install
}

zabbix_main
