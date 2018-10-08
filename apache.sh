#!/bin/bash


# Modificado por Vitor Mazuco                                                                        
# Data atualizacao: 
# 12/03/2018                                                                        
# Changelog:                                                                                          
#   - Alteração da variável "tmp"                                                                     
#   - Inclusão de CPULoad após atualização do Apache ter adicionado essa métrica no server-status     
#   - Inclusão de verificação da versão do Apache em execução no servidor                             


# O endereço IP de seu Servidor Apache, lembre-se de mudar o parâmetro host no script caso for monitorar um outro tipo de servidor.
host="localhost"
resposta=0

# Será salvo no diretório /tmp, mude de lugar, caso queira:
tmp="/tmp/apache_status"
captura_status=`wget --quiet -O $tmp http://$host/server-status?auto`

case $1 in
   TotalAccesses)
      $captura_status
      fgrep "Total Accesses:" $tmp | awk '{print $3}'
      resposta=$?;;
   TotalKBytes)
      $captura_status
      fgrep "Total kBytes:" $tmp | awk '{print $3}'
      resposta=$?;;
   CPULoad)
      $captura_status
      fgrep "CPULoad:" $tmp | awk '{print $2}'
      resposta=$?;;
   Uptime)
      $captura_status
      fgrep "Uptime:" $tmp | awk '{print $2}'
      resposta=$?;;
   ReqPerSec)
      $captura_status
      fgrep "ReqPerSec:" $tmp | awk '{print $2}'
      resposta=$?;;
   BytesPerSec)
      $captura_status
      fgrep "BytesPerSec:" $tmp | awk '{print $2}'
      resposta=$?;;
   BytesPerReq)
      $captura_status
      fgrep "BytesPerReq:" $tmp | awk '{print $2}'
      resposta=$?;;
   BusyWorkers)
      $captura_status
      fgrep "BusyWorkers:" $tmp | awk '{print $2}'
      resposta=$?;;
   IdleWorkers)
      $captura_status
      fgrep "IdleWorkers:" $tmp | awk '{print $2}'
      resposta=$?;;
   WaitingForConnection)
      $captura_status
      fgrep "Scoreboard:" $tmp | awk '{print $2}'| awk 'BEGIN { FS = "_" } ; { print NF-1 }'
      resposta=$?;;
   StartingUp)
      $captura_status
      fgrep "Scoreboard:" $tmp | awk '{print $2}'| awk 'BEGIN { FS = "S" } ; { print NF-1 }'
      resposta=$?;;
   ReadingRequest)
      $captura_status
      fgrep "Scoreboard:" $tmp| awk '{print $2}'| awk 'BEGIN { FS = "R" } ; { print NF-1 }'
      resposta=$?;;
   SendingReply)
      $captura_status
      fgrep "Scoreboard:" $tmp | awk '{print $2}'| awk 'BEGIN { FS = "W" } ; { print NF-1 }'
      resposta=$?;;
   KeepAlive)
      $captura_status
      fgrep "Scoreboard:" $tmp | awk '{print $2}'| awk 'BEGIN { FS = "K" } ; { print NF-1 }'
      resposta=$?;;
   DNSLookup)
      $captura_status
      fgrep "Scoreboard:" $tmp | awk '{print $2}'| awk 'BEGIN { FS = "D" } ; { print NF-1 }'
      resposta=$?;;
   ClosingConnection)
      $captura_status
      fgrep "Scoreboard:" $tmp | awk '{print $2}'| awk 'BEGIN { FS = "C" } ; { print NF-1 }'
      resposta=$?;;
   Logging)
      $captura_status
      fgrep "Scoreboard:" $tmp | awk '{print $2}'| awk 'BEGIN { FS = "L" } ; { print NF-1 }'
      resposta=$?;;
   GracefullyFinishing)
      $captura_status
      fgrep "Scoreboard:" $tmp | awk '{print $2}'| awk 'BEGIN { FS = "G" } ; { print NF-1 }'
      resposta=$?;;
  IdleCleanupOfWorker)
      $captura_status
      fgrep "Scoreboard:" $tmp | awk '{print $2}'| awk 'BEGIN { FS = "I" } ; { print NF-1 }'
      resposta=$?;;
  OpenSlotWithNoCurrentProcess)
      $captura_status
      fgrep "Scoreboard:" $tmp | awk '{print $2}'| awk 'BEGIN { FS = "." } ; { print NF-1 }'
      resposta=$?;;
    version)
      /usr/sbin/apachectl -v | grep "version" | cut -f2 -d "/" | awk '{print $1}'
      resposta=$?;;
   *)
      echo "ZBX_NOTSUPPORTED"
esac
if [ "$resposta" -ne 0 ]; then
   echo "ZBX_NOTSUPPORTED"
fi

exit $resposta
