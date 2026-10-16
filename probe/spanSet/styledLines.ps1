param([string]$V)
$e = [char]27
[Console]::OutputEncoding = [Text.Encoding]::UTF8
switch ($V) {
	'plain' { Write-Host "$e[1mbold$e[0m $e[4:3mcurly$e[0m plain" }
	'cjk'   { Write-Host "$e[1mbold$e[0m $e[4:3mcurly$e[0m plain 中" }
	'emoji' { Write-Host "$e[1mbold$e[0m $e[4:3mcurly$e[0m plain 😀" }
	'box'   { Write-Host "$e[1mbold$e[0m $e[4:3mcurly$e[0m plain ┌─┐" }
}
Write-Host "next line"
Start-Sleep -Seconds 30
