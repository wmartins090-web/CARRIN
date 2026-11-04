#!/usr/bin/env python3
"""
Upload de APK e version.json para o Cloudflare R2 Object Storage.
"""

import os
import sys
import json
import argparse
import boto3
from botocore.exceptions import ClientError
import urllib.request

def load_credentials():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    cred_file = os.path.join(script_dir, "r2_credentials.json")
    if not os.path.exists(cred_file):
        print(f"[ERRO] Arquivo de credenciais R2 não encontrado em: {cred_file}")
        sys.exit(1)
    with open(cred_file, "r", encoding="utf-8") as f:
        return json.load(f)

def upload_file(apk_path, version=None):
    creds = load_credentials()
    
    endpoint_url = creds["endpoint_url"]
    access_key = creds["access_key_id"]
    secret_key = creds["secret_access_key"]
    bucket_name = creds["bucket_name"]
    public_base_url = creds["public_base_url"].rstrip("/")

    if not os.path.exists(apk_path):
        print(f"[ERRO] APK não encontrado em: {apk_path}")
        sys.exit(1)

    file_name = os.path.basename(apk_path)
    file_size_mb = round(os.path.getsize(apk_path) / (1024 * 1024), 1)

    print(f"[INFO] Conectando ao Cloudflare R2 (Bucket: {bucket_name})...")
    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint_url,
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        region_name="auto",
    )

    print(f"[INFO] Fazendo upload de {file_name} ({file_size_mb} MB) para o Cloudflare R2...")
    try:
        s3.upload_file(
            apk_path,
            bucket_name,
            file_name,
            ExtraArgs={"ContentType": "application/vnd.android.package-archive"}
        )
        print(f"[SUCESSO] Upload do APK concluído!")
    except ClientError as e:
        print(f"[ERRO] Falha no upload para o Cloudflare R2: {e}")
        sys.exit(1)

    # Também faz upload do version.json para o bucket R2 se existir
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    version_json_path = os.path.join(repo_root, "version.json")
    if os.path.exists(version_json_path):
        try:
            print("[INFO] Sincronizando version.json no Cloudflare R2...")
            s3.upload_file(
                version_json_path,
                bucket_name,
                "version.json",
                ExtraArgs={"ContentType": "application/json", "CacheControl": "no-cache, no-store, must-revalidate"}
            )
            print("[SUCESSO] version.json sincronizado no Cloudflare R2!")
        except Exception as e:
            print(f"[AVISO] Falha ao sincronizar version.json no R2: {e}")

    public_download_url = f"{public_base_url}/{file_name}"
    print(f"\n[OK] URL Pública Cloudflare R2: {public_download_url}")

    # Validação rápida de download HTTP HEAD
    try:
        req = urllib.request.Request(public_download_url, method="HEAD", headers={"User-Agent": "CARRIN-App/1.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            content_len = resp.headers.get("Content-Length")
            status = resp.status
            print(f"[INFO] Teste HTTP HEAD: Status {status}, Content-Length: {content_len} bytes")
    except Exception as e:
        print(f"[AVISO] Não foi possível verificar HEAD: {e}")

    return public_download_url

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Upload de APK para o Cloudflare R2")
    parser.add_argument("-a", "--apk", required=True, help="Caminho do arquivo APK")
    parser.add_argument("-v", "--version", help="Versão (opcional)")
    args = parser.parse_args()

    upload_file(args.apk, args.version)
