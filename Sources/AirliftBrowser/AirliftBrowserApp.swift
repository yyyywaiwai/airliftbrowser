import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct AirliftBrowserApp: App {
    @State private var browser = Browser()

    var body: some Scene {
        Window("Airlift Browser", id: "browser") {
            BrowserView(browser: browser)
                .background(ToolbarLabels())
        }
        .defaultSize(width: 1040, height: 680)
        .commands { CommandGroup(replacing: .newItem) {} }

        Settings {
            SettingsView(browser: browser)
        }
    }
}

private struct LocationRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct BrowserView: View {
    @Bindable var browser: Browser
    @State private var appManager = AppManager()
    @State private var appSection = "apps"
    @State private var search = ""
    @State private var pathDraft = "/"
    @State private var naming: NameRequest?
    @State private var deleting: [Entry] = []
    @State private var showDelete = false
    @State private var dropTargeted = false
    @State private var showPoC = false
    @State private var restoringCard: PayCard?

    init(browser: Browser) {
        self.browser = browser
    }

    private var visibleEntries: [Entry] {
        browser.entries.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
    }

    private var deleteTitle: String {
        if deleting.count == 1, let name = deleting.first?.name {
            return String(localized: "「\(name)」を削除しますか？")
        }
        return String(localized: "\(max(deleting.count, 1)) 項目を削除しますか？")
    }

    private var deleteMessage: String {
        let folders = deleting.contains { $0.isDirectory }
        if browser.scope == .system {
            return folders
                ? String(localized: "完全に削除します。フォルダは中の項目ごと消えます。元には戻せません。")
                : String(localized: "完全に削除します。元には戻せません。")
        }
        return folders
            ? String(localized: "ゴミ箱には入りません。フォルダは中の項目ごと削除します。")
            : String(localized: "ゴミ箱には入りません。")
    }

    private var visibleCards: [PayCard] {
        browser.cards.filter {
            search.isEmpty || $0.title.localizedStandardContains(search) || $0.subtitle.localizedStandardContains(search)
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(selection: Binding(get: { browser.deviceID }, set: { browser.connect($0) })) {
                    Section("デバイス") {
                        ForEach(browser.devices) { device in
                            VStack(alignment: .leading, spacing: 5) {
                                Label(device.name, systemImage: device.product.hasPrefix("iPad") ? "ipad" : "iphone")
                                Text(verbatim: (device.product.hasPrefix("iPad") ? "iPadOS " : "iOS ") + device.version)
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5).tag(device.id)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("場所").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    locationButton("アプリ", icon: "square.grid.2x2", hint: "アプリのデータを表示したり、Macにバックアップしたりできます。", selected: appSection == "apps") {
                        appSection = "apps"
                    }
                    locationButton("バックアップ", icon: "archivebox", hint: "Macに保存したバックアップを開いたり、デバイスに復元したりできます。", selected: appSection == "backups") {
                        appSection = "backups"
                    }
                    locationButton("Media", icon: "externaldrive", hint: "写真や音楽などが入っているMediaフォルダのファイルを表示・操作します。", selected: appSection == "legacy" && browser.scope == .media) {
                        appSection = "legacy"
                        browser.showMedia()
                    }
                    locationButton("Apple Pay", icon: "creditcard", hint: "Walletに追加したカードの画像を表示し、差し替えられます。", selected: appSection == "legacy" && browser.scope == .cards) {
                        appSection = "legacy"
                        browser.showCards()
                    }
                }.padding(.horizontal, 12).padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 6) {
                    Button(action: { browser.scan() }) {
                        sidebarRowLabel("デバイスを再検索", icon: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(LocationRowButtonStyle())
                    .padding(.horizontal, 8)

                    SettingsLink {
                        sidebarRowLabel("設定", icon: "gearshape")
                    }
                    .buttonStyle(LocationRowButtonStyle())
                    .padding(.horizontal, 8)
                }
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
            .disabled(browser.blocksNewWork || appManager.busy)
        } detail: {
            if appSection != "legacy" {
                AppWorkspaceView(manager: appManager, deviceID: browser.deviceID, library: appSection == "backups")
                    .disabled(browser.blocksNewWork)
            } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button("戻る", systemImage: "chevron.left") { browser.goBack() }
                        .labelStyle(.iconOnly).disabled(!browser.canGoBack)
                    Button("進む", systemImage: "chevron.right") { browser.goForward() }
                        .labelStyle(.iconOnly).disabled(!browser.canGoForward)
                    Button("上のフォルダ", systemImage: "arrow.up") { browser.goUp() }
                        .labelStyle(.iconOnly).disabled(!browser.canGoUp || browser.scope == .cards)
                    Text(browser.scope == .cards ? "Apple Pay" : browser.scope == .system ? "デバイス" : "Media")
                        .font(.callout.weight(.semibold))
                    if browser.scope == .cards {
                        Text("Walletに追加したカードの画像です。")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if browser.scope == .system {
                        Text(browser.path)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(browser.path)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(14)
                Divider()
                if browser.deviceID == nil {
                    ContentUnavailableView("iPhoneまたはiPadを接続してください", systemImage: "cable.connector",
                        description: Text("ケーブルでつないでロックを解除し、「このコンピュータを信頼」を選んでから再検索してください。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if browser.scope == .cards {
                    cardBrowser
                } else {
                    VStack(spacing: 0) {
                        if !browser.pending.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(browser.pending) { item in
                                    HStack(spacing: 8) {
                                        Image(systemName: "arrow.up.doc").foregroundStyle(Color.accentColor)
                                        Text(item.name).lineLimit(1)
                                        Spacer(minLength: 8)
                                        ActivityBar(fraction: item.fraction)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            Divider()
                        }
                        Table(of: Entry.self, selection: $browser.selection) {
                            TableColumn("名前") { entry in
                            HStack(spacing: 8) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : entry.isFile ? "doc" : "link")
                                    .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                        .foregroundStyle(entry.isVerifiedDirectory ? Color.accentColor : Color.primary)
                                    if let subtitle = entry.subtitle {
                                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let activity = browser.rowActivity[entry.id] {
                                        ActivityBar(fraction: activity.fraction)
                                    }
                                }
                            }
                        }.width(min: 180, ideal: 380)
                        TableColumn("種類", value: \.typeName).width(120)
                        TableColumn("サイズ") { entry in
                            Text(entry.sizeLabel).monospacedDigit().foregroundStyle(.secondary)
                        }.width(100)
                        } rows: {
                            ForEach(visibleEntries) { entry in
                                TableRow(entry)
                            }
                        }
                        .contextMenu(forSelectionType: String.self) { ids in
                            let chosen = browser.entries.filter { ids.contains($0.id) }
                            if chosen.count == 1, let entry = chosen.first, entry.isDirectory {
                                Button("開く") { browser.navigate(entry.id) }
                            }
                            if !chosen.isEmpty, chosen.allSatisfy(browser.canExport) {
                                Button("Macに保存…") {
                                    browser.selection = Set(chosen.map(\.id))
                                    browser.download()
                                }
                            }
                            if chosen.count == 1, let entry = chosen.first,
                               browser.canModify, entry.isFile || entry.isDirectory {
                                Button("名前を変更…") { beginRename(entry) }
                            }
                            if !chosen.isEmpty, chosen.allSatisfy(browser.canDelete) {
                                Divider()
                                Button("削除…", role: .destructive) {
                                    deleting = chosen
                                    showDelete = true
                                }
                                .disabled(browser.blocksNewWork)
                            }
                        } primaryAction: { ids in
                            guard ids.count == 1, let id = ids.first,
                                  let entry = browser.entries.first(where: { $0.id == id }),
                                  entry.isDirectory else { return }
                            browser.navigate(entry.id)
                        }
                        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                            // Dropping a row back onto this list is not an import. Reading it as a file URL
                            // fails with "Could not coerce an item to class NSURL" and leaves dragging stuck.
                            if FinderDragGate.active || providers.contains(where: {
                                $0.registeredTypeIdentifiers.contains(deviceDragType)
                            }) || !providers.contains(where: {
                                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                            }) {
                                return false
                            }
                            guard !browser.blocksNewWork, browser.deviceID != nil else { return false }
                            browser.importProviders(providers)
                            return true
                        }
                        .overlay {
                            if dropTargeted {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.accentColor, lineWidth: 2)
                                    .padding(4)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay(FinderDragMonitor(browser: browser, entries: visibleEntries))
                        .overlay {
                            if visibleEntries.isEmpty && !browser.busy && browser.pending.isEmpty {
                                ContentUnavailableView(
                                    search.isEmpty
                                        ? (browser.notice == nil ? "このフォルダは空です" : "このフォルダの中身は表示できません")
                                        : "一致する項目はありません",
                                    systemImage: search.isEmpty ? "folder.badge.questionmark" : "magnifyingglass",
                                    description: Text(browser.notice ?? String(localized: "Finderからファイルをドロップして追加できます。")))
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    if browser.batchTotal > 0 {
                        ProgressView(value: Double(browser.batchDone), total: Double(browser.batchTotal))
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .frame(width: 120)
                    } else if browser.busy || browser.exportsInFlight > 0 {
                        ProgressView().controlSize(.small)
                    }
                    Text(browser.status).lineLimit(1)
                    Spacer()
                    if !browser.selection.isEmpty && browser.scope != .cards {
                        Text("\(browser.selection.count) 項目を選択中")
                    }
                    Text(browser.scope == .cards ? "\(visibleCards.count) 枚" : "\(visibleEntries.count) 項目")
                    if browser.scope != .cards {
                        Text(browser.scope == .system ? "ドラッグでファイルを送受信" : "ドラッグでファイルを送受信（128 MBまで）")
                            .foregroundStyle(.tertiary)
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(12)
            }
            .onDeleteCommand {
                let targets = browser.selectedEntries.filter(browser.canDelete)
                guard !browser.blocksNewWork, !targets.isEmpty else { return }
                deleting = targets
                showDelete = true
            }
            .navigationTitle(browser.device?.name ?? "Airlift Browser")
            .searchable(text: $search, prompt: browser.scope == .cards ? "カードを検索" : "このフォルダを検索")
            .toolbar {
                ToolbarItemGroup {
                    Button("更新", systemImage: "arrow.clockwise") { browser.reload() }
                        .keyboardShortcut("r").disabled(browser.deviceID == nil || browser.blocksNewWork)
                    if browser.scope != .cards {
                    Button("新規フォルダ", systemImage: "folder.badge.plus") {
                        naming = NameRequest(entry: nil)
                    }.disabled(browser.deviceID == nil || browser.blocksNewWork)
                    Button("追加", systemImage: "square.and.arrow.up") { browser.upload() }
                        .disabled(browser.deviceID == nil || browser.blocksNewWork)
                    Button("Macに保存", systemImage: "square.and.arrow.down") { browser.download() }
                        .disabled(browser.blocksNewWork || browser.selectedEntries.isEmpty
                                  || browser.selectedEntries.contains { !browser.canExport($0) })
                    Button("開く", systemImage: "folder") { browser.openSelected() }
                        .disabled(browser.blocksNewWork || browser.selected?.isDirectory != true)
                    Button("削除", systemImage: "trash", role: .destructive) {
                        deleting = browser.selectedEntries.filter(browser.canDelete)
                        showDelete = !deleting.isEmpty
                    }
                    .disabled(browser.blocksNewWork || browser.selectedEntries.isEmpty
                              || browser.selectedEntries.contains { !browser.canDelete($0) })
                    if browser.scope == .system {
                        Button("このフォルダをテスト", systemImage: "checkmark.shield") {
                            showPoC = true
                        }
                    }
                    }
                }
            }
            }
        }
        .frame(minWidth: 1040, minHeight: 600)
        .task { browser.scan() }
        .onChange(of: browser.path) {
            search = ""
            pathDraft = browser.path
        }
        .onChange(of: browser.locationToken) { pathDraft = browser.path }
        .onChange(of: browser.deviceID) { search = "" }
        .alert("操作に失敗しました", isPresented: Binding(get: { browser.error != nil }, set: { if !$0 { browser.error = nil } })) {
            Button("OK", role: .cancel) { browser.error = nil }
        } message: { Text(browser.error ?? "") }
        .sheet(item: $naming) { request in
            NameEditor(request: request) { name in
                naming = nil
                if let entry = request.entry { browser.rename(entry, to: name) }
                else { browser.mkdir(name) }
            }
        }
        .sheet(isPresented: $showPoC) {
            PoCView(browser: browser,
                    initialTarget: browser.scope == .system ? browser.path : "/var/mobile/Documents")
        }
        .confirmationDialog("元のカード画像に戻しますか？", isPresented: Binding(
            get: { restoringCard != nil },
            set: { if !$0 { restoringCard = nil } }
        ), titleVisibility: .visible) {
            Button("元に戻す") {
                if let card = restoringCard { browser.restoreCard(card) }
                restoringCard = nil
            }
            Button("キャンセル", role: .cancel) { restoringCard = nil }
        } message: {
            Text("元の画像をダウンロードして、今の画像と入れ替えます。")
        }
        .confirmationDialog(deleteTitle, isPresented: $showDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                let entries = deleting
                deleting = []
                browser.remove(entries)
            }
            Button("キャンセル", role: .cancel) { deleting = [] }
        } message: {
            Text(deleteMessage)
        }
    }

    private var cardBrowser: some View {
        Group {
            if browser.busy && browser.cards.isEmpty {
                ProgressView("カードを読み込んでいます…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleCards.isEmpty {
                ContentUnavailableView("カードがありません", systemImage: "creditcard",
                    description: Text(search.isEmpty
                        ? "このデバイスのWalletにカードが追加されていません。"
                        : "一致するカードはありません。"))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                        ForEach(visibleCards) { card in
                            VStack(alignment: .leading, spacing: 8) {
                                cardFace(card)
                                    .id(card.thumbnailPath ?? card.id)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 164)
                                Text(card.title).font(.headline).lineLimit(1)
                                if !card.subtitle.isEmpty {
                                    Text(card.subtitle)
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button("画像を差し替え") { pickReplacement(for: card) }
                                    Button("元に戻す") { restoringCard = card }
                                }
                                .disabled(card.assets.isEmpty || browser.busy)
                                Button("Macに保存") { browser.saveOriginalCard(card) }
                                    .disabled(browser.busy)
                            }
                            .padding(12)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func cardFace(_ card: PayCard) -> some View {
        let image = card.thumbnailPath.flatMap { NSImage(contentsOfFile: $0) }
        return Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .overlay(Image(systemName: "creditcard").font(.largeTitle).foregroundStyle(.secondary))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("\(card.title) \(card.subtitle)")
    }

    private func pickReplacement(for card: PayCard) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .pdf]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "カードの形に合わせて切り取り、このカードの画像にします。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        browser.replaceCard(card, with: url)
    }

    private func beginRename(_ entry: Entry) {
        naming = NameRequest(entry: entry)
    }

    private func sidebarRowLabel(_ title: LocalizedStringKey, icon: String) -> some View {
        Label(title, systemImage: icon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
    }

    private func locationButton(_ title: LocalizedStringKey, icon: String, hint: LocalizedStringKey, selected: Bool,
                                action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                sidebarRowLabel(title, icon: icon)
            }
            .buttonStyle(LocationRowButtonStyle())
            .disabled(browser.deviceID == nil || browser.blocksNewWork)
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .help(hint)
                .accessibilityLabel(title)
                .accessibilityValue(hint)
        }
        .padding(.horizontal, 8)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct ActivityBar: View {
    let fraction: Double?

    var body: some View {
        Group {
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
            } else {
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
        .controlSize(.small)
        .frame(width: 92)
    }
}

private struct SettingsView: View {
    let browser: Browser
    @State private var showPoC = false
    @State private var confirmDeleteLogs = false
    @State private var hasLogs = false
    @State private var language = (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first ?? ""

    var body: some View {
        Form {
            Section {
                Picker("言語", selection: $language) {
                    Text("システムのデフォルト").tag("")
                    Divider()
                    Text(verbatim: "日本語").tag("ja")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "简体中文").tag("zh-Hans")
                }
                .onChange(of: language) {
                    UserDefaults.standard.set(language.isEmpty ? nil : [language], forKey: "AppleLanguages")
                }
            } footer: {
                Text("変更はアプリの再起動後に反映されます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Button("テストを実行") { showPoC = true }
                        .disabled(browser.deviceID == nil || browser.blocksNewWork)
                } label: {
                    Text("書き込みテスト")
                    Text("指定したフォルダにテスト用のファイルを作り、正しく読み戻せるか確認してから削除します。すでにあるファイルには触れません。")
                }
            }

            Section("保存場所") {
                LabeledContent {
                    HStack {
                        Button("Finderで表示") { reveal(AppOperation.logFolder) }
                        Button("すべて削除…", role: .destructive) { confirmDeleteLogs = true }
                            .disabled(!hasLogs)
                            .confirmationDialog("ログファイルをすべて削除しますか？", isPresented: $confirmDeleteLogs) {
                                Button("削除", role: .destructive) {
                                    try? FileManager.default.removeItem(at: AppOperation.logFolder)
                                    refreshLogs()
                                }
                            }
                    }
                } label: {
                    Text("ログファイル")
                    Text(verbatim: (AppOperation.logFolder.path as NSString).abbreviatingWithTildeInPath)
                }
                LabeledContent {
                    Button("Finderで表示") { reveal(Self.backupFolder) }
                } label: {
                    Text("バックアップ")
                    Text(verbatim: (Self.backupFolder.path as NSString).abbreviatingWithTildeInPath)
                }
            }

            Section("クレジット") {
                LabeledContent("airlift") {
                    Link(destination: URL(string: "https://github.com/0xjohnnydev/airlift")!) {
                        Text(verbatim: "GitHub")
                    }
                }
                LabeledContent("Airlift Cards") {
                    Link(destination: URL(string: "https://github.com/licht-jb/AirliftCards")!) {
                        Text(verbatim: "GitHub")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 500, height: 540)
        .onAppear(perform: refreshLogs)
        .sheet(isPresented: $showPoC) {
            PoCView(
                browser: browser,
                initialTarget: browser.scope == .system ? browser.path : "/var/mobile/Documents"
            )
        }
    }

    private static let backupFolder = URL.applicationSupportDirectory.appending(path: "Airlift Browser/Backups", directoryHint: .isDirectory)

    private func refreshLogs() {
        hasLogs = (try? FileManager.default.contentsOfDirectory(atPath: AppOperation.logFolder.path))?.isEmpty == false
    }

    private func reveal(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

private struct PoCView: View {
    @Environment(\.dismiss) private var dismiss
    let browser: Browser
    @State private var target: String

    init(browser: Browser, initialTarget: String) {
        self.browser = browser
        self._target = State(initialValue: initialTarget)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("書き込みテスト", systemImage: "lock.open.trianglebadge.exclamationmark")
                .font(.title2.bold())
            Text("指定したフォルダにテスト用のファイルを作り、正しく読み戻せるか確認してから削除します。すでにあるファイルには触れません。")
                .foregroundStyle(.secondary)
            TextField("フォルダのパス（/から始まる）", text: $target)
                .textFieldStyle(.roundedBorder)
                .disabled(browser.busy)
            if let result = browser.pocResult {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow { Text("フォルダ").foregroundStyle(.secondary); Text(result.targetDirectory ?? "—") }
                    GridRow { Text("テストファイル").foregroundStyle(.secondary); Text(result.generatedLeaf ?? "—") }
                    GridRow { Text("サイズ（バイト）").foregroundStyle(.secondary); Text(result.payloadLength.map(String.init) ?? "—") }
                    GridRow { Text("SHA-256").foregroundStyle(.secondary); Text(result.payloadSHA256 ?? "—").font(.system(.caption, design: .monospaced)) }
                    GridRow { Text("内容の一致").foregroundStyle(.secondary); Label(result.exactBytesRecovered == true ? "一致" : "確認できず", systemImage: result.exactBytesRecovered == true ? "checkmark.circle.fill" : "xmark.circle") }
                    GridRow { Text("後片付け").foregroundStyle(.secondary); Label(result.cleanupComplete == true ? "完了" : "未完了", systemImage: result.cleanupComplete == true ? "checkmark.circle.fill" : "exclamationmark.triangle") }
                }
                .textSelection(.enabled)
            }
            HStack {
                if browser.busy { ProgressView(); Text(browser.status).foregroundStyle(.secondary) }
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("テストを実行") { browser.pocResult = nil; browser.runPoC(target: target) }
                    .buttonStyle(.borderedProminent)
                    .disabled(browser.blocksNewWork || !target.hasPrefix("/") || target == "/")
            }
        }
        .padding(24)
        .frame(width: 620)
        .interactiveDismissDisabled(browser.busy)
    }
}

private struct NameRequest: Identifiable {
    let id = UUID()
    let entry: Entry?
}

private struct NameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let request: NameRequest
    let save: (String) -> Void

    init(request: NameRequest, save: @escaping (String) -> Void) {
        self.request = request
        self.save = save
        self.name = request.entry?.name ?? String(localized: "新規フォルダ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.entry == nil ? "新規フォルダ" : "名前を変更").font(.headline)
            TextField("名前", text: $name).textFieldStyle(.roundedBorder)
                .onSubmit { if !name.isEmpty { save(name) } }
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save(name) }.keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }
        }.padding(24).frame(width: 360)
    }
}
