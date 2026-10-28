# 精确清理 OSM 抓取相关进程（按命令行匹配 python/bash 子进程）
$pat = 'osm_geometry|fetch_osm_all'
$procs = Get-CimInstance Win32_Process | Where-Object {
    $_.CommandLine -match $pat -and $_.Name -in @('python.exe', 'bash.exe', 'sh.exe', 'sleep.exe')
}
foreach ($p in $procs) {
    try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
        Write-Output ("killed {0} {1}" -f $p.ProcessId, $p.Name)
    } catch {
        Write-Output ("skip {0} ({1})" -f $p.ProcessId, $_.Exception.Message)
    }
}
Write-Output "total matched: $($procs.Count)"
