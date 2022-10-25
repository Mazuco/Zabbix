#!/bin/bash
#################### SCRIPT PARA BACKUP MYSQL E DO APACHE DO ZABBIX ####################
# Vitor Mazuco <contato@vmzsolutions.com.br>                             #
# Created Jun, 2017                                                     ##

DATE=`date +%Y-%m-%d--%H:%M:%S`
SENHA='zabbix'

# Agora estamos começando o backup da pasta /var/www
echo "host_trapper backup.inicio $(date)" > /tmp/logBackup.trap

echo "host_trapper backupmysql.inicio $(date)" > /tmp/logBackupMysql.trap

# Gerando arquivo sql
mysqldump --add-drop-table -u root -p$SENHA -x -e -B zabbix > /backup/mysql/zabbix-$DATE.sql

# Compactando em bz2 e Excluindo arquivo
tar -cjf /backup/mysql/zabbix-$DATE.tar.bz2 -C /backup/mysql zabbix-$DATE.sql --remove-files

# Compactando o arquivo do apache
tar -czvf /tmp/backupDados.tgz /var/www /etc/zabbix*

# Verificando o tamanho do apache
TAMANHO=`du /tmp/backupDados.tgz | awk '{print $1}'`;

# Verificando o tamanho do MySQL
TAMANHO2=`du /backup/mysql/ | awk '{print $1}'`;

# Criando um log de backup
echo "host_trapper backup.tamanho $TAMANHO" >> /tmp/logBackup.trap

echo "host_trapper backupmysql.tamanho $TAMANHO2" >> /tmp/logBackupMysql.trap

echo "host_trapper backup.fim $(date)" >> /tmp/logBackup.trap

echo "host_trapper backupmysql.fim $(date)" >> /tmp/logBackupMysql.trap

# Usando o Zabbix Trap para o uso de trigger de backup
zabbix_sender -z 127.0.0.1 -i /tmp/logBackup.trap 
zabbix_sender -z 127.0.0.1 -i /tmp/logBackupMysql.trap

# Por fim, vamos remover os backups antigos, e sempre deixando os últimos 10 dias

TIME="+10"

find /backup/mysql -name "*.bz2" -ctime +10 -exec rm {} \;

exit 0
