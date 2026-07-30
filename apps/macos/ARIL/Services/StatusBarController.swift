import AppKit

@MainActor
final class StatusBarController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private var pulseTimer: Timer?
    private var pulsePhase: CGFloat = 0
    private var isPulsing = false

    func setEnabled(_ enabled: Bool) {
        if enabled {
            ensureStatusItem()
        } else {
            stopPulse()
            removeStatusItem()
        }
    }

    /// Soft pulse while a reply is in flight so the tray mark stays noticeable.
    func setBusy(_ busy: Bool) {
        guard statusItem != nil else { return }
        if busy {
            startPulse()
        } else {
            stopPulse()
            statusItem?.button?.image = Self.menuBarIcon(emphasis: 1)
            statusItem?.button?.alphaValue = 1
        }
    }

    private func ensureStatusItem() {
        if statusItem != nil { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.menuBarIcon(emphasis: 1)
            button.imagePosition = .imageOnly
            button.toolTip = "ARIL"
            button.appearsDisabled = false
        }
        item.menu = makeMenu()
        statusItem = item
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func startPulse() {
        guard !isPulsing else { return }
        isPulsing = true
        pulseTimer?.invalidate()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickPulse()
            }
        }
        if let pulseTimer {
            RunLoop.main.add(pulseTimer, forMode: .common)
        }
    }

    private func stopPulse() {
        isPulsing = false
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulsePhase = 0
        statusItem?.button?.alphaValue = 1
    }

    private func tickPulse() {
        pulsePhase += 0.12
        let wave = (sin(pulsePhase) + 1) / 2 // 0…1
        statusItem?.button?.alphaValue = 0.45 + 0.55 * wave
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: "Open ARIL",
            action: #selector(openARIL),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let prefsItem = NSMenuItem(
            title: "Preferences…",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit ARIL",
            action: #selector(quitARIL),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    /// Mono adaptive-mesh silhouette as a template image (macOS tints it for light/dark menu bars).
    private static func menuBarIcon(emphasis: CGFloat) -> NSImage {
        let pointSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            defer { ctx.restoreGState() }

            let inset = rect.insetBy(dx: 1.2, dy: 1.2)
            let cx = inset.midX
            let cy = inset.midY
            let r = min(inset.width, inset.height) * 0.38

            // Black + alpha → template tint (white on dark menu bar, dark on light).
            NSColor.black.withAlphaComponent(0.35 * emphasis).setStroke()
            let mesh = NSBezierPath()
            mesh.lineWidth = 1.0
            mesh.lineCapStyle = .round
            // Outer ring hint
            mesh.appendOval(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            // Cross chords (mesh suggestion)
            mesh.move(to: CGPoint(x: cx - r * 0.85, y: cy - r * 0.25))
            mesh.line(to: CGPoint(x: cx + r * 0.55, y: cy + r * 0.55))
            mesh.move(to: CGPoint(x: cx - r * 0.75, y: cy + r * 0.45))
            mesh.line(to: CGPoint(x: cx + r * 0.65, y: cy - r * 0.35))
            mesh.move(to: CGPoint(x: cx - r * 0.15, y: cy - r * 0.9))
            mesh.line(to: CGPoint(x: cx + r * 0.2, y: cy + r * 0.85))
            mesh.stroke()

            // Best path (stronger)
            NSColor.black.withAlphaComponent(emphasis).setStroke()
            NSColor.black.withAlphaComponent(emphasis).setFill()
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let input = CGPoint(x: cx - r * 1.05, y: cy)
            let p1 = CGPoint(x: cx - r * 0.45, y: cy - r * 0.08)
            let p2 = CGPoint(x: cx + r * 0.15, y: cy + r * 0.12)
            let selected = CGPoint(x: cx + r * 1.0, y: cy)
            path.move(to: input)
            path.line(to: p1)
            path.line(to: p2)
            path.line(to: selected)
            path.stroke()

            // Input hollow ring
            let inR: CGFloat = 2.1
            let inRing = NSBezierPath(ovalIn: CGRect(x: input.x - inR, y: input.y - inR, width: inR * 2, height: inR * 2))
            inRing.lineWidth = 1.3
            inRing.stroke()

            // Path nodes
            for p in [p1, p2] {
                let nr: CGFloat = 1.35
                NSBezierPath(ovalIn: CGRect(x: p.x - nr, y: p.y - nr, width: nr * 2, height: nr * 2)).fill()
            }

            // Selected node (filled + ring)
            let outR: CGFloat = 2.4
            let outRing = NSBezierPath(ovalIn: CGRect(x: selected.x - outR, y: selected.y - outR, width: outR * 2, height: outR * 2))
            outRing.lineWidth = 1.3
            outRing.stroke()
            let coreR: CGFloat = 1.1
            NSBezierPath(ovalIn: CGRect(x: selected.x - coreR, y: selected.y - coreR, width: coreR * 2, height: coreR * 2)).fill()

            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func openARIL() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quitARIL() {
        NSApp.terminate(nil)
    }
}
