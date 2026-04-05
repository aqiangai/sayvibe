import WidgetKit
import SwiftUI

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = Entry(date: Date())
        let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

private struct Entry: TimelineEntry {
    let date: Date
}

private struct SayVibeQuickWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.99, green: 0.96, blue: 0.90),
                    Color(red: 0.95, green: 0.89, blue: 0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(red: 0.91, green: 0.50, blue: 0.17))
                        .frame(width: 8, height: 8)
                    Text("say vibe")
                        .font(.system(size: family == .systemSmall ? 12 : 13, weight: .bold))
                        .foregroundStyle(Color(red: 0.24, green: 0.19, blue: 0.15))
                }

                Link(destination: widgetURL(host: "open", queryItems: [URLQueryItem(name: "tab", value: "input")])) {
                    widgetActionLabel(
                        "打开输入区",
                        icon: "square.and.pencil",
                        fill: Color.white.opacity(0.88)
                    )
                }
                .buttonStyle(.plain)

                if family == .systemSmall {
                    Link(destination: widgetURL(host: "quick", queryItems: [URLQueryItem(name: "text", value: "收到")])) {
                        widgetActionLabel(
                            "快捷：收到",
                            icon: "bolt.fill",
                            fill: Color(red: 1.0, green: 0.97, blue: 0.90)
                        )
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 8) {
                        quickPhraseLink("收到")
                        quickPhraseLink("请稍等")
                        quickPhraseLink("马上处理")
                    }
                }
            }
            .padding(12)
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private func quickPhraseLink(_ text: String) -> some View {
        Link(destination: widgetURL(host: "quick", queryItems: [URLQueryItem(name: "text", value: text)])) {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.35, green: 0.27, blue: 0.18))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.86), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color(red: 0.92, green: 0.74, blue: 0.46).opacity(0.7), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func widgetActionLabel(_ text: String, icon: String, fill: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color(red: 0.30, green: 0.23, blue: 0.16))
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color(red: 0.92, green: 0.74, blue: 0.46).opacity(0.7), lineWidth: 1)
        )
    }

    private func widgetURL(host: String, queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents()
        components.scheme = "sayvibe"
        components.host = host
        components.queryItems = queryItems
        return components.url ?? URL(string: "sayvibe://open?tab=input")!
    }
}

struct SayVibeQuickWidget: Widget {
    private let kind = "SayVibeQuickWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            SayVibeQuickWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("say vibe 快捷入口")
        .description("主屏一键打开输入区，或快速带入常用短语。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
