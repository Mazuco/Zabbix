#!/bin/sh
# Script de instalação fácil em Debian 9.x com o Zabbix 3.x
# Autor: vitor.mazuco@gmail.com
# Data: 28/07/2017

apt-get install sudo -y 

set -e

# Versão 5.5 do MySQL
MYSQL_VERSION=5.5
[ -z "${MYSQL_PASSWD}" ] && MYSQL_PASSWD=mysql
[ -z "${ZABBIX_PASSWD}" ] && ZABBIX_PASSWD=zabbix

zabbix_server_install()
{
  cat <<EOF | sudo debconf-set-selections
mysql-server-${MYSQL_VERSION} mysql-server/root_password password ${MYSQL_PASSWD}
mysql-server-${MYSQL_VERSION} mysql-server/root_password_again password ${MYSQL_PASSWD}
EOF

  sudo apt install -y zabbix-server-mysql zabbix-frontend-php \
       php-mysql libapache2-mod-php sudo vim

  sudo cp /usr/share/doc/zabbix-frontend-php/examples/apache.conf \
       /etc/apache2/conf-available/zabbix-frontend-php.conf
  sudo a2enconf zabbix-frontend-php

  timezone=$(cat /etc/timezone)
  sudo sed -e 's/^post_max_size = .*/post_max_size = 16M/g' \
       -e 's/^max_execution_time = .*/max_execution_time = 300/g' \
       -e 's/^max_input_time = .*/max_input_time = 300/g' \
       -e "s:^;date.timezone =.*:date.timezone = \"${timezone}\":g" \
       -i /etc/php/7.0/apache2/php.ini

  cat <<EOF | sudo mysql -uroot -p${MYSQL_PASSWD}
create database zabbix character set utf8 collate utf8_bin;
grant all privileges on zabbix.* to zabbix@localhost identified by '${ZABBIX_PASSWD}';
exit
EOF

  for sql in schema.sql.gz images.sql.gz data.sql.gz; do
    zcat /usr/share/zabbix-server-mysql/"${sql}" | \
      sudo mysql -uzabbix -p${ZABBIX_PASSWD} zabbix;
  done

  sudo sed -e 's/# ListenPort=.*/ListenPort=10051/g' \
       -e "s/# DBPassword=.*/DBPassword=${ZABBIX_PASSWD}/g" \
       -i /etc/zabbix/zabbix_server.conf

  # Pula a etapa do setup.php do Zabbix
  cat <<EOF | sudo tee /etc/zabbix/zabbix.conf.php
<?php
// Zabbix GUI configuration file.
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
}

zabbix_main()
{
  zabbix_server_install
  zabbix_agent_install
}

zabbix_main
