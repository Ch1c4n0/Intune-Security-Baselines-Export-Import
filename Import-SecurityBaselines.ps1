<#
.SYNOPSIS
  Imports Security Baselines into Intune from previously exported JSON files.

.DESCRIPTION
    Connects to Microsoft Graph via the device code flow (no Microsoft.Graph SDK),
    reads JSON files from a folder, and presents an interactive selector so the
    operator can choose which baselines to import.

    Compatible with JSONs exported by Export-SecurityBaselines.ps1 or the
    dgulle/Security-Baselines repository.

.PARAMETER SourcePath
    Folder with the JSON files (recursive search in subfolders).
    Default: the script's current folder.

.PARAMETER GroupAssignmentId
    Object ID of an Entra ID group. If provided, all created policies will be
    assigned to this group.

.PARAMETER KeepAsBaseline
    By default, templateReference is cleared and the policy is created as a
    Settings Catalog policy. Use this switch to preserve the link to the
    original Security Baseline template.

.PARAMETER OverwriteExisting
    Policies with an identical name are deleted and recreated.
    By default, existing policies are skipped.

.PARAMETER AdminUPN
    Administrator UPN — used as login hint in the device code flow.

.OUTPUTS
    Status in the console and log at "<script folder>\Import-SecurityBaselines.log"

.NOTES
  Version:      2.0.0
  Author:       Marcelo Gonçalves
  Date:         2026-06-24
  Requires:     PowerShell 7+, DeviceManagementConfiguration.ReadWrite.All permission
  Note:         Does not require the Microsoft.Graph SDK module.

.EXAMPLE
  .\Import-SecurityBaselines.ps1
  Reads JSONs from the current folder and opens the interactive selector.

.EXAMPLE
  .\Import-SecurityBaselines.ps1 -SourcePath "C:\Baselines\Backup"
  Imports from the specified folder (shows interactive selection).

.EXAMPLE
  .\Import-SecurityBaselines.ps1 -SourcePath ".\Exported-Baselines" -GroupAssignmentId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  Imports and assigns to the given group.

.EXAMPLE
  .\Import-SecurityBaselines.ps1 -SourcePath ".\Exported-Baselines" -KeepAsBaseline
  Imports while preserving the link to the original Security Baseline template.
#>
[CmdletBinding()]
param(
    [string]$SourcePath        = "",
    [string]$GroupAssignmentId = "",
    [string]$AdminUPN          = "",
    [string]$ClientId          = "",   # Application (client) ID of the app registered in Entra ID
    [string]$TenantId          = "",   # Directory (tenant) ID or domain (e.g. contoso.onmicrosoft.com)
    [switch]$KeepAsBaseline,
    [switch]$OverwriteExisting
)

# ── Constants ────────────────────────────────────────────────────────────────
$script:graphBaseUri = 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies'

# ── Logging ──────────────────────────────────────────────────────────────────
$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFilePath = Join-Path $scriptDir "Import-SecurityBaselines.log"

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
    try { Add-Content -Path $logFilePath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message" -ErrorAction Stop }
    catch { Write-Warning "Could not write to the log: $logFilePath" }
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
Write-Host "  Security Baselines - Selective Import to Intune           " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Resolve source folder ──────────────────────────────────────────────────────
if (-not $SourcePath) { $SourcePath = Get-Location }

if (-not (Test-Path -Path $SourcePath)) {
    Write-Log "ERROR: Folder not found: $SourcePath" "Red"
    exit 1
}

# ── List JSONs (including subfolders) ─────────────────────────────────────────
$jsonFiles = Get-ChildItem -Path $SourcePath -Filter "*.json" -File -Recurse | Sort-Object FullName

if ($jsonFiles.Count -eq 0) {
    Write-Log "No .json file found in: $SourcePath" "Red"
    exit 1
}

Write-Log "  Source folder   : $SourcePath" "Yellow"
Write-Log "  JSON files found: $($jsonFiles.Count)" "Yellow"
Write-Host ""

# ── Build the list with metadata for the selector ─────────────────────────────
$policyList = foreach ($file in $jsonFiles) {
    try {
        $data = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
        # Configuration: use description (readable name written by export) or file name
        $isFullBaseline = (-not $data.settingDefinitionId)
        $configName  = if ($data.description -and $data.description -notmatch '^vendor_|^device_vendor_') {
            $data.description
        } elseif ($isFullBaseline) { '(full baseline)' } else { $data.settingDefinitionId }
        $categoryName = if ($data.category) { $data.category } `
                        elseif ($isFullBaseline) { '—' } else { 'Other' }
        [PSCustomObject]@{
            Category      = $categoryName
            Configuration = $configName
            'Policy Name' = $data.name
            Template      = "$($data.templateReference.templateDisplayName) ($($data.templateReference.templateDisplayVersion))"
            Platform      = $data.platforms
            Settings      = ($data.settings | Measure-Object).Count
            File          = $file.Name
            Folder        = $file.DirectoryName
            FullPath      = $file.FullName
        }
    }
    catch {
        [PSCustomObject]@{
            Category      = '?'
            Configuration = '(error reading JSON)'
            'Policy Name' = $file.BaseName
            Template      = "-"
            Platform      = "-"
            Settings      = 0
            File          = $file.Name
            Folder        = $file.DirectoryName
            FullPath      = $file.FullName
        }
    }
}

# ── Interactive selector ───────────────────────────────────────────────────────
Write-Host "  Opening interactive selector..." -ForegroundColor Cyan
Write-Host "  -> Select the desired baselines (Ctrl+click for multiple) and click OK." -ForegroundColor Yellow
Write-Host ""

$selected = $policyList |
    Select-Object Category, Configuration, 'Policy Name', Template, Platform, Settings, File |
    Out-GridView -Title "Select the Security Baselines to import" -PassThru

if (-not $selected -or $selected.Count -eq 0) {
    Write-Log "No baseline selected. Operation cancelled." "Yellow"
    exit 0
}

$toImport = $policyList | Where-Object { $selected.File -contains $_.File }

Write-Host ""
Write-Log "  Selected : $($toImport.Count) file(s)" "Green"

# ── Group and rename ──────────────────────────────────────────────────────────
# Each "import unit" can be a single file or a merge of several
$importUnits = [System.Collections.Generic.List[object]]::new()

# Group by Category + Template (same baseline + same category = merge candidates)
$groups = $toImport | Group-Object { "$($_.Category)|$($_.Template)" }

foreach ($grp in $groups) {
    $items = @($grp.Group)

    # Read the JSONs for this group's files
    $jsons = $items | ForEach-Object { Get-Content $_.FullPath -Raw | ConvertFrom-Json }

    if ($items.Count -gt 1) {
        # Multiple files in the same category — ask whether to merge
        Write-Host ""
        Write-Host "  Category   : $($items[0].Category)" -ForegroundColor Cyan
        Write-Host "  Template   : $($items[0].Template)"  -ForegroundColor Cyan
        Write-Host "  Settings   : $($items.Count) selected:" -ForegroundColor Cyan
        $items | ForEach-Object { Write-Host "    - $($_.Configuration)" -ForegroundColor White }
        Write-Host ""
        $merge = Read-Host "  Merge into ONE policy? (Y/N)"

        if ($merge -in @('S','s','Y','y')) {
            # Merge: combine all settings into one policy
            $first       = $jsons[0]
            $catName     = $items[0].Category
            $tmplName    = $first.templateReference.templateDisplayName
            $tmplVersion = $first.templateReference.templateDisplayVersion
            $defaultName = "$tmplName - $tmplVersion - $catName"

            Write-Host "  Default name: $defaultName" -ForegroundColor Gray
            $newName = Read-Host "  Policy name (Enter to keep)"
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

    # No merge (or just 1 file): import individually with the option to rename
    foreach ($item in $items) {
        $json        = $jsons[$items.IndexOf($item)]
        $defaultName = $json.name

        Write-Host ""
        Write-Host "  Configuration: $($item.Configuration)" -ForegroundColor Cyan
        Write-Host "  Default name : $defaultName" -ForegroundColor Gray
        $newName = Read-Host "  Policy name (Enter to keep)"
        if ([string]::IsNullOrWhiteSpace($newName)) { $newName = $defaultName }

        $json.name = $newName
        $importUnits.Add([PSCustomObject]@{
            PolicyName = $newName
            JsonObject = $json
        })
    }
}

Write-Host ""
Write-Log "  Policies to create: $($importUnits.Count)" "Green"
if ($GroupAssignmentId) { Write-Log "  Group        : $GroupAssignmentId" "Yellow" }
$modeLabel = if ($KeepAsBaseline) { "Security Baseline (templateReference preserved)" } else { "Settings Catalog (templateReference cleared)" }
Write-Log "  Mode         : $modeLabel" "Yellow"
Write-Host ""

$proceed = Read-Host "Continue with the import? (Y/N)"
if ($proceed -notin @('Y', 'y')) {
    Write-Log "Import cancelled by the user." "Red"
    exit 0
}

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
if ($GroupAssignmentId) { $scope += " https://graph.microsoft.com/Group.Read.All" }
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
        # ── Username and password authentication (ROPC) ──────────────────────
        Write-Log "Step 1: Authenticate to Microsoft Graph (username and password)" "Cyan"
        if (-not $AdminUPN) { $AdminUPN = Read-Host "  Username (UPN)" }
        $secPass   = Read-Host "  Password" -AsSecureString
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

# ── Step 2 – Import policies ──────────────────────────────────────────────────
Write-Log ""
Write-Log "Step 2: Import selected policies" "Cyan"

$stats   = @{ Created = 0; Skipped = 0; Overwritten = 0; Failed = 0 }
$baseUri = $script:graphBaseUri   # defined at the top of the script to ensure scope

foreach ($unit in $importUnits) {
    $policyName = $unit.PolicyName
    $jsonObject = $unit.JsonObject
    Write-Log ""
    Write-Log "  Processing: $policyName" "Cyan"

    try {
        # Check whether it already exists — local search (avoids OData filter URI issues)
        $allPolicies = Invoke-Graph -Method GET -Uri $baseUri -Token $token
        $existing    = $allPolicies.value | Where-Object { $_.name -eq $policyName } | Select-Object -First 1

        if ($existing) {
            if ($OverwriteExisting) {
                Write-Log "    Removing existing version (ID: $($existing.id))..." "Yellow"
                Invoke-Graph -Method DELETE -Uri "$baseUri/$($existing.id)" -Token $token | Out-Null
                Write-Log "    Removed. Recreating..." "Yellow"
                $stats.Overwritten++
            }
            else {
                Write-Log "    Skipped — already exists in the tenant." "Yellow"
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
        Write-Log "    Created successfully (ID: $($newPolicy.id))" "Green"
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
                Write-Log "    Assigned to group $GroupAssignmentId" "Green"
            }
            catch {
                Write-Log "    WARNING: Created but failed to assign to the group — $_" "Yellow"
            }
        }
    }
    catch {
        Write-Log "    ERROR: $_" "Red"
        $stats.Failed++
    }
}

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Import Summary                                             " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Log "  Created              : $($stats.Created)"     "Green"
Write-Log "  Skipped (existed)    : $($stats.Skipped)"     "Yellow"
if ($stats.Overwritten -gt 0) { Write-Log "  Overwritten          : $($stats.Overwritten)" "Yellow" }
if ($stats.Failed -gt 0)      { Write-Log "  With errors          : $($stats.Failed)"       "Red"    }
Write-Log "  Total processed      : $($stats.Created + $stats.Skipped + $stats.Overwritten + $stats.Failed)" "Cyan"
if ($GroupAssignmentId) { Write-Log "  Group assigned       : $GroupAssignmentId" "Cyan" }
Write-Log "  Log                  : $logFilePath" "Cyan"
Write-Host ""
Write-Log "Import completed." "Green"
