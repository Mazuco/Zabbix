#!/bin/bash

####
## Instalação rápida do Zabbix no Docker em sistemas Rocky Linux 9

## Setup de instalação:

## * Rocky Linux 9 S.O principal
## * Docker com Linux Alpine
## * Docker Zabbix 7.0 LTS
## * Docker Banco de dados PostgreSQL 16
## * Docker Servidor Web Ngnix

## Troque as variaveis DB_SERVER_HOST e ZBX_PASSIVESERVERS para o seu IP ou Hostname!


# Configurações de SElinux e FirewallD:

sed -i "s/SELINUX=enforcing/SELINUX=disabled/" /etc/selinux/config

sudo setenforce 0

# Vamos configurar o nosso Firewall:

sudo firewall-cmd --add-port=8080/tcp --permanent
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
  zabbix-server:
    container_name: "zabbix-server"
    image: zabbix/zabbix-server-pgsql:alpine-7.0-latest 
    restart: always
    ports:
      - 10051:10051
    networks:
      - zabbix7
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro 
    environment:
      ZBX_CACHESIZE: 4096M
      ZBX_HISTORYCACHESIZE: 1024M
      ZBX_HISTORYINDEXCACHESIZE: 1024M
      ZBX_TRENDCACHESIZE: 1024M
      ZBX_VALUECACHESIZE: 1024M
      DB_SERVER_HOST: "192.168.15.163"
      DB_PORT: 5432
      POSTGRES_USER: "zabbix"
      POSTGRES_PASSWORD: "zabbix123"
      POSTGRES_DB: "zabbix_db"
    stop_grace_period: 30s
    labels:
      com.zabbix.description: "Zabbix server with PostgreSQL database support"
      com.zabbix.company: "Zabbix LLC"
      com.zabbix.component: "zabbix-server"
      com.zabbix.dbtype: "pgsql"
      com.zabbix.os: "alpine"

  zabbix-web-nginx-pgsql:
    container_name: "zabbix-web"
    image: zabbix/zabbix-web-nginx-pgsql:alpine-7.0-latest
    restart: always
    ports:
      - 8080:8080
      - 8443:8443
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
      - ./cert/:/usr/share/zabbix/conf/certs/:ro
    networks:
      - zabbix7
    environment:
      ZBX_SERVER_HOST: "192.168.15.163"
      DB_SERVER_HOST: "192.168.15.163"
      DB_PORT: 5432
      POSTGRES_USER: "zabbix"
      POSTGRES_PASSWORD: "zabbix123"
      POSTGRES_DB: "zabbix_db"
      ZBX_MEMORYLIMIT: "1024M"
    depends_on:
      - zabbix-server
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/ping"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 30s
    stop_grace_period: 10s
    labels:
      com.zabbix.description: "Zabbix frontend on Nginx web-server with PostgreSQL database support"
      com.zabbix.company: "Zabbix LLC"
      com.zabbix.component: "zabbix-frontend"
      com.zabbix.webserver: "nginx"
      com.zabbix.dbtype: "pgsql"
      com.zabbix.os: "alpine"

  zabbix-db-agent:
    container_name: "zabbix-agent"
    image: zabbix/zabbix-agent:alpine-7.0-latest
    depends_on:
      - zabbix-server
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
      - /run/docker.sock:/var/run/docker.sock
    environment:
      ZBX_HOSTNAME: "zabbix7"
      ZBX_SERVER_HOST: "172.18.0.1"
      ZBX_ENABLEREMOTECOMMANDS: "1"
    ports:
      - 10050:10050
      - 31999:31999
    networks:
      - zabbix7
    stop_grace_period: 5s
    
  db:
    container_name: "zabbix_db"
    image: postgres:16-bullseye
    restart: always
    volumes:
     - zbx_db16:/var/lib/postgresql/data
    ports:
     - 5432:5432
    networks:
     - zabbix7
    environment:
     POSTGRES_USER: "zabbix"
     POSTGRES_PASSWORD: "zabbix123"
     POSTGRES_DB: "zabbix_db"

networks:
  zabbix7:
   driver: bridge
volumes:
  zbx_db16:
EOF

# Agora irá para o diretório e dar o comando para criar os container
cd /home/zabbix/

# Esse comando serve para criar os container
sudo docker compose up -d

# Esse comando serve para ver o container
sudo docker ps

# Se for necessário ver os logs basta dar o comando baixo
# sudo docker logs nomedocontainer
