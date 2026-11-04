#!/usr/bin/env python3
"""
Script para disparo de notificações Push via Firebase Cloud Messaging (FCM HTTP v1 API).
Envia notificação para o tópico de atualizações do CARRIN ('novas_versoes').
"""

import sys
import os
import glob
import json
import argparse
from google.oauth2 import service_account
import google.auth.transport.requests
import requests

SCOPES = ['https://www.googleapis.com/auth/firebase.messaging']

def find_service_account_file():
    # 1. Checa arquivo explícito padrão ou glob em scripts/
    script_dir = os.path.dirname(os.path.abspath(__file__))
    patterns = [
        os.path.join(script_dir, "*firebase-adminsdk*.json"),
        os.path.join(script_dir, "firebase_service_account.json"),
        os.path.join(os.path.dirname(script_dir), "*firebase-adminsdk*.json"),
    ]
    for p in patterns:
        files = glob.glob(p)
        if files:
            return files[0]
    return None

def send_fcm_notification(version, title, body, build_number=None, topic="novas_versoes"):
    sa_path = find_service_account_file()
    if not sa_path:
        print("[ERRO] Arquivo de credenciais do Firebase (*firebase-adminsdk*.json) não encontrado na pasta scripts/.")
        sys.exit(1)

    print(f"[INFO] Usando chave de serviço: {os.path.basename(sa_path)}")
    with open(sa_path, "r", encoding="utf-8") as f:
        sa_data = json.load(f)
    
    project_id = sa_data.get("project_id")
    if not project_id:
        print("[ERRO] 'project_id' não encontrado no arquivo JSON de credenciais.")
        sys.exit(1)

    # Obter Access Token OAuth2
    credentials = service_account.Credentials.from_service_account_file(sa_path, scopes=SCOPES)
    auth_req = google.auth.transport.requests.Request()
    credentials.refresh(auth_req)
    access_token = credentials.token

    url = f"https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"
    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json; UTF-8",
    }

    clean_version = version.lstrip('v')
    b_num = str(build_number) if build_number else clean_version.replace('.', '')

    notification_title = title or f"Nova versão do CARRIN ({version})"
    notification_body = body or "Uma nova atualização está pronta para você. Toque para baixar agora!"

    payload = {
        "message": {
            "topic": topic,
            "notification": {
                "title": notification_title,
                "body": notification_body
            },
            "data": {
                "version": clean_version,
                "build_number": b_num,
                "title": notification_title,
                "body": notification_body,
            },
            "android": {
                "priority": "HIGH",
                "notification": {
                    "channel_id": "app_updates_v1",
                    "notification_priority": "PRIORITY_MAX",
                    "icon": "ic_notification_cart",
                    "color": "#10B981",
                    "default_sound": True,
                    "default_vibrate_timings": True
                }
            }
        }
    }

    print(f"[INFO] Enviando push para o tópico: '{topic}' via FCM v1...")
    response = requests.post(url, headers=headers, json=payload, timeout=15)

    if response.status_code == 200:
        print(f"[SUCESSO] Notificação enviada com sucesso! Resposta: {response.text}")
    else:
        print(f"[FALHA] Erro ao enviar notificação FCM: Status {response.status_code}")
        print(response.text)
        sys.exit(1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Disparar notificação Push de nova versão via FCM")
    parser.add_argument("-v", "--version", default="v1.3.610", help="Versão do app (ex: v1.3.610)")
    parser.add_argument("-t", "--title", default="", help="Título da notificação")
    parser.add_argument("-b", "--body", default="", help="Corpo da mensagem")
    parser.add_argument("-n", "--build-number", default="", help="Número de build (ex: 610)")
    parser.add_argument("--topic", default="novas_versoes", help="Tópico FCM (default: novas_versoes)")

    args = parser.parse_args()
    send_fcm_notification(
        version=args.version,
        title=args.title,
        body=args.body,
        build_number=args.build_number,
        topic=args.topic
    )
