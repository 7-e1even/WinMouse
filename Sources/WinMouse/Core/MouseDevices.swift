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

extension CGEvent {
    /// 产生本事件的 HID 设备 registryID；合成事件（无来源设备）返回 nil
    var hidSenderID: UInt64? {
        guard let io = _copyIOHIDEvent(self) else { return nil }
        defer { _cfRelease(io) }
        let id = _senderID(io)
        return id == 0 ? nil : id
    }
}

/// 枚举本机"真鼠标"（IOHID GenericDesktop/Mouse），供事件 tap 按设备来源过滤。
/// 内置触控板走私有 usage（vendor-defined），不在集合内——其移动事件原样放行；
/// 蓝牙/2.4G 接收器鼠标按标准鼠标 usage 枚举，正常接管。
///
/// 注：回报率自动检测（IOHIDManagerRegisterInputValueCallback）在无输入监控权限的
/// 环境下收不到回调（实测 12s 零事件），故回报率由用户在设置中选择。
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
