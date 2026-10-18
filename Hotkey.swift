import Carbon

// 전체 단축키: 어느 앱을 쓰고 있든 대시보드를 열고 닫음 (접근성 권한 필요 없음)

enum Hotkey {
    static let key = "hotkey"

    struct Preset {
        let id: String
        let label: String
        let keyCode: Int
        let modifiers: Int
    }

    static let presets: [Preset] = [
        Preset(id: "off", label: "", keyCode: 0, modifiers: 0),
        Preset(id: "optcmdU", label: "⌥⌘U", keyCode: kVK_ANSI_U, modifiers: optionKey | cmdKey),
        Preset(id: "ctrloptU", label: "⌃⌥U", keyCode: kVK_ANSI_U, modifiers: controlKey | optionKey),
        Preset(id: "ctrloptcmdU", label: "⌃⌥⌘U", keyCode: kVK_ANSI_U, modifiers: controlKey | optionKey | cmdKey),
        Preset(id: "optcmdB", label: "⌥⌘B", keyCode: kVK_ANSI_B, modifiers: optionKey | cmdKey),
        Preset(id: "shiftcmdSpace", label: "⇧⌘Space", keyCode: kVK_Space, modifiers: shiftKey | cmdKey),
    ]

    static var action: (() -> Void)?
    private static var ref: EventHotKeyRef?
    private static var installed = false
    private static var current = ""

    // 설정 값에 맞춰 단축키를 다시 등록 (같으면 아무것도 안 함)
    static func apply() {
        let id = UserDefaults.standard.string(forKey: key) ?? "optcmdU"
        guard id != current else { return }
        current = id
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard let p = presets.first(where: { $0.id == id }), p.id != "off" else { return }

        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { Hotkey.action?() }
                return noErr
            }, 1, &spec, nil, nil)
            installed = true
        }
        let hotID = EventHotKeyID(signature: OSType(0x5553_4252), id: 1)   // "USBR"
        let status = RegisterEventHotKey(UInt32(p.keyCode), UInt32(p.modifiers), hotID, GetApplicationEventTarget(), 0, &ref)
        if ProcessInfo.processInfo.environment["USAGE_DEBUG"] != nil { print("hotkey", p.label, "status", status); fflush(stdout) }
    }
}
