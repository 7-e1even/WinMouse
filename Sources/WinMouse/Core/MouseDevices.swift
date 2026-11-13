import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

// CGEvent.h 未公开这两个符号，但系统库中一直存在（LinearMouse 同款用法）：
// 取事件的底层 IOHIDEvent，读出产生该事件的设备 registryID（senderID）。
@_silgen_name("CGEventCopyIOHIDEvent")
private func _copyIOHIDEvent(_ event: CGEvent) -> UnsafeMutableRawPointer?

@_silgen_name("IOHIDEventGetSenderID")
private func _senderID(_ ioHidEvent: UnsafeMutableRawPointer?) -> UInt64

@_silgen_name("CFRelease")
private func _cfRelease(_ cf: UnsafeMutableRawPointer?)

// 读取 IOHIDEvent 字段（IOKit 导出、头文件未公开；签名见 IOHIDFamily 开源代码）
@_silgen_name("IOHIDEventGetType")
private func _eventType(_ ioHidEvent: UnsafeMutableRawPointer) -> UInt32

@_silgen_name("IOHIDEventGetEventFlags")
private func _eventFlags(_ ioHidEvent: UnsafeMutableRawPointer) -> UInt32

@_silgen_name("IOHIDEventIsAbsolute")
private func _isAbsolute(_ ioHidEvent: UnsafeMutableRawPointer) -> UInt8

@_silgen_name("IOHIDEventGetFloatValue")
private func _floatValue(_ ioHidEvent: UnsafeMutableRawPointer, _ field: UInt32) -> Double

/// 返回 CFArrayRef（Get 语义，不转移所有权），无子事件时为 NULL
@_silgen_name("IOHIDEventGetChildren")
private func _children(_ ioHidEvent: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?

private let kPointerEventType: UInt32 = 17                     // kIOHIDEventTypePointer
private let kPointerFieldX: UInt32 = kPointerEventType << 16    // kIOHIDEventFieldPointerX
private let kPointerFieldY: UInt32 = kPointerFieldX | 1         // kIOHIDEventFieldPointerY
private let kAcceleratedFlag: UInt32 = 0x0001_0000             // kIOHIDAccelerated

/// 事件底层 IOHIDEvent 里与指针相关的信息
struct HIDPointerInfo {
    /// 产生本事件的 HID 设备 registryID；合成事件（无来源设备）为 nil
    var senderID: UInt64?
    /// 本次 HID 上报的原始计数（macOS 加速/跟踪速度缩放之前）；取不到时为 nil
    var rawDelta: (dx: Double, dy: Double)?
}

extension CGEvent {
    /// 一次拷贝 IOHIDEvent，同时取出来源设备与原始计数（每个移动事件只付一次开销）
    var hidPointerInfo: HIDPointerInfo {
        guard let io = _copyIOHIDEvent(self) else { return HIDPointerInfo() }
        defer { _cfRelease(io) }
        let id = _senderID(io)
        return HIDPointerInfo(senderID: id == 0 ? nil : id, rawDelta: rawPointerDelta(io, depth: 0))
    }
}

/// 在事件树里找第一个"未加速"的相对指针事件，返回它的 X/Y。
///
/// macOS 的 IOHIDPointerScrollFilter 不改原事件：它把加速（含"跟踪速度"线性缩放）后的
/// 结果拷贝成带 kIOHIDAccelerated 标记的子事件追加上去，原事件的 X/Y 仍是设备上报的
/// 原始计数——正是 Windows 曲线要吃的输入。绝对坐标事件（绘图板）不是位移，跳过。
private func rawPointerDelta(_ e: UnsafeMutableRawPointer, depth: Int) -> (dx: Double, dy: Double)? {
    if _eventType(e) == kPointerEventType,
       _eventFlags(e) & kAcceleratedFlag == 0,
       _isAbsolute(e) == 0 {
        return (_floatValue(e, kPointerFieldX), _floatValue(e, kPointerFieldY))
    }
    guard depth < 4, let ref = _children(e) else { return nil }
    let children = Unmanaged<CFArray>.fromOpaque(ref).takeUnretainedValue()
    for i in 0..<CFArrayGetCount(children) {
        guard let child = CFArrayGetValueAtIndex(children, i) else { continue }
        if let d = rawPointerDelta(UnsafeMutableRawPointer(mutating: child), depth: depth + 1) {
            return d
        }
    }
    return nil
}

/// 枚举本机"真鼠标"（IOHID GenericDesktop/Mouse），供事件 tap 按设备来源过滤。
/// 内置触控板走私有 usage（vendor-defined），不在集合内——其移动事件原样放行；
/// 蓝牙/2.4G 接收器鼠标按标准鼠标 usage 枚举，正常接管。
///
/// 注：不依赖 IOHIDManagerRegisterInputValueCallback 检测回报率；该回调在无输入监控
/// 权限时可能收不到事件，实际回报率由 HID 事件时间戳自动估计或由用户手动指定。
final class MouseDevices {
    static let shared = MouseDevices()
    private init() {}

    private var manager: IOHIDManager?
    private let lock = NSLock()
    private var registryIDs: Set<UInt64> = []

    func start() {
        guard manager == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0) // kIOHIDManagerOptionNone

        // UsagePage=1 (GenericDesktop) / Usage=2 (Mouse)
        let match: [String: Any] = [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 2]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)

        let cb: IOHIDDeviceCallback = { _, result, _, _ in
            guard result == kIOReturnSuccess else { return }
            MouseDevices.shared.refresh()
        }
        IOHIDManagerRegisterDeviceMatchingCallback(m, cb, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(m, cb, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, 0)

        manager = m
        refresh()
    }

    private func refresh() {
        guard let m = manager else { return }
        var ids = Set<UInt64>()
        if let devices = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> {
            for d in devices {
                // 内置触控板会额外暴露一个 (1,2) 兼容鼠标服务，按 Built-In 属性排除
                let builtIn = (IOHIDDeviceGetProperty(d, "Built-In" as CFString) as? Bool) ?? false
                guard !builtIn else { continue }
                // senderID 对应 HID 设备内核服务的注册表条目 ID
                let service = IOHIDDeviceGetService(d)
                var id: UInt64 = 0
                if service != 0, IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS {
                    ids.insert(id)
                }
            }
        }
        lock.lock()
        registryIDs = ids
        lock.unlock()
    }

    func contains(_ id: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return registryIDs.contains(id)
    }

    /// 当前枚举到的鼠标设备数（调试用）
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return registryIDs.count
    }
}
