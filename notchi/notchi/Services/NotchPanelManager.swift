import AppKit

@MainActor
@Observable
final class NotchPanelManager {
    enum CollapsedMode: Equatable {
        case normalCollapsed
        case compactIdle
        case compactHoverPreview
    }

    static let shared = NotchPanelManager()

    private static let compactNotchPaddingTotal: CGFloat = 16
    private static func makeCompactNotchRect(notchSize: CGSize, notchRect: CGRect) -> CGRect {
        CGRect(
            x: notchRect.midX - ((notchSize.width + compactNotchPaddingTotal) / 2),
            y: notchRect.minY,
            width: notchSize.width + compactNotchPaddingTotal,
            height: notchRect.height
        )
    }

    private let notificationCenter: NotificationCenter
    private let userDefaults: UserDefaults
    private let hoverExitDelay: Duration
    private let activeSessionCountProvider: @MainActor () -> Int

    private var observerTokens: [NSObjectProtocol] = []
    private var cachedShouldUseCompactIdle = false
    private var pendingCompactIdleTask: Task<Void, Never>?
    private var mouseDownMonitor: EventMonitor?
    private var mouseMoveMonitor: EventMonitor?

    private(set) var isExpanded = false
    private(set) var isPinned = false
    private(set) var collapsedMode: CollapsedMode = .normalCollapsed
    private(set) var notchSize: CGSize = .zero
    private(set) var notchRect: CGRect = .zero
    private(set) var compactNotchRect: CGRect = .zero
    private(set) var panelRect: CGRect = .zero
    /// The exact notch shape from the system bezel path, or nil if unavailable
    private(set) var systemNotchPath: CGPath?

    var activeCollapsedRect: CGRect {
        collapsedMode == .compactIdle ? compactNotchRect : notchRect
    }

    init(
        notificationCenter: NotificationCenter = .default,
        userDefaults: UserDefaults = .standard,
        hoverExitDelay: Duration = .milliseconds(150),
        activeSessionCountProvider: @escaping @MainActor () -> Int = { SessionStore.shared.activeSessionCount },
        startEventMonitors: Bool = true,
        observeExternalState: Bool = true
    ) {
        self.notificationCenter = notificationCenter
        self.userDefaults = userDefaults
        self.hoverExitDelay = hoverExitDelay
        self.activeSessionCountProvider = activeSessionCountProvider

        if startEventMonitors {
            setupEventMonitors()
        }
        if observeExternalState {
            setupObservers()
        }

        refreshIdleMode()
    }

    isolated deinit {
        observerTokens.forEach { notificationCenter.removeObserver($0) }
        pendingCompactIdleTask?.cancel()
    }

    func updateGeometry(for screen: NSScreen) {
        let newNotchSize = screen.notchSize
        let screenFrame = screen.frame

        notchSize = newNotchSize
        systemNotchPath = screen.notchPath

        let notchCenterX = screenFrame.origin.x + screenFrame.width / 2
        let sideWidth = max(0, newNotchSize.height - 12) + 24
        let notchTotalWidth = newNotchSize.width + sideWidth

        notchRect = CGRect(
            x: notchCenterX - notchTotalWidth / 2,
            y: screenFrame.maxY - newNotchSize.height,
            width: notchTotalWidth,
            height: newNotchSize.height
        )

        compactNotchRect = Self.makeCompactNotchRect(notchSize: newNotchSize, notchRect: notchRect)

        let panelSize = NotchConstants.expandedPanelSize
        let panelWidth = panelSize.width + NotchConstants.expandedPanelHorizontalPadding
        panelRect = CGRect(
            x: notchCenterX - panelWidth / 2,
            y: screenFrame.maxY - panelSize.height,
            width: panelWidth,
            height: panelSize.height
        )

        refreshIdleMode()
    }

#if DEBUG
    func setGeometryForTesting(
        notchSize: CGSize,
        notchRect: CGRect,
        panelRect: CGRect = .zero,
        systemNotchPath: CGPath? = nil
    ) {
        self.notchSize = notchSize
        self.notchRect = notchRect
        self.panelRect = panelRect
        self.systemNotchPath = systemNotchPath

        compactNotchRect = Self.makeCompactNotchRect(notchSize: notchSize, notchRect: notchRect)

        refreshIdleMode()
    }
#endif

    func expand() {
        guard !isExpanded else { return }
        cancelPendingCompactIdleTask()
        isExpanded = true
        refreshIdleMode()
    }

    func collapse() {
        guard isExpanded else { return }
        cancelPendingCompactIdleTask()
        isExpanded = false
        isPinned = false
        refreshIdleMode()
    }

    func toggle() {
        if isExpanded {
            collapse()
        } else {
            expand()
        }
    }

    func togglePin() {
        isPinned.toggle()
    }

    private func handleCollapsedHoverEntered() {
        cancelPendingCompactIdleTask()
        guard !isExpanded, cachedShouldUseCompactIdle else { return }

        if collapsedMode == .compactIdle {
            setCollapsedMode(.compactHoverPreview)
        }
    }

    private func handleCollapsedHoverExited() {
        guard !isExpanded,
              cachedShouldUseCompactIdle,
              collapsedMode == .compactHoverPreview else { return }
        scheduleCompactIdleReturn()
    }

    func handleMouseLocationChanged(_ location: CGPoint) {
        guard !isExpanded, cachedShouldUseCompactIdle else { return }

        switch collapsedMode {
        case .compactIdle:
            if compactNotchRect.contains(location) {
                handleCollapsedHoverEntered()
            }
        case .compactHoverPreview:
            if notchRect.contains(location) {
                cancelPendingCompactIdleTask()
            } else {
                handleCollapsedHoverExited()
            }
        case .normalCollapsed:
            break
        }
    }

    func refreshIdleMode() {
        cachedShouldUseCompactIdle = userDefaults.bool(forKey: AppSettings.minimizeWhenIdleKey)
            && activeSessionCountProvider() == 0

        if !cachedShouldUseCompactIdle {
            cancelPendingCompactIdleTask()
            setCollapsedMode(.normalCollapsed)
            return
        }

        if isExpanded {
            cancelPendingCompactIdleTask()
            setCollapsedMode(.compactIdle)
            return
        }

        if collapsedMode != .compactHoverPreview {
            setCollapsedMode(.compactIdle)
        }
    }

    private func setupObservers() {
        observerTokens.append(
            notificationCenter.addObserver(
                forName: .sessionStoreActiveSessionCountDidChange,
                object: SessionStore.shared,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshIdleMode()
                }
            }
        )

        observerTokens.append(
            notificationCenter.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshIdleMode()
                }
            }
        )
    }

    private func setupEventMonitors() {
        mouseDownMonitor = EventMonitor(mask: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseDown()
            }
        }
        mouseDownMonitor?.start()

        mouseMoveMonitor = EventMonitor(mask: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                self?.handleMouseLocationChanged(location)
            }
        }
        mouseMoveMonitor?.start()
    }

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation

        if isExpanded {
            if !isPinned && !panelRect.contains(location) {
                collapse()
            }
        } else if activeCollapsedRect.contains(location) {
            expand()
        }
    }

    private func scheduleCompactIdleReturn() {
        cancelPendingCompactIdleTask()
        pendingCompactIdleTask = Task { [weak self, hoverExitDelay] in
            try? await Task.sleep(for: hoverExitDelay)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                guard !self.isExpanded, self.cachedShouldUseCompactIdle else { return }
                self.setCollapsedMode(.compactIdle)
            }
        }
    }

    private func cancelPendingCompactIdleTask() {
        pendingCompactIdleTask?.cancel()
        pendingCompactIdleTask = nil
    }

    private func setCollapsedMode(_ newMode: CollapsedMode) {
        guard collapsedMode != newMode else { return }
        collapsedMode = newMode
    }
}
