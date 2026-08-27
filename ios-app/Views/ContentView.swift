import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var urlText = ""
    @State private var statusText = "粘贴链接后点击解析"
    @State private var isParsing = false
    @State private var result: ParseResult?
    @State private var errorMessage: String?
    @State private var savingIds: Set<String> = []
    @State private var finishedIds: Set<String> = []

    var body: some View {
        ZStack {
            Image("AppBackground")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
            Color.white.opacity(0.64)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Text("小帮手小熊猫")
                    .font(.title.bold())
                    .foregroundColor(Color(red: 0.118, green: 0.533, blue: 0.898))
                    .padding(.top, 8)

                Text("支持抖音 / 小红书 / B站，解析后保存原视频、原图、文案")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    TextField("粘贴抖音 / 小红书 / B站链接", text: $urlText, axis: .vertical)
                        .lineLimit(2...3)
                        .textFieldStyle(.roundedBorder)

                    Button("粘贴") {
                        if let s = UIPasteboard.general.string {
                            urlText = s
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("解析") {
                        startParse()
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 8) {
                    if isParsing {
                        ProgressView()
                    }
                    Text(statusText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let result = result {
                    resultHeader(result)
                    itemList(result.items)
                } else {
                    Spacer()
                }
            }
            .padding()
        }
        .alert("解析失败", isPresented: errorBinding, actions: {
            Button("复制错误信息") {
                UIPasteboard.general.string = errorMessage ?? ""
            }
            Button("知道了", role: .cancel) {}
        }, message: {
            Text(errorMessage ?? "")
        })
        .overlay(alignment: .bottomTrailing) {
            HiddenWebViewContainer()
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    @ViewBuilder
    private func resultHeader(_ result: ParseResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(result.platform.rawValue)" + (result.author.map { " · @\($0)" } ?? ""))
                .font(.footnote)
                .foregroundColor(.secondary)
            Text(result.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
    }

    private func itemList(_ items: [MediaItem]) -> some View {
        List(items) { item in
            itemRow(item)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func itemRow(_ item: MediaItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label)
                    .font(.subheadline)
                if let p = downloads.progress[item.id], p < 1 {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                }
            }
            Spacer()

            if finishedIds.contains(item.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else if savingIds.contains(item.id) {
                ProgressView()
            } else {
                Button("保存") {
                    save(item)
                }
                .buttonStyle(.bordered)
                .disabled(isParsing)
            }

            if item.kind == .caption {
                Button("复制") {
                    UIPasteboard.general.string = item.text ?? ""
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 动作

    @MainActor
    private func startParse() {
        guard let url = UrlUtils.extractUrl(from: urlText) else {
            errorMessage = "未找到有效链接"
            return
        }
        let platform = UrlUtils.detectPlatform(url)
        guard platform != .unknown else {
            errorMessage = "暂不支持该平台，目前支持抖音 / 小红书 / B站。\n\n识别到的链接：\n\(url)"
            return
        }

        isParsing = true
        statusText = "正在解析\(platform.rawValue)链接…"
        result = nil
        savingIds = []
        finishedIds = []

        Task {
            do {
                let r: ParseResult
                switch platform {
                case .douyin: r = try await DouyinParser().parse(url)
                case .xiaohongshu: r = try await XiaohongshuParser().parse(url)
                case .bilibili: r = try await BilibiliParser().parse(url)
                default: throw ParseError("未知平台")
                }
                await MainActor.run {
                    result = r
                    statusText = "解析完成，共 \(r.items.count) 项"
                    isParsing = false
                }
            } catch {
                await MainActor.run {
                    statusText = "解析失败"
                    isParsing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @MainActor
    private func save(_ item: MediaItem) {
        if item.kind == .caption {
            UIPasteboard.general.string = item.text ?? ""
            finishedIds.insert(item.id)
            return
        }
        Task {
            await MainActor.run { savingIds.insert(item.id) }
            do {
                guard await PhotoSaver.requestAuthorization() else {
                    throw ParseError("没有相册权限，请在系统设置中允许访问相册")
                }
                switch item.kind {
                case .image:
                    guard let url = item.url else { throw ParseError("没有图片地址") }
                    let data = try await downloadData(url)
                    try await PhotoSaver.saveImage(data)
                case .video:
                    guard let url = item.url else { throw ParseError("没有视频地址") }
                    let local: URL
                    if item.isHls {
                        await MainActor.run { savingIds.insert(item.id) }
                        local = try await VideoExporter.exportHls(url)
                    } else {
                        local = try await DownloadManager.shared.download(item: item)
                    }
                    defer { try? FileManager.default.removeItem(at: local) }
                    try await PhotoSaver.saveVideo(from: local)
                case .caption:
                    break
                }
                await MainActor.run {
                    savingIds.remove(item.id)
                    finishedIds.insert(item.id)
                }
            } catch {
                await MainActor.run {
                    savingIds.remove(item.id)
                    errorMessage = "保存失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func downloadData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(UrlUtils.UA.desktop, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}
