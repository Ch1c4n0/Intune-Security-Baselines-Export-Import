<#
.SYNOPSIS
  Exporta todos os Security Baseline templates disponíveis no Intune para JSON.

.DESCRIPTION
    Lista todos os templates de Security Baseline disponíveis no tenant
    (configurationPolicyTemplates com templateFamily = 'baseline') — inclusive
    os que ainda não têm nenhum perfil criado.

    Para cada template selecionado:
      1. Lê os settingTemplates do template (valores recomendados pela Microsoft)
      2. Converte para o formato de policy settings
      3. Cria um perfil temporário com essas settings
      4. Exporta o perfil para JSON numa pasta nomeada <Template> - <Versão>
      5. Deleta o perfil temporário

    O JSON gerado é compatível com o Import-SecurityBaselines.ps1.

.PARAMETER OutputPath
    Pasta de destino dos arquivos JSON exportados.
    Padrão: .\Exported-Baselines\<data-hora>

.PARAMETER AdminUPN
    UPN do administrador — usado como login hint no device code.

.OUTPUTS
    Arquivos JSON por template em OutputPath.
    Log em "$env:TEMP\Export-SecurityBaselines.log"

.NOTES
  Version:      4.0.0
  Author:       Marcelo Gonçalves
  Date:         2026-06-24
  Requires:     PowerShell 7+
                Permissões: DeviceManagementConfiguration.ReadWrite.All
  Nota:         Não requer nenhum módulo do Microsoft.Graph SDK.

.EXAMPLE
  .\Export-SecurityBaselines.ps1
  Exporta todos os templates para .\Exported-Baselines\<timestamp>

.EXAMPLE
  .\Export-SecurityBaselines.ps1 -OutputPath "C:\Backup" -AdminUPN "admin@contoso.com"
#>
[CmdletBinding()]
param(
    [string]$OutputPath = "",
    [string]$AdminUPN   = "",
    [string]$ClientId   = "",   # Application (client) ID do app registrado no Entra ID
    [string]$TenantId   = ""    # Directory (tenant) ID ou domínio (ex: contoso.onmicrosoft.com)
)

# ── Logging ───────────────────────────────────────────────────────────────────
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFilePath = Join-Path $scriptDir "Export-SecurityBaselines.log"

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
    try { Add-Content -Path $logFilePath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message" -ErrorAction Stop }
    catch {}
}

# ── Helper REST Graph ─────────────────────────────────────────────────────────
function Invoke-Graph {
    param([string]$Method, [string]$Uri, [object]$Body = $null, [string]$Token)
    $headers = @{ Authorization = "Bearer $Token"; "Content-Type" = "application/json" }
    $params  = @{ Method = $Method; Uri = $Uri; Headers = $headers; ErrorAction = "Stop" }
    if ($Body) { $params["Body"] = ($Body | ConvertTo-Json -Depth 100 -Compress) }
    Invoke-RestMethod @params
}

function Get-GraphAll {
    param([string]$Uri, [string]$Token)
    $results = @()
    do {
        $resp     = Invoke-Graph -Method GET -Uri $Uri -Token $Token
        $results += $resp.value
        $Uri      = $resp.'@odata.nextLink'
    } while ($Uri)
    return $results
}

# Busca múltiplos recursos em lote via Graph Batch API (max 20 por chamada)
# Retorna hashtable: relativeUrl -> objeto de resposta
function Invoke-GraphBatch {
    param([string[]]$RelativeUrls, [string]$Token)
    $results   = @{}
    $batchSize = 20
    $batchUri  = 'https://graph.microsoft.com/beta/$batch'

    for ($i = 0; $i -lt $RelativeUrls.Count; $i += $batchSize) {
        $slice    = $RelativeUrls[$i..([Math]::Min($i + $batchSize - 1, $RelativeUrls.Count - 1))]
        $requests = @()
        $reqId    = 1
        foreach ($url in $slice) {
            $requests += [ordered]@{ id = "$reqId"; method = 'GET'; url = $url }
            $reqId++
        }
        $batchResp = Invoke-Graph -Method POST -Uri $batchUri `
            -Body @{ requests = $requests } -Token $Token
        $respIdx = 0
        foreach ($r in $batchResp.responses) {
            if ($r.status -eq 200) { $results[$slice[$respIdx]] = $r.body }
            $respIdx++
        }
    }
    return $results
}

# ── Conversor: settingInstanceTemplate → settingInstance ──────────────────────
# Converte recursivamente um settingInstanceTemplate para settingInstance,
# incluindo os filhos obrigatórios da opção padrão selecionada.

function Convert-SettingInstanceTemplate {
    param([object]$Inst)
    if (-not $Inst) { return $null }

    $type = $Inst.'@odata.type' -replace 'Template$', ''

    $si = [ordered]@{
        '@odata.type'       = $type
        settingDefinitionId = $Inst.settingDefinitionId
    }
    if ($Inst.settingInstanceTemplateId) {
        $si['settingInstanceTemplateReference'] = @{
            settingInstanceTemplateId = $Inst.settingInstanceTemplateId
        }
    }

    switch -Wildcard ($type) {

        '*choiceSettingInstance' {
            $vt       = $Inst.choiceSettingValueTemplate
            $defValue = $vt.defaultValue.settingDefinitionOptionId

            # Filhos estão em defaultValue.children — cada item já é um settingInstanceTemplate completo
            $children = @()
            if ($vt.defaultValue -and $vt.defaultValue.children) {
                $children = @(
                    $vt.defaultValue.children | ForEach-Object {
                        Convert-SettingInstanceTemplate -Inst $_
                    } | Where-Object { $_ -ne $null }
                )
            }

            $si['choiceSettingValue'] = [ordered]@{
                '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'
                value         = $defValue
                settingValueTemplateReference = @{
                    settingValueTemplateId = $vt.settingValueTemplateId
                    useTemplateDefault     = $false
                }
                children = $children
            }
        }

        '*simpleSettingInstance' {
            $vt     = $Inst.simpleSettingValueTemplate
            $isInt  = ($vt.'@odata.type'              -match 'Integer') -or
                      ($vt.defaultValue.'@odata.type' -match 'Integer')
            $rawVal = if ($null -ne $vt.defaultValue.constantValue) { $vt.defaultValue.constantValue }
                      elseif ($null -ne $vt.defaultValue.value)     { $vt.defaultValue.value }
                      else { $null }
            # Valor já desserializado como número
            if (-not $isInt -and ($rawVal -is [int] -or $rawVal -is [long] -or $rawVal -is [double])) {
                $isInt = $true
            }
            # Bug nos templates da Microsoft: campo marcado como String mas a API exige Integer.
            # Se o valor é uma string de dígitos puros (ex: "6", "17"), tratar como Integer.
            if (-not $isInt -and ($rawVal -is [string]) -and ($rawVal -match '^\d+$')) {
                $isInt = $true
            }
            if ($null -eq $rawVal) { $rawVal = if ($isInt) { 0 } else { "" } }
            $defVal  = if ($isInt) { [int]$rawVal } else { [string]$rawVal }
            $valType = if ($isInt) {
                '#microsoft.graph.deviceManagementConfigurationIntegerSettingValue'
            } else {
                '#microsoft.graph.deviceManagementConfigurationStringSettingValue'
            }
            $si['simpleSettingValue'] = [ordered]@{
                '@odata.type' = $valType
                value         = $defVal
                settingValueTemplateReference = @{
                    settingValueTemplateId = $vt.settingValueTemplateId
                    useTemplateDefault     = $false
                }
            }
        }

        '*simpleSettingCollectionInstance' {
            # simpleSettingCollectionValueTemplate é um array de value templates
            $vtArray = $Inst.simpleSettingCollectionValueTemplate
            if ($vtArray -and $vtArray.Count -gt 0) {
                $collValues = @()
                foreach ($vtItem in $vtArray) {
                    $isInt  = ($vtItem.'@odata.type'              -match 'Integer') -or
                              ($vtItem.defaultValue.'@odata.type' -match 'Integer')
                    $rawVal = if ($null -ne $vtItem.defaultValue.constantValue) { $vtItem.defaultValue.constantValue }
                              elseif ($null -ne $vtItem.defaultValue.value)     { $vtItem.defaultValue.value }
                              else { $null }
                    if (-not $isInt -and ($rawVal -is [int] -or $rawVal -is [long] -or $rawVal -is [double])) { $isInt = $true }
                    if (-not $isInt -and ($rawVal -is [string]) -and ($rawVal -match '^\d+$')) { $isInt = $true }
                    if ($null -eq $rawVal) { $rawVal = if ($isInt) { 0 } else { "" } }
                    $val     = if ($isInt) { [int]$rawVal } else { [string]$rawVal }
                    $valType = if ($isInt) {
                        '#microsoft.graph.deviceManagementConfigurationIntegerSettingValue'
                    } else {
                        '#microsoft.graph.deviceManagementConfigurationStringSettingValue'
                    }
                    $collValues += @{
                        '@odata.type' = $valType
                        value         = $val
                        settingValueTemplateReference = @{
                            settingValueTemplateId = $vtItem.settingValueTemplateId
                            useTemplateDefault     = $false
                        }
                    }
                }
                $si['simpleSettingCollectionValue'] = $collValues
            } else {
                $si['simpleSettingCollectionValue'] = @()
            }
        }

        '*groupSettingCollectionInstance' {
            # groupSettingCollectionValueTemplate é um array (não objeto com itemTemplate)
            $vtArray = $Inst.groupSettingCollectionValueTemplate
            if ($vtArray -and $vtArray.Count -gt 0) {
                $groupItems = @()
                foreach ($vtItem in $vtArray) {
                    $groupChildren = @()
                    if ($vtItem.children) {
                        $groupChildren = @(
                            $vtItem.children | ForEach-Object {
                                Convert-SettingInstanceTemplate -Inst $_
                            } | Where-Object { $_ -ne $null }
                        )
                    }
                    $groupItems += @{
                        children = $groupChildren
                        settingValueTemplateReference = @{
                            settingValueTemplateId = $vtItem.settingValueTemplateId
                            useTemplateDefault     = $false
                        }
                    }
                }
                $si['groupSettingCollectionValue'] = $groupItems
            } else {
                $si['groupSettingCollectionValue'] = @()
            }
        }

        '*choiceSettingCollectionInstance' {
            # choiceSettingCollectionValueTemplate é um array de value templates
            $vtArray = $Inst.choiceSettingCollectionValueTemplate
            if ($vtArray -and $vtArray.Count -gt 0) {
                $collValues = @()
                foreach ($vtItem in $vtArray) {
                    $collValues += @{
                        '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingValue'
                        value         = $vtItem.defaultValue.settingDefinitionOptionId
                        children      = @()
                        settingValueTemplateReference = @{
                            settingValueTemplateId = $vtItem.settingValueTemplateId
                            useTemplateDefault     = $false
                        }
                    }
                }
                $si['choiceSettingCollectionValue'] = $collValues
            } else {
                $si['choiceSettingCollectionValue'] = @()
            }
        }

        default { <# tipo desconhecido — não bloqueia o POST #> }
    }

    return $si
}

function Convert-SettingTemplate {
    param([object]$SettingTemplate, [int]$Index)
    $inst = $SettingTemplate.settingInstanceTemplate
    if (-not $inst) { return $null }
    $si = Convert-SettingInstanceTemplate -Inst $inst
    if (-not $si) { return $null }
    return [ordered]@{ id = "$Index"; settingInstance = $si }
}

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Security Baselines - Export Templates para JSON           " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Pasta de saída ────────────────────────────────────────────────────────────
if (-not $OutputPath) {
    $timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputPath = Join-Path (Get-Location) "Exported-Baselines\$timestamp"
}

New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
Write-Log "  Destino : $OutputPath" "Yellow"
Write-Host ""

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
        $secPass  = Read-Host "  Senha" -AsSecureString
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

# ── Step 2 – Listar templates disponíveis ────────────────────────────────────
Write-Log ""
Write-Log "Step 2: Listar Security Baseline templates disponíveis" "Cyan"

try {
    $allTemplates = Get-GraphAll `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicyTemplates?`$filter=templateFamily eq 'baseline'&`$top=100" `
        -Token $token

    Write-Log "  Templates encontrados: $($allTemplates.Count)" "Green"
}
catch {
    Write-Log "  ERRO ao listar templates: $_" "Red"
    exit 1
}

if ($allTemplates.Count -eq 0) {
    Write-Log "  Nenhum Security Baseline template encontrado no tenant." "Yellow"
    exit 0
}

# ── Seletor interativo ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Abrindo seletor interativo..." -ForegroundColor Cyan
Write-Host "  -> Selecione os templates desejados (Ctrl+clique para múltiplos) e clique em OK." -ForegroundColor Yellow
Write-Host ""

$templateList = $allTemplates | ForEach-Object {
    [PSCustomObject]@{
        'Nome do Template' = $_.displayName
        'Versão'           = $_.displayVersion
        'Plataforma'       = $_.platforms
        '_id'              = $_.id
    }
}

$selected = $templateList |
    Select-Object 'Nome do Template', Versão, Plataforma |
    Out-GridView -Title "Selecione os Security Baseline templates para exportar" -PassThru

if (-not $selected -or $selected.Count -eq 0) {
    Write-Log "Nenhum template selecionado. Operação cancelada." "Yellow"
    exit 0
}

$selectedKeys = $selected | ForEach-Object { "$($_.'Nome do Template')||$($_.Versão)" }
$toExport     = $templateList | Where-Object { $selectedKeys -contains "$($_.'Nome do Template')||$($_.Versão)" }

Write-Log "  Selecionados: $($toExport.Count) template(s)" "Green"

# ── Step 3 – Exportar cada template ──────────────────────────────────────────
Write-Log ""
Write-Log "Step 3: Exportar templates para JSON" "Cyan"

$baseUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies"
$tmplUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicyTemplates"
$stats   = @{ Exported = 0; Failed = 0 }
$tempTag = "TEMP_EXPORT_$(Get-Date -Format 'HHmmss')"

foreach ($tmpl in $toExport) {
    $templateName    = $tmpl.'Nome do Template'
    $templateVersion = $tmpl.Versão
    $templateId      = $tmpl.'_id'
    $templatePlatform = $tmpl.Plataforma

    Write-Log ""
    Write-Log "  Template: $templateName ($templateVersion)" "Cyan"

    $tempPolicyId = $null

    try {
        # 1. Ler os settingTemplates para obter os valores recomendados
        Write-Log "    Lendo setting templates..." "Gray"
        $settingTemplates = Get-GraphAll `
            -Uri "$tmplUri/$templateId/settingTemplates?`$top=1000" `
            -Token $token

        Write-Log "    $($settingTemplates.Count) setting templates encontrados." "Gray"

        # 2. Debug: salvar raw dos settingTemplates para análise
        $debugPath = Join-Path $scriptDir "DEBUG_settingTemplates_$($templateName -replace '[\\/:*?"<>|]','_').json"
        $settingTemplates | ConvertTo-Json -Depth 20 | Out-File -FilePath $debugPath -Encoding UTF8 -Force
        Write-Log "    DEBUG: settingTemplates salvo em $debugPath" "Yellow"

        # 3. Converter para o formato de settings da policy
        $settings = [System.Collections.Generic.List[object]]::new()
        $idx = 0
        foreach ($st in $settingTemplates) {
            $converted = Convert-SettingTemplate -SettingTemplate $st -Index $idx
            if ($converted) { $settings.Add($converted) }
            $idx++
        }

        Write-Log "    $($settings.Count) settings convertidas." "Gray"

        # 3a. Debug: salvar settings convertidas para diagnóstico
        $debugConvPath = Join-Path $scriptDir "DEBUG_converted_$($templateName -replace '[\\/:*?"<>|]','_').json"
        $settings | ConvertTo-Json -Depth 30 | Out-File -FilePath $debugConvPath -Encoding UTF8 -Force
        Write-Log "    DEBUG: settings convertidas salvas em $debugConvPath" "Yellow"

        # 3. Criar perfil temporário com as settings
        $tempPolicyName = "$tempTag - $($templateName -replace '[\\/:*?"<>|]','_')"
        $createBody = @{
            name              = $tempPolicyName
            description       = ""
            platforms         = $templatePlatform
            technologies      = "mdm"
            templateReference = @{
                templateId     = $templateId
                templateFamily = "baseline"
            }
            settings          = $settings.ToArray()
        }

        Write-Log "    Criando perfil temporário..." "Gray"
        $tempPolicy   = Invoke-Graph -Method POST -Uri $baseUri -Body $createBody -Token $token
        $tempPolicyId = $tempPolicy.id
        Write-Log "    Perfil criado (ID: $tempPolicyId)" "Gray"

        # 4. Ler de volta com os valores finais preenchidos pelo Intune
        $allSettings = Get-GraphAll `
            -Uri "$baseUri/$tempPolicyId/settings?`$top=1000" `
            -Token $token

        Write-Log "    $($allSettings.Count) settings capturadas do perfil." "Gray"

        # 5. Montar objeto de exportação
        $exportObject = [ordered]@{
            description       = ""
            name              = "$templateName - $templateVersion"
            platforms         = $tempPolicy.platforms
            technologies      = $tempPolicy.technologies
            templateReference = [ordered]@{
                templateId             = $templateId
                templateFamily         = "baseline"
                templateDisplayName    = $templateName
                templateDisplayVersion = $templateVersion
            }
            roleScopeTagIds   = @("0")
            settings          = $allSettings
        }

        # 6. Criar pasta da baseline
        $safeFolderName = ("$templateName - $templateVersion" -replace '[\\/:*?"<>|]', '_')
        $folderPath     = Join-Path $OutputPath $safeFolderName
        New-Item -Path $folderPath -ItemType Directory -Force | Out-Null

        # 6a. Salvar JSON completo da baseline na raiz da pasta
        $safeFileName = "$safeFolderName.json"
        $filePath     = Join-Path $folderPath $safeFileName
        $exportObject | ConvertTo-Json -Depth 100 | Out-File -FilePath $filePath -Encoding UTF8 -Force
        Write-Log "    Salvo (completo): $safeFolderName\$safeFileName" "Green"

        # 6b. Buscar displayName e categoryId de todas as settings em lote (Graph Batch API)
        Write-Log "    Buscando nomes e categorias via batch API..." "Gray"
        $settingsBase  = '/deviceManagement/configurationSettings'
        $categoriesBase = '/deviceManagement/configurationCategories'

        # Coletar settingDefinitionIds únicos das settings exportadas
        $defIds = $allSettings | ForEach-Object { $_.settingInstance.settingDefinitionId } | Select-Object -Unique
        $settingUrls = $defIds | ForEach-Object { "$settingsBase/$([uri]::EscapeDataString($_))" }

        # Batch: buscar todas as setting definitions
        Write-Log "    Batch: $($settingUrls.Count) setting definition(s) em $([Math]::Ceiling($settingUrls.Count/20)) chamada(s)..." "Gray"
        $settingDefMap = Invoke-GraphBatch -RelativeUrls $settingUrls -Token $token
        # Remontar chave por defId (sem o prefixo de URL)
        $defById = @{}
        foreach ($url in $settingDefMap.Keys) {
            $obj = $settingDefMap[$url]
            if ($obj.id) { $defById[$obj.id] = $obj }
        }

        # Coletar categoryIds únicos e buscar em batch
        $uniqueCatIds = $defById.Values | Where-Object { $_.categoryId } |
                        ForEach-Object { $_.categoryId } | Select-Object -Unique
        $catUrls  = $uniqueCatIds | ForEach-Object { "$categoriesBase/$_" }
        $catByUrl = if ($catUrls) { Invoke-GraphBatch -RelativeUrls $catUrls -Token $token } else { @{} }
        $catById  = @{}
        foreach ($url in $catByUrl.Keys) {
            $obj = $catByUrl[$url]
            if ($obj.id) { $catById[$obj.id] = $obj.displayName }
        }
        Write-Log "    Categorias: $($catById.Values | Sort-Object -Unique)" "Gray"

        # Montar metadados de cada setting
        $settingIdx  = 1
        $settingMeta = [System.Collections.Generic.List[object]]::new()
        foreach ($setting in $allSettings) {
            $defId        = $setting.settingInstance.settingDefinitionId
            $def          = $defById[$defId]
            $displayName  = if ($def -and $def.displayName) { $def.displayName } else {
                ($defId -replace '^.*~policy~', '' `
                        -replace '^vendor_msft_', '' `
                        -replace '^device_vendor_msft_policy_config_', '' `
                        -replace '_', ' ').Trim()
            }
            $categoryName = if ($def -and $def.categoryId -and $catById.ContainsKey($def.categoryId)) {
                $catById[$def.categoryId]
            } else { 'Other' }

            $settingMeta.Add([PSCustomObject]@{
                Setting      = $setting
                DefId        = $defId
                DisplayName  = $displayName
                CategoryName = $categoryName
                Index        = $settingIdx
            })
            $settingIdx++
        }

        # 6d. Agrupar por categoria e salvar JSONs em subpastas de categoria
        $grouped = $settingMeta | Group-Object -Property CategoryName
        foreach ($group in $grouped | Sort-Object Name) {
            $safeCatName = ($group.Name -replace '[\\/:*?"<>|]', '_').Trim()
            $catFolder   = Join-Path $folderPath $safeCatName
            New-Item -Path $catFolder -ItemType Directory -Force | Out-Null
            Write-Log "    Categoria: $($group.Name) ($($group.Count) setting(s))" "Cyan"

            $idxInCat = 1
            foreach ($meta in $group.Group | Sort-Object Index) {
                $safeSettingName = (("{0:D3} - {1}" -f $idxInCat, $meta.DisplayName) `
                    -replace '[\\/:*?"<>|{}]', '_' -replace '\s+', ' ').Trim()

                $settingFolder = Join-Path $catFolder $safeSettingName
                New-Item -Path $settingFolder -ItemType Directory -Force | Out-Null

                $singleExport = [ordered]@{
                    description         = $meta.DisplayName
                    category            = $meta.CategoryName
                    settingDefinitionId = $meta.DefId
                    name                = "$templateName - $templateVersion - $($meta.DisplayName)"
                    platforms           = $tempPolicy.platforms
                    technologies        = $tempPolicy.technologies
                    templateReference   = [ordered]@{
                        templateId             = $templateId
                        templateFamily         = "baseline"
                        templateDisplayName    = $templateName
                        templateDisplayVersion = $templateVersion
                    }
                    roleScopeTagIds     = @("0")
                    settings            = @($meta.Setting)
                }

                $singleJson = "$safeSettingName.json"
                $singleExport | ConvertTo-Json -Depth 100 |
                    Out-File -FilePath (Join-Path $settingFolder $singleJson) -Encoding UTF8 -Force

                Write-Log "      $safeSettingName" "Gray"
                $idxInCat++
            }
        }

        Write-Log "    $($allSettings.Count) setting(s) exportadas por categoria." "Green"
        $stats.Exported++
    }
    catch {
        Write-Log "    ERRO: $_" "Red"
        $stats.Failed++
    }
    finally {
        if ($tempPolicyId) {
            try {
                Invoke-Graph -Method DELETE -Uri "$baseUri/$tempPolicyId" -Token $token | Out-Null
                Write-Log "    Perfil temporário removido." "Gray"
            }
            catch {
                Write-Log "    AVISO: Não foi possível remover perfil temporário (ID: $tempPolicyId) — remova manualmente no Intune." "Yellow"
            }
        }
    }
}

# ── Resumo ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Resumo da Exportação                                      " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Log "  Exportados com sucesso : $($stats.Exported)" "Green"
if ($stats.Failed -gt 0) {
    Write-Log "  Com erro               : $($stats.Failed)" "Red"
}
Write-Log "  Pasta de saída         : $OutputPath" "Cyan"
Write-Log "  Log                    : $logFilePath" "Cyan"
Write-Host ""
Write-Log "Exportação concluída." "Green"
