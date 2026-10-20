# launch-detached.ps1
#
# WHY THIS FILE EXISTS
# --------------------
# dsh-tools.bat calls `taskkill /IM "DeepSeek Harness.exe" /T /F`.
# If that batch file runs as a CHILD of the DSH process tree (for example
# started from a DSH tool call), then /T walks up its own ancestry and the
# batch script is destroyed mid-run -- the app gets killed but never reopens.
#
# WMI's Win32_Process.Create launches the target through the WMI service, so
# the new process is parented to WmiPrvSE.exe, NOT to the caller. It survives
# the /T kill. This is the same mechanism that made the earlier in-session
# plugin update work.
#
# Because the child window is detached and its console output is invisible,
# everything it prints is ALSO redirected to a log file under logs/.
#
# USAGE (from any shell, including one inside DSH):
#   powershell -NoProfile -ExecutionPolicy Bypass -File launch-detached.ps1 status
#   powershell -NoProfile -ExecutionPolicy Bypass -File launch-detached.ps1 restart
#   powershell -NoProfile -ExecutionPolicy Bypass -File launch-detached.ps1 update dshmarket@1.66.44
#
# Anything you pass is forwarded verbatim to dsh-tools.bat.

param(
    # Leave the detached window open when the run finishes so the final result
    # (DONE, or an error) stays readable. Default on; use -NoKeepOpen for CI.
    [switch] $NoKeepOpen,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ForwardArgs
)

$ErrorActionPreference = 'Stop'
$KeepOpen = -not $NoKeepOpen

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bat = Join-Path $here 'dsh-tools.bat'

if (-not (Test-Path -LiteralPath $bat)) {
    Write-Output "ERROR: dsh-tools.bat not found next to this script:`n  $bat"
    exit 3
}

# ---------------------------------------------------------------------------
# CRLF GUARD -- do not remove.
#
# A .bat file MUST use CRLF. With LF-only endings cmd.exe's byte-offset
# bookkeeping for `call :LABEL` goes wrong and the script silently stops part
# way through: it reaches "[1/2] all DSH processes are gone" and then never
# prints "[2/2] starting DSH". The app is therefore closed but never reopened,
# which looks exactly like "the script just closed DSH and gave up".
#
# This was a real bug in this repo (an editor had saved the file as LF), so the
# check is kept here rather than only in the README.
#
# We repair in place instead of failing: an LF copy is still valid source, and
# refusing to run would leave the user unable to restart the app at all.
# ---------------------------------------------------------------------------
$batBytes = [System.IO.File]::ReadAllBytes($bat)
$lfCount = 0
$crCount = 0
foreach ($b in $batBytes) {
    if ($b -eq 10) { $lfCount++ }
    elseif ($b -eq 13) { $crCount++ }
}
if ($lfCount -gt 0 -and $crCount -ne $lfCount) {
    Write-Output "WARNING: dsh-tools.bat had non-CRLF line endings (CR=$crCount, LF=$lfCount)."
    Write-Output "         An LF-only .bat silently stops before reopening DSH. Repairing to CRLF."
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString($batBytes)
    $text = $text.Replace("`r`n", "`n").Replace("`n", "`r`n")
    [System.IO.File]::WriteAllBytes($bat, [System.Text.Encoding]::GetEncoding(28591).GetBytes($text))
    Write-Output "         fixed: $bat"
}

# One log per invocation so successive runs never overwrite each other.
$logDir = Join-Path (Split-Path -Parent $here) 'logs'
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$mode = if ($ForwardArgs -and $ForwardArgs.Count -gt 0) { $ForwardArgs[0] } else { 'restart' }
$log = Join-Path $logDir "dsh-tools-$mode-$stamp.log"

# ---------------------------------------------------------------------------
# Run through run-visible.ps1 instead of piping the batch straight into a log.
#
# The old command was:
#   cmd.exe /c ""dsh-tools.bat" ... > "log" 2>&1"
# which captured everything in the log but left the detached window BLANK for
# the entire run. Users rightly asked "why does the window show nothing?".
#
# run-visible.ps1 tees the output: every line is echoed to the console live
# AND appended to the log. $KeepOpen holds the window open at the end so the
# final "DONE" (or an error) is readable instead of the window vanishing.
# ---------------------------------------------------------------------------
$runner = Join-Path $here 'run-visible.ps1'
if (-not (Test-Path -LiteralPath $runner)) {
    Write-Output "ERROR: run-visible.ps1 not found next to this script:"
    Write-Output "  $runner"
    exit 6
}

# Batch arguments are passed as ONE pre-quoted string, not as a parameter
# array: flags like `--delay=2` begin with a dash and PowerShell would try to
# bind them by name instead of forwarding them.
$argsLine = ''
if ($ForwardArgs -and $ForwardArgs.Count -gt 0) {
    $argsLine = ($ForwardArgs | ForEach-Object {
            if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
        }) -join ' '
}

$runnerArgs = @(
    '-NoProfile'
    '-ExecutionPolicy', 'Bypass'
    '-File', $runner
    '-Bat', $bat
    '-Log', $log
)
if ($argsLine) { $runnerArgs += @('-ArgsLine', $argsLine) }
# status is read-only and finishes on its own; holding the window open would
# just leave a stray console behind after the result is printed.
if ($KeepOpen -and $mode -ne 'status') { $runnerArgs += '-KeepOpen' }

$cmdLine = 'powershell.exe ' + (($runnerArgs | ForEach-Object {
            if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
        }) -join ' ')

Write-Output "launching detached:"
Write-Output "  mode : $mode"
Write-Output "  log  : $log"

try {
    $result = ([wmiclass] 'Win32_Process').Create($cmdLine)

    if ($result.ReturnValue -ne 0) {
        Write-Output "ERROR: Win32_Process.Create returned $($result.ReturnValue)"
        exit 4
    }

    Write-Output "  pid  : $($result.ProcessId) (parented to WMI, survives taskkill /T)"
    Write-Output ''
    Write-Output "A separate window shows live progress (and is logged to the file above)."
    Write-Output "If it closes too fast, read the log:"
    Write-Output "  Get-Content -Wait -LiteralPath '$log'"

    # status is quick and harmless: wait for it and print the result inline so
    # the caller gets a useful answer instead of having to open the log.
    if ($mode -eq 'status') {
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 400
            if (Test-Path -LiteralPath $log) {
                $content = Get-Content -LiteralPath $log -Raw -ErrorAction SilentlyContinue
                if ($content -and $content -match '=====\s*$') {
                    Start-Sleep -Milliseconds 300
                    break
                }
            }
        }
        Write-Output ''
        Write-Output '--- detached output ---'
        if (Test-Path -LiteralPath $log) {
            Get-Content -LiteralPath $log
        }
        else {
            Write-Output '(log not created yet)'
        }
    }

    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    exit 5
}
