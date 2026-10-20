# Runs one workload in a live Haro window and prints one JSON line.
#   pwsh bench/live/drive.ps1 -Exe out/haroStats.exe -Work flood|color|echo|nvim|replay|launch
# The exe must be built with --stats support; build it with -d:voidProfiler to get Void's draw
# times.
# flood and color wait for the shell to come up, then time `cmd /c type` of 10 MB inside Haro.
# echo types keys into cmd's prompt; nvim presses j in `nvim --clean` over the plain file.
# replay plays the plain file through --replay, from launch to the end of the recording.
# launch starts the configured shell and prints each launch mark in ms after the process was
# created.
# -LoadFile names a machine-load status line ("... OK ... cpu=N% ..."); the run waits up to 15 min
# for cpu <= -MaxCpu. -Unset names environment variables the shell inside Haro must not inherit.
param(
	[string]$Exe,
	[string]$Work,
	[string]$Cwd = (Resolve-Path "$PSScriptRoot/../..").Path,
	[int]$Keys = 120,
	[int]$GapMs = 40,
	[int]$MaxCpu = 60,
	[string]$LoadFile = "",
	[string[]]$Unset = @('NO_COLOR'),
	[string]$Inner = "",
	[string]$Out = ""
)
$ErrorActionPreference = 'Stop'
$data = Join-Path $env:TEMP 'haroLive'

function Now { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

if ($Inner -ne "") {
	Set-Content "$Out.ready" $PID
	while (-not (Test-Path "$Out.go")) { Start-Sleep -Milliseconds 100 }
	Start-Sleep 1
	$t0 = Now
	$p = Start-Process cmd.exe -ArgumentList "/c type `"$data\$Inner.txt`"" -NoNewWindow -PassThru
	$p.WaitForExit()
	Set-Content "$Out.span" "$t0 $(Now)"
	Start-Sleep 2
	exit 0
}

function Ensure-Data {
	New-Item -ItemType Directory -Force $data | Out-Null
	$size = 10MB
	if (-not (Test-Path "$data\plain.txt")) {
		$sb = [System.Text.StringBuilder]::new()
		$i = 0
		while ($sb.Length -lt $size) {
			[void]$sb.Append("line $i the quick brown fox jumps over the lazy dog 0123456789`r`n")
			$i++
		}
		[IO.File]::WriteAllText("$data\plain.txt", $sb.ToString())
	}
	if (-not (Test-Path "$data\color.txt")) {
		$esc = [char]27
		$sb = [System.Text.StringBuilder]::new()
		$y = 0
		while ($sb.Length -lt $size) {
			for ($x = 0; $x -lt 80; $x++) {
				$rgb = "$(($x * 3) % 256);$(($y * 5) % 256);$((($x + $y) * 7) % 256)"
				[void]$sb.Append("$esc[38;2;${rgb}m#")
			}
			[void]$sb.Append("$esc[0m`r`n")
			$y++
		}
		[IO.File]::WriteAllText("$data\color.txt", $sb.ToString())
	}
}

Add-Type @'
using System; using System.Runtime.InteropServices;
public static class HaroLive {
	[DllImport("user32.dll")]
	public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
	[DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint code, uint type);
}
'@

function Press([IntPtr]$hwnd, [int]$vk, [int]$ch) {
	$sc = [HaroLive]::MapVirtualKeyW($vk, 0)
	[int64]$down = 1 -bor ($sc -shl 16)
	[int64]$up = $down -bor (1 -shl 30) -bor ([int64]1 -shl 31)
	[void][HaroLive]::PostMessageW($hwnd, 0x100, [IntPtr]$vk, [IntPtr]$down)
	[void][HaroLive]::PostMessageW($hwnd, 0x102, [IntPtr]$ch, [IntPtr]$down)
	[void][HaroLive]::PostMessageW($hwnd, 0x101, [IntPtr]$vk, [IntPtr]$up)
}

function Median([double[]]$xs) {
	if ($xs.Count -eq 0) { return $null }
	$s = $xs | Sort-Object
	return $s[[math]::Floor($s.Count / 2)]
}

$loadStart = ""
if ($LoadFile -ne "") {
	$waited = Get-Date
	while (((Get-Date) - $waited).TotalSeconds -lt 900) {
		$l = "$(Get-Content $LoadFile -ErrorAction SilentlyContinue)"
		$calm = $l -match ' OK ' -and $l -match 'cpu=(\d+)%' -and [int]$Matches[1] -le $MaxCpu
		if ($calm) { break }
		Start-Sleep 10
	}
	$loadStart = "$(Get-Content $LoadFile -ErrorAction SilentlyContinue)"
}

Ensure-Data
$logs = Join-Path $data 'logs'
New-Item -ItemType Directory -Force $logs | Out-Null
$stamp = "$Work-$(Now)"
$out = Join-Path $logs $stamp
$exePath = (Resolve-Path $Exe).Path
if ("$PSCommandPath$out" -match " ") {
	throw "--shell takes these paths unquoted; move the checkout or TEMP to a path with no spaces"
}
$floodFile = @{ flood = 'plain'; color = 'color' }[$Work]
$shell = switch ($Work) {
	{ $null -ne $floodFile } {
		"pwsh.exe -NoLogo -NoProfile -File $PSCommandPath -Inner $floodFile -Out $out"
	}
	'echo' { 'cmd.exe /k' }
	'nvim' { "nvim --clean -n $data\plain.txt" }
	'replay' { '' }
	'launch' { '' }
	default { throw "unknown workload ${Work}; use flood, color, echo, nvim, replay or launch" }
}
foreach ($v in $Unset) { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
$haroArgs = if ($Work -eq 'replay') {
	@('--stats', '--replay', "$data\plain.txt")
} elseif ($Work -eq 'launch') {
	@('--stats')
} else {
	@('--stats', '--shell', "`"$shell`"")
}
$launched = Get-Date
$p = Start-Process $exePath -WorkingDirectory $Cwd -ArgumentList $haroArgs `
	-RedirectStandardOutput "$out.out" -RedirectStandardError "$out.err" -PassThru
try {
	$null = $p.Handle
	$hwnd = [IntPtr]::Zero
	for ($i = 0; $i -lt 100 -and $hwnd -eq [IntPtr]::Zero; $i++) {
		Start-Sleep -Milliseconds 100
		$p.Refresh()
		$hwnd = $p.MainWindowHandle
	}
	if ($hwnd -eq [IntPtr]::Zero) { throw "Haro showed no window; see $out.err" }
	$marks = [ordered]@{}
	if ($Work -eq 'launch') {
		while (-not (Select-String -Path "$out.out" -Pattern '^haro launch:' -Quiet)) {
			if (((Get-Date) - $launched).TotalSeconds -gt 30) {
				throw "no launch line in 30 s; see $out.out"
			}
			Start-Sleep -Milliseconds 100
		}
		$created = ([DateTimeOffset]$p.StartTime).ToUnixTimeMilliseconds()
		$launchLine = Select-String -Path "$out.out" -Pattern '^haro launch: (.*)$'
		foreach ($pair in ($launchLine.Matches[0].Groups[1].Value -split ' ')) {
			$kv = $pair.Split('=')
			$marks[$kv[0]] = [double]$kv[1] - $created
		}
		$wall = $marks['painted']
		$busy = 0; $idle = 0; $fromLine = 0
	} elseif ($Work -eq 'replay') {
		while (-not (Select-String -Path "$out.out" -Pattern 'the recording ended' -Quiet)) {
			if (((Get-Date) - $launched).TotalSeconds -gt 120) {
				throw "the replay did not end in 120 s; see $out.out"
			}
			Start-Sleep -Milliseconds 50
		}
		$wall = ((Get-Date) - $launched).TotalMilliseconds
		$p.Refresh(); $busy = 100 * $p.TotalProcessorTime.TotalMilliseconds / $wall
		$idle = 0; $fromLine = 0
	} else {
		if ($floodFile) {
			while (-not (Test-Path "$out.ready")) {
				if ($p.HasExited) { throw "Haro exited early; see $out.err" }
				Start-Sleep -Milliseconds 200
			}
			Start-Sleep 2
		} else {
			Start-Sleep 3
		}
		$p.Refresh(); $c0 = $p.TotalProcessorTime.TotalMilliseconds; $w0 = Get-Date
		Start-Sleep 3
		$p.Refresh()
		$idleCpuMs = $p.TotalProcessorTime.TotalMilliseconds - $c0
		$idle = 100 * $idleCpuMs / ((Get-Date) - $w0).TotalMilliseconds
		$fromLine = @(Get-Content "$out.out" -ErrorAction SilentlyContinue).Count
		$p.Refresh(); $c0 = $p.TotalProcessorTime.TotalMilliseconds; $w0 = Get-Date
		if ($floodFile) {
			New-Item "$out.go" -ItemType File | Out-Null
			while (-not (Test-Path "$out.span") -and -not $p.HasExited) {
				Start-Sleep -Milliseconds 100
			}
			$span = (Get-Content "$out.span").Split(' ')
			$wall = [double]$span[1] - [double]$span[0]
		} else {
			$vk = if ($Work -eq 'echo') { 0x41 } else { 0x4A }
			$ch = if ($Work -eq 'echo') { 97 } else { 106 }
			for ($k = 0; $k -lt $Keys; $k++) {
				Press $hwnd $vk $ch
				Start-Sleep -Milliseconds $GapMs
			}
			Start-Sleep 1
			$wall = ((Get-Date) - $w0).TotalMilliseconds
		}
		$p.Refresh()
		$busyCpuMs = $p.TotalProcessorTime.TotalMilliseconds - $c0
		$busy = 100 * $busyCpuMs / ((Get-Date) - $w0).TotalMilliseconds
	}
	Start-Sleep 1.2
} finally {
	if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
}

$lines = @(Get-Content "$out.out" | Select-Object -Skip $fromLine |
	Where-Object { $_ -like 'haro stats:*' })
$sum = [ordered]@{
	refreshes = 0; more = 0; rows = 0; scrolled = 0; chars = 0
	wakes = 0; applies = 0; requested = 0; drawn = 0
}
$echo = @{ n = 0; p50 = @(); max = 0 }
$settle = @{ n = 0; p50 = @(); max = 0 }
$voidLine = ''
foreach ($line in $lines) {
	foreach ($k in @($sum.Keys)) { if ($line -match " $k=(\d+)") { $sum[$k] += [int]$Matches[1] } }
	foreach ($pair in @(@('echo', $echo), @('settle', $settle))) {
		if ($line -match "$($pair[0]) n=(\d+) p50=([\d.]+) max=([\d.]+)") {
			$pair[1].n += [int]$Matches[1]
			$pair[1].p50 += [double]$Matches[2]
			$pair[1].max = [math]::Max($pair[1].max, [double]$Matches[3])
		}
	}
	if ($line -match '(void frames=.*)$') { $voidLine = $Matches[1] }
}
$r = [ordered]@{
	work = $Work
	exe = $exePath
	load_start = $loadStart
	wall_ms = [math]::Round($wall)
	idle_cpu_pct = [math]::Round($idle, 1)
	busy_cpu_pct = [math]::Round($busy, 1)
	seconds = $lines.Count
}
foreach ($k in $sum.Keys) { $r[$k] = $sum[$k] }
foreach ($pair in @(@('echo', $echo), @('settle', $settle))) {
	$r["$($pair[0])_n"] = $pair[1].n
	$r["$($pair[0])_p50_of_seconds_ms"] = Median $pair[1].p50
	$r["$($pair[0])_max_ms"] = $pair[1].max
}
$r['void'] = $voidLine
if ($marks.Count -gt 0) { $r['launch_ms'] = $marks }
$r['log'] = "$out.out"
$r | ConvertTo-Json -Compress
