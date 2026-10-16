$sw = [Diagnostics.Stopwatch]::StartNew()
$seen = ''
while ($sw.ElapsedMilliseconds -lt 4000) {
	if ([Console]::KeyAvailable) {
		$k = [Console]::ReadKey($true)
		$c = [int]$k.KeyChar
		$seen += "[$($sw.ElapsedMilliseconds)ms $c $($k.Key)]"
	} else { Start-Sleep -Milliseconds 5 }
}
[Console]::WriteLine('keys=' + $seen)
