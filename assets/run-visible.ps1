# run-visible.ps1
#
# WHY THIS FILE EXISTS
# --------------------
# launch-detached.ps1 used to start the batch like this:
#
#   cmd.exe /c ""dsh-tools.bat" ... > "log" 2>&1"
#
# The redirect sent EVERY line to the log file, so the detached console window
# stayed completely blank for the whole run -- a window appeared, sat there
# saying nothing, and then vanished. That is useless: the point of running
# restart in a window is to watch the countdown and see whether the reopen
# worked.
#
# We cannot just drop the redirect either, because the log is the only way to
# diagnose a failure afterwards (the window disappears when the script ends).
#
# So this runner sits between them: it executes the batch, streams every line
# to the console AND records it to the log file. Live feedback plus a durable
# record.
#
# It is launched by launch-detached.ps1 through WMI, so the window is parented
# to WmiPrvSE.exe and does not die when the caller's process tree is killed.
#
# HOW THE BATCH IS INVOKED  (this part is easy to get wrong)
# ----------------------------------------------------------
# The batch is called DIRECTLY (`& $Bat @args`), not through `cmd.exe /c "..."`.
# PowerShell's native-command argument quoting mangles a hand-built
# `cmd.exe /c "..."` string: the result was a cmd-level parse error such as
# `此时不应有 =restart"`. Calling the .bat directly lets PowerShell hand the
# correct argv to cmd, and `2>&1 | Tee-Object` then captures both streams.
#
# ARGUMENT PASSING
# ----------------
# Batch arguments arrive as ONE pre-quoted string (-ArgsLine) and are split
# here. Reason: flags like `--delay=2` start with a dash, so PowerShell would
# try to bind them by name if they were real parameters and fail with
# "AmbiguousParameter". A plain string has no such problem.
#
# Note that cmd treats '=' as an argument separator, so `--delay=2` reaches
# dsh-tools.bat as two arguments. The batch handles that case explicitly.

param(
    [Parameter(Mandatory = $true)][string] $Bat,
    [Parameter(Mandatory = $true)][string] $Log,
    [string] $ArgsLine = '',
    [switch] $KeepOpen
)

$ErrorActionPreference = 'Continue'

# Split the pre-quoted argument string back into an array, honouring the
# double quotes that launch-detached.ps1 added around values with spaces.
$batchArgs = @()
if ($ArgsLine -and $ArgsLine.Trim()) {
    foreach ($m in [regex]::Matches($ArgsLine, '"([^"]*)"|(\S+)')) {
        if ($m.Groups[1].Success) { $batchArgs += $m.Groups[1].Value }
        else { $batchArgs += $m.Groups[2].Value }
    }
}

# Run the batch directly and mirror the merged streams to console + log.
#
# Tee-Object is deliberately NOT used: on PowerShell 5.1 it writes the file as
# UTF-16LE, so the log came out with a NUL byte between every character and was
# unreadable in normal editors. A StreamWriter using UTF8 without BOM keeps the
# log plain text; ForEach-Object writes through as lines arrive so the console
# output stays live instead of appearing only at the end.
# ---------------------------------------------------------------------------
# CONSOLE ENCODING -- set to UTF-8 before the batch runs.
#
# tasklist.exe and friends emit text in the OEM code page (936 / GBK on a
# Chinese Windows). PowerShell picks those bytes up using [Console]::OutputEncoding,
# which starts as the ANSI page, and the Chinese column headers came out as
# mojibake ("会话?"). chcp and OutputEncoding have to BOTH be changed: chcp tells
# the native program which page to WRITE, OutputEncoding tells PowerShell how to
# DECODE it. Setting only one still produces garbage.
#
# Restored afterwards so this script does not leak a global setting into the
# calling console.
$prevOutputEncoding = [Console]::OutputEncoding
chcp 65001 > $null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$utf8 = New-Object System.Text.UTF8Encoding($false)
$sw = New-Object System.IO.StreamWriter($Log, $false, $utf8)
try {
    if ($batchArgs.Count -gt 0) {
        & $Bat @batchArgs 2>&1 | ForEach-Object {
            Write-Host $_
            $sw.WriteLine($_)
        }
    }
    else {
        & $Bat 2>&1 | ForEach-Object {
            Write-Host $_
            $sw.WriteLine($_)
        }
    }
}
finally {
    $sw.Close()
    # Put the console back the way we found it.
    [Console]::OutputEncoding = $prevOutputEncoding
}
$rc = $LASTEXITCODE

if ($KeepOpen) {
    Write-Host ''
    Write-Host ('--- finished, exit code ' + $rc + ' ---')
    Write-Host 'Press Enter to close this window (DSH is already running).'
    [void][Console]::ReadLine()
}

exit $rc
