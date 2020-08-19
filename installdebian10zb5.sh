#!/bin/sh

# Sumário: Script de instalação fácil em Debian 10 Buster com o Zabbix 5 e MySQL 8
# Autor: VMZ Solutions
# Contato: contato@vmzsolutions.com.br
# Data: 12/05/2020

# Instalando os repositórios atuais:
apt-get install sudo gnupg -y 

set -e

wget http://repo.mysql.com/mysql-apt-config_0.8.15-1_all.deb

dpkg -i mysql-apt-config_0.8.15-1_all.deb

apt-key adv --keyserver keys.gnupg.net --recv-keys 8C718D3B5072E1F5

apt update

wget https://repo.zabbix.com/zabbix/5.0/debian/pool/main/z/zabbix-release/zabbix-release_5.0-1%2Bbuster_all.deb

apt install -y mysql-community-server 

dpkg -i zabbix-release_5.0-1+buster_all.deb 

apt update

# Versão 8.0 do MySQL
MYSQL_VERSION=8.0
MYSQL_PASSWD=Senha123! # ALTERE ESSA SENHA DO ROOT!!
ZABBIX_PASSWD=Z@bbix123 # ALTERE ESSA SENHA DO USUÁRIO ZABBIX!!
[ -z "${MYSQL_PASSWD}" ] && MYSQL_PASSWD=mysql
[ -z "${ZABBIX_PASSWD}" ] && ZABBIX_PASSWD=zabbix

# Bloco de instalação do Zabbix 5 com MySQL 8
zabbix_server_install()
{
  cat <<EOF | sudo debconf-set-selections mysql-server-${MYSQL_VERSION} mysql-server/root_password password ${MYSQL_PASSWD} mysql-server-${MYSQL_VERSION} mysql-server/root_password_again password ${MYSQL_PASSWD} 
EOF

  sudo apt install -y zabbix-server-mysql zabbix-frontend-php php-mysql libapache2-mod-php vim zabbix-apache-conf

  #sudo a2enconf zabbix-frontend-php

  timezone=$(cat /etc/timezone)
  sudo sed -e 's/^post_max_size = .*/post_max_size = 16M/g' \
       -e 's/^max_execution_time = .*/max_execution_time = 300/g' \
       -e 's/^max_input_time = .*/max_input_time = 300/g' \
       -e "s:^;date.timezone =.*:date.timezone = \"${timezone}\":g" \
       -i /etc/php/7.3/apache2/php.ini

  cat <<EOF | mysql -uroot -p${MYSQL_PASSWD}
create database zabbix character set utf8 collate utf8_bin;
use mysql;
create user 'zabbix'@'localhost' identified by '${ZABBIX_PASSWD}';
ALTER USER 'zabbix'@'localhost' IDENTIFIED WITH mysql_native_password BY '${ZABBIX_PASSWD}';
GRANT ALL ON zabbix.* to 'zabbix'@'localhost';
flush privileges;
exit
EOF

  zcat /usr/share/doc/zabbix-server-mysql/create.sql.gz |mysql -uroot -p${MYSQL_PASSWD} zabbix;

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

  sudo systemctl enable apache2 zabbix-server
  sudo systemctl restart apache2 zabbix-server
}

zabbix_agent_install()
{
  # This Hostname is used for Host name in
  # Configuration -> Hosts -> Create Host.
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
