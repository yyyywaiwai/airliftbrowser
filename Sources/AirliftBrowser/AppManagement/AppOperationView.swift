import SwiftUI

struct AppOperationView: View {
    @Bindable var operation: AppOperation
    let cancel: () -> Void
    let close: () -> Void
    @State private var followLog = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(operation.title).font(.title.weight(.semibold))
                    Text(operation.appName).font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                TimelineView(.periodic(from: operation.started, by: 1)) { context in
                    let seconds = Int((operation.finished ?? context.date).timeIntervalSince(operation.started))
                    Text("経過 \(seconds / 60)分\(seconds % 60)秒")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if !operation.steps.isEmpty {
                HStack {
                    Text("全体の進み具合").font(.headline)
                    Spacer()
                    Text(operation.overallFraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
                ProgressView(value: operation.overallFraction).tint(.accentColor)
                    .accessibilityLabel("全体の進み具合")
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(operation.stageName).font(.headline)
                    Spacer()
                    if let region = operation.region {
                        Text(region).lineLimit(1).truncationMode(.middle)
                    }
                    if let index = operation.regionIndex, let count = operation.regionCount {
                        Text("対象 \(index) / \(count)").monospacedDigit()
                    }
                }
                if operation.running {
                    if let fraction = operation.fraction { ProgressView(value: fraction) }
                    else { ProgressView().progressViewStyle(.linear) }
                } else {
                    Label(operation.failed ? "問題が発生しました。ログを確認してください" : "完了しました",
                          systemImage: operation.failed ? "exclamationmark.triangle" : "checkmark.circle.fill")
                        .foregroundStyle(operation.failed ? Color.orange : Color.green)
                }
                Text(operation.message).font(.callout)
                    .lineLimit(3, reservesSpace: true).textSelection(.enabled)
                ZStack(alignment: .leading) {
                    Text("転送情報").hidden().accessibilityHidden(true)
                    HStack {
                        if let completed = operation.completed, let total = operation.total {
                            Text("現在のファイル: \(AppOperation.bytes(completed)) / \(AppOperation.bytes(total))")
                        }
                        Spacer()
                        if let rate = operation.bytesPerSecond {
                            Text("\(AppOperation.bytes(Int64(rate)))/秒")
                        }
                    }
                }.font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            Divider()
            HStack {
                Text(operation.steps.isEmpty ? "ログ" : "手順とログ").font(.headline)
                Text("最新1,000行を表示").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("自動でスクロール", isOn: $followLog).toggleStyle(.checkbox)
                Button("ログをFinderで表示", action: operation.revealLog).disabled(operation.logURL == nil)
            }
            HSplitView {
                if !operation.steps.isEmpty {
                    AppOperationStepsView(steps: operation.steps)
                        .frame(minWidth: 220, idealWidth: 300, maxWidth: 400)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(operation.logs) { entry in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(entry.date, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
                                    Text(entry.message).frame(maxWidth: .infinity, alignment: .leading)
                                }.id(entry.id)
                            }
                        }.font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(12)
                    }
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: operation.logs.last?.id) {
                        if followLog, let id = operation.logs.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }.frame(minHeight: 140)
            AppGlassActions {
                VStack(alignment: .leading, spacing: 4) {
                    if operation.cancelling {
                        Text("中止しています。データを元の場所に戻すまでお待ちください。")
                    }
                    if operation.running {
                        Text("終わるまで、デバイスでこのアプリを開かないでください。")
                    }
                }.font(.caption).foregroundStyle(.secondary)
                Spacer()
                if operation.running {
                    Button("中止", role: .destructive, action: cancel).disabled(operation.cancelling)
                }
                Button(operation.running ? "バックグラウンドで続行" : "閉じる", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 760, idealWidth: 920, maxWidth: .infinity, minHeight: 480, idealHeight: 650, maxHeight: .infinity)
        .interactiveDismissDisabled(operation.running)
    }
}
