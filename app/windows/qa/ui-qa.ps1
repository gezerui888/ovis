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
function Log([string]$Line) { $stamp = (Get-Date).ToString('HH:mm:ss'); "$stamp $Line" | Tee-Object -Variable line | Write-Host; [IO.File]::AppendAllText($logFile, $line + "`n", [Text.UTF8Encoding]::new($false)) }
$shot = 0
function Shot([string]$Name) {
    if (Get-Command Front -ErrorAction SilentlyContinue) { try { Front (Window) } catch { } }
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
    $lastError = $null
    do {
        try { $value = & $Test; if ($value) { return $value } } catch { $lastError = $_ }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    Shot "timeout"
    if ($lastError) { Log "LAST ERROR: $lastError" }
    $w = Window
    if ($w) { Log ("WINDOW TEXT: " + ((Names $w) -join ' | ')) }
    throw "Timed out after $Seconds s: $What"
}
function Find-Text([string]$Text) {
    $w = Window
    if (-not $w) { return $null }
    $w.FindAll($tree::Descendants, [Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.Name -like "*$Text*" } | Select-Object -First 1
}
if (-not ('Qa.Mouse' -as [type])) {
    Add-Type -Namespace Qa -Name Mouse -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
[DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
'@
    [void][Qa.Mouse]::SetProcessDPIAware()
}
# Ovis in front of the runner's console: a screenshot shows it, and a mouse click lands on it
function Front($Element) {
    if (-not $Element) { $Element = Window }
    if (-not $Element) { return }
    $handle = [IntPtr]$Element.Current.NativeWindowHandle
    if ($handle -eq [IntPtr]::Zero) { return }
    [Qa.Mouse]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [Qa.Mouse]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [void][Qa.Mouse]::ShowWindow($handle, 9)
    [void][Qa.Mouse]::SetForegroundWindow($handle)
    Start-Sleep -Milliseconds 300
}
function Click([string]$Name, $Within = $null) {
    $element = Wait-For {
        $scope = if ($Within) { $Within } else { Window }
        if (-not $scope) { return $null }
        $matches = @($scope.FindAll($tree::Descendants, [Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.Name -eq $Name })
        ($matches | Where-Object { $_.Current.ControlType.ProgrammaticName -eq 'ControlType.Button' } | Select-Object -First 1), ($matches | Select-Object -First 1) | Where-Object { $_ } | Select-Object -First 1
    } 30 "button '$Name'"
    $patterns = ($element.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName }) -join ','
    $pattern = $null
    if ($element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        Log "CLICK '$Name' (invoke; $($element.Current.ControlType.ProgrammaticName); $patterns)"
        $pattern.Invoke()
        return
    }
    Front $(if ($Within) { $Within } else { Window })
    $box = $element.Current.BoundingRectangle
    $x = [int]($box.X + $box.Width / 2); $y = [int]($box.Y + $box.Height / 2)
    Log "CLICK '$Name' (mouse at $x,$y; $($element.Current.ControlType.ProgrammaticName); $patterns)"
    [void][Qa.Mouse]::SetCursorPos($x, $y)
    [Qa.Mouse]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    [Qa.Mouse]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
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

# Any window a download's first run raises (SmartScreen, the Open File security warning): its text and a
# screenshot go in the log, then it is answered the way a user answers it.
function Answer-Prompts {
    foreach ($top in $root.FindAll($tree::Children, [Windows.Automation.Condition]::TrueCondition)) {
        $name = $top.Current.Name
        if ($name -eq 'Ovis' -or $name -eq 'Taskbar' -or $name -eq 'Program Manager' -or $top.Current.ClassName -eq 'ConsoleWindowClass' -or $top.Current.ClassName -eq 'CASCADIA_HOSTING_WINDOW_CLASS') { continue }
        $names = @(Names $top)
        $buttons = @('More info', 'Run anyway', 'Run', '실행', '추가 정보') | Where-Object { $names -contains $_ }
        if (-not $buttons) { continue }
        Log "PROMPT window '$name' class $($top.Current.ClassName): $($names -join ' | ')"
        Shot 'prompt'
        $pick = @('Run anyway', 'More info', 'Run', '실행', '추가 정보') | Where-Object { $buttons -contains $_ } | Select-Object -First 1
        Click $pick $top
        Start-Sleep -Seconds 2
        return $true
    }
    $false
}
function Launch {
    if ($Mode -eq 'exe') {
        # as a download: Mark of the Web, opened by Explorer like a double-click
        Log "LAUNCH $env:OVIS_EXE (Zone.Identifier: $((Get-Content -Raw -Path $env:OVIS_EXE -Stream Zone.Identifier -ErrorAction SilentlyContinue) -replace "`r?`n", ' '))"
        Start-Process explorer.exe -ArgumentList ('"{0}"' -f $env:OVIS_EXE)
    } else {
        Log "LAUNCH shell:AppsFolder\$env:OVIS_AUMID"
        Start-Process explorer.exe "shell:AppsFolder\$env:OVIS_AUMID"
    }
    $deadline = (Get-Date).AddSeconds(90)
    $prompted = $false
    while (-not (Window) -and (Get-Date) -lt $deadline) {
        if (Answer-Prompts) { $prompted = $true } else { Start-Sleep -Milliseconds 500 }
    }
    if (-not (Window)) { Shot 'no-window'; throw 'Ovis did not open within 90 s' }
    if (-not $prompted) { Log 'PROMPT none: no SmartScreen or security warning appeared before the window' }
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
$ErrorActionPreference = 'Continue'
$pluginId = ((herdr plugin list --json | ConvertFrom-Json).result.plugins | Where-Object { $_.plugin_id -in 'devswha.ovis', 'devswha.herdr-web-ui' } | Select-Object -First 1).plugin_id
Log "plugin id: $pluginId"
herdr plugin action invoke "$pluginId.stop-windows" 2>&1 | Out-Null
Wait-For { -not (Get-NetTCPConnection -LocalPort 7317 -State Listen -ErrorAction SilentlyContinue) } 60 'the Ovis server to stop' | Out-Null
herdr server stop 2>&1 | Out-Null
$ErrorActionPreference = 'Stop'
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
function Ovis-Server { (Get-NetTCPConnection -LocalPort 7317 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess }
$serverBefore = Ovis-Server
Log "Ovis server pid before Restart: $serverBefore"
Click 'Restart'
Start-Sleep -Seconds 1
Shot 'restarting'
$serverAfter = Wait-For { $p = Ovis-Server; if ($p -and $p -ne $serverBefore -and (Find-Text 'Running on this PC') -and -not (Find-Text 'Restarting')) { $p } } 300 'the Ovis server to come back as a new process'
Shot 'restarted'
Log "Ovis server pid after Restart: $serverAfter (was $serverBefore); herdr server pid before $before, after $((Herdr-Server | Select-Object -First 1).ProcessId)"

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
