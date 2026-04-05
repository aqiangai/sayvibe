import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct ContentView: View {
    private enum RootTab: Hashable {
        case settings
        case vibe
        case meeting
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppPreferenceKey.language) private var selectedLanguage = AppLanguage.simplifiedChinese.rawValue
    @AppStorage(AppPreferenceKey.theme) private var selectedTheme = AppTheme.system.rawValue
    @StateObject private var viewModel = RelayViewModel()
    @StateObject private var notesStore = MeetingNotesStore()
    @State private var selectedTab: RootTab = .settings
    @State private var meetingExportDocument: MeetingExportDocument?
    @State private var meetingExportFileName = "会议纪要"
    @State private var showingMeetingExporter = false
    @State private var showingPairScanner = false
    @State private var meetingNavigationPath = NavigationPath()
    @State private var meetingSearchText = ""

    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    private var appLanguage: AppLanguage {
        AppLanguage(rawValue: selectedLanguage) ?? .simplifiedChinese
    }

    private var appTheme: AppTheme {
        AppTheme(rawValue: selectedTheme) ?? .system
    }

    private var hasConnectionDraft: Bool {
        !viewModel.ipAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var accentColor: Color {
        Color(red: 0.91, green: 0.50, blue: 0.17)
    }

    private func localized(_ chinese: @autoclosure () -> String, _ english: @autoclosure () -> String) -> String {
        appLanguage.text(chinese(), english())
    }

    private var connectButtonTitle: String {
        if viewModel.isConnected {
            return localized("断开连接", "Disconnect")
        }
        if viewModel.isConnecting {
            return localized("连接中...", "Connecting...")
        }
        return localized("连接电脑", "Connect to Mac")
    }

    private var scanButtonTitle: String {
        viewModel.isScanning ? localized("扫描中...", "Scanning...") : localized("扫描局域网设备", "Scan Local Network")
    }

    private var pairButtonTitle: String {
        localized("扫码配对", "Scan Pair QR")
    }

    private var vibeConnectionSummary: String {
        localized(
            "已连接 \(viewModel.ipAddress):\(viewModel.portText) · 自动同步已开启",
            "Connected to \(viewModel.ipAddress):\(viewModel.portText) · Auto-sync is on"
        )
    }

    private var vibeCharacterCountLabel: String {
        localized("\(viewModel.syncText.count) 字", "\(viewModel.syncText.count) chars")
    }

    private var meetingDocumentCountLabel: String {
        localized("\(notesStore.documents.count) 份", "\(notesStore.documents.count) notes")
    }

    private var filteredMeetingDocuments: [MeetingNoteDocument] {
        let query = meetingSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return notesStore.documents }

        return notesStore.documents.filter { document in
            document.displayTitle.localizedCaseInsensitiveContains(query)
                || document.body.localizedCaseInsensitiveContains(query)
                || document.previewText.localizedCaseInsensitiveContains(query)
        }
    }

    private var meetingDocumentSections: [MeetingDocumentSection] {
        let query = meetingSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            guard !filteredMeetingDocuments.isEmpty else { return [] }
            return [
                MeetingDocumentSection(
                    id: "search",
                    title: appLanguage == .english ? "Results" : "搜索结果",
                    documents: filteredMeetingDocuments
                )
            ]
        }

        let calendar = Calendar.current
        let today = filteredMeetingDocuments.filter { calendar.isDateInToday($0.updatedAt) }
        let recent = filteredMeetingDocuments.filter { document in
            guard !calendar.isDateInToday(document.updatedAt) else { return false }
            let dayDelta = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: document.updatedAt),
                to: calendar.startOfDay(for: Date())
            ).day ?? 0
            return dayDelta < 7
        }
        let earlier = filteredMeetingDocuments.filter { document in
            guard !calendar.isDateInToday(document.updatedAt) else { return false }
            let dayDelta = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: document.updatedAt),
                to: calendar.startOfDay(for: Date())
            ).day ?? 0
            return dayDelta >= 7
        }

        return [
            MeetingDocumentSection(id: "today", title: appLanguage == .english ? "Today" : "今天", documents: today),
            MeetingDocumentSection(id: "recent", title: appLanguage == .english ? "Last 7 Days" : "近 7 天", documents: recent),
            MeetingDocumentSection(id: "earlier", title: appLanguage == .english ? "Earlier" : "更早", documents: earlier)
        ]
        .filter { !$0.documents.isEmpty }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            settingsTab
                .tabItem {
                    Label(localized("设置", "Settings"), systemImage: "slider.horizontal.3")
                }
                .tag(RootTab.settings)

            vibeTab
                .tabItem {
                    Label("Vibe", systemImage: "sparkles")
                }
                .tag(RootTab.vibe)

            meetingTab
                .tabItem {
                    Label(localized("会议纪要", "Notes"), systemImage: "note.text")
                }
                .tag(RootTab.meeting)
        }
        .tint(accentColor)
        .task {
            seedMeetingDocumentsIfNeeded()
        }
        .environment(\.locale, Locale(identifier: appLanguage.localeIdentifier))
        .preferredColorScheme(appTheme.colorScheme)
        .fileExporter(
            isPresented: $showingMeetingExporter,
            document: meetingExportDocument,
            contentType: .plainText,
            defaultFilename: meetingExportFileName
        ) { _ in }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                viewModel.suspendForBackground()
            } else if phase == .active {
                viewModel.resumeForForeground()
            }
        }
        .onChange(of: viewModel.isConnected) { _, connected in
            if connected {
                selectedTab = .vibe
            }
        }
        .onChange(of: selectedLanguage) { _, _ in
            viewModel.relocalizeVisibleText()
        }
        .onOpenURL { url in
            handleWidgetURL(url)
        }
        .sheet(isPresented: $showingPairScanner) {
            QRCodeScannerSheet(
                title: localized("扫码配对", "Scan Pair QR"),
                subtitle: localized("扫描电脑端展示的二维码后，会自动填入地址并尝试连接。", "Scan the QR code shown on the desktop to fill in the address and connect.")
            ) { scannedCode in
                selectedTab = .settings
                viewModel.applyPairingPayload(scannedCode)
            }
        }
    }

    private var settingsTab: some View {
        NavigationStack {
            List {
                Section(localized("连接", "Connection")) {
                    TextField("192.168.1.100", text: $viewModel.ipAddress)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    TextField("18700", text: $viewModel.portText)
                        .keyboardType(.numberPad)

                    Button(action: viewModel.connectButtonTapped) {
                        Text(connectButtonTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(WarmPrimaryButtonStyle())
                    .disabled(viewModel.isConnecting)

                    Button {
                        showingPairScanner = true
                    } label: {
                        Label(pairButtonTitle, systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(WarmSecondaryButtonStyle())
                    .disabled(viewModel.isConnecting)

                    StatusBanner(
                        tone: viewModel.statusTone,
                        message: viewModel.statusMessage
                    )
                }

                if viewModel.isConnected {
                    Section(localized("电脑输入动作", "Desktop Output Action")) {
                        if viewModel.autoImeSupported {
                            Picker(
                                localized("自动输出动作", "Auto Output Action"),
                                selection: Binding(
                                    get: { viewModel.autoImeMode },
                                    set: { viewModel.setAutoImeMode($0) }
                                )
                            ) {
                                ForEach(AutoImeActionMode.allCases) { mode in
                                    Text(mode.title(for: appLanguage))
                                        .tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            Text(viewModel.autoImeMode.detail(for: appLanguage))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            if viewModel.isUpdatingAutoImeMode {
                                ProgressView()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            Text(localized("当前这台电脑暂不支持自动输出动作控制。", "This desktop does not currently support remote auto output control."))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(localized("发现设备", "Discover Devices")) {
                    Button(action: viewModel.startLanScan) {
                        Label(scanButtonTitle, systemImage: viewModel.isScanning ? "antenna.radiowaves.left.and.right" : "wifi")
                    }
                    .disabled(viewModel.isScanning || viewModel.isConnected || viewModel.isConnecting)

                    Text(viewModel.scanSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if !viewModel.scanResults.isEmpty {
                    Section(localized("扫描结果", "Scan Results")) {
                        ForEach(viewModel.scanResults) { device in
                            Button {
                                viewModel.selectScannedDevice(device)
                            } label: {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(device.relayPortOpen ? Color.green : Color.orange)
                                        .frame(width: 10, height: 10)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(device.ip)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(.primary)
                                        Text(device.displayName)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Text(device.relayPortOpen ? localized("可连接", "Ready") : localized("仅发现设备", "Detected"))
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !viewModel.recentDevices.isEmpty {
                    Section(localized("最近设备", "Recent Devices")) {
                        ForEach(viewModel.recentDevices) { device in
                            Button {
                                viewModel.selectRecentDevice(device)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.subtitle)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text(device.displayName)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) {
                                    viewModel.removeRecentDevice(device)
                                } label: {
                                    Label(localized("删除", "Delete"), systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                Section(localized("偏好", "Preferences")) {
                    Picker(localized("语言", "Language"), selection: $selectedLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.title).tag(language.rawValue)
                        }
                    }

                    Picker(localized("外观", "Appearance"), selection: $selectedTheme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title(for: appLanguage)).tag(theme.rawValue)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(localized("设置", "Settings"))
        }
    }

    private var vibeTab: some View {
        NavigationStack {
            Group {
                if viewModel.isConnected {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Button(action: viewModel.triggerPCEnter) {
                                    Label("PC Enter", systemImage: "return")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(WarmPrimaryButtonStyle())
                                .disabled(viewModel.isTriggeringPcEnter)
                            }

                            HStack(alignment: .center, spacing: 10) {
                                Text(vibeConnectionSummary)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Text(vibeCharacterCountLabel)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }

                            StatusBanner(
                                tone: viewModel.statusTone,
                                message: viewModel.statusMessage
                            )
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 12)

                        Divider()

                        NotesBodyEditor(
                            text: $viewModel.syncText,
                            placeholder: localized("输入你想在电脑侧继续处理的内容", "Write what you want to continue on your Mac")
                        )
                        .onChange(of: viewModel.syncText) { _, newValue in
                            viewModel.handleTextChanged(newValue)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    .background((isDarkMode ? Color.black : Color.white).ignoresSafeArea())
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                viewModel.clearLocalInput()
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label(localized("Vibe 暂不可用", "Vibe is unavailable"), systemImage: "sparkles")
                    } description: {
                        Text(
                            hasConnectionDraft
                            ? localized("请先在设置页连接电脑，随后这里会进入实时输入模式。", "Connect to your Mac in Settings to unlock live input here.")
                            : localized("请先到设置页填写电脑地址和端口，然后连接电脑。", "Enter your Mac address and port in Settings, then connect.")
                        )
                    } actions: {
                        Button(localized("前往设置", "Open Settings")) {
                            selectedTab = .settings
                        }
                    }
                }
            }
            .navigationTitle("Vibe")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var meetingTab: some View {
        NavigationStack(path: $meetingNavigationPath) {
            List {
                if meetingDocumentSections.isEmpty {
                    ContentUnavailableView {
                        Label(localized("还没有会议纪要", "No meeting notes yet"), systemImage: "note.text")
                    } description: {
                        Text(localized("右上角新建后，就会像备忘录一样保存在这里。", "Create one from the top-right corner and it will stay here like Notes."))
                    } actions: {
                        Button(localized("新建纪要", "New Note")) {
                            createMeetingDocumentAndOpen()
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 32, leading: 20, bottom: 24, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(meetingDocumentSections) { section in
                        Section(section.title) {
                            ForEach(section.documents) { document in
                                NavigationLink(value: document.id) {
                                    MeetingDocumentListRow(document: document)
                                }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        deleteMeetingDocument(document.id)
                                    } label: {
                                        Label(localized("删除", "Delete"), systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $meetingSearchText, prompt: localized("搜索纪要", "Search notes"))
            .navigationTitle(localized("会议纪要", "Notes"))
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: UUID.self) { documentID in
                meetingEditorView(for: documentID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !notesStore.documents.isEmpty {
                        Text(meetingDocumentCountLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: createMeetingDocumentAndOpen) {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func meetingEditorView(for documentID: UUID) -> some View {
        if let document = notesStore.document(documentID) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(localized("标题", "Title"), text: meetingTitleBinding(for: documentID), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text(meetingMetadataText(for: document))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

                Divider()

                NotesBodyEditor(
                    text: meetingBodyBinding(for: documentID),
                    placeholder: localized("开始记录这次会议内容", "Start writing the meeting note")
                )
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background((isDarkMode ? Color.black : Color.white).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportMeetingDocument(documentID)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            syncMeetingDocumentIntoVibe(documentID)
                        } label: {
                            Label(viewModel.isConnected ? localized("同步到 Vibe", "Sync to Vibe") : localized("写入 Vibe 草稿", "Write to Vibe Draft"), systemImage: "arrow.up.forward.app")
                        }

                        Button {
                            createMeetingDocumentAndOpen()
                        } label: {
                            Label(localized("新建纪要", "New Note"), systemImage: "square.and.pencil")
                        }

                        Button(role: .destructive) {
                            clearMeetingBody(documentID)
                        } label: {
                            Label(localized("清空正文", "Clear Body"), systemImage: "eraser")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                notesStore.selectDocument(documentID)
            }
        } else {
            ContentUnavailableView(localized("文档不存在", "Document not found"), systemImage: "exclamationmark.triangle")
        }
    }

    private func meetingTitleBinding(for documentID: UUID) -> Binding<String> {
        Binding(
            get: { notesStore.document(documentID)?.title ?? "" },
            set: { notesStore.updateDocument(documentID, title: $0) }
        )
    }

    private func meetingBodyBinding(for documentID: UUID) -> Binding<String> {
        Binding(
            get: { notesStore.document(documentID)?.body ?? "" },
            set: { notesStore.updateDocument(documentID, body: $0) }
        )
    }

    private func meetingMetadataText(for document: MeetingNoteDocument) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage.localeIdentifier)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let updatedText = formatter.string(from: document.updatedAt)
        let lineCount = document.body
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
        return localized("更新于 \(updatedText) · \(lineCount) 条", "Updated \(updatedText) · \(lineCount) lines")
    }

    private func seedMeetingDocumentsIfNeeded() {
        notesStore.ensureInitialDocument(
            title: defaultMeetingDocumentTitle(),
            body: "",
            templateID: "memo"
        )
    }

    private func createMeetingDocument() {
        notesStore.createDocument(
            title: defaultMeetingDocumentTitle(),
            body: "",
            templateID: "memo"
        )
    }

    private func createMeetingDocumentAndOpen() {
        meetingSearchText = ""
        let document = notesStore.createDocument(
            title: defaultMeetingDocumentTitle(),
            body: "",
            templateID: "memo"
        )
        meetingNavigationPath.append(document.id)
    }

    private func deleteMeetingDocument(_ documentID: UUID) {
        notesStore.deleteDocument(documentID)
    }

    private func clearMeetingBody(_ documentID: UUID) {
        notesStore.updateDocument(documentID, body: "")
    }

    private func exportMeetingDocument(_ documentID: UUID) {
        guard let document = notesStore.document(documentID) else { return }
        meetingExportDocument = MeetingExportDocument(text: document.exportedText)
        meetingExportFileName = document.exportFileName
        showingMeetingExporter = true
    }

    private func syncMeetingDocumentIntoVibe(_ documentID: UUID) {
        guard let document = notesStore.document(documentID) else { return }

        let title = document.displayTitle
        let notes = document.body.trimmingCharacters(in: .whitespacesAndNewlines)

        let payload: String
        if notes.isEmpty {
            payload = title
        } else {
            payload = "【\(title)】\n\(notes)"
        }

        viewModel.replaceSyncText(
            with: payload,
            status: viewModel.isConnected ? localized("会议纪要已写入 Vibe，并同步到电脑", "Meeting note was written into Vibe and synced to your Mac") : localized("会议纪要已写入 Vibe 草稿", "Meeting note was written into the Vibe draft"),
            tone: .info
        )
        selectedTab = .vibe
        meetingNavigationPath = NavigationPath()
    }

    private func defaultMeetingDocumentTitle() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: appLanguage.localeIdentifier)
        formatter.dateFormat = appLanguage == .english ? "MMM d HH:mm" : "M月d日 HH:mm"
        let dateText = formatter.string(from: Date())
        return appLanguage == .english ? "Meeting Note \(dateText)" : "会议纪要 \(dateText)"
    }

    private func handleWidgetURL(_ url: URL) {
        guard url.scheme?.lowercased() == "sayvibe" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }

        let host = (components.host ?? "").lowercased()
        switch host {
        case "open":
            let tab = components.queryItems?.first(where: { $0.name == "tab" })?.value?.lowercased()
            switch tab {
            case "input", "vibe":
                selectedTab = .vibe
            case "meeting", "notes":
                selectedTab = .meeting
            default:
                selectedTab = .settings
            }
        case "quick":
            selectedTab = .vibe
            let text = components.queryItems?.first(where: { $0.name == "text" })?.value ?? ""
            viewModel.insertTextFromWidget(text)
        case "pair":
            selectedTab = .settings
            viewModel.applyPairingPayload(url.absoluteString)
        default:
            break
        }
    }
}

private struct MeetingDocumentSection: Identifiable {
    let id: String
    let title: String
    let documents: [MeetingNoteDocument]
}

private struct MeetingDocumentListRow: View {
    let document: MeetingNoteDocument

    private var dateLabel: String {
        let locale = Locale(identifier: AppLanguage.current.localeIdentifier)
        let calendar = Calendar.current
        if calendar.isDateInToday(document.updatedAt) {
            return document.updatedAt.formatted(.dateTime.hour().minute().locale(locale))
        }
        if calendar.isDate(document.updatedAt, equalTo: Date(), toGranularity: .year) {
            return document.updatedAt.formatted(.dateTime.month().day().locale(locale))
        }
        return document.updatedAt.formatted(.dateTime.year().month().day().locale(locale))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(document.displayTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(dateLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(document.previewText)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 6)
    }
}

private struct NotesBodyEditor: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    let placeholder: String

    private var textColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.95) : Color(red: 0.12, green: 0.12, blue: 0.13)
    }

    private var placeholderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.35) : Color(red: 0.56, green: 0.56, blue: 0.58)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .font(.system(size: 17))
                .foregroundStyle(textColor)
                .padding(.horizontal, 0)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(.system(size: 17))
                    .foregroundStyle(placeholderColor)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct StatusBanner: View {
    let tone: StatusTone
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tone.background)
                .frame(width: 9, height: 9)
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct InputFieldStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    private var fillColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.11) : Color.white.opacity(0.76)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.22) : Color.white.opacity(0.86)
    }

    private var textColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.95) : Color(red: 0.18, green: 0.16, blue: 0.15)
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: 15))
            .foregroundStyle(textColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(fillColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
    }
}

private struct WarmPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.91, green: 0.50, blue: 0.17), Color(red: 0.95, green: 0.62, blue: 0.17)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct WarmSecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    private var fillColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.88)
    }

    private var strokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.18) : Color(red: 0.90, green: 0.79, blue: 0.66)
    }

    private var textColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color(red: 0.33, green: 0.24, blue: 0.16)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(fillColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1)
            )
            .foregroundStyle(textColor)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct QRCodeScannerSheet: View {
    enum PermissionState {
        case checking
        case ready
        case denied
    }

    let title: String
    let subtitle: String
    let onScanned: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var permissionState: PermissionState = .checking

    private var appLanguage: AppLanguage {
        .current
    }

    private func localized(_ chinese: @autoclosure () -> String, _ english: @autoclosure () -> String) -> String {
        appLanguage.text(chinese(), english())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                switch permissionState {
                case .checking:
                    ProgressView()
                case .ready:
                    ZStack(alignment: .bottom) {
                        QRCodeScannerViewControllerRepresentable { code in
                            onScanned(code)
                            dismiss()
                        }
                        .ignoresSafeArea()

                        VStack(spacing: 10) {
                            Text(subtitle)
                                .font(.system(size: 13, weight: .medium))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white)

                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(Color.white.opacity(0.92), lineWidth: 2)
                                .frame(width: 240, height: 240)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 44)
                    }
                    .background(Color.black.ignoresSafeArea())
                case .denied:
                    ContentUnavailableView {
                        Label(localized("相机", "Camera"), systemImage: "camera")
                    } description: {
                        Text(localized("请在系统设置里允许 say vibe 使用相机后，再回来扫码配对。", "Allow camera access for say vibe in Settings, then come back to scan the pairing code."))
                    } actions: {
                        Button(localized("打开设置", "Open Settings")) {
                            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                            openURL(settingsURL)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(localized("关闭", "Close")) {
                        dismiss()
                    }
                }
            }
            .task {
                await updatePermissionState()
            }
        }
    }

    private func updatePermissionState() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionState = .ready
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permissionState = granted ? .ready : .denied
        default:
            permissionState = .denied
        }
    }
}

private struct QRCodeScannerViewControllerRepresentable: UIViewControllerRepresentable {
    let onScanned: (String) -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        QRCodeScannerViewController(onScanned: onScanned)
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}
}

private final class QRCodeScannerPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

private final class QRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let captureSession = AVCaptureSession()
    private let previewView = QRCodeScannerPreviewView()
    private let onScanned: (String) -> Void
    private var didEmitCode = false

    init(onScanned: @escaping (String) -> Void) {
        self.onScanned = onScanned
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = previewView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureSession()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !captureSession.isRunning {
            captureSession.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewView.previewLayer.frame = previewView.bounds
    }

    private func configureSession() {
        guard let captureDevice = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: captureDevice),
              captureSession.canAddInput(input) else {
            return
        }

        captureSession.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else { return }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        previewView.previewLayer.session = captureSession
        previewView.previewLayer.videoGravity = .resizeAspectFill
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !didEmitCode else { return }
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject else { return }
        guard let scannedString = object.stringValue, !scannedString.isEmpty else { return }

        didEmitCode = true
        captureSession.stopRunning()
        onScanned(scannedString)
    }
}
