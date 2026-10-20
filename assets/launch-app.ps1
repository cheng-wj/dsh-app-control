# launch-app.ps1
#
# WHY THIS FILE EXISTS
# --------------------
# The classic mistake is:
#     start "" "C:\...\DeepSeek Harness.exe"
# from inside a batch file. That looks detached, but it is NOT: a GUI app
# started with `start` inherits the console of the cmd.exe that launched it.
# Windows sends CTRL_CLOSE_EVENT to every process attached to a console when
# that console window is closed, and Electron exits on that event.
#
# Result: the user closes the little cmd window the tool opened, and DSH dies
# with it. That is exactly the "I closed the script and DSH exited too" bug.
#
# WMI's Win32_Process.Create launches the image from the WMI service, so the
# new process is parented to WmiPrvSE.exe and has NO console attached to our
# cmd window. Closing any window we opened cannot touch it.
#
# Prints the new PID on success. Exits non-zero on failure.

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $ExePath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ExePath)) {
    Write-Error "exe not found: $ExePath"
    exit 3
}

# The path is wrapped in quotes because it contains a space
# ("DeepSeek Harness"). Win32_Process.Create needs that to parse the image name.
$cmdLine = '"' + $ExePath + '"'

try {
    $result = ([wmiclass] 'Win32_Process').Create($cmdLine)

    if ($result.ReturnValue -ne 0) {
        Write-Error "Win32_Process.Create returned $($result.ReturnValue)"
        exit 4
    }

    Write-Output $result.ProcessId
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 5
}
