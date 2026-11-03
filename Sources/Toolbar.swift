// Kadr — плавающая панель редактора: кнопки инструментов, цвета, толщины, действия.
import AppKit

/// Кнопка панели: SF Symbol, подсветка при наведении, выбранное состояние, подсказка с клавишей.
final class BarButton: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true; updateTint() } }
    var isEnabledButton = true { didSet { alphaValue = isEnabledButton ? 1 : 0.35 } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    private let icon = NSImageView()
    private let label: NSTextField?
    private let prominent: Bool

    init(symbol: String, tip: String, title: String? = nil, prominent: Bool = false) {
        self.prominent = prominent
        self.label = title.map { NSTextField(labelWithString: $0) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = tip
        setAccessibilityElement(true)
        setAccessibilityLabel(tip)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("kadr.button." + symbol)
        self.symbolName = symbol
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        icon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        var width: CGFloat = 30
        if let label {
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            width = 30 + label.intrinsicContentSize.width + 10
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        updateTint()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String) {
        icon.image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)
    }

    private var symbolName = ""

    /// Уникальный идентификатор в пределах окна или строки: «<окно>.button.<символ>», «<строка>.button.<символ>».
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        var v = superview
        while let s = v {
            let id = s.accessibilityIdentifier()
            if id.hasSuffix(".row") { setAccessibilityIdentifier(id + ".button." + symbolName); return }
            v = s.superview
        }
        let wid = window?.accessibilityIdentifier() ?? ""
        if !wid.isEmpty { setAccessibilityIdentifier(wid + ".button." + symbolName) }
    }

    // Для проверок через Accessibility API: нажатие кнопки = щелчок.
    override func accessibilityPerformPress() -> Bool {
        guard isEnabledButton else { return false }
        onClick?()
        return true
    }

    private func updateTint() {
        if prominent {
            icon.contentTintColor = .white
            label?.textColor = .white
        } else {
            icon.contentTintColor = isSelected ? .controlAccentColor : .labelColor
            label?.textColor = .labelColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { if isEnabledButton { pressed = true } }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside && isEnabledButton { onClick?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        if prominent {
            var c = NSColor.controlAccentColor
            if hovering { c = c.blended(withFraction: 0.12, of: .white) ?? c }
            if pressed { c = c.blended(withFraction: 0.15, of: .black) ?? c }
            c.setFill(); path.fill()
            return
        }
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(pressed ? 0.3 : 0.18).setFill(); path.fill()
        } else if pressed {
            NSColor.labelColor.withAlphaComponent(0.16).setFill(); path.fill()
        } else if hovering && isEnabledButton {
            NSColor.labelColor.withAlphaComponent(0.08).setFill(); path.fill()
        }
    }
}

/// Кружок цвета.
final class SwatchButton: NSView {
    let color: NSColor
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    init(color: NSColor, tip: String) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = tip
        setAccessibilityLabel(tip)
        setAccessibilityRole(.button)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 22), heightAnchor.constraint(equalToConstant: 30)])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func mouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = (hovering || isSelected) ? 16 : 14
        let r = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        color.setFill()
        let p = NSBezierPath(ovalIn: r)
        p.fill()
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        p.lineWidth = 0.75
        p.stroke()
        if isSelected {
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: -3, dy: -3))
            ring.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
        }
    }
}

/// Точка толщины линии.
final class WidthButton: NSView {
    let dot: CGFloat
    var onClick: (() -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    init(dot: CGFloat, tip: String) {
        self.dot = dot
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = tip
        setAccessibilityLabel(tip)
        setAccessibilityRole(.button)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 26), heightAnchor.constraint(equalToConstant: 30)])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func mouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 8, yRadius: 8)
        if isSelected { NSColor.controlAccentColor.withAlphaComponent(0.18).setFill(); bg.fill() }
        else if hovering { NSColor.labelColor.withAlphaComponent(0.08).setFill(); bg.fill() }
        let r = NSRect(x: bounds.midX - dot / 2, y: bounds.midY - dot / 2, width: dot, height: dot)
        (isSelected ? NSColor.controlAccentColor : NSColor.labelColor).setFill()
        NSBezierPath(ovalIn: r).fill()
    }
}

/// Вертикальный разделитель групп.
final class BarSeparator: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 11), heightAnchor.constraint(equalToConstant: 30)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX - 0.5, y: 7, width: 1, height: bounds.height - 14).fill()
    }
}

/// Капсула на материале с тенью, которая «парит» над подложкой редактора.
final class FloatingBar: NSView {
    let stack = NSStackView()

    init(items: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .withinWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor.separatorColor.cgColor
        fx.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fx)

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 7, bottom: 5, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        items.forEach { stack.addArrangedSubview($0) }
        fx.addSubview(stack)

        NSLayoutConstraint.activate([
            fx.leadingAnchor.constraint(equalTo: leadingAnchor),
            fx.trailingAnchor.constraint(equalTo: trailingAnchor),
            fx.topAnchor.constraint(equalTo: topAnchor),
            fx.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor),
            stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for v in subviews { v.layer?.borderColor = NSColor.separatorColor.cgColor }
        }
    }
}
