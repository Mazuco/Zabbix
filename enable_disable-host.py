#!/usr/bin/python3
# -*- coding: utf-8 -*-
#
# Autor original: Opensource ICT Solutions B.V - license by GPL-3.0 
# Alteração feita por Vitor Mazuco
#
# 05-08-2024

import sys
import requests
import json
import os

url = 'http://SEUIP/zabbix/api_jsonrpc.php?'  # altere conforme a sua URL!!
token = "PUT_YOUR_TOKEN_HERE"  # coloque o seu TOKEN de acesso!
headers = {'Content-Type': 'application/json'}

state = sys.argv[1].lower()
hostname = sys.argv[2]  # habilita e desabilitar o host

def main():
    try:
        hostid = get_hostid(token, hostname)
        if not hostid:
            suggest_hosts(token, hostname)
            return

        if state == 'disable':
            event_dict, eventid_array = get_problems(hostid, token)
            toggle_host(hostid, token, state)
            close_problems(eventid_array, token)
            print(f"Host {hostid} disabled")
        elif state == 'enable':
            toggle_host(hostid, token, state)
            print(f"Host {hostid} enabled")
        else:
            print("Invalid state. Use 'enable' or 'disable'.")
    except Exception as e:
        print(f"An error occurred: {e}")

def get_hostid(token, hostname):
    payload = {
        'jsonrpc': '2.0',
        'method': 'host.get',
        'params': {
            'output': ['hostid'],
            'filter': {'host': hostname}
        },
        'auth': token,
        'id': 1
    }

    response = requests.post(url, data=json.dumps(payload), headers=headers)
    data = response.json()

    if data["result"]:
        return data["result"][0]["hostid"]
    return None

def get_problems(hostid, token):
    payload = {
        'jsonrpc': '2.0',
        'method': 'problem.get',
        'params': {
            'output': ['eventid', 'name', 'severity'],
            'hostids': hostid,
            'sortfield': ['eventid'],
            'sortorder': "DESC",
            'filter': {'r_eventid': "0"}
        },
        'auth': token,
        'id': 1
    }

    response = requests.post(url, data=json.dumps(payload), headers=headers)
    data = response.json()

    eventid_array = [str(event["eventid"]) for event in data["result"]]
    event_dict = {event["eventid"]: {'name': event["name"], 'severity': event["severity"]} for event in data["result"]}
    return event_dict, eventid_array

def toggle_host(hostid, token, state):
    set_status = '1' if state == 'disable' else '0'

    payload = {
        'jsonrpc': '2.0',
        'method': 'host.update',
        'params': {
            'hostid': hostid,
            'status': set_status
        },
        'auth': token,
        'id': 1
    }

    requests.post(url, data=json.dumps(payload), headers=headers)

def close_problems(eventid_array, token):
    payload = {
        'jsonrpc': '2.0',
        'method': 'event.acknowledge',
        'params': {
            'eventids': eventid_array,
            'action': '1'
        },
        'auth': token,
        'id': 1
    }

    requests.post(url, data=json.dumps(payload), headers=headers)

def suggest_hosts(token, partial_hostname):
    payload = {
        'jsonrpc': '2.0',
        'method': 'host.get',
        'params': {
            'output': ['host'],
            'search': {'host': partial_hostname},
            'limit': 10
        },
        'auth': token,
        'id': 1
    }

    response = requests.post(url, data=json.dumps(payload), headers=headers)
    data = response.json()

    if data["result"]:
        print("Host not found. Did you mean one of these?")
        for host in data["result"]:
            print(f"- {host['host']}")
    else:
        print("No similar hosts found.")

if __name__ == '__main__':
    main()
