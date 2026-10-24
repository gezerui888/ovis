# TEMPORARY QA (not for the PR): drives Ovis.exe through UI Automation on a GitHub windows runner.
param(
    [Parameter(Mandatory)][string]$Mode, # exe | msix
    [Parameter(Mandatory)][string]$Evidence
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms
New-Item -ItemType Directory -Force -Path $Evidence | Out-Null
$logFile = Join-Path $Evidence "$Mode-actions.log"
function Log([string]$Line) { $stamp = (Get-Date).ToString('HH:mm:ss'); "$stamp $Line" | Tee-Object -FilePath $logFile -Append | Write-Host }
$shot = 0
function Shot([string]$Name) {
    $script:shot++
    $bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Location, [Drawing.Point]::Empty, $bounds.Size)
    $path = Join-Path $Evidence ('{0}-{1:00}-{2}.png' -f $Mode, $script:shot, $Name)
    $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
    Log "SCREENSHOT $path"
}
$root = [Windows.Automation.AutomationElement]::RootElement
$tree = [Windows.Automation.TreeScope]
function Window([string]$Name = 'Ovis') {
    $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, $Name)
    $root.FindFirst($tree::Children, $condition)
}
function Names($Element) {
    @($Element.FindAll($tree::Descendants, [Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name } | Where-Object { $_ })
}
function Wait-For([scriptblock]$Test, [int]$Seconds, [string]$What) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        try { $value = & $Test; if ($value) { return $value } } catch { }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    Shot "timeout"
    $w = Window
    if ($w) { Log ("WINDOW TEXT: " + ((Names $w) -join ' | ')) }
    throw "Timed out after $Seconds s: $What"
}
function Find-Text([string]$Text) {
    $w = Window
    if (-not $w) { return $null }
    $w.FindAll($tree::Descendants, [Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.Name -like "*$Text*" } | Select-Object -First 1
}
function Click([string]$Name, $Within = $null) {
    if (-not $Within) { $Within = Window }
    $condition = [Windows.Automation.AndCondition]::new(
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, $Name),
        [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button))
    $button = Wait-For { $Within.FindFirst($tree::Descendants, $condition) } 30 "button '$Name'"
    Log "CLICK '$Name'"
    $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
}
$env:PATH = "$env:USERPROFILE\.bun\bin;$env:LOCALAPPDATA\Programs\Herdr\bin;$env:PATH"
function Herdr-Server { Get-CimInstance Win32_Process -Filter "Name = 'herdr.exe'" | Where-Object { $_.CommandLine -match '\sserver\b' } }
function Package-Of([int]$ProcessId) {
    if (-not ('Qa.Pkg' -as [type])) {
        Add-Type -Namespace Qa -Name Pkg -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern int GetPackageFullName(IntPtr process, ref int length, System.Text.StringBuilder name);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);
'@
    }
    $handle = [Qa.Pkg]::OpenProcess(0x1000, $false, $ProcessId)
    $length = 256; $name = New-Object Text.StringBuilder 256
    $code = [Qa.Pkg]::GetPackageFullName($handle, [ref]$length, $name)
    [void][Qa.Pkg]::CloseHandle($handle)
    if ($code -eq 15700) { 'NO PACKAGE' } elseif ($code -eq 0) { $name.ToString() } else { "error $code" }
}

function Launch {
    if ($Mode -eq 'exe') {
        # as a download: Mark of the Web, opened through the shell like a double-click
        Log "LAUNCH $env:OVIS_EXE (Zone.Identifier: $((Get-Content -Raw -Path $env:OVIS_EXE -Stream Zone.Identifier) -replace "`r?`n", ' '))"
        Start-Process -FilePath $env:OVIS_EXE
    } else {
        Log "LAUNCH shell:AppsFolder\$env:OVIS_AUMID"
        Start-Process explorer.exe "shell:AppsFolder\$env:OVIS_AUMID"
    }
    Wait-For { Window } 60 'the Ovis window' | Out-Null
    Start-Sleep -Seconds 2
    $p = Get-Process Ovis -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { Log "Ovis.exe pid $($p.Id) package: $(Package-Of $p.Id)" }
}
function Close-Ovis {
    $w = Window
    if ($w) { $w.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close() }
    Wait-For { -not (Window) } 20 'Ovis to close' | Out-Null
}

if ($env:QA_GIT_MISSING -eq '1') {
    Launch
    Wait-For { Find-Text 'Git for Windows' } 60 'the Git step' | Out-Null
    Log ("GIT STEP TEXT: " + ((Names (Window)) -join ' | '))
    Shot 'git-missing'
    Close-Ovis
    exit 0
}

Launch
Wait-For { Find-Text 'Set up this PC' } 60 'the not-installed screen' | Out-Null
Shot 'not-installed'
Click 'Install'
Start-Sleep -Seconds 20
Shot 'installing'
Wait-For { (Find-Text 'Running on this PC') -or (Find-Text 'error') } 1500 'the install to finish' | Out-Null
if (Find-Text 'error') { Shot 'install-failed'; Log ("FAILED TEXT: " + ((Names (Window)) -join ' | ')); throw 'Install failed' }
Shot 'installed'
Log ("INSTALLED TEXT: " + ((Names (Window)) -join ' | '))
$server = Herdr-Server | Select-Object -First 1
Log "herdr server pid $($server.ProcessId) package: $(Package-Of $server.ProcessId) path: $($server.ExecutablePath)"
Log "herdr.exe on disk (outside the package view): $(Test-Path "$env:LOCALAPPDATA\Programs\Herdr\bin\herdr.exe")"
Log "plugin list: $((herdr plugin list --json | ConvertFrom-Json).result.plugins | ForEach-Object { $_.plugin_id + ' ' + $_.plugin_root })"
Log "health: $((Invoke-WebRequest http://127.0.0.1:7317/api/health -UseBasicParsing -TimeoutSec 5).StatusCode)"
if ($Mode -eq 'exe') {
    Log "Run value: $((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name Ovis -ErrorAction SilentlyContinue).Ovis)"
    Log "installed copy: $(Test-Path "$env:LOCALAPPDATA\Programs\Ovis\Ovis.exe"); Zone.Identifier on it: $([bool](Get-Item "$env:LOCALAPPDATA\Programs\Ovis\Ovis.exe" -Stream Zone.Identifier -ErrorAction SilentlyContinue))"
    Log "Start menu shortcut: $(Test-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Ovis.lnk")"
}

# the login start: herdr stopped, then the login entry run as Windows runs it at sign-in
Close-Ovis
Log 'STOP herdr server (as after a reboot)'
herdr plugin action invoke devswha.ovis.stop-windows 2>&1 | Out-Null
herdr plugin action invoke devswha.herdr-web-ui.stop-windows 2>&1 | Out-Null
herdr server stop | Out-Null
Wait-For { -not (Herdr-Server) } 30 'herdr to stop' | Out-Null
Log "herdr running after stop: $([bool](Herdr-Server))"
if ($Mode -eq 'exe') {
    $command = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name Ovis).Ovis
    Log "LOGIN START: $command"
    $exe = [regex]::Match($command, '^"([^"]+)"').Groups[1].Value
    Start-Process -FilePath $exe -ArgumentList '--start' -Wait
} else {
    Log "LOGIN START: shell:AppsFolder\$env:OVIS_START_AUMID (the startup task's application)"
    Start-Process explorer.exe "shell:AppsFolder\$env:OVIS_START_AUMID"
}
$server = Wait-For { Herdr-Server | Select-Object -First 1 } 60 'herdr to start at login'
Log "herdr server after login start: pid $($server.ProcessId) package: $(Package-Of $server.ProcessId)"
Wait-For { (Invoke-WebRequest http://127.0.0.1:7317/api/health -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200 } 120 'the app to start with herdr' | Out-Null
Log 'app answers after login start: 200'
Log "a window opened by the login start: $([bool](Window))"

Launch
Wait-For { Find-Text 'Running on this PC' } 120 'the running screen' | Out-Null
Shot 'running-after-login-start'
$before = (Herdr-Server | Select-Object -First 1).ProcessId
Click 'Restart'
Start-Sleep -Seconds 1
Shot 'restarting'
Wait-For { Find-Text 'Running on this PC' } 300 'the restart to finish' | Out-Null
Shot 'restarted'
Log "herdr server pid before restart $before, after $((Herdr-Server | Select-Object -First 1).ProcessId)"

Click 'Remove…'
$dialog = Wait-For { Window 'Remove the Ovis server from this PC?' } 30 'the Remove dialog'
Shot 'remove-confirm'
Click 'OK' $dialog
Wait-For { Find-Text 'Set up this PC' } 300 'the remove to finish' | Out-Null
Shot 'removed'
$after = Herdr-Server | Select-Object -First 1
Log "herdr server still running after Remove: $([bool]$after) (pid $($after.ProcessId), was $before)"
Log "plugin list after Remove: $(((herdr plugin list --json | ConvertFrom-Json).result.plugins | ForEach-Object { $_.plugin_id }) -join ',')"
if ($Mode -eq 'exe') {
    Log "Run value after Remove: $([bool](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name Ovis -ErrorAction SilentlyContinue))"
    Log "Start menu shortcut after Remove: $(Test-Path "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Ovis.lnk")"
}
Close-Ovis
if ($Mode -eq 'exe') {
    Start-Sleep -Seconds 5
    Log "installed copy after closing: $(Test-Path "$env:LOCALAPPDATA\Programs\Ovis\Ovis.exe")"
}
Log 'QA DONE'
