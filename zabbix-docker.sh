#!/usr/bin/env bash
# =============================================================================
#  Zabbix 8.0 LTS em Docker - instalação rápida
#  Host: Rocky Linux / AlmaLinux / RHEL / Oracle Linux 9 e 10
#
#  Containers (Alpine):
#    - zabbix-server     Zabbix server 8.0 (PostgreSQL)
#    - zabbix-web        Frontend Nginx  -> http://IP:8080  e  https://IP:8443
#    - zabbix-agent      Zabbix agent 2 (monitora o próprio stack e o Docker)
#    - zabbix-snmptraps  Receptor de SNMP traps (162/udp)
#    - zabbix-db         PostgreSQL 18
#
#  Uso:   sudo ./zabbix-docker.sh
#  Ajustes por variável de ambiente, ex.:
#         sudo TZ=America/Sao_Paulo ZBX_TAG=alpine-8.0-latest ./zabbix-docker.sh
#
#  Arquivos: /opt/zabbix-docker/{docker-compose.yaml,.env,ssl/}
#  Senhas:   /opt/zabbix-docker/.env (somente root)
# =============================================================================

set -Eeuo pipefail

# ----------------------------- Configuração ----------------------------------
INSTALL_DIR="${INSTALL_DIR:-/opt/zabbix-docker}"
ZBX_TAG="${ZBX_TAG:-alpine-8.0-latest}"          # fixe uma versão em produção, ex.: alpine-8.0.1
PG_IMAGE="${PG_IMAGE:-postgres:18-bookworm}"
TZ="${TZ:-America/Sao_Paulo}"
WEB_HTTP_PORT="${WEB_HTTP_PORT:-8080}"
WEB_HTTPS_PORT="${WEB_HTTPS_PORT:-8443}"

# Caches do Zabbix server: valores para um laboratório de 4 GB de RAM.
# Os 4096M/1024M do script antigo reservavam ~8 GB de memória compartilhada.
ZBX_CACHESIZE="${ZBX_CACHESIZE:-256M}"
ZBX_HISTORYCACHESIZE="${ZBX_HISTORYCACHESIZE:-64M}"
ZBX_HISTORYINDEXCACHESIZE="${ZBX_HISTORYINDEXCACHESIZE:-16M}"
ZBX_TRENDCACHESIZE="${ZBX_TRENDCACHESIZE:-32M}"
ZBX_VALUECACHESIZE="${ZBX_VALUECACHESIZE:-128M}"

# ----------------------------- Funções auxiliares ----------------------------
if [[ -t 1 ]]; then G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' B=$'\e[1m' N=$'\e[0m'; else G="" Y="" R="" B="" N=""; fi
info() { printf '%s[INFO]%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[AVISO]%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s[ERRO]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
trap 'die "Falha na linha $LINENO: $BASH_COMMAND"' ERR

# ----------------------------- Pré-checagens ---------------------------------
[[ $EUID -eq 0 ]] || die "Execute como root: sudo $0"

. /etc/os-release
case "${ID}" in
  rocky|almalinux|rhel|ol|centos) ;;
  *) die "Sistema não suportado: ${PRETTY_NAME}. Use Rocky/Alma/RHEL/Oracle 9 ou 10." ;;
esac
[[ "${VERSION_ID%%.*}" =~ ^(9|10)$ ]] || die "Versão não suportada: ${PRETTY_NAME}. Use a versão 9 ou 10."
[[ -e "/usr/share/zoneinfo/${TZ}" ]] || die "Fuso horário inválido: ${TZ}"
ok "Sistema: ${PRETTY_NAME}"

# ----------------------------- SELinux e firewall ----------------------------
# O SELinux continua ATIVO: o Docker funciona com ele em modo enforcing.
# (O script antigo desligava o SELinux, o que não é necessário nem recomendado.)
info "SELinux: $(getenforce 2>/dev/null || echo 'não instalado') (mantido como está)"

if systemctl is-active --quiet firewalld; then
  firewall-cmd --quiet --permanent --add-port="${WEB_HTTP_PORT}/tcp" \
                                   --add-port="${WEB_HTTPS_PORT}/tcp" \
                                   --add-port=10051/tcp \
                                   --add-port=162/udp
  firewall-cmd --quiet --reload
  ok "firewalld: liberadas ${WEB_HTTP_PORT}/tcp, ${WEB_HTTPS_PORT}/tcp, 10051/tcp e 162/udp"
else
  info "firewalld inativo - nenhuma regra criada"
fi

# ----------------------------- Docker ----------------------------------------
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  info "Instalando o Docker Engine + plugin compose (repositório oficial para RHEL)"
  # Pacotes que conflitam com o Docker oficial (ignora se não existirem)
  dnf remove -y docker docker-client docker-common docker-latest podman-docker runc >/dev/null 2>&1 || true
  curl -fsSL https://download.docker.com/linux/rhel/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo
  dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
dnf install -y jq openssl >/dev/null
systemctl enable --now docker
ok "Docker $(docker version --format '{{.Server.Version}}') e $(docker compose version --short | sed 's/^/compose /')"

# Quem rodou o sudo passa a usar docker sem sudo (efeito no próximo login)
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  usermod -aG docker "${SUDO_USER}"
  info "Usuário ${SUDO_USER} adicionado ao grupo docker (vale a partir do próximo login)"
fi
DOCKER_GID="$(getent group docker | cut -d: -f3)"

# ----------------------------- Diretório, .env e certificado -----------------
mkdir -p "${INSTALL_DIR}/ssl"
chmod 750 "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# Em uma nova execução, reaproveita a senha: o banco já foi criado com ela
if [[ -f .env ]] && grep -q '^POSTGRES_PASSWORD=' .env; then
  POSTGRES_PASSWORD="$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"
  info "Reaproveitando a senha do banco de ${INSTALL_DIR}/.env"
else
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}"
fi

cat > .env <<EOF
# Gerado por zabbix-docker.sh em $(date '+%F %T')
ZBX_TAG=${ZBX_TAG}
PG_IMAGE=${PG_IMAGE}
TZ=${TZ}
WEB_HTTP_PORT=${WEB_HTTP_PORT}
WEB_HTTPS_PORT=${WEB_HTTPS_PORT}
DOCKER_GID=${DOCKER_GID}

POSTGRES_USER=zabbix
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=zabbix

ZBX_CACHESIZE=${ZBX_CACHESIZE}
ZBX_HISTORYCACHESIZE=${ZBX_HISTORYCACHESIZE}
ZBX_HISTORYINDEXCACHESIZE=${ZBX_HISTORYINDEXCACHESIZE}
ZBX_TRENDCACHESIZE=${ZBX_TRENDCACHESIZE}
ZBX_VALUECACHESIZE=${ZBX_VALUECACHESIZE}
EOF
chmod 600 .env

# Certificado autoassinado para o HTTPS do frontend (a imagem lê de /etc/ssl/nginx)
if [[ ! -f ssl/ssl.crt ]]; then
  info "Gerando certificado autoassinado (o dhparam pode levar até 1 minuto)"
  IP_ADDR="$(hostname -I | awk '{print $1}')"
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout ssl/ssl.key -out ssl/ssl.crt \
    -subj "/CN=$(hostname -f)" -addext "subjectAltName=DNS:$(hostname -f),IP:${IP_ADDR}" 2>/dev/null
  openssl dhparam -out ssl/dhparam.pem 2048 2>/dev/null
  chmod 755 ssl && chmod 644 ssl/ssl.crt ssl/ssl.key ssl/dhparam.pem
fi

# ----------------------------- docker-compose.yaml ---------------------------
cat > docker-compose.yaml <<'EOF'
name: zabbix

x-tz: &tz
  TZ: ${TZ}

services:
  db:
    container_name: zabbix-db
    image: ${PG_IMAGE}
    restart: unless-stopped
    environment:
      <<: *tz
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      # PostgreSQL 18+: o volume é /var/lib/postgresql (NÃO mais .../data)
      - pgdata:/var/lib/postgresql
    networks: [zabbix8]
    # sem "ports": o banco só é acessível pela rede interna dos containers
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 10
    stop_grace_period: 60s

  zabbix-server:
    container_name: zabbix-server
    image: zabbix/zabbix-server-pgsql:${ZBX_TAG}
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "10051:10051"
    environment:
      <<: *tz
      DB_SERVER_HOST: db
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      ZBX_CACHESIZE: ${ZBX_CACHESIZE}
      ZBX_HISTORYCACHESIZE: ${ZBX_HISTORYCACHESIZE}
      ZBX_HISTORYINDEXCACHESIZE: ${ZBX_HISTORYINDEXCACHESIZE}
      ZBX_TRENDCACHESIZE: ${ZBX_TRENDCACHESIZE}
      ZBX_VALUECACHESIZE: ${ZBX_VALUECACHESIZE}
      ZBX_ENABLE_SNMP_TRAPS: "true"
    volumes:
      - snmptraps:/var/lib/zabbix/snmptraps:ro
    networks: [zabbix8]
    stop_grace_period: 30s

  zabbix-web:
    container_name: zabbix-web
    image: zabbix/zabbix-web-nginx-pgsql:${ZBX_TAG}
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
      zabbix-server:
        condition: service_started
    ports:
      - "${WEB_HTTP_PORT}:8080"
      - "${WEB_HTTPS_PORT}:8443"
    environment:
      <<: *tz
      PHP_TZ: ${TZ}
      ZBX_SERVER_HOST: zabbix-server
      ZBX_SERVER_NAME: "Zabbix 8.0"
      DB_SERVER_HOST: db
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      ZBX_MEMORYLIMIT: "512M"
    volumes:
      - ./ssl:/etc/ssl/nginx:ro
    networks: [zabbix8]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/ping"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 30s
    stop_grace_period: 10s

  zabbix-agent:
    container_name: zabbix-agent
    hostname: zabbix-agent
    image: zabbix/zabbix-agent2:${ZBX_TAG}
    restart: unless-stopped
    depends_on: [zabbix-server]
    environment:
      <<: *tz
      ZBX_HOSTNAME: "Zabbix server"       # mesmo nome do host padrão do Zabbix
      ZBX_SERVER_HOST: zabbix-server
    group_add:
      - "${DOCKER_GID}"                   # acesso ao docker.sock para o plugin Docker
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [zabbix8]
    stop_grace_period: 5s

  zabbix-snmptraps:
    container_name: zabbix-snmptraps
    image: zabbix/zabbix-snmptraps:${ZBX_TAG}
    restart: unless-stopped
    environment:
      <<: *tz
    ports:
      - "162:1162/udp"
    volumes:
      - snmptraps:/var/lib/zabbix/snmptraps
    networks: [zabbix8]

networks:
  zabbix8:
    driver: bridge

volumes:
  pgdata:
  snmptraps:
EOF

# ----------------------------- Subir os containers ---------------------------
info "Baixando as imagens e subindo os containers"
docker compose pull --quiet
docker compose up -d --remove-orphans

info "Aguardando o frontend responder (a 1ª subida cria o banco e leva 1-3 minutos)"
API="http://127.0.0.1:${WEB_HTTP_PORT}/api_jsonrpc.php"
api() {  # api METODO 'PARAMS_JSON' [TOKEN]
  local auth=()
  [[ -n "${3:-}" ]] && auth=(-H "Authorization: Bearer $3")
  curl -fsS -m 15 "$API" -H 'Content-Type: application/json-rpc' "${auth[@]}" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":$2,\"id\":1}"
}
ZBX_VERSION=""
for _ in $(seq 1 60); do
  ZBX_VERSION="$(api apiinfo.version '{}' 2>/dev/null | jq -r '.result // empty' || true)"
  [[ -n "$ZBX_VERSION" ]] && break
  sleep 5
done
[[ -n "$ZBX_VERSION" ]] || die "O frontend não respondeu em 5 minutos. Veja: docker compose -f ${INSTALL_DIR}/docker-compose.yaml logs"
ok "Zabbix ${ZBX_VERSION} respondendo"

# ----------------------------- Ajustes via API -------------------------------
# O host padrão "Zabbix server" vem com interface 127.0.0.1, que no Docker não
# chega ao agente. Apontamos para o nome do container e vinculamos o template Docker.
TOKEN="$(api user.login '{"username":"Admin","password":"zabbix"}' 2>/dev/null | jq -r '.result // empty' || true)"
if [[ -n "$TOKEN" ]]; then
  HOST_JSON="$(api host.get '{"filter":{"host":["Zabbix server"]},"selectInterfaces":["interfaceid"],"output":["hostid"]}' "$TOKEN")"
  HOSTID="$(jq -r '.result[0].hostid // empty' <<<"$HOST_JSON")"
  IFID="$(jq -r '.result[0].interfaces[0].interfaceid // empty' <<<"$HOST_JSON")"
  if [[ -n "$HOSTID" && -n "$IFID" ]]; then
    api host.update "{\"hostid\":\"$HOSTID\",\"interfaces\":[{\"interfaceid\":\"$IFID\",\"type\":1,\"main\":1,\"useip\":0,\"ip\":\"\",\"dns\":\"zabbix-agent\",\"port\":\"10050\"}]}" "$TOKEN" >/dev/null \
      && ok "Host 'Zabbix server' apontado para o container zabbix-agent"
    TPLID="$(api template.get '{"filter":{"host":["Docker by Zabbix agent 2"]},"output":["templateid"]}' "$TOKEN" | jq -r '.result[0].templateid // empty')"
    if [[ -n "$TPLID" ]]; then
      api host.massadd "{\"hosts\":[{\"hostid\":\"$HOSTID\"}],\"templates\":[{\"templateid\":\"$TPLID\"}]}" "$TOKEN" >/dev/null \
        && ok "Template 'Docker by Zabbix agent 2' vinculado"
    fi
  else
    warn "Host 'Zabbix server' não encontrado - ajuste a interface manualmente."
  fi
  api user.logout '[]' "$TOKEN" >/dev/null 2>&1 || true
else
  warn "Não foi possível logar como Admin/zabbix (senha já alterada?)."
  warn "Ajuste manual: Data collection > Hosts > Zabbix server > interface Agent: DNS 'zabbix-agent', Connect to DNS."
fi

# ----------------------------- Resumo ----------------------------------------
IP_ADDR="$(hostname -I | awk '{print $1}')"
docker compose ps --format 'table {{.Name}}\t{{.Status}}'
cat <<EOF

${G}${B}==============================================================
 Zabbix ${ZBX_VERSION} em Docker instalado
==============================================================${N}
 Frontend : http://${IP_ADDR}:${WEB_HTTP_PORT}
            https://${IP_ADDR}:${WEB_HTTPS_PORT} (certificado autoassinado)
 Login    : Admin / zabbix   <-- troque a senha no primeiro acesso
 Agentes  : apontem Server/ServerActive para ${IP_ADDR} (porta 10051)
 Traps    : envie SNMP traps para ${IP_ADDR}:162/udp
 Arquivos : ${INSTALL_DIR} (senha do banco em .env)

 Comandos úteis (dentro de ${INSTALL_DIR}):
   docker compose ps                 status
   docker compose logs -f zabbix-server
   docker compose pull && docker compose up -d     atualizar
   docker compose down               parar (os dados ficam nos volumes)
==============================================================
EOF
