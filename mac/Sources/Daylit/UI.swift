// The panel, the on-screen indicator and the keyboard shortcuts window.
import SwiftUI
import AppKit
import Carbon.HIToolbox
import DaylitCore

struct Panel: View {
    @ObservedObject var m: Daylit

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Daylit").font(.system(size: 13, weight: .semibold))
                Spacer()
                gearMenu
            }

            if m.mons.isEmpty {
                Text("No external monitors. Plug one in and Daylit takes over; the built-in screen stays with macOS.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                monitors
            }
            if m.builtIn != nil { builtInRow() }

            if m.source != .off {
                automaticRow
            } else {
                Text("Set a location or Home Assistant in the config file (gear menu) for automatic brightness.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if let p = m.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    /// Everything that is set once and left alone lives here, so the panel stays short.
    var gearMenu: some View {
        Menu {
            Button(m.dark ? "Switch to Light Mode" : "Switch to Dark Mode") { m.toggleDark() }
            Toggle("Light or Dark Mode from Daylight", isOn: Binding(get: { m.lookOn }, set: { m.setLook($0) }))
                .disabled(m.source == .off)
            if m.hasBattery {
                Toggle("Pause on Battery", isOn: Binding(get: { m.pauseOnBattery }, set: { m.setPause($0) }))
            }
            Toggle("Open at Login", isOn: Binding(get: { m.login }, set: { m.setLogin($0) }))
            Divider()
            Button("Keyboard Shortcuts…") { ShortcutsWindow.show() }
            if m.source == .homeAssistant { Button("Home Assistant Token…") { TokenWindow.show(m) } }
            Button("Open Config File…") { m.openConfig() }
            Button("Reload Config") { m.reload() }
            Divider()
            Button("Quit Daylit") { NSApp.terminate(nil) }
        } label: { Image(systemName: "gearshape") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Settings").accessibilityLabel("Settings")
    }

    /// The monitor cards. With two or more, a round link button sits in the gap between the first two.
    var monitors: some View {
        let linked = m.sync && m.mons.count > 1
        return VStack(spacing: 0) {
            ForEach(m.mons.indices, id: \.self) { i in
                row(i, linked: linked)
                if i == 0 && m.mons.count > 1 {
                    linkButton.frame(height: 10).zIndex(1)
                } else if i < m.mons.count - 1 {
                    Spacer().frame(height: 10)
                }
            }
        }
    }

    var linkButton: some View {
        let on = m.sync
        return Button { m.setSync(!on) } label: {
            Image(systemName: "link")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(on ? Color.accentColor : Color(nsColor: .windowBackgroundColor)))
                .overlay(Circle().strokeBorder(on ? Color.clear : Color.primary.opacity(0.15), lineWidth: 0.5))
                .opacity(on ? 1 : 0.9)
        }
        .buttonStyle(.plain)
        .help(on ? "Monitors linked: brightness changes apply to every monitor. Click to unlink."
                 : "Link monitors: brightness changes apply to every monitor, keeping how much brighter each one is.")
        .accessibilityLabel("Sync monitors")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    var automaticRow: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Automatic").font(.system(size: 13, weight: .medium))
                if !m.detail.isEmpty {
                    Text(m.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .help(m.detail)
                }
            }
            Spacer(minLength: 8)
            Toggle("Automatic brightness", isOn: Binding(get: { m.auto }, set: { m.setAuto($0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel("Automatic brightness").accessibilityHint(m.detail)
        }
        .padding(.horizontal, 2)
    }

    /// Shown on hover over a slider instead of a paragraph in the panel.
    var keysHint: String {
        let k = HotKeys.shared
        return k.ok ? "Brightness keys or \(k.pairText) change the screen with the active window. Add ⇧ (⌥⇧ with brightness keys) for fine steps."
                    : "\(k.pairText) are taken by another app; change them in the gear menu. Brightness keys still work (⌥⇧ for fine steps)."
    }

    func note(_ mon: Mon, usable: Bool, unknown: Bool) -> String? {
        if let r = mon.noControl { return r }
        if unknown { return "This monitor doesn't report its brightness. Move the slider to set it." }
        if mon.control == .ddc && mon.readState == .writeOnly { return "Doesn't report its brightness: the slider shows the last level sent." }
        if mon.control == .ddc && mon.readState == .silent { return "This monitor refused the change. Check that DDC/CI is on in its menu." }
        if !usable { return "This monitor did not answer. It may be showing another computer." }
        return nil
    }

    /// The laptop screen while the lid is open: a plain slider, lighter than the managed monitors.
    func builtInRow() -> some View {
        let b = m.builtIn!
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(b.name).font(.system(size: 13)).lineLimit(1)
                Text("macOS").font(.caption2).foregroundStyle(.secondary)
                    .help("Manual only: automatic mode leaves the built-in screen to macOS")
                Spacer()
                Text("\(Int(b.level))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min.fill").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: Binding(get: { m.builtIn?.level ?? 0 }, set: { m.setBuiltIn($0.rounded()) }),
                       in: 0...100, onEditingChanged: { m.draggingBuiltIn = $0 })
                    .controlSize(.small)
                    .accessibilityLabel("\(b.name) brightness")
                Image(systemName: "sun.max.fill").font(.system(size: 13)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    func row(_ i: Int, linked: Bool) -> some View {
        let mon = m.mons[i]
        // A DDC monitor that has not reported its level yet can still be tried with the slider.
        let unknown = mon.control == .ddc && mon.readState == .unknown && !mon.available
        let usable = mon.control != .none && mon.noControl == nil && (mon.available || unknown)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "display").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(mon.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if mon.manual {
                    Text("Manual").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule()).help("Set by hand: kept until the automatic level moves")
                }
                Spacer()
                Text(usable && !unknown ? "\(Int(mon.level))%" : "–").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min.fill").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: Binding(get: { m.mons.indices.contains(i) ? m.mons[i].level : 0 },
                                      set: { m.userSet(i, $0.rounded()) }),
                       in: 0...100, onEditingChanged: { m.dragChanged(i, $0) })
                    .controlSize(.small)
                    .help(keysHint)
                    .accessibilityLabel("\(mon.label) brightness")
                Image(systemName: "sun.max.fill").font(.system(size: 13)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .disabled(!usable)
            if let note = note(mon, usable: usable, unknown: unknown) {
                Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(linked ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1))
    }
}

@MainActor enum HUD {
    static var panel: NSPanel?
    static var hide: DispatchWorkItem?
    static func show(_ label: String, _ v: Double, on id: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }) else { return }
        let size = NSSize(width: 240, height: 70)
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.ignoresMouseEvents = true; p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel = p; return p
        }()
        p.contentView = NSHostingView(rootView: HUDView(label: label, value: v).frame(width: size.width, height: size.height))
        let f = screen.frame
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + f.height * 0.12, width: size.width, height: size.height), display: true)
        p.alphaValue = 1; p.orderFrontRegardless()
        hide?.cancel()
        let w = DispatchWorkItem { NSAnimationContext.runAnimationGroup { $0.duration = 0.3; p.animator().alphaValue = 0 } }
        hide = w; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }
}

/// The on-screen indicator's content.
struct HUDView: View {
    let label: String
    let value: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "display").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text("\(Int(value))%").font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min.fill").font(.system(size: 11)).foregroundStyle(.secondary).accessibilityHidden(true)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(.primary).frame(width: max(6, g.size.width * value / 100))
                    }
                }.frame(height: 6)
                Image(systemName: "sun.max.fill").font(.system(size: 13)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(width: 240, height: 70)
        .panelSurface(cornerRadius: 18)
    }
}

/// Keyboard shortcuts window: click a box, press the combination.
struct ShortcutsView: View {
    // Passed in by the caller (main actor): older compilers treat @State defaults as nonisolated.
    @State var up: HotKeys.Combo
    @State var down: HotKeys.Combo
    @State var recording: Int? = nil     // 0 up, 1 down
    @State var error: String? = nil
    @State var monitor: Any? = nil
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Click a box and press the new combination.")
            Text("They change the screen with the active window. Hold ⇧ as well for steps of 1. The brightness keys keep working.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow { Text("Brighter"); box(0, up) }
                GridRow { Text("Dimmer"); box(1, down) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Reset to Defaults") { up = HotKeys.defaultUp; down = HotKeys.defaultDown; error = nil }
                Spacer()
                Button("Cancel") { stop(); done() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    stop()
                    if HotKeys.shared.apply(up, down) { done() }
                    else { error = "\(up.text) or \(down.text) is taken by another app (or not allowed by macOS). Try another." }
                }.keyboardShortcut(.defaultAction)
            }.padding(.top, 6)
        }
        .padding(20).frame(width: 380)
        .onAppear { HotKeys.shared.unregister() }   // so pressing the current keys records them instead of firing
        .onDisappear { stop(); HotKeys.shared.ok = HotKeys.shared.register(HotKeys.shared.up, HotKeys.shared.down) }
    }

    func box(_ i: Int, _ c: HotKeys.Combo) -> some View {
        Button { start(i) } label: {
            Text(recording == i ? "Press keys…" : c.text).frame(minWidth: 160).monospaced()
        }
        .accessibilityLabel(i == 0 ? "Brighter shortcut" : "Dimmer shortcut")
    }

    func start(_ i: Int) {
        stop(); recording = i; error = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let f = e.modifierFlags
            if f.contains(.shift) { error = "Leave ⇧ out: it is added automatically for steps of 1."; return nil }
            if !f.contains(.control) && !f.contains(.command) { error = "Use ⌃ or ⌘ with the key, so it does not clash with typing."; return nil }
            var mods: UInt32 = 0
            if f.contains(.control) { mods |= UInt32(controlKey) }
            if f.contains(.option) { mods |= UInt32(optionKey) }
            if f.contains(.command) { mods |= UInt32(cmdKey) }
            let names: [Int: String] = [kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                                        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Home: "↖", kVK_End: "↘"]
            let ch = names[Int(e.keyCode)] ?? (e.charactersIgnoringModifiers ?? "?").uppercased()
            let c = HotKeys.Combo(key: UInt32(e.keyCode), mods: mods, char: ch)
            if recording == 0 { up = c } else { down = c }
            error = nil; stop()
            return nil
        }
    }
    func stop() { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil; recording = nil }
}

@MainActor enum ShortcutsWindow {
    static var window: NSWindow?
    static func show() {
        StatusController.shared?.close()
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Daylit — Keyboard Shortcuts"; w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: ShortcutsView(up: HotKeys.shared.up, down: HotKeys.shared.down) { window?.close() })
        w.center(); window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            Task { @MainActor in window = nil; StatusController.shared?.model.objectWillChange.send() }
        }
        NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
    }
}
