# Verify the transfer-function gain table (same math as TransferFunction.swift)
# Windows 原生行为（默认）：曲线直接吃原始 counts/ms，系统不识别鼠标 DPI。
# 若在设置中开启了 400dpi 锚定，把 $dpiAnchor 改为 $true 再运行。
$dpiAnchor = $false
$dpi = 800.0   # 用于把 counts/ms 换算成手速 inch/s（锚定模式下还参与曲线折算）

$x = @(0.0, (28181/65536.0), (81920/65536.0), (252969/65536.0), (2621440/65536.0))
$y = @(0.0, (70141/65536.0), (271360/65536.0), (1244160/65536.0), (29081600/65536.0))
$base = $y[1] / $x[1]

function Interp([double]$v) {
    if ($v -ge $x[4]) { return $y[4] + ($v - $x[4]) * ($y[4]-$y[3]) / ($x[4]-$x[3]) }
    for ($i = 1; $i -le 4; $i++) {
        if ($v -le $x[$i]) {
            $t = ($v - $x[$i-1]) / ($x[$i] - $x[$i-1])
            return $y[$i-1] + $t * ($y[$i] - $y[$i-1])
        }
    }
    return $y[4]
}

"speed(counts/ms)   hand speed(inch/s @$dpi dpi)   normalized_gain(slow=1.0x)"
foreach ($v in @(0.05, 0.2, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0)) {
    $vRef = if ($dpiAnchor) { $v * 400.0 / $dpi } else { $v }
    if ($vRef -le 0.0005) { $g = 1.0 } else { $g = (Interp $vRef) / $vRef / $base }
    "{0,12:N2}          {1,10:N2}          {2,10:N2}x" -f $v, ($v * 1000 / $dpi), $g
}
""
"curve inflection points (inch/s @$dpi dpi): " + (($x | Select-Object -Skip 1 | ForEach-Object { [math]::Round($_ * 1000 / $dpi, 2) }) -join ", ")
