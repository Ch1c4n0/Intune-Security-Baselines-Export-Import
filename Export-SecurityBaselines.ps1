<#
.SYNOPSIS
  Exports all available Security Baseline templates from Intune to JSON.

.DESCRIPTION
    Lists all Security Baseline templates available in the tenant
    (configurationPolicyTemplates with templateFamily = 'baseline') — including
    the ones that don't have any profile created yet.

    For each selected template:
      1. Reads the template's settingTemplates (Microsoft recommended values)
      2. Converts them to the policy settings format
      3. Creates a temporary profile with these settings
      4. Exports the profile to JSON in a folder named <Template> - <Version>
      5. Deletes the temporary profile

    The generated JSON is compatible with Import-SecurityBaselines.ps1.

.PARAMETER OutputPath
    Destination folder for the exported JSON files.
    Default: .\Exported-Baselines\<timestamp>

.PARAMETER AdminUPN
    Administrator UPN — used as login hint in the device code flow.

.OUTPUTS
    JSON files per template in OutputPath.
    Log at "$env:TEMP\Export-SecurityBaselines.log"

.NOTES
  Version:      4.0.0
  Author:       Marcelo Gonçalves
  Date:         2026-06-24
  Requires:     PowerShell 7+
                Permission: DeviceManagementConfiguration.ReadWrite.All
  Note:         Does not require the Microsoft.Graph SDK module.

.EXAMPLE
  .\Export-SecurityBaselines.ps1
  Exports all templates to .\Exported-Baselines\<timestamp>

.EXAMPLE
  .\Export-SecurityBaselines.ps1 -OutputPath "C:\Backup" -AdminUPN "admin@contoso.com"
#>
[CmdletBinding()]
param(
    [string]$OutputPath = "",
    [string]$AdminUPN   = "",
    [string]$ClientId   = "",   # Application (client) ID of the app registered in Entra ID
    [string]$TenantId   = ""    # Directory (tenant) ID or domain (e.g. contoso.onmicrosoft.com)
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

# Fetches multiple resources in batch via the Graph Batch API (max 20 per call)
# Returns hashtable: relativeUrl -> response object
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

# ── Converter: settingInstanceTemplate → settingInstance ─────────────────────
# Recursively converts a settingInstanceTemplate into a settingInstance,
# including the required children of the selected default option.

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

            # Children are in defaultValue.children — each item is already a full settingInstanceTemplate
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
            # Value already deserialized as a number
            if (-not $isInt -and ($rawVal -is [int] -or $rawVal -is [long] -or $rawVal -is [double])) {
                $isInt = $true
            }
            # Bug in Microsoft's templates: field marked as String but the API requires Integer.
            # If the value is a string of pure digits (e.g. "6", "17"), treat it as Integer.
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
            # simpleSettingCollectionValueTemplate is an array of value templates
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
            # groupSettingCollectionValueTemplate is an array (not an object with itemTemplate)
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
            # choiceSettingCollectionValueTemplate is an array of value templates
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

        default { <# unknown type — does not block the POST #> }
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
Write-Host "  Security Baselines - Export Templates to JSON             " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Output folder ─────────────────────────────────────────────────────────────
if (-not $OutputPath) {
    $timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputPath = Join-Path (Get-Location) "Exported-Baselines\$timestamp"
}

New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
Write-Log "  Destination : $OutputPath" "Yellow"
Write-Host ""

# ── Step 1 – Authentication ───────────────────────────────────────────────────
# ClientId/TenantId are no longer hardcoded — they come from a parameter or are asked here.
if (-not $ClientId) {
    Write-Host "  ClientId not provided (use -ClientId or type it below)." -ForegroundColor Yellow
    Write-Host "  Press Enter to use Microsoft Graph PowerShell (multi-tenant, requires admin consent on 1st use)" -ForegroundColor Gray
    $inputClientId = Read-Host "  Application (client) ID [14d82eec-204b-4c2f-b7e8-296a70dab67e]"
    $ClientId = if ($inputClientId) { $inputClientId } else { "14d82eec-204b-4c2f-b7e8-296a70dab67e" }
}
if (-not $TenantId) {
    $inputTenantId = Read-Host "  Directory (tenant) ID or domain [common]"
    $TenantId = if ($inputTenantId) { $inputTenantId } else { "common" }
}

$clientId = $ClientId
$tenantId = $TenantId
$scope    = "https://graph.microsoft.com/DeviceManagementConfiguration.ReadWrite.All offline_access"
$authBase = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0"

Write-Host ""
Write-Host "  Choose the authentication method:" -ForegroundColor Cyan
Write-Host "  [1] Device code  (opens browser with a code)" -ForegroundColor White
Write-Host "  [2] Username and password" -ForegroundColor White
Write-Host ""
$authChoice = Read-Host "  Option (1 or 2)"

$token = $null
try {
    if ($authChoice -eq '2') {
        # ── Username and password authentication (ROPC) ─────────────────────
        Write-Log "Step 1: Authenticate to Microsoft Graph (username and password)" "Cyan"
        if (-not $AdminUPN) { $AdminUPN = Read-Host "  Username (UPN)" }
        $secPass  = Read-Host "  Password" -AsSecureString
        $plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass))

        $body = "grant_type=password" +
                "&client_id=$clientId" +
                "&scope=$([uri]::EscapeDataString($scope))" +
                "&username=$([uri]::EscapeDataString($AdminUPN))" +
                "&password=$([uri]::EscapeDataString($plainPass))"
        $plainPass = $null   # clear from memory

        $tkResp = Invoke-RestMethod -Method POST -Uri "$authBase/token" `
                      -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        $token = $tkResp.access_token
    } else {
        # ── Device code authentication ───────────────────────────────────────
        Write-Log "Step 1: Authenticate to Microsoft Graph (device code)" "Cyan"
        $dcBody = "client_id=$clientId&scope=$([uri]::EscapeDataString($scope))"
        if ($AdminUPN) { $dcBody += "&login_hint=$([uri]::EscapeDataString($AdminUPN))" }

        $dc = Invoke-RestMethod -Method POST -Uri "$authBase/devicecode" `
                  -Body $dcBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop

        Write-Host ""
        Write-Host "  Go to  : $($dc.verification_uri)" -ForegroundColor Yellow
        Write-Host "  Code   : $($dc.user_code)"        -ForegroundColor Yellow
        Write-Host ""
        Write-Log "  Waiting for authentication (expires in $($dc.expires_in)s)..." "Gray"

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

    if (-not $token) { Write-Log "  ERROR: Timeout — authentication not completed in time." "Red"; exit 1 }
    Write-Log "  Authenticated successfully." "Green"
}
catch {
    Write-Log "  ERROR during authentication: $_" "Red"
    exit 1
}

# ── Step 2 – List available templates ─────────────────────────────────────────
Write-Log ""
Write-Log "Step 2: List available Security Baseline templates" "Cyan"

try {
    $allTemplates = Get-GraphAll `
        -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicyTemplates?`$filter=templateFamily eq 'baseline'&`$top=100" `
        -Token $token

    Write-Log "  Templates found: $($allTemplates.Count)" "Green"
}
catch {
    Write-Log "  ERROR listing templates: $_" "Red"
    exit 1
}

if ($allTemplates.Count -eq 0) {
    Write-Log "  No Security Baseline template found in the tenant." "Yellow"
    exit 0
}

# ── Interactive selector ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Opening interactive selector..." -ForegroundColor Cyan
Write-Host "  -> Select the desired templates (Ctrl+click for multiple) and click OK." -ForegroundColor Yellow
Write-Host ""

$templateList = $allTemplates | ForEach-Object {
    [PSCustomObject]@{
        'Template Name' = $_.displayName
        'Version'       = $_.displayVersion
        'Platform'      = $_.platforms
        '_id'           = $_.id
    }
}

$selected = $templateList |
    Select-Object 'Template Name', Version, Platform |
    Out-GridView -Title "Select the Security Baseline templates to export" -PassThru

if (-not $selected -or $selected.Count -eq 0) {
    Write-Log "No template selected. Operation cancelled." "Yellow"
    exit 0
}

$selectedKeys = $selected | ForEach-Object { "$($_.'Template Name')||$($_.Version)" }
$toExport     = $templateList | Where-Object { $selectedKeys -contains "$($_.'Template Name')||$($_.Version)" }

Write-Log "  Selected: $($toExport.Count) template(s)" "Green"

# ── Step 3 – Export each template ─────────────────────────────────────────────
Write-Log ""
Write-Log "Step 3: Export templates to JSON" "Cyan"

$baseUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies"
$tmplUri = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicyTemplates"
$stats   = @{ Exported = 0; Failed = 0 }
$tempTag = "TEMP_EXPORT_$(Get-Date -Format 'HHmmss')"

foreach ($tmpl in $toExport) {
    $templateName    = $tmpl.'Template Name'
    $templateVersion = $tmpl.Version
    $templateId      = $tmpl.'_id'
    $templatePlatform = $tmpl.Platform

    Write-Log ""
    Write-Log "  Template: $templateName ($templateVersion)" "Cyan"

    $tempPolicyId = $null

    try {
        # 1. Read the settingTemplates to get the recommended values
        Write-Log "    Reading setting templates..." "Gray"
        $settingTemplates = Get-GraphAll `
            -Uri "$tmplUri/$templateId/settingTemplates?`$top=1000" `
            -Token $token

        Write-Log "    $($settingTemplates.Count) setting templates found." "Gray"

        # 2. Debug: save raw settingTemplates for analysis
        $debugPath = Join-Path $scriptDir "DEBUG_settingTemplates_$($templateName -replace '[\\/:*?"<>|]','_').json"
        $settingTemplates | ConvertTo-Json -Depth 20 | Out-File -FilePath $debugPath -Encoding UTF8 -Force
        Write-Log "    DEBUG: settingTemplates saved to $debugPath" "Yellow"

        # 3. Convert to the policy settings format
        $settings = [System.Collections.Generic.List[object]]::new()
        $idx = 0
        foreach ($st in $settingTemplates) {
            $converted = Convert-SettingTemplate -SettingTemplate $st -Index $idx
            if ($converted) { $settings.Add($converted) }
            $idx++
        }

        Write-Log "    $($settings.Count) settings converted." "Gray"

        # 3a. Debug: save converted settings for diagnostics
        $debugConvPath = Join-Path $scriptDir "DEBUG_converted_$($templateName -replace '[\\/:*?"<>|]','_').json"
        $settings | ConvertTo-Json -Depth 30 | Out-File -FilePath $debugConvPath -Encoding UTF8 -Force
        Write-Log "    DEBUG: converted settings saved to $debugConvPath" "Yellow"

        # 3. Create a temporary profile with the settings
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

        Write-Log "    Creating temporary profile..." "Gray"
        $tempPolicy   = Invoke-Graph -Method POST -Uri $baseUri -Body $createBody -Token $token
        $tempPolicyId = $tempPolicy.id
        Write-Log "    Profile created (ID: $tempPolicyId)" "Gray"

        # 4. Read it back with the final values filled in by Intune
        $allSettings = Get-GraphAll `
            -Uri "$baseUri/$tempPolicyId/settings?`$top=1000" `
            -Token $token

        Write-Log "    $($allSettings.Count) settings captured from the profile." "Gray"

        # 5. Build the export object
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

        # 6. Create the baseline folder
        $safeFolderName = ("$templateName - $templateVersion" -replace '[\\/:*?"<>|]', '_')
        $folderPath     = Join-Path $OutputPath $safeFolderName
        New-Item -Path $folderPath -ItemType Directory -Force | Out-Null

        # 6a. Save the full baseline JSON at the root of the folder
        $safeFileName = "$safeFolderName.json"
        $filePath     = Join-Path $folderPath $safeFileName
        $exportObject | ConvertTo-Json -Depth 100 | Out-File -FilePath $filePath -Encoding UTF8 -Force
        Write-Log "    Saved (full): $safeFolderName\$safeFileName" "Green"

        # 6b. Fetch displayName and categoryId for all settings in batch (Graph Batch API)
        Write-Log "    Fetching names and categories via batch API..." "Gray"
        $settingsBase  = '/deviceManagement/configurationSettings'
        $categoriesBase = '/deviceManagement/configurationCategories'

        # Collect unique settingDefinitionIds from the exported settings
        $defIds = $allSettings | ForEach-Object { $_.settingInstance.settingDefinitionId } | Select-Object -Unique
        $settingUrls = $defIds | ForEach-Object { "$settingsBase/$([uri]::EscapeDataString($_))" }

        # Batch: fetch all setting definitions
        Write-Log "    Batch: $($settingUrls.Count) setting definition(s) in $([Math]::Ceiling($settingUrls.Count/20)) call(s)..." "Gray"
        $settingDefMap = Invoke-GraphBatch -RelativeUrls $settingUrls -Token $token
        # Rebuild key by defId (without the URL prefix)
        $defById = @{}
        foreach ($url in $settingDefMap.Keys) {
            $obj = $settingDefMap[$url]
            if ($obj.id) { $defById[$obj.id] = $obj }
        }

        # Collect unique categoryIds and fetch in batch
        $uniqueCatIds = $defById.Values | Where-Object { $_.categoryId } |
                        ForEach-Object { $_.categoryId } | Select-Object -Unique
        $catUrls  = $uniqueCatIds | ForEach-Object { "$categoriesBase/$_" }
        $catByUrl = if ($catUrls) { Invoke-GraphBatch -RelativeUrls $catUrls -Token $token } else { @{} }
        $catById  = @{}
        foreach ($url in $catByUrl.Keys) {
            $obj = $catByUrl[$url]
            if ($obj.id) { $catById[$obj.id] = $obj.displayName }
        }
        Write-Log "    Categories: $($catById.Values | Sort-Object -Unique)" "Gray"

        # Build metadata for each setting
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

        # 6d. Group by category and save JSONs in category subfolders
        $grouped = $settingMeta | Group-Object -Property CategoryName
        foreach ($group in $grouped | Sort-Object Name) {
            $safeCatName = ($group.Name -replace '[\\/:*?"<>|]', '_').Trim()
            $catFolder   = Join-Path $folderPath $safeCatName
            New-Item -Path $catFolder -ItemType Directory -Force | Out-Null
            Write-Log "    Category: $($group.Name) ($($group.Count) setting(s))" "Cyan"

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

        Write-Log "    $($allSettings.Count) setting(s) exported by category." "Green"
        $stats.Exported++
    }
    catch {
        Write-Log "    ERROR: $_" "Red"
        $stats.Failed++
    }
    finally {
        if ($tempPolicyId) {
            try {
                Invoke-Graph -Method DELETE -Uri "$baseUri/$tempPolicyId" -Token $token | Out-Null
                Write-Log "    Temporary profile removed." "Gray"
            }
            catch {
                Write-Log "    WARNING: Could not remove the temporary profile (ID: $tempPolicyId) — remove it manually in Intune." "Yellow"
            }
        }
    }
}

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Export Summary                                             " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Log "  Exported successfully  : $($stats.Exported)" "Green"
if ($stats.Failed -gt 0) {
    Write-Log "  With errors            : $($stats.Failed)" "Red"
}
Write-Log "  Output folder          : $OutputPath" "Cyan"
Write-Log "  Log                    : $logFilePath" "Cyan"
Write-Host ""
Write-Log "Export completed." "Green"
