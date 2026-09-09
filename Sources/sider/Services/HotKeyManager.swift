import AppKit
import Carbon.HIToolbox

/// Registers ⌥⌘S as a system-wide toggle for the panel.
///
/// Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor: a global monitor
/// only *observes* keystrokes (so the shortcut would also reach whatever app is in front),
/// needs Accessibility to see key events at all, and stops being delivered while another app
/// runs a modal tracking loop. A registered hot key is owned by the system, consumed rather
/// than observed, and needs no permission.
///
/// One fixed combination, not a recorder. A rebindable shortcut needs a capture UI, a
/// persistence format and a conflict story; ⌥⌘S is unclaimed on a stock macOS and this can
/// grow a recorder later without changing anything outside this file.
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x53445221   // 'SDR!'

    private init() {}

    var isRegistered: Bool { hotKeyRef != nil }

    func register() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.onTrigger?() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_S),
                                         UInt32(optionKey | cmdKey),
                                         id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            // Almost always means another app already owns ⌥⌘S. Nothing to do about it from
            // here, and it must not be fatal — the edge hover is the primary way in.
            Logger.log("HotKeyManager: could not register ⌥⌘S (OSStatus \(status))")
            hotKeyRef = nil
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    func apply(enabled: Bool) {
        enabled ? register() : unregister()
    }
}
