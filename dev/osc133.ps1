# Control Room dev helper: prints the OSC 133 shell-integration marks of one
# command, so Tern records it as finished with the given line and exit status.
#   & dev/osc133.ps1 -Line 'npm test' -Status 3
param([string]$Line = "npm test", [int]$Status = 3, [int]$Seconds = 1)
$e = [char]27; $b = [char]7
Write-Host -NoNewline "$e]133;A$b$e]133;B$b"
Write-Host -NoNewline "$e]133;C;cmdline_url=$([uri]::EscapeDataString($Line))$b"
Write-Host "simulated output of $Line"
Start-Sleep -Seconds $Seconds
Write-Host -NoNewline "$e]133;D;$Status$b$e]133;A$b"
