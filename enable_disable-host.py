#!/usr/bin/python3
# -*- coding: utf-8 -*-
#
# Autor original: Opensource ICT Solutions B.V - license by GPL-3.0 
# Alteração feita por Vitor Mazuco
# https://github.com/Mazuco/Zabbix/blob/master/enable_disable-host.py
#
# 05-08-2024

import sys
import requests
import json
import os
import time

url = 'http://SEUIP/zabbix/api_jsonrpc.php?' # altere conforme a sua URL!!
token = "PUT_YOUR_TOKEN_HERE"  # coloque o seu TOKEN de acesso!
headers = {'Content-Type': 'application/json'}

state    = sys.argv[1]
hostname = sys.argv[2] # habilita e desabilitar o host

def main():
    hostid = hostid_get(token)
    if sys.argv[1].lower() == 'disable':
        event_dict,eventid_array = get_problems(hostid,token)
        toggle_host(hostid,token)
        close_problems(eventid_array, token)
        print("Host " + hostid + " disabled")
    elif sys.argv[1].lower() == 'enable':
        toggle_host(hostid, token)
        print("Host " + hostid + " enabled")
    else:
        print("Feito!")
#    os.system('zabbix_server -R config_cache_reload')

def hostid_get(token):
    payload = {}
    payload['jsonrpc'] = '2.0'
    payload['method'] = 'host.get'
    payload['params'] = {}
    payload['params']['output'] = ['hostid']
    payload['params']['filter'] = {}
    payload['params']['filter']['host'] = hostname
    payload['auth'] = token
    payload['id'] = 1


    #Doing the request
    request = requests.post(url, data=json.dumps(payload), headers=headers)
    data = request.json()

    hostid = data["result"][0]["hostid"]
    return hostid

def get_problems(hostid,token):
    payload = {}
    payload['jsonrpc'] = '2.0'
    payload['method'] = 'problem.get'
    payload['params'] = {}
    payload['params']['output'] = ['eventid','name','severity']
    payload['params']['hostids'] = hostid
    payload['params']['sortfield'] = ['eventid']
    payload['params']['sortorder'] = "DESC"
    payload['params']['filter'] = {}
    payload['params']['filter']['r_eventid'] = "0"
    payload['auth'] = token
    payload['id'] = 1

    request = requests.post(url, data=json.dumps(payload), headers=headers)
    data = request.json()

    eventid_array = []
    for eventid in data["result"]:
            eventid_array.append(str(eventid["eventid"]))

    event_dict = {}
    for x in data["result"]:
        event_dict[x["eventid"]] = {}
        event_dict[x["eventid"]]['name'] = x["name"]
        event_dict[x["eventid"]]['name'] = x["name"]
        event_dict[x["eventid"]]['severity'] = x["severity"]
    return event_dict, eventid_array


def toggle_host(hostid, token):
    if sys.argv[1].lower() == 'disable':
        set_status = '1'
    elif sys.argv[1].lower() == 'enable':
        set_status = '0'

    payload = {}
    payload['jsonrpc'] = '2.0'
    payload['method'] = 'host.update'
    payload['params'] = {}
    payload['params']['hostid'] = hostid
    payload['params']['status'] = set_status
    payload['auth'] = token
    payload['id'] = 1

    request = requests.post(url, data=json.dumps(payload), headers=headers)

def close_problems(eventid_array,token):
    payload = {}
    payload['jsonrpc'] = '2.0'
    payload['method'] = 'event.acknowledge'
    payload['params'] = {}
    payload['params']['eventids'] = eventid_array
    payload['params']['action'] = '1'
    payload['auth'] = token
    payload['id'] = 1

    request = requests.post(url, data=json.dumps(payload), headers=headers)

if __name__ == '__main__':
    # Call to main
    main()
