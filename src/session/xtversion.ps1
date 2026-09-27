$esc = [char]27
[Console]::Write($esc + '[>q')
Start-Sleep -Milliseconds 300
$reply = ''
while ([Console]::KeyAvailable) {
	$c = [Console]::ReadKey($true).KeyChar
	if ($c -eq $esc) { $reply += '^' } else { $reply += $c }
}
[Console]::WriteLine('reply=' + $reply)
