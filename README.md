# WinMouse — 把 Windows 鼠标手感搬到 macOS

一个菜单栏小工具，把三个知名鼠标工具的核心功能"缝合"为一体：

| 功能 | 来源灵感 | 实现 |
|---|---|---|
| 指针跟手（Windows 曲线/线性增益） | LinearMouse | 接管移动事件，套用**从你自己的 Windows 注册表导出的真实加速曲线** |
| 滚轮增强 | Mos | 速度倍率 0.25×–8× + 方向反转（只影响鼠标滚轮，触控板不动） |
| 侧键映射 | Mac Mouse Fix | X1/X2 → 后退/前进（⌘[ / ⌘]），可开关 |

## 原理

```
鼠标硬件 → macOS(关闭系统指针加速) → CGEventTap 拦截
        ├─ 移动: 逐事件瞬时速度(与 Windows 一致,无平滑) → 五点曲线插值(读自注册表) → 增益放大 → 亚像素余量累加 → 放行
        ├─ 滚轮: 行/像素增量缩放(带余量) + 可选反转 → 放行
        └─ 侧键: X1/X2 → 吞掉原事件, 发送 ⌘[ / ⌘]
```

- **Windows 曲线模式**（EPP 开 · 默认手感）：现代 Windows 实际公式 `增益 = (Y/X) × 96/420`，其中 `X = 每次上报计数 / 3.5`（回报率相关）。100% 缩放、1000Hz 鼠标下：慢速 ×0.57，约 2.3 counts/ms 处 ×1.0，急甩最高约 ×2.5（公式经 MarkC 逆向实测验证）。曲线控制点为注册表实测值：

  | 点 | X (每报计数/3.5) | Y (输出) | 实际像素增益（100% 缩放） |
  |---|---|---|---|
  | 1 | 0 | 0 | ×0.57（慢速段） |
  | 2 | 0.43 | 1.07 | ×0.57 |
  | 3 | 1.25 | 4.14 | ×0.76 |
  | 4 | 3.86 | 18.98 | ×1.13 |
  | 5 | 40.0 | 443.75 | ×2.54 |

- **纯线性模式**（EPP 关 · 游戏手感）：固定增益，纯 1:1 映射。

## 构建与打包（在 Mac 上）

```bash
cd WinMouse
./scripts/make_app.sh     # 编译 release 并打包成 build/WinMouse.app（含临时签名）
open build/WinMouse.app
```

要求：macOS 13+，Xcode Command Line Tools（`xcode-select --install`）。
直接 `swift run` 也能跑，但只有 .app 形态开机自启才生效、辅助功能授权身份才稳定。

## 应用界面

- **菜单栏**：🖱️ 图标（未授权时 ⚠️），快捷开关启用状态、切换曲线模式、开机自启、打开设置、退出
- **设置窗口**（菜单栏 → 设置…），分页式：
  - **指针**：运行状态（未授权时显示授权按钮）、启用开关、曲线模式（Windows 曲线 / 纯线性）、指针灵敏度、400dpi 锚定开关与 DPI、**实时曲线图**（对数速度轴上的归一化增益形状 + 控制点 + 当前速度红点）、**实时速度与增益监测**、校准提示
  - **滚轮与按键**：滚轮速度倍率、方向反转、侧键 X1/X2 → 前进/后退
  - **关于**：使用步骤、辅助功能授权按钮、开机自启、曲线数据来源说明

## 首次运行（重要）

1. **关闭 macOS 自带加速**：系统设置 → 鼠标 → 高级 → 关闭"指针加速"。
   否则系统曲线与本工具增益叠加，手感会双重加速。
2. 启动 WinMouse.app，首次会请求**辅助功能**权限：系统设置 → 隐私与安全性 → 辅助功能，勾选 WinMouse（`swift run` 方式则授权给终端）。
3. 菜单栏图标说明：🖱️ 正常工作；⚠️ 未获权限（点击菜单"授权辅助功能…"）。

## 校准（做到和你的 Windows 位移一致）

1. 同一只鼠标，两台电脑 DPI 设成相同值，Windows 滑块保持默认 6/11。
2. Windows 上匀速移动鼠标一段距离，记住光标行程。
3. Mac 上打开 WinMouse → 设置…，选好鼠标 DPI，微调"灵敏度"，直到同样手上距离光标行程一致。
4. 先用中速校准，再分别验证慢速（微调 DPI 档）与快速甩动（曲线形状已内置，无需调）。

## 文件结构

```
WinMouse/
├── Package.swift
├── Info.plist                # .app 包配置（LSUIElement 菜单栏应用、bundle id、版本）
├── scripts/
│   ├── make_app.sh           # 一键打包 build/WinMouse.app（优先用自签证书签名）
│   ├── make_cert.sh          # 创建自签代码签名证书（每台机器一次，重编译不丢授权）
│   ├── read_curve.ps1        # 在 Windows 上重新导出注册表曲线（如有改动）
│   └── verify_curve.ps1      # 打印增益表，验证曲线数学与 Swift 实现一致
├── reference/                # 参考用开源实现克隆（已被 .gitignore 排除）
└── Sources/WinMouse/
    ├── main.swift            # 入口，菜单栏应用
    ├── AppDelegate.swift     # 菜单栏、权限轮询、登录项
    ├── Core/                 # 鼠标逻辑
    │   ├── EventTap.swift        # CGEventTap 接管：移动增益 + 滚轮缩放/反转 + 侧键映射
    │   ├── TransferFunction.swift# Windows 五点曲线（实测常量）+ 线性模式
    │   └── Settings.swift        # UserDefaults 持久化
    └── UI/                   # 设置界面
        ├── SettingsWindow.swift  # 设置窗口：三页 + 实时监测
        └── CurveGraphView.swift  # 归一化增益曲线图（对数速度轴 + 当前速度红点）
```

Windows 侧曲线若被改动（驱动、加速补丁），在 Windows 上运行 `scripts/read_curve.ps1`，把输出的 raw 值按 16.16 定点换算后替换 `Core/TransferFunction.swift` 里的 `curveX / curveY` 即可。

## 已知限制

- 移动增益默认只接管真实鼠标：以事件的 IOHID senderID 与 IOKit 枚举到的鼠标设备匹配（LinearMouse 同款方案），触控板、绘图板及远程控制软件合成的移动原样放行（设置里可关闭该过滤）。滚轮模块本就只处理离散滚动，触控板连续滚动不受影响。
- 滚轮只做缩放/反转，没有 Mos 那种动画式平滑滚动（后续路线图）。
- 游戏 raw input 直接读设备、不经过事件 tap，不受影响（与 Windows 行为一致）。
- 曲线直接吃原始 counts/ms（与真实 Windows 一致：系统不识别鼠标 DPI），高 DPI 鼠标会更早进入加速段；校准只需两台电脑 DPI 设成相同值。若更想要"400dpi 设计基准"手感（拐点按手速固定），可在设置里勾选锚定并选对 DPI。

## 参考与致谢

- 微软《Pointer Ballistics for Windows XP》（曲线算法官方描述，现代 Windows 沿用）
- [LinearMouse](https://github.com/linearmouse/linearmouse)、[Mac Mouse Fix](https://github.com/noah-nuebling/mac-mouse-fix)、[Mos](https://github.com/Caldis/Mos) — 同类开源实现，进阶功能（按设备过滤、滚轮、按键）可参考它们的源码
