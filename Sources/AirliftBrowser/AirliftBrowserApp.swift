import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct AirliftBrowserApp: App {
    var body: some Scene {
        Window("Airlift Browser", id: "browser") {
            BrowserView()
        }
        .defaultSize(width: 1040, height: 680)
        .commands { CommandGroup(replacing: .newItem) {} }
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
    @State private var browser = Browser()
    @State private var search = ""
    @State private var pathDraft = "/"
    @State private var naming: NameRequest?
    @State private var deleting: [Entry] = []
    @State private var showDelete = false
    @State private var dropTargeted = false
    @State private var showPoC = false
    @State private var restoringCard: PayCard?

    private var visibleEntries: [Entry] {
        browser.entries.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
    }

    private var deleteTitle: String {
        if deleting.count == 1, let name = deleting.first?.name {
            return "「\(name)」を削除しますか？"
        }
        return "\(max(deleting.count, 1)) 項目を削除しますか？"
    }

    private var deleteMessage: String {
        let folders = deleting.contains { $0.isDirectory }
        if browser.scope == .system {
            return folders
                ? "AirTrafficでMediaへ回収してから完全に削除します。フォルダは中身ごと消えます。元に戻せません。"
                : "AirTrafficでMediaへ回収してから完全に削除します。元に戻せません。"
        }
        return folders
            ? "ゴミ箱には移動しません。フォルダは中身ごと削除します。"
            : "ゴミ箱には移動しません。"
    }

    private var visibleCards: [PayCard] {
        browser.cards.filter {
            search.isEmpty || $0.title.localizedStandardContains(search) || $0.subtitle.localizedStandardContains(search)
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                Label("AIRLIFT", systemImage: "externaldrive.connected.to.line.below")
                    .font(.headline).tracking(2).padding(20)
                List(selection: Binding(get: { browser.deviceID }, set: { browser.connect($0) })) {
                    Section("USB デバイス") {
                        ForEach(browser.devices) { device in
                            VStack(alignment: .leading, spacing: 5) {
                                Label(device.name, systemImage: device.product.hasPrefix("iPad") ? "ipad" : "iphone")
                                Text("\(device.transport) · \(device.version)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5).tag(device.id)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("場所").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    locationButton("端末ファイル", icon: "internaldrive", selected: browser.scope == .system && browser.path != "/var/tmp") {
                        browser.showSystem()
                    }
                    locationButton("一時ファイル", icon: "clock.arrow.circlepath", selected: browser.scope == .system && browser.path == "/var/tmp") {
                        browser.showSystem("/var/tmp")
                    }
                    locationButton("Media", icon: "externaldrive", selected: browser.scope == .media) {
                        browser.showMedia()
                    }
                    locationButton("Apple Pay", icon: "creditcard", selected: browser.scope == .cards) {
                        browser.showCards()
                    }
                }.padding(.horizontal, 12).padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 8) {
                    Label(browser.scope == .system ? "実機ファイルブラウザ" : "Media領域",
                          systemImage: browser.scope == .system ? "folder.badge.gearshape" : "externaldrive")
                    Text(browser.scope == .system
                         ? "DVT / CoreDeviceで実項目を階層表示します。現在地へAirlift書込みできます。"
                         : "AFCで公開されるMediaを直接操作します。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("USB端末を再検索", systemImage: "arrow.triangle.2.circlepath") { browser.scan() }
                        .padding(.top, 6)
                    Button("AirTraffic PoCを実行…", systemImage: "lock.open.trianglebadge.exclamationmark") {
                        showPoC = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(browser.deviceID == nil)
                }.padding(16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("クレジット")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Link("airlift", destination: URL(string: "https://github.com/0xjohnnydev/airlift")!)
                    Link("Airlift Cards", destination: URL(string: "https://github.com/licht-jb/AirliftCards")!)
                }
                .font(.caption)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
            .disabled(browser.blocksNewWork)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button("戻る", systemImage: "chevron.left") { browser.goBack() }
                        .labelStyle(.iconOnly).disabled(!browser.canGoBack)
                    Button("進む", systemImage: "chevron.right") { browser.goForward() }
                        .labelStyle(.iconOnly).disabled(!browser.canGoForward)
                    Button("上のフォルダ", systemImage: "arrow.up") { browser.goUp() }
                        .labelStyle(.iconOnly).disabled(!browser.canGoUp || browser.scope == .cards)
                    Text(browser.scope == .cards ? "Apple Pay" : browser.scope == .system ? "Device" : "Media")
                        .font(.callout.weight(.semibold))
                    if browser.scope == .cards {
                        Text("Walletの券面です。名前、下4桁、画像だけを表示し、読み出し後に端末へ戻します。")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if browser.scope == .system {
                        TextField("絶対パスを貼り付け", text: $pathDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .onSubmit { browser.openPastedPath(pathDraft) }
                        Button("移動") { browser.openPastedPath(pathDraft) }
                            .disabled(browser.deviceID == nil
                                      || pathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Text(browser.path)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(14)
                Divider()
                if browser.deviceID == nil {
                    ContentUnavailableView("USBデバイスを接続", systemImage: "cable.connector",
                        description: Text("iPad / iPhoneのロックを解除し、このMacを信頼してから再検索してください。"))
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
                                        ? (browser.notice == nil ? "このフォルダは空です" : "子項目名を列挙できません")
                                        : "一致する項目はありません",
                                    systemImage: search.isEmpty ? "folder.badge.questionmark" : "magnifyingglass",
                                    description: Text(browser.notice ?? "Finderからファイルをドロップできます。"))
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
                        Text("\(browser.selection.count) 選択")
                    }
                    Text(browser.scope == .cards ? "\(visibleCards.count) 枚" : "\(visibleEntries.count) 項目")
                    Text(browser.scope == .cards ? "券面のみ · 下4桁" : browser.scope == .system ? "ドラッグで送受信" : "ドラッグで送受信 · 128 MiB")
                        .foregroundStyle(.tertiary)
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
                    Button("フォルダ作成", systemImage: "folder.badge.plus") {
                        naming = NameRequest(entry: nil)
                    }.disabled(browser.deviceID == nil || browser.scope == .cards || browser.blocksNewWork)
                    Button("送信", systemImage: "square.and.arrow.up") { browser.upload() }
                        .disabled(browser.deviceID == nil || browser.scope == .cards || browser.blocksNewWork)
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
                        Button("このフォルダを検証", systemImage: "checkmark.shield") {
                            showPoC = true
                        }
                    }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 480)
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
        .confirmationDialog("元の券面に戻しますか？", isPresented: Binding(
            get: { restoringCard != nil },
            set: { if !$0 { restoringCard = nil } }
        ), titleVisibility: .visible) {
            Button("Appleの画像を戻す") {
                if let card = restoringCard { browser.restoreCard(card) }
                restoringCard = nil
            }
            Button("キャンセル", role: .cancel) { restoringCard = nil }
        } message: {
            Text("端末に保存されている元画像のURLから取得し、今の券面と入れ替えます。")
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
                ProgressView("Apple Payの券面を読み込んでいます")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleCards.isEmpty {
                ContentUnavailableView("支払いカードはありません", systemImage: "creditcard",
                    description: Text(search.isEmpty
                        ? "この端末のWalletに支払いカードがありません。"
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
                                    Button("差し替え") { pickReplacement(for: card) }
                                    Button("元の画像") { restoringCard = card }
                                }
                                .disabled(card.assets.isEmpty || browser.busy)
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
        panel.message = "券面いっぱいに切り取って、このカードへ書き込みます。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        browser.replaceCard(card, with: url)
    }

    private func beginRename(_ entry: Entry) {
        naming = NameRequest(entry: entry)
    }

    private func locationButton(_ title: String, icon: String, selected: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(selected ? Color.accentColor.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(LocationRowButtonStyle())
        .disabled(browser.deviceID == nil || browser.blocksNewWork)
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
            Label("AirTraffic サンドボックス境界検証", systemImage: "lock.open.trianglebadge.exclamationmark")
                .font(.title2.bold())
            Text("指定ディレクトリへランダムなcanaryを新規作成し、Mediaへ回収して完全一致を確認した後、canaryと一時データを削除します。既存ファイルは対象にしません。")
                .foregroundStyle(.secondary)
            TextField("絶対ディレクトリパス", text: $target)
                .textFieldStyle(.roundedBorder)
                .disabled(browser.busy)
            if let result = browser.pocResult {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow { Text("対象").foregroundStyle(.secondary); Text(result.targetDirectory ?? "—") }
                    GridRow { Text("生成ファイル").foregroundStyle(.secondary); Text(result.generatedLeaf ?? "—") }
                    GridRow { Text("バイト数").foregroundStyle(.secondary); Text(result.payloadLength.map(String.init) ?? "—") }
                    GridRow { Text("SHA-256").foregroundStyle(.secondary); Text(result.payloadSHA256 ?? "—").font(.system(.caption, design: .monospaced)) }
                    GridRow { Text("読み戻し").foregroundStyle(.secondary); Label(result.exactBytesRecovered == true ? "完全一致" : "未確認", systemImage: result.exactBytesRecovered == true ? "checkmark.circle.fill" : "xmark.circle") }
                    GridRow { Text("後片付け").foregroundStyle(.secondary); Label(result.cleanupComplete == true ? "完了" : "未完了", systemImage: result.cleanupComplete == true ? "checkmark.circle.fill" : "exclamationmark.triangle") }
                }
                .textSelection(.enabled)
            }
            HStack {
                if browser.busy { ProgressView(); Text(browser.status).foregroundStyle(.secondary) }
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("検証を実行") { browser.pocResult = nil; browser.runPoC(target: target) }
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
        self.name = request.entry?.name ?? "新しいフォルダ"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.entry == nil ? "新しいフォルダ" : "名前を変更").font(.headline)
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
