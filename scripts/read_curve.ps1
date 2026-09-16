$m = Get-ItemProperty 'HKCU:\Control Panel\Mouse'
$bytes = [byte[]]$m.SmoothMouseXCurve
Write-Output ("XCount: " + $bytes.Count)
for ($i = 0; $i -lt 5; $i++) {
    $v = [BitConverter]::ToInt64($bytes, $i * 8)
    Write-Output ("X[" + $i + "] raw=" + $v + "  fixed16.16=" + ($v / 65536.0))
}
$bytes = [byte[]]$m.SmoothMouseYCurve
Write-Output ("YCount: " + $bytes.Count)
for ($i = 0; $i -lt 5; $i++) {
    $v = [BitConverter]::ToInt64($bytes, $i * 8)
    Write-Output ("Y[" + $i + "] raw=" + $v + "  fixed16.16=" + ($v / 65536.0))
}
