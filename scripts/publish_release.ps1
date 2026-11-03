param (
    [string]$tag = "v1.3.610",
    [string]$apkPath = "C:\dev\CARRIN\build\app\outputs\flutter-apk\carrin_v1.3.610.apk",
    [string]$releaseTitle = "CARRIN v1.3.610",
    [string]$releaseNotes = "Notificações push em tempo real com app fechado via Firebase e download/instalação direta."
)

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class CredManager {
    [DllImport("Advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public long LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }

    public static string GetPassword(string target) {
        IntPtr credPtr;
        if (CredRead(target, 1, 0, out credPtr)) {
            CREDENTIAL cred = (CREDENTIAL)Marshal.PtrToStructure(credPtr, typeof(CREDENTIAL));
            byte[] b = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, b, 0, cred.CredentialBlobSize);
            string s2 = Encoding.UTF8.GetString(b);
            if (s2.StartsWith("ghp_") || s2.StartsWith("github_pat_")) return s2;
            return Encoding.Unicode.GetString(b);
        }
        return null;
    }
}
"@

$token = [CredManager]::GetPassword("git:https://github.com")
if (-not $token) {
    $token = [CredManager]::GetPassword("GitHub - https://api.github.com/wmartins090-web")
}

if (-not $token) {
    Write-Error "Token GitHub nao encontrado no Gerenciador de Credenciais."
    exit 1
}

$headers = @{
    "Authorization" = "Bearer $token"
    "Accept" = "application/vnd.github.v3+json"
    "User-Agent" = "CARRIN-Releaser"
}

$repo = "wmartins090-web/CARRIN"

if (-not (Test-Path $apkPath)) {
    Write-Error "APK nao encontrado em $apkPath"
    exit 1
}

Write-Output "Verificando release $tag no GitHub..."
$release = $null
try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/tags/$tag" -Headers $headers -Method Get
    Write-Output "Release existente encontrada: ID $($release.id)"
} catch {
    Write-Output "Criando nova release para a tag $tag..."
    $bodyObj = @{
        tag_name = $tag
        name = $releaseTitle
        body = $releaseNotes
        draft = $false
        prerelease = $false
    }
    $jsonBody = $bodyObj | ConvertTo-Json
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases" -Headers $headers -Method Post -Body $jsonBody -ContentType "application/json; charset=utf-8"
    Write-Output "Release criada com sucesso! ID: $($release.id)"
}

$releaseId = $release.id
if (-not $releaseId) {
    Write-Error "Nao foi possivel obter o ID da release no GitHub."
    exit 1
}

$assetName = [System.IO.Path]::GetFileName($apkPath)

if ($release.assets) {
    $existing = $release.assets | Where-Object { $_.name -eq $assetName }
    if ($existing) {
        Write-Output "Removendo asset antigo ID $($existing.id)..."
        Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/assets/$($existing.id)" -Headers $headers -Method Delete
        Start-Sleep -Seconds 2
    }
}

Write-Output "Fazendo upload de $assetName ($([math]::Round((Get-Item $apkPath).Length / 1MB, 1)) MB) para a release..."
$uploadUrl = "https://uploads.github.com/repos/$repo/releases/$releaseId/assets?name=$assetName"

& curl.exe -s -X POST `
    -H "Authorization: Bearer $token" `
    -H "Accept: application/vnd.github.v3+json" `
    -H "Content-Type: application/vnd.android.package-archive" `
    --data-binary "@$apkPath" `
    "$uploadUrl"

Write-Output "`nUpload concluido! Verificando link publico..."
Start-Sleep -Seconds 4

$check = & curl.exe -L -I -s "https://github.com/$repo/releases/download/$tag/$assetName" | Select-String "HTTP/|Content-Type|Content-Length"
Write-Output $check

# Disparo automatico de Notificacao Push via Firebase FCM
Write-Output "`nDisparando notificacao push FCM para todos os usuarios instalados..."
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$fcmScript = Join-Path $scriptDir "send_fcm_notification.py"
if (Test-Path $fcmScript) {
    & python $fcmScript -v "$tag" -t "🚀 Nova versao do CARRIN ($tag)!" -b "$releaseNotes"
} else {
    Write-Warning "Script send_fcm_notification.py nao encontrado em $fcmScript"
}
