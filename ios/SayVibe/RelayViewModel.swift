import Foundation

@MainActor
final class RelayViewModel: ObservableObject {
    @Published var ipAddress = ""
    @Published var portText = "18700"
    @Published var statusMessage: String
    @Published var statusTone: StatusTone = .neutral
    @Published var syncText = ""
    @Published var scanResults: [LanDevice] = []
    @Published var recentDevices: [RecentDevice] = []
    @Published var scanSummary: String
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var isScanning = false
    @Published var autoImeSupported = false
    @Published var autoImeMode: AutoImeActionMode = .review
    @Published var isUpdatingAutoImeMode = false
    @Published var isTriggeringPcEnter = false

    private let lanScanner = LanScanner()
    private let jsonEncoder = JSONEncoder()
    private let userDefaults = UserDefaults.standard
    private var pendingSyncTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    private enum StorageKey {
        static let ipAddress = "sayvibe.ip_address"
        static let port = "sayvibe.port"
        static let recentDevices = "sayvibe.recent_devices"
    }

    private lazy var urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        return URLSession(configuration: configuration)
    }()

    init() {
        statusMessage = AppLanguage.current.text("未连接", "Not connected")
        scanSummary = AppLanguage.current.text("可扫码配对，也可扫描局域网自动发现电脑地址", "Use QR pairing or scan the local network to discover your Mac")
        restorePersistedState()
    }

    private var appLanguage: AppLanguage {
        .current
    }

    private func localized(_ chinese: @autoclosure () -> String, _ english: @autoclosure () -> String) -> String {
        appLanguage.text(chinese(), english())
    }

    func connectButtonTapped() {
        if isConnected {
            disconnect(reason: localized("用户主动断开", "User disconnected manually"))
            return
        }

        guard !isConnecting else { return }
        Task { await connect() }
    }

    func applyPairingPayload(_ rawValue: String) {
        guard let payload = PairingPayload.parse(rawValue) else {
            setStatus(localized("无法识别配对信息", "Unable to recognize the pairing data"), tone: .error)
            return
        }

        let trimmedIP = payload.ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LocalNetwork.isValidIPv4(trimmedIP) else {
            setStatus(localized("二维码里的电脑地址无效", "The QR code does not contain a valid Mac address"), tone: .error)
            return
        }

        if isConnected {
            disconnect(reason: localized("切换配对设备", "Switching paired devices"))
        }

        ipAddress = trimmedIP
        portText = payload.port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "18700" : payload.port
        persistConnectionDraft()
        scanSummary = localized("已通过扫码填入电脑地址", "The Mac address was filled in from the QR code")
        setStatus(localized("已读取配对信息，正在连接电脑...", "Pairing read. Connecting to your Mac..."), tone: .info)

        guard !isConnecting else { return }
        Task { await connect() }
    }

    func setAutoImeMode(_ mode: AutoImeActionMode) {
        autoImeMode = mode
        guard isConnected else { return }

        Task {
            await updateRemoteAutoImeMode(mode)
        }
    }

    func clearLocalInput() {
        pendingSyncTask?.cancel()
        pendingSyncTask = nil
        syncText = ""
        setStatus(localized("已清空本地输入", "Local draft cleared"), tone: .info)
    }

    func triggerPCEnter() {
        guard isConnected else {
            setStatus(localized("请先连接电脑，再执行 PC Enter", "Connect to your Mac before triggering PC Enter"), tone: .error)
            return
        }

        guard !isTriggeringPcEnter else { return }

        Task {
            await sendPCEnter()
        }
    }

    func insertTextFromWidget(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if syncText.isEmpty {
            syncText = trimmed
        } else {
            syncText += "\n" + trimmed
        }

        scheduleAutoSync(for: syncText)
    }

    func selectScannedDevice(_ device: LanDevice) {
        ipAddress = device.ip
        addOrUpdateRecentDevice(ip: device.ip, hostName: device.hostName, port: normalizedPortString())
        persistConnectionDraft()
        setStatus(localized("已选择设备：\(device.ip)", "Selected device: \(device.ip)"), tone: .info)
    }

    func selectRecentDevice(_ device: RecentDevice) {
        ipAddress = device.ip
        portText = device.port
        addOrUpdateRecentDevice(ip: device.ip, hostName: device.hostName, port: device.port)
        persistConnectionDraft()
        setStatus(localized("已选择最近设备：\(device.subtitle)", "Selected recent device: \(device.subtitle)"), tone: .info)
    }

    func removeRecentDevice(_ device: RecentDevice) {
        recentDevices.removeAll { $0.id == device.id }
        saveRecentDevices()
    }

    func handleTextChanged(_ text: String) {
        scheduleAutoSync(for: text)
    }

    func replaceSyncText(with text: String, status: String? = nil, tone: StatusTone = .info) {
        syncText = text
        if let status {
            setStatus(status, tone: tone)
        }
        scheduleAutoSync(for: text)
    }

    func startLanScan() {
        guard !isScanning else { return }
        guard !isConnected && !isConnecting else {
            setStatus(localized("连接中或已连接时无法扫描，请先断开", "Disconnect before scanning for devices"), tone: .info)
            return
        }

        let manualIP = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let scanSeedIP: String
        let scanSource: String

        if LocalNetwork.isValidIPv4(manualIP) {
            scanSeedIP = manualIP
            scanSource = localized("输入地址", "Manual address")
        } else {
            guard let localIP = LocalNetwork.resolveLocalIPv4() else {
                setStatus(localized("无法获取当前局域网 IP，请确认 iPhone 已连接 Wi-Fi", "Unable to get the local network IP. Make sure your iPhone is on Wi-Fi"), tone: .error)
                return
            }
            scanSeedIP = localIP
            scanSource = localized("本机网络", "Current network")
        }

        guard let subnetPrefix = LocalNetwork.subnetPrefix(for: scanSeedIP) else {
            setStatus(localized("无法解析当前局域网网段", "Unable to determine the local subnet"), tone: .error)
            return
        }

        let relayPort = normalizedPortValue()

        cancelLanScan()
        isScanning = true
        scanResults = []
        scanSummary = localized("正在扫描 \(subnetPrefix).x 网段（\(scanSource)）...", "Scanning \(subnetPrefix).x (\(scanSource))...")
        setStatus(localized("已开始扫描局域网设备", "Started scanning the local network"), tone: .info)

        scanTask = Task { [weak self] in
            guard let self else { return }
            let devices = await self.lanScanner.scan(localIP: scanSeedIP, relayPort: relayPort)
            guard !Task.isCancelled else {
                self.scanTask = nil
                self.isScanning = false
                return
            }

            self.scanTask = nil
            self.scanResults = devices
            self.isScanning = false
            self.scanSummary = devices.isEmpty
                ? self.localized("扫描完成：未发现可连接设备", "Scan complete: no available devices found")
                : self.localized("扫描完成：发现 \(devices.count) 台设备（点一项可直接填入）", "Scan complete: found \(devices.count) devices. Tap one to fill it in")
            self.setStatus(self.localized("扫描结束", "Scan finished"), tone: .info)
        }
    }

    func suspendForBackground() {
        cancelLanScan(summary: localized("应用进入后台，扫描已停止", "The app moved to the background, so scanning stopped"))
        if isConnected {
            setStatus(localized("应用在后台，返回后可继续输入同步", "The app is in the background. Return to continue syncing"), tone: .info)
        }
    }

    func resumeForForeground() {
        guard isConnected else { return }
        setStatus(localized("已连接，输入内容会自动同步", "Connected. Input syncs automatically"), tone: .success)
    }

    func shutdown() {
        cancelLanScan(summary: localized("点击“扫描局域网设备”自动发现电脑地址", "Tap “Scan Local Network” to discover your Mac"))
        disconnect(reason: localized("界面退出", "View exited"))
    }

    private func connect() async {
        let ip = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = normalizedPortString()

        guard !ip.isEmpty else {
            setStatus(localized("请输入电脑地址", "Enter your Mac address"), tone: .error)
            return
        }

        ipAddress = ip
        portText = port
        isConnecting = true
        cancelLanScan(summary: localized("扫描已取消，可随时重新开始", "Scan cancelled. You can start again anytime"))
        persistConnectionDraft()

        await connectHTTP(ip: ip, port: port)
    }

    private func connectHTTP(ip: String, port: String) async {
        guard let url = URL(string: "http://\(ip):\(port)/health") else {
            isConnecting = false
            setStatus(localized("连接失败：地址格式无效", "Connection failed: invalid address"), tone: .error)
            return
        }

        setStatus(localized("正在连接电脑...", "Connecting to Mac..."), tone: .info)

        do {
            let (_, response) = try await urlSession.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                isConnecting = false
                setStatus(localized("连接失败：未收到有效响应", "Connection failed: invalid response"), tone: .error)
                return
            }

            isConnecting = false
            if (200...299).contains(httpResponse.statusCode) {
                isConnected = true
                await refreshRemoteDesktopState(ip: ip, port: port)
                addOrUpdateRecentDevice(ip: ip, hostName: hostNameForDevice(ip: ip, port: port), port: port)
                setStatus(localized("已连接，输入内容会自动同步", "Connected. Input syncs automatically"), tone: .success)
                scheduleAutoSync(for: syncText)
            } else {
                isConnected = false
                setStatus(localized("连接失败：HTTP \(httpResponse.statusCode)", "Connection failed: HTTP \(httpResponse.statusCode)"), tone: .error)
            }
        } catch {
            isConnecting = false
            isConnected = false
            setStatus(localized("连接失败：\(mapErrorToLocalized(error))", "Connection failed: \(mapErrorToLocalized(error))"), tone: .error)
        }
    }

    private func disconnect(reason: String) {
        _ = reason
        pendingSyncTask?.cancel()
        pendingSyncTask = nil
        isConnecting = false
        isConnected = false
        autoImeSupported = false
        setStatus(localized("未连接", "Not connected"), tone: .neutral)
    }

    private func cancelLanScan(summary: String? = nil) {
        let hadActiveScan = isScanning || scanTask != nil
        if hadActiveScan {
            scanTask?.cancel()
            scanTask = nil
            isScanning = false
        }
        if let summary, hadActiveScan {
            scanSummary = summary
        }
    }

    private func scheduleAutoSync(for text: String) {
        pendingSyncTask?.cancel()
        guard isConnected else { return }

        pendingSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self else { return }
            await self.sendTextViaHTTP(text)
        }
    }

    private func sendTextViaHTTP(_ text: String) async {
        guard isConnected else { return }

        let ip = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = normalizedPortString()
        guard let url = URL(string: "http://\(ip):\(port)/api/push_text") else {
            setStatus(localized("发送失败：推送地址无效", "Send failed: invalid push URL"), tone: .error)
            return
        }

        let payload = SyncPayload(
            text: text,
            cursor: text.count,
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            requestId: UUID().uuidString
        )

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try jsonEncoder.encode(payload)

            _ = try await urlSession.data(for: request)
            if isConnected {
                setStatus(localized("发送成功", "Sent"), tone: .success)
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            if isConnected {
                setStatus(localized("已发出请求，网络波动时会继续重试", "Request sent. It will retry if the network fluctuates"), tone: .info)
            }
        }
    }

    private func refreshRemoteDesktopState(ip: String, port: String) async {
        guard let url = URL(string: "http://\(ip):\(port)/api/state") else { return }

        do {
            let (data, response) = try await urlSession.data(from: url)
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200...299).contains(httpResponse.statusCode)
            else {
                return
            }

            let payload = try JSONDecoder().decode(DesktopRelayState.self, from: data)
            autoImeSupported = payload.autoImeSupported ?? false
            autoImeMode = payload.autoImeMode ?? .review
        } catch {
            autoImeSupported = false
        }
    }

    private func updateRemoteAutoImeMode(_ mode: AutoImeActionMode) async {
        guard isConnected else { return }

        let ip = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = normalizedPortString()
        guard let url = URL(string: "http://\(ip):\(port)/api/control/auto-ime-mode") else {
            setStatus(localized("设置失败：控制地址无效", "Update failed: invalid control URL"), tone: .error)
            return
        }

        isUpdatingAutoImeMode = true
        defer { isUpdatingAutoImeMode = false }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try jsonEncoder.encode(AutoImeModeControlRequest(mode: mode.rawValue))

            let (data, response) = try await urlSession.data(for: request)
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200...299).contains(httpResponse.statusCode)
            else {
                setStatus(localized("设置失败：电脑未返回成功状态", "Update failed: the Mac did not return success"), tone: .error)
                return
            }

            let payload = try JSONDecoder().decode(AutoImeModeControlResponse.self, from: data)
            autoImeMode = payload.mode ?? mode
            setStatus(localized("电脑端自动输出动作已更新", "Desktop auto output action updated"), tone: .success)
        } catch {
            setStatus(localized("设置失败：请确认电脑端服务在线", "Update failed: make sure the desktop service is online"), tone: .error)
        }
    }

    private func sendPCEnter() async {
        guard isConnected else { return }

        let ip = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = normalizedPortString()
        guard let url = URL(string: "http://\(ip):\(port)/api/control/pc-enter") else {
            setStatus(localized("PC Enter 失败：控制地址无效", "PC Enter failed: invalid control URL"), tone: .error)
            return
        }

        isTriggeringPcEnter = true
        defer { isTriggeringPcEnter = false }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)

            let (_, response) = try await urlSession.data(for: request)
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200...299).contains(httpResponse.statusCode)
            else {
                setStatus(localized("PC Enter 失败：电脑未返回成功状态", "PC Enter failed: the Mac did not return success"), tone: .error)
                return
            }

            setStatus(localized("PC Enter 已发送", "PC Enter sent"), tone: .success)
        } catch {
            setStatus(localized("PC Enter 失败：请确认电脑端在线且焦点正确", "PC Enter failed: make sure the desktop is online and focused correctly"), tone: .error)
        }
    }

    private func normalizedPortString() -> String {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = UInt16(trimmed), parsed > 0 else {
            return "18700"
        }
        return String(parsed)
    }

    private func normalizedPortValue() -> UInt16 {
        let parsed = UInt16(normalizedPortString()) ?? 18700
        return parsed == 0 ? 18700 : parsed
    }

    private func setStatus(_ message: String, tone: StatusTone) {
        statusMessage = message
        statusTone = tone
    }

    func relocalizeVisibleText() {
        if isConnecting {
            statusMessage = localized("正在连接电脑...", "Connecting to Mac...")
        } else if isConnected {
            statusMessage = localized("已连接，输入内容会自动同步", "Connected. Input syncs automatically")
        } else if statusTone == .neutral || statusMessage.isEmpty {
            statusMessage = localized("未连接", "Not connected")
        }

        if isScanning {
            scanSummary = localized("正在扫描局域网设备...", "Scanning local network devices...")
        } else if scanResults.isEmpty {
            scanSummary = localized("可扫码配对，也可扫描局域网自动发现电脑地址", "Use QR pairing or scan the local network to discover your Mac")
        } else {
            scanSummary = localized("扫描完成：发现 \(scanResults.count) 台设备（点一项可直接填入）", "Scan complete: found \(scanResults.count) devices. Tap one to fill it in")
        }
    }

    private func addOrUpdateRecentDevice(ip: String, hostName: String, port: String) {
        let trimmedIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIP.isEmpty else { return }

        let normalizedPort = port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "18700" : port
        let trimmedHostName = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        var next = recentDevices.filter { !($0.ip == trimmedIP && $0.port == normalizedPort) }
        let existing = recentDevices.first { $0.ip == trimmedIP && $0.port == normalizedPort }

        next.insert(
            RecentDevice(
                ip: trimmedIP,
                hostName: trimmedHostName.isEmpty ? (existing?.hostName ?? "") : trimmedHostName,
                port: normalizedPort,
                lastUsedTimestamp: now
            ),
            at: 0
        )

        if next.count > 8 {
            next = Array(next.prefix(8))
        }

        recentDevices = next
        saveRecentDevices()
    }

    private func hostNameForDevice(ip: String, port: String) -> String {
        if let scanHit = scanResults.first(where: { $0.ip == ip }) {
            let hostName = scanHit.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hostName.isEmpty {
                return hostName
            }
        }

        if let recent = recentDevices.first(where: { $0.ip == ip && $0.port == port }) {
            let hostName = recent.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hostName.isEmpty {
                return hostName
            }
        }

        return ""
    }

    private func persistConnectionDraft() {
        userDefaults.set(ipAddress.trimmingCharacters(in: .whitespacesAndNewlines), forKey: StorageKey.ipAddress)
        userDefaults.set(normalizedPortString(), forKey: StorageKey.port)
    }

    private func restorePersistedState() {
        if let persistedIP = userDefaults.string(forKey: StorageKey.ipAddress) {
            ipAddress = persistedIP
        } else {
            ipAddress = ""
        }

        if let persistedPort = userDefaults.string(forKey: StorageKey.port) {
            portText = persistedPort
        }

        if
            let data = userDefaults.data(forKey: StorageKey.recentDevices),
            let decoded = try? JSONDecoder().decode([RecentDevice].self, from: data)
        {
            recentDevices = decoded.sorted { $0.lastUsedTimestamp > $1.lastUsedTimestamp }
        }
    }

    private func saveRecentDevices() {
        if recentDevices.isEmpty {
            userDefaults.removeObject(forKey: StorageKey.recentDevices)
            return
        }

        guard let encoded = try? JSONEncoder().encode(recentDevices) else { return }
        userDefaults.set(encoded, forKey: StorageKey.recentDevices)
    }

    private func mapErrorToLocalized(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case URLError.timedOut.rawValue:
                return localized("连接超时，请确认手机和电脑在同一局域网，并检查 IP/端口是否正确", "Connection timed out. Make sure your iPhone and Mac are on the same local network and check the IP and port")
            case URLError.cannotConnectToHost.rawValue, URLError.cannotFindHost.rawValue:
                return localized("无法连接目标主机，请检查电脑服务是否启动、IP 和端口是否正确", "Unable to reach the target host. Check that the Mac service is running and the IP and port are correct")
            case URLError.notConnectedToInternet.rawValue, URLError.networkConnectionLost.rawValue:
                return localized("网络不可用，请确认手机已连接到与电脑相同的 Wi-Fi", "Network unavailable. Make sure your iPhone is connected to the same Wi-Fi as your Mac")
            case URLError.appTransportSecurityRequiresSecureConnection.rawValue:
                return localized("系统安全策略阻止了连接，请检查本地网络权限设置", "The system blocked the connection. Check local network permission settings")
            default:
                break
            }
        }

        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return localized("未知错误", "Unknown error")
        }

        let lowercased = raw.lowercased()
        if lowercased.contains("timed out") || lowercased.contains("timeout") {
            return localized("连接超时，请确认手机和电脑在同一局域网", "Connection timed out. Make sure your iPhone and Mac are on the same local network")
        }
        if lowercased.contains("failed to connect") || lowercased.contains("could not connect") {
            return localized("无法连接目标主机，请检查电脑程序是否启动、IP 和端口是否正确", "Unable to reach the target host. Check that the Mac app is running and the IP and port are correct")
        }
        if lowercased.contains("offline") {
            return localized("网络不可用，请确认手机已连接到局域网", "Network unavailable. Make sure your iPhone is on the local network")
        }

        return raw
    }
}
