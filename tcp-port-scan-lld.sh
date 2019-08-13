#!/bin/bash
#################### SCRIPT PARA A DESCOBERTA DE SISTEMAS DE ARQUIVOS ####################
# Vitor Mazuco <contato@vmzsolutions.com.br>                             #
# Created Jun, 2017 

usage() {
    echo Uso: $0 hostname
    echo "Exemplo: $0 localhost"
}


if [ -z $1 ]; then
    echo "Nenhum host especificado" > /dev/stderr
    usage
    exit 1
fi

Scan=$(nmap -Pn --open -n $1)

OldIFS=$IFS
IFS="
"
procurar=".*/tcp open .*"

echo '{"data":['

contador=0

for linha in $Scan; do
    Tmp=$(echo $linha | sed -e 's/^[[:space:]]*//' | sed -r 's/ +/ /g' | grep $procurar)
    if [ $? -eq 0 ]; then
        porta=$(echo -n $Tmp | cut -d "/" -f 1 | tr -d "\n")
        servico=$(echo -n $Tmp | cut -d " " -f 3 | tr -d "\n")

        if [ "$servico" = "unknown" ]; then
            Name="port $Porta"
        fi

        if [ $contador -gt 0 ]; then
                printf  ','
                echo
        fi
        printf '{"{#PORTA}":"%s", "{#SERVICO}":"%s"}' "$porta" "$servico"

        let contador++

    fi
done

echo
echo ']}'

IFS=$OldIFS
