<#
    setup_win_patch_monitoring.ps1  (v4 - OFFLINE, all-in-one, an toan cho windows_exporter moi)
    Danh cho may KHONG ra internet / patch tay. Chay tren MOI version windows_exporter (0.28 -> moi nhat).
    Khac v3: KHONG dung --config.file (tranh dung config MSI tren ban moi lam service khong start).
             Khai bao bang CO DONG LENH (co-line always override), va TU DONG ROLLBACK neu service khong len.
    Cac buoc:
      1. Thu muc textfile
      2. Ghi win_patch_metrics.ps1 (KB da cai + KB moi nhat) + chay thu
      3. Don file .prom / task cu (tranh trung metric)
      4. Scheduled Task moi (06:00 & 18:00)
      5. Cap nhat ImagePath = them --collectors.enabled "[defaults],textfile" + --collector.textfile.directories
         (giu exe, --web.listen-address, --web.config.file; BO --config.file va --collectors.enabled cu)
      6. Restart co kiem tra; neu KHONG start => rollback ImagePath cu
    Chay bang PowerShell voi quyen Administrator.
#>

#requires -RunAsAdministrator

# ====== THAM SO (sua neu cai o duong dan khac) ======
$SvcName      = "windows_exporter"
$ExporterDir  = "C:\Program Files\windows_exporter"
$TextfileDir  = Join-Path $ExporterDir "textfile_inputs"
$MetricScript = Join-Path $ExporterDir "win_patch_metrics.ps1"
$MetricsPort  = 9182
$TaskName     = "windows_exporter_patch_metrics"
$OldTaskName  = "windows_exporter_installed_kb"
$OldPromFile  = Join-Path $TextfileDir "installed_kb.prom"
$OldConfig    = Join-Path $ExporterDir "config.yaml"   # config do v3 tao (neu co) - se khong dung nua
# ====================================================

function Info($m){ Write-Host "[i] $m" -ForegroundColor Cyan }
function Ok($m){ Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!] $m" -ForegroundColor Yellow }
function Err($m){ Write-Host "[X] $m" -ForegroundColor Red }

$svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
if (-not $svc) { Err "Khong tim thay service '$SvcName'."; return }

# --- 1. Thu muc textfile ---
if (-not (Test-Path $TextfileDir)) { New-Item -ItemType Directory -Force $TextfileDir | Out-Null }
Ok "Thu muc textfile: $TextfileDir"

# --- 2. Ghi script sinh metric (offline) ---
$body = @'
# win_patch_metrics.ps1 (OFFLINE) - KB da cai + KB moi nhat cho windows_exporter textfile collector
$dir = "C:\Program Files\windows_exporter\textfile_inputs"
$out = Join-Path $dir "patch_metrics.prom"
$tmp = "$out.tmp"
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
function Esc([string]$s){ if($null -eq $s){return ""}; return ($s -replace '\\','\\' -replace '"','\"' -replace "[\r\n]"," ").Trim() }
$epoch0 = [datetime]'1970-01-01T00:00:00Z'
$now = [int64]((Get-Date).ToUniversalTime() - $epoch0).TotalSeconds
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# HELP windows_installed_hotfix_info Ban hotfix/KB da cai (1 dong = 1 KB).")
[void]$sb.AppendLine("# TYPE windows_installed_hotfix_info gauge")
$latest = 0; $latestKb = ""; $latestOn = ""
Get-HotFix | Sort-Object InstalledOn | ForEach-Object {
    $kb = Esc $_.HotFixID; $desc = Esc $_.Description; $inst = ""
    if ($_.InstalledOn) {
        $u = $_.InstalledOn.ToUniversalTime()
        $ep = [int64]($u - $epoch0).TotalSeconds
        $inst = $u.ToString("yyyy-MM-dd")
        if ($ep -gt $latest) { $latest = $ep; $latestKb = $kb; $latestOn = $inst }
    }
    [void]$sb.AppendLine("windows_installed_hotfix_info{hotfix_id=`"$kb`",description=`"$desc`",installed_on=`"$inst`"} 1")
}
[void]$sb.AppendLine("# HELP windows_last_patch_timestamp_seconds Thoi diem KB moi nhat duoc cai (unix seconds).")
[void]$sb.AppendLine("# TYPE windows_last_patch_timestamp_seconds gauge")
[void]$sb.AppendLine("windows_last_patch_timestamp_seconds $latest")
[void]$sb.AppendLine("# HELP windows_last_patch_info KB moi nhat da cai (nhan: hotfix_id, installed_on; value = unix seconds).")
[void]$sb.AppendLine("# TYPE windows_last_patch_info gauge")
if ($latest -gt 0) { [void]$sb.AppendLine("windows_last_patch_info{hotfix_id=`"$latestKb`",installed_on=`"$latestOn`"} $latest") }
[void]$sb.AppendLine("# HELP windows_update_scrape_timestamp_seconds Lan script sinh metric gan nhat (unix seconds).")
[void]$sb.AppendLine("# TYPE windows_update_scrape_timestamp_seconds gauge")
[void]$sb.AppendLine("windows_update_scrape_timestamp_seconds $now")
[void]$sb.AppendLine("")
[System.IO.File]::WriteAllText($tmp, $sb.ToString(), (New-Object System.Text.ASCIIEncoding))
Move-Item -Force $tmp $out
'@
Set-Content -Path $MetricScript -Value $body -Encoding ASCII
Ok "Da ghi script: $MetricScript"

# --- 3. Don file .prom / task cu ---
if (Test-Path $OldPromFile) { Remove-Item $OldPromFile -Force -ErrorAction SilentlyContinue; Info "Da xoa .prom cu: $OldPromFile" }
$ot = Get-ScheduledTask -TaskName $OldTaskName -ErrorAction SilentlyContinue
if ($ot) { Unregister-ScheduledTask -TaskName $OldTaskName -Confirm:$false; Info "Da go task cu: $OldTaskName" }

try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $MetricScript; Ok "Da sinh patch_metrics.prom lan dau." }
catch { Warn "Chay thu script loi: $($_.Exception.Message)" }

# --- 4. Scheduled Task moi ---
$ex = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($ex) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$MetricScript`""
$t1        = New-ScheduledTaskTrigger -Daily -At 6am
$t2        = New-ScheduledTaskTrigger -Daily -At 6pm
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($t1,$t2) -Principal $principal | Out-Null
Ok "Da dang ky Scheduled Task '$TaskName' (06:00 & 18:00)."

# --- 5. Cap nhat ImagePath (co-line only) ---
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$SvcName"
$oldImg  = (Get-ItemProperty -Path $regPath -Name ImagePath).ImagePath
Info "ImagePath cu: $oldImg"

# Backup (chi backup 1 lan, giu ImagePath goc dau tien)
if (-not (Get-ItemProperty -Path $regPath -Name ImagePath_backup -ErrorAction SilentlyContinue)) {
    New-ItemProperty -Path $regPath -Name "ImagePath_backup" -Value $oldImg -PropertyType String -Force | Out-Null
    Info "Da backup ImagePath goc vao 'ImagePath_backup'."
}

# exe
if ($oldImg -match '^\s*"([^"]+)"') { $exe = $matches[1] } else { $exe = ($oldImg -split '\s+')[0] }

# Giu lai --web.listen-address / --web.config.file (neu co), chuan hoa ve dang '='
$keep = ""
foreach ($flag in @('--web\.listen-address','--web\.config\.file')) {
    if ($oldImg -match "($flag)[=\s]+`"?([^`"\s]+)`"?") {
        $keep += ' ' + ($matches[1] -replace '\\','') + '=' + $matches[2]
    }
}
if ($keep -notmatch 'web\.listen-address') { $keep += " --web.listen-address=:$MetricsPort" }

$newImg = "`"$exe`"$keep --collectors.enabled `"[defaults],textfile`" --collector.textfile.directories `"$TextfileDir`""
Set-ItemProperty -Path $regPath -Name ImagePath -Value $newImg
Ok "ImagePath moi: $newImg"

# --- 6. Restart co kiem tra + rollback neu that bai ---
try {
    Restart-Service -Name $SvcName -Force -ErrorAction Stop
    Start-Sleep -Seconds 3
} catch { Warn "Restart bao loi: $($_.Exception.Message)" }

Start-Sleep -Seconds 4
$st = (Get-Service -Name $SvcName).Status
if ($st -ne "Running") {
    Err "Service KHONG start ($st) voi cau hinh moi -> ROLLBACK ImagePath cu."
    $bak = (Get-ItemProperty -Path $regPath -Name ImagePath_backup).ImagePath
    Set-ItemProperty -Path $regPath -Name ImagePath -Value $bak
    try { Start-Service -Name $SvcName -ErrorAction Stop; Ok "Da rollback va start lai service (cau hinh cu)." }
    catch { Err "Van khong start duoc sau rollback: $($_.Exception.Message). Kiem tra Event Viewer > Application." }
    Warn "Gui minh dong ImagePath cu o tren + version windows_exporter (windows_exporter.exe --version) de chinh chinh xac."
    return
}
Ok "Service dang Running."

# --- Tu kiem tra metric ---
Start-Sleep -Seconds 5
try {
    $m     = (Invoke-WebRequest "http://localhost:$MetricsPort/metrics" -UseBasicParsing -TimeoutSec 30).Content
    $cTxt  = ($m | Select-String 'collector_success\{collector="textfile"\}\s+1').Count
    $err   = ($m | Select-String 'windows_textfile_scrape_error\s+1').Count
    $nKb   = ([regex]::Matches($m, 'windows_installed_hotfix_info\{')).Count
    $nLast = ([regex]::Matches($m, 'windows_last_patch_info\{')).Count
    Write-Host ""
    Write-Host "================ KET QUA ================" -ForegroundColor White
    if ($cTxt -gt 0) { Ok "collector textfile = 1" } else { Warn "collector textfile CHUA OK (xem lai --collectors.enabled)." }
    if ($err -gt 0)  { Warn "windows_textfile_scrape_error = 1 => con file .prom loi/trung!" } else { Ok "khong co loi doc textfile." }
    Info "windows_installed_hotfix_info: $nKb dong"
    Info "windows_last_patch_info      : $nLast dong (1 = OK)"
    Write-Host "=========================================" -ForegroundColor White
}
catch { Warn "Khong doc duoc /metrics: $($_.Exception.Message)" }

Write-Host ""
Info "Xong. Trong textfile_inputs chi nen co dung 1 file: patch_metrics.prom."
Info "Khoi phuc thu cong: dat ImagePath = gia tri 'ImagePath_backup' roi Restart-Service $SvcName."
