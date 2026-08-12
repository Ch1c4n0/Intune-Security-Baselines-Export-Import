<#
.SYNOPSIS
  Importa Security Baselines para o Intune a partir de arquivos JSON exportados.

.DESCRIPTION
    Conecta ao Microsoft Graph via device code flow (sem Microsoft.Graph SDK),
    lê os arquivos JSON de uma pasta e apresenta um seletor interativo para que
    o operador escolha quais baselines importar.

    Compatível com JSONs exportados pelo Export-SecurityBaselines.ps1 ou pelo
    repositório dgulle/Security-Baselines.

.PARAMETER SourcePath
    Pasta com os arquivos JSON (busca recursiva nas subpastas).
    Padrão: pasta atual do script.

.PARAMETER GroupAssignmentId
    Object ID de um grupo do Entra ID. Se informado, todas as políticas criadas
    serão atribuídas a esse grupo.

.PARAMETER KeepAsBaseline
    Por padrão, o templateReference é zerado e a política é criada como
    Settings Catalog. Use este switch para preservar o vínculo com o template
    de Security Baseline original.

.PARAMETER OverwriteExisting
    Políticas com nome idêntico são deletadas e recriadas.
    Por padrão, políticas existentes são ignoradas.

.PARAMETER AdminUPN
    UPN do administrador — usado como login hint no device code.

.OUTPUTS
    Status no console e log em "<pasta do script>\Import-SecurityBaselines.log"

.NOTES
  Version:      2.0.0
  Author:       Marcelo Gonçalves
  Date:         2026-06-24
  Requires:     PowerShell 7+, permissão DeviceManagementConfiguration.ReadWrite.All
  Nota:         Não requer nenhum módulo do Microsoft.Graph SDK.

.EXAMPLE
  .\Import-SecurityBaselines.ps1
  Lê JSONs da pasta atual e abre seletor interativo.

.EXAMPLE
  .\Import-SecurityBaselines.ps1 -SourcePath "C:\Baselines\Backup"
  Importa da pasta especificada (apresenta seleção interativa).

.EXAMPLE
  .\Import-SecurityBaselines.ps1 -SourcePath ".\Exported-Baselines" -GroupAssignmentId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  Importa e atribui ao grupo informado.

.EXAMPLE
  .\Import-SecurityBaselines.ps1 -SourcePath ".\Exported-Baselines" -KeepAsBaseline
  Importa preservando o vínculo com o Security Baseline template original.
#>
[CmdletBinding()]
param(
    [string]$SourcePath        = "",
    [string]$GroupAssignmentId = "",
    [string]$AdminUPN          = "",
    [string]$ClientId          = "",   # Application (client) ID do app registrado no Entra ID
    [string]$TenantId          = "",   # Directory (tenant) ID ou domínio (ex: contoso.onmicrosoft.com)
    [switch]$KeepAsBaseline,
    [switch]$OverwriteExisting
)

# ── Constantes ───────────────────────────────────────────────────────────────
$script:graphBaseUri = 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies'

# ── Logging ──────────────────────────────────────────────────────────────────
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFilePath = Join-Path $scriptDir "Import-SecurityBaselines.log"

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
    try { Add-Content -Path $logFilePath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message" -ErrorAction Stop }
    catch { Write-Warning "Não foi possível gravar no log: $logFilePath" }
}

# ── Helper REST Graph ─────────────────────────────────────────────────────────
function Invoke-Graph {
    param([string]$Method, [string]$Uri, [object]$Body = $null, [string]$Token)
    $headers = @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" }
    $params  = @{ Method = $Method; Uri = $Uri; Headers = $headers; ErrorAction = "Stop" }
    if ($Body) { $params["Body"] = ($Body | ConvertTo-Json -Depth 100 -Compress) }
    Invoke-RestMethod @params
}

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Security Baselines - Importação Seletiva para Intune      " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Resolver pasta de origem ──────────────────────────────────────────────────
if (-not $SourcePath) { $SourcePath = Get-Location }

if (-not (Test-Path -Path $SourcePath)) {
    Write-Log "ERRO: Pasta não encontrada: $SourcePath" "Red"
    exit 1
}

# ── Listar JSONs (inclui subpastas) ───────────────────────────────────────────
$jsonFiles = Get-ChildItem -Path $SourcePath -Filter "*.json" -File -Recurse | Sort-Object FullName

if ($jsonFiles.Count -eq 0) {
    Write-Log "Nenhum arquivo .json encontrado em: $SourcePath" "Red"
    exit 1
}

Write-Log "  Pasta de origem : $SourcePath" "Yellow"
Write-Log "  JSON encontrados: $($jsonFiles.Count)" "Yellow"
Write-Host ""

# ── Montar lista com metadados para o seletor ─────────────────────────────────
$policyList = foreach ($file in $jsonFiles) {
    try {
        $data = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
        # Configuração: usa description (nome legível gravado pelo export) ou nome do arquivo
        $isFullBaseline = (-not $data.settingDefinitionId)
        $configName  = if ($data.description -and $data.description -notmatch '^vendor_|^device_vendor_') {
            $data.description
        } elseif ($isFullBaseline) { '(baseline completa)' } else { $data.settingDefinitionId }
        $categoryName = if ($data.category) { $data.category } `
                        elseif ($isFullBaseline) { '—' } else { 'Other' }
        [PSCustomObject]@{
            Categoria          = $categoryName
            Configuração       = $configName
            'Nome da Política' = $data.name
            Template           = "$($data.templateReference.templateDisplayName) ($($data.templateReference.templateDisplayVersion))"
            Plataforma         = $data.platforms
            Settings           = ($data.settings | Measure-Object).Count
            Arquivo            = $file.Name
            Pasta              = $file.DirectoryName
            FullPath           = $file.FullName
        }
    }
    catch {
        [PSCustomObject]@{
            Categoria          = '?'
            Configuração       = '(erro ao ler JSON)'
            'Nome da Política' = $file.BaseName
            Template           = "-"
            Plataforma         = "-"
            Settings           = 0
            Arquivo            = $file.Name
            Pasta              = $file.DirectoryName
            FullPath           = $file.FullName
        }
    }
}

# ── Seletor interativo ────────────────────────────────────────────────────────
Write-Host "  Abrindo seletor interativo..." -ForegroundColor Cyan
Write-Host "  -> Selecione as baselines desejadas (Ctrl+clique para múltiplos) e clique em OK." -ForegroundColor Yellow
Write-Host ""

$selected = $policyList |
    Select-Object Categoria, Configuração, 'Nome da Política', Template, Plataforma, Settings, Arquivo |
    Out-GridView -Title "Selecione as Security Baselines para importar" -PassThru

if (-not $selected -or $selected.Count -eq 0) {
    Write-Log "Nenhuma baseline selecionada. Operação cancelada." "Yellow"
    exit 0
}

$toImport = $policyList | Where-Object { $selected.Arquivo -contains $_.Arquivo }

Write-Host ""
Write-Log "  Selecionadas : $($toImport.Count) arquivo(s)" "Green"

# ── Agrupar e renomear ────────────────────────────────────────────────────────
# Cada "unidade de importação" pode ser um arquivo individual ou um merge de vários
$importUnits = [System.Collections.Generic.List[object]]::new()

# Agrupar por Categoria + Template (mesma baseline + mesma categoria = candidatos ao merge)
$groups = $toImport | Group-Object { "$($_.Categoria)|$($_.Template)" }

foreach ($grp in $groups) {
    $items = @($grp.Group)

    # Ler JSONs dos arquivos deste grupo
    $jsons = $items | ForEach-Object { Get-Content $_.FullPath -Raw | ConvertFrom-Json }

    if ($items.Count -gt 1) {
        # Múltiplos arquivos da mesma categoria — perguntar se quer unir
        Write-Host ""
        Write-Host "  Categoria  : $($items[0].Categoria)" -ForegroundColor Cyan
        Write-Host "  Template   : $($items[0].Template)"  -ForegroundColor Cyan
        Write-Host "  Settings   : $($items.Count) selecionadas:" -ForegroundColor Cyan
        $items | ForEach-Object { Write-Host "    - $($_.Configuração)" -ForegroundColor White }
        Write-Host ""
        $merge = Read-Host "  Unir em UMA política? (S/N)"

        if ($merge -in @('S','s','Y','y')) {
            # Merge: combinar todas as settings em uma política
            $first       = $jsons[0]
            $catName     = $items[0].Categoria
            $tmplName    = $first.templateReference.templateDisplayName
            $tmplVersion = $first.templateReference.templateDisplayVersion
            $defaultName = "$tmplName - $tmplVersion - $catName"

            Write-Host "  Nome padrão: $defaultName" -ForegroundColor Gray
            $newName = Read-Host "  Nome da política (Enter para manter)"
            if ([string]::IsNullOrWhiteSpace($newName)) { $newName = $defaultName }

            $mergedSettings = @($jsons | ForEach-Object { $_.settings } | Where-Object { $_ })

            $importUnits.Add([PSCustomObject]@{
                PolicyName   = $newName
                JsonObject   = [PSCustomObject]@{
                    description       = $catName
                    name              = $newName
                    platforms         = $first.platforms
                    technologies      = $first.technologies
                    templateReference = $first.templateReference
                    roleScopeTagIds   = @("0")
                    settings          = $mergedSettings
                }
            })
            continue
        }
    }

    # Sem merge (ou só 1 arquivo): importar individualmente com opção de renomear
    foreach ($item in $items) {
        $json        = $jsons[$items.IndexOf($item)]
        $defaultName = $json.name

        Write-Host ""
        Write-Host "  Configuração: $($item.Configuração)" -ForegroundColor Cyan
        Write-Host "  Nome padrão : $defaultName" -ForegroundColor Gray
        $newName = Read-Host "  Nome da política (Enter para manter)"
        if ([string]::IsNullOrWhiteSpace($newName)) { $newName = $defaultName }

        $json.name = $newName
        $importUnits.Add([PSCustomObject]@{
            PolicyName = $newName
            JsonObject = $json
        })
    }
}

Write-Host ""
Write-Log "  Políticas a criar: $($importUnits.Count)" "Green"
if ($GroupAssignmentId) { Write-Log "  Grupo        : $GroupAssignmentId" "Yellow" }
$modeLabel = if ($KeepAsBaseline) { "Security Baseline (templateReference preservado)" } else { "Settings Catalog (templateReference zerado)" }
Write-Log "  Modo         : $modeLabel" "Yellow"
Write-Host ""

$proceed = Read-Host "Continuar com a importação? (Y/N)"
if ($proceed -notin @('Y', 'y')) {
    Write-Log "Importação cancelada pelo usuário." "Red"
    exit 0
}

# ── Step 1 – Autenticação ─────────────────────────────────────────────────────
# ClientId/TenantId não são mais hardcoded — vêm de parâmetro ou são perguntados aqui.
if (-not $ClientId) {
    Write-Host "  ClientId não informado (use -ClientId ou digite abaixo)." -ForegroundColor Yellow
    Write-Host "  Enter para usar o Microsoft Graph PowerShell (multi-tenant, exige consentimento do admin na 1ª vez)" -ForegroundColor Gray
    $inputClientId = Read-Host "  Application (client) ID [14d82eec-204b-4c2f-b7e8-296a70dab67e]"
    $ClientId = if ($inputClientId) { $inputClientId } else { "14d82eec-204b-4c2f-b7e8-296a70dab67e" }
}
if (-not $TenantId) {
    $inputTenantId = Read-Host "  Directory (tenant) ID ou domínio [common]"
    $TenantId = if ($inputTenantId) { $inputTenantId } else { "common" }
}

$clientId = $ClientId
$tenantId = $TenantId
$scope    = "https://graph.microsoft.com/DeviceManagementConfiguration.ReadWrite.All offline_access"
if ($GroupAssignmentId) { $scope += " https://graph.microsoft.com/Group.Read.All" }
$authBase = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0"

Write-Host ""
Write-Host "  Escolha o método de autenticação:" -ForegroundColor Cyan
Write-Host "  [1] Device code  (abre navegador com código)" -ForegroundColor White
Write-Host "  [2] Usuário e senha" -ForegroundColor White
Write-Host ""
$authChoice = Read-Host "  Opção (1 ou 2)"

$token = $null
try {
    if ($authChoice -eq '2') {
        # ── Autenticação por usuário e senha (ROPC) ──────────────────────────
        Write-Log "Step 1: Autenticar no Microsoft Graph (usuário e senha)" "Cyan"
        if (-not $AdminUPN) { $AdminUPN = Read-Host "  Usuário (UPN)" }
        $secPass   = Read-Host "  Senha" -AsSecureString
        $plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass))

        $body = "grant_type=password" +
                "&client_id=$clientId" +
                "&scope=$([uri]::EscapeDataString($scope))" +
                "&username=$([uri]::EscapeDataString($AdminUPN))" +
                "&password=$([uri]::EscapeDataString($plainPass))"
        $plainPass = $null   # limpar da memória

        $tkResp = Invoke-RestMethod -Method POST -Uri "$authBase/token" `
                      -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        $token = $tkResp.access_token
    } else {
        # ── Autenticação por device code ─────────────────────────────────────
        Write-Log "Step 1: Autenticar no Microsoft Graph (device code)" "Cyan"
        $dcBody = "client_id=$clientId&scope=$([uri]::EscapeDataString($scope))"
        if ($AdminUPN) { $dcBody += "&login_hint=$([uri]::EscapeDataString($AdminUPN))" }

        $dc = Invoke-RestMethod -Method POST -Uri "$authBase/devicecode" `
                  -Body $dcBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop

        Write-Host ""
        Write-Host "  Acesse : $($dc.verification_uri)" -ForegroundColor Yellow
        Write-Host "  Código : $($dc.user_code)"        -ForegroundColor Yellow
        Write-Host ""
        Write-Log "  Aguardando autenticação (expira em $($dc.expires_in)s)..." "Gray"

        $expires  = (Get-Date).AddSeconds($dc.expires_in)
        $interval = [int]$dc.interval
        while ((Get-Date) -lt $expires) {
            Start-Sleep -Seconds $interval
            try {
                $tkBody = "grant_type=urn:ietf:params:oauth:grant-type:device_code" +
                          "&client_id=$clientId&device_code=$($dc.device_code)"
                $tkResp = Invoke-RestMethod -Method POST -Uri "$authBase/token" `
                              -Body $tkBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
                $token = $tkResp.access_token
                break
            }
            catch {
                $err = ($_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue).error
                if ($err -ne "authorization_pending") { throw }
            }
        }
    }

    if (-not $token) { Write-Log "  ERRO: Timeout — autenticação não concluída a tempo." "Red"; exit 1 }
    Write-Log "  Autenticado com sucesso." "Green"
}
catch {
    Write-Log "  ERRO na autenticação: $_" "Red"
    exit 1
}

# ── Step 2 – Importar políticas ───────────────────────────────────────────────
Write-Log ""
Write-Log "Step 2: Importar políticas selecionadas" "Cyan"

$stats   = @{ Created = 0; Skipped = 0; Overwritten = 0; Failed = 0 }
$baseUri = $script:graphBaseUri   # definido no topo do script para garantir escopo

foreach ($unit in $importUnits) {
    $policyName = $unit.PolicyName
    $jsonObject = $unit.JsonObject
    Write-Log ""
    Write-Log "  Processando: $policyName" "Cyan"

    try {
        # Verificar se já existe — busca local (evita problema de URI com OData filter)
        $allPolicies = Invoke-Graph -Method GET -Uri $baseUri -Token $token
        $existing    = $allPolicies.value | Where-Object { $_.name -eq $policyName } | Select-Object -First 1

        if ($existing) {
            if ($OverwriteExisting) {
                Write-Log "    Removendo versão existente (ID: $($existing.id))..." "Yellow"
                Invoke-Graph -Method DELETE -Uri "$baseUri/$($existing.id)" -Token $token | Out-Null
                Write-Log "    Removida. Recriando..." "Yellow"
                $stats.Overwritten++
            }
            else {
                Write-Log "    Ignorada — já existe no tenant." "Yellow"
                $stats.Skipped++
                continue
            }
        }

        if (-not $KeepAsBaseline) {
            $jsonObject.templateReference = [PSCustomObject]@{
                templateId             = ""
                templateFamily         = "none"
                templateDisplayName    = $null
                templateDisplayVersion = $null
            }
        }

        $jsonObject.name = $policyName
        $newPolicy = Invoke-Graph -Method POST -Uri $baseUri -Body $jsonObject -Token $token
        Write-Log "    Criada com sucesso (ID: $($newPolicy.id))" "Green"
        $stats.Created++

        if ($GroupAssignmentId) {
            try {
                $assignBody = @{
                    assignments = @(
                        @{ target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $GroupAssignmentId } }
                    )
                }
                Invoke-Graph -Method POST -Uri "$baseUri/$($newPolicy.id)/assign" `
                    -Body $assignBody -Token $token | Out-Null
                Write-Log "    Atribuída ao grupo $GroupAssignmentId" "Green"
            }
            catch {
                Write-Log "    AVISO: Criada mas falhou ao atribuir ao grupo — $_" "Yellow"
            }
        }
    }
    catch {
        Write-Log "    ERRO: $_" "Red"
        $stats.Failed++
    }
}

# ── Resumo ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Resumo da Importação                                      " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Log "  Criadas             : $($stats.Created)"     "Green"
Write-Log "  Ignoradas (existiam): $($stats.Skipped)"     "Yellow"
if ($stats.Overwritten -gt 0) { Write-Log "  Substituídas        : $($stats.Overwritten)" "Yellow" }
if ($stats.Failed -gt 0)      { Write-Log "  Com erro            : $($stats.Failed)"       "Red"    }
Write-Log "  Total processadas   : $($stats.Created + $stats.Skipped + $stats.Overwritten + $stats.Failed)" "Cyan"
if ($GroupAssignmentId) { Write-Log "  Grupo atribuído     : $GroupAssignmentId" "Cyan" }
Write-Log "  Log                 : $logFilePath" "Cyan"
Write-Host ""
Write-Log "Importação concluída." "Green"
