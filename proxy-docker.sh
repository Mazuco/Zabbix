#!/bin/bash

####
## Instalação rápida do Zabbix Proxy no Docker em sistemas Rocky Linux 9

## Setup de instalação:

## * Rocky Linux 9 S.O principal
## * Docker com Alpine Linux
## * Docker Zabbix Proxy 7.0 LTS
## * Docker Banco de dados SQLite

## Troque as variaveis ZBX_SERVER_HOST para o IP do Zabbix Server e ZBX_TLSPSKIDENTITY para o seu nome do zabbix proxy

# Configurações de SElinux e FirewallD:

sed -i "s/SELINUX=enforcing/SELINUX=disabled/" /etc/selinux/config

sudo setenforce 0

# Vamos configurar o nosso Firewall:

sudo firewall-cmd --add-port=10051/tcp --permanent
sudo firewall-cmd --add-port=10050/tcp --permanent
sudo firewall-cmd --add-port=162/udp --permanent
sudo firewall-cmd --reload

# Os três primeiros comando é para instalar o docker e update do SO
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf -y install docker-ce docker-ce-cli containerd.io
sudo usermod -aG docker $(whoami)
sudo systemctl enable --now docker

# Esse comando serve para criar o diretório onde irá ficar o docker-compose.yaml
sudo mkdir -p /home/zabbix/

# Agora é a criação do arquivo docker-compose.yaml
cat <<EOF > /home/zabbix/docker-compose.yaml
services:
  zabbix-proxy:
    container_name: "zabbix-proxy"
    image: zabbix/zabbix-proxy-sqlite3:alpine-7.0-latest
    pull_policy: always
    environment:
      - ZBX_PROXYMODE=0  # 0 - active proxy and 1 - passive proxy
      - ZBX_SERVER_HOST=192.168.15.164 #IP DOS ZABBIX SERVER
      - ZBX_SERVER_PORT=10051 #PORTA UTILIZADA 
      - ZBX_HOSTNAME=proxy01 #NOME DO SEU PROXY
      - ZBX_DEBUGLEVEL=3  # 0 - basic info, 1 - critical, 2 - error, 3 - warning                                                                                                                                                             s, 4 - for debugging, 5 - extended debugging
      - ZBX_ENABLEREMOTECOMMANDS=1
      - ZBX_PROXYLOCALBUFFER=0  # mantém cópia dos eventos mesmo depois de envia                                                                                                                                                             r ao server (valor em horas)
      - ZBX_PROXYOFFLINEBUFFER=1  # 6 horas
      - ZBX_PROXYHEARTBEATFREQUENCY=60  # 60 seg
      - ZBX_PROXYCONFIGFREQUENCY=200
      - ZBX_DATASENDERFREQUENCY=1  # 1 Seg
      - ZBX_STARTHISTORYPOLLERS=2  # ----------------
      - ZBX_STARTPOLLERS=10 #500
      - ZBX_STARTPREPROCESSORS=20 #500
      - ZBX_STARTPOLLERSUNREACHABLE=10   #300
      - ZBX_STARTPINGERS=10  #100
      - ZBX_STARTDISCOVERERS=5
      - ZBX_STARTHTTPPOLLERS=5
      - ZBX_HOUSEKEEPINGFREQUENCY=1
      - ZBX_STARTVMWARECOLLECTORS=1
      - ZBX_VMWAREFREQUENCY=60
      - ZBX_VMWAREPERFFREQUENCY=60
      - ZBX_VMWARECACHESIZE=32M
      - ZBX_VMWARETIMEOUT=300
      - ZBX_CACHESIZE=32M
      - ZBX_STARTDBSYNCERS=10 #20
      - ZBX_HISTORYCACHESIZE=32M
      - ZBX_HISTORYINDEXCACHESIZE=32M
      - ZBX_TIMEOUT=30  # 30 Seg
      - ZBX_UNREACHABLEPERIOD=10
      - ZBX_UNAVAILABLEDELAY=10
      - ZBX_UNREACHABLEDELAY=10
      - ZBX_LOGSLOWQUERIES=3000
      - ZBX_STATSALLOWEDIP=127.0.0.1
      - ZBX_TLSCONNECT=psk
      - ZBX_TLSACCEPT=psk
      - ZBX_TLSPSKIDENTITY=proxy01 #NOME DO SEU PROXY
      - ZBX_TLSPSKFILE=zabbix_proxy.psk
    restart: always
    network_mode: host
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /zabbix-proxy/usr/lib/zabbix/alertscripts:/usr/lib/zabbix/alertscripts:r                                                                                                                                                             o
      - /zabbix-proxy/usr/lib/zabbix/externalscripts:/usr/lib/zabbix/externalscr                                                                                                                                                             ipts:ro
      - /zabbix-proxy/var/lib/zabbix/enc:/var/lib/zabbix/enc:ro
      - /zabbix-proxy/var/lib/zabbix/mibs:/var/lib/zabbix/mibs:ro
EOF

# Agora irá para o diretório e dar o comando para criar os container
cd /home/zabbix/

# Esse comando serve para criar os container
sudo docker compose up -d

# Esse comando serve para ver o container
sudo docker ps

# Se for necessário ver os logs basta dar o comando baixo
# sudo docker logs nomedocontainer
