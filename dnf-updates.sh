#!/usr/bin/env bash
# Autor: Vitor Mazuco
# Descrição: Script para monitorar updates no Rocky/RHEL e enviar para Zabbix
# dnf-updates.sh
# Modificado em: 01/09/2025

ZABBIX_HOST=$(hostname)
SECURITY_UPDATES=$(dnf updateinfo list security updates -q | grep -cE '^[A-Z]')
TOTAL_UPDATES=$(dnf check-update --quiet | grep -cE '^[a-zA-Z0-9]')
DATE_RUN=$(date +%s)

# Saída no formato esperado pelo zabbix_sender
echo "dnf.updates.total[$ZABBIX_HOST] $TOTAL_UPDATES"
echo "dnf.updates.security[$ZABBIX_HOST] $SECURITY_UPDATES"
echo "dnf.updates.lastcheck[$ZABBIX_HOST] $DATE_RUN"







