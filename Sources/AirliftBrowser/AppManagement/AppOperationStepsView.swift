import SwiftUI

struct AppOperationStepsView: View {
    let steps: [AppOperationStep]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(steps) { step in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top) {
                                Image(systemName: step.symbol)
                                    .foregroundStyle(step.state == "failed" ? Color.orange : step.state == "complete" ? Color.green : Color.secondary)
                                Text(step.title).frame(maxWidth: .infinity, alignment: .leading)
                                Text(step.stateLabel).foregroundStyle(.secondary)
                            }
                            if step.state == "running" || step.state == "complete" {
                                if step.total != nil || step.state == "complete" {
                                    ProgressView(value: step.fraction)
                                    if let total = step.total {
                                        Text("\(AppOperation.bytes(step.completed)) / \(AppOperation.bytes(total))")
                                            .foregroundStyle(.secondary).monospacedDigit()
                                    }
                                } else { ProgressView().progressViewStyle(.linear) }
                            }
                        }.id(step.id)
                    }
                }.font(.caption).padding(12)
            }
            .onChange(of: steps.first(where: { $0.state == "running" })?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}
