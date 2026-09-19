import SwiftUI
import UIKit

struct ContentView: View {

    private enum TabId {
        case download
        case more
    }

    @ObservedObject private var downloads = DownloadManager.shared
    @State private var tab: TabId = .download
    @State private var urlText = ""
    @State private var statusText = "粘贴链接后点击解析"
    @State private var isParsing = false
    @State private var result: ParseResult?
    @State private var errorMessage: String?
    @State private var unknownLink: String?
    @State private var savingIds: Set<String> = []
    @State private var finishedIds: Set<String> = []

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    var body: some View {
        ZStack {
            Image("AppBackground")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
            Color.white.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                Text("小帮手小熊猫")
                    .font(.title.bold())
                    .foregroundColor(Color(red: 0.118, green: 0.533, blue: 0.898))
                    .padding(.top, 6)

                Text("v\(version) · 支持 \(Platforms.supportedText)，保存无水印原视频、原图与文案")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                tabBar

                if tab == .download {
                    downloadPanel
                } else {
                    morePanel
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .alert("没认出这个链接", isPresented: unknownBinding, actions: {
                Button("仍然尝试解析") {
                    if let link = unknownLink {
                        launchParse(platform: .xiaohongshu, url: link)
                    }
                }
                Button("复制错误信息") {
                    UIPasteboard.general.string =
                        "版本：\(version)\n链接：\(unknownLink ?? "")\n原文：\(urlText)"
                }
                Button("知道了", role: .cancel) {}
            }, message: {
                Text(
                    "暂不支持该平台。\n\n目前支持：\(Platforms.supportedText)\n\n识别到的链接：\n"
                        + (unknownLink ?? "")
                        + "\n\n点【复制错误信息】把这段发给我，就能立刻加上支持。"
                )
            })
        }
        .alert("提示", isPresented: errorBinding, actions: {
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

    // MARK: - 标签栏

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton(title: "下载", systemImage: "square.and.arrow.down", target: .download)
            tabButton(title: "更多", systemImage: "ellipsis.circle", target: .more)
        }
        .padding(3)
        .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private func tabButton(title: String, systemImage: String, target: TabId) -> some View {
        let active = tab == target
        return Button {
            tab = target
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.subheadline.weight(active ? .semibold : .regular))
            .foregroundColor(active ? Color(red: 0.118, green: 0.533, blue: 0.898) : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(active ? Color.white.opacity(0.95) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 下载页

    private var downloadPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("粘贴抖音 / 小红书 / B站 / 微博 / X / Instagram 链接",
                          text: $urlText, axis: .vertical)
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
    }

    // MARK: - 更多页

    private var morePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                infoCard(
                    title: "已支持的平台",
                    body: "抖音 / 小红书 / B站 / 微博 / X（推特）/ Instagram\n都能保存原视频、原图、原文案。"
                )
                infoCard(
                    title: "使用步骤",
                    body: "1. 在对应 App 里点【分享 → 复制链接】\n2. 回到本应用点【粘贴】，再点【解析】\n3. 在结果列表里保存原视频 / 原图 / 文案"
                )
                infoCard(
                    title: "小提示",
                    body: "· 小红书请整段粘贴分享文字，链接里的 xsec_token 是能否读取笔记的关键。\n"
                        + "· X 和 Instagram 在中国大陆需要网络加速工具才能访问。\n"
                        + "· 视频保存在相册，文案可复制或存成 txt。\n"
                        + "· 解析太频繁会被平台临时拦截，等几分钟再试即可。"
                )
                infoCard(title: "版本", body: "v\(version)")
            }
        }
    }

    private func infoCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(body)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 结果列表

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
        .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
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
                Text(item.label).font(.subheadline)
                if let p = downloads.progress[item.id], p < 1 {
                    ProgressView(value: p).progressViewStyle(.linear)
                }
            }
            Spacer()

            if finishedIds.contains(item.id) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            } else if savingIds.contains(item.id) {
                ProgressView()
            } else {
                Button(item.kind == .caption ? "复制" : "保存") {
                    save(item)
                }
                .buttonStyle(.bordered)
                .disabled(isParsing)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 解析

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var unknownBinding: Binding<Bool> {
        Binding(get: { unknownLink != nil }, set: { if !$0 { unknownLink = nil } })
    }

    @MainActor
    private func startParse() {
        guard let url = UrlUtils.extractUrl(from: urlText) else {
            errorMessage = "没在这段文字里找到链接。\n\n版本：\(version)\n\n你粘贴的内容是：\n"
                + String(urlText.prefix(300))
                + "\n\n请在对应 App 里点【分享 → 复制链接】，再回到本应用点【粘贴】。"
            return
        }
        let platform = UrlUtils.detectPlatform(url, text: urlText)
        guard platform != .unknown else {
            unknownLink = url
            return
        }
        launchParse(platform: platform, url: url)
    }

    @MainActor
    private func launchParse(platform: Platform, url: String) {
        isParsing = true
        statusText = "正在解析\(platform.rawValue)链接…"
        result = nil
        savingIds = []
        finishedIds = []

        Task {
            do {
                let parsed: ParseResult
                switch platform {
                case .douyin: parsed = try await DouyinParser().parse(url)
                case .xiaohongshu: parsed = try await XiaohongshuParser().parse(url)
                case .bilibili: parsed = try await BilibiliParser().parse(url)
                case .weibo: parsed = try await WeiboParser().parse(url)
                case .x: parsed = try await TwitterParser().parse(url)
                case .instagram: parsed = try await InstagramParser().parse(url)
                default: throw ParseError("未知平台")
                }
                await MainActor.run {
                    result = parsed
                    statusText = "解析完成，共 \(parsed.items.count) 项"
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

    // MARK: - 保存

    private func headers(for platform: Platform) -> [String: String] {
        switch platform {
        case .xiaohongshu: return ["Referer": "https://www.xiaohongshu.com/"]
        case .weibo: return ["Referer": "https://m.weibo.cn/"]
        case .instagram: return ["Referer": "https://www.instagram.com/"]
        case .x: return ["Referer": "https://x.com/"]
        case .douyin: return ["Referer": "https://www.douyin.com/"]
        case .bilibili: return ["Referer": "https://www.bilibili.com/"]
        default: return [:]
        }
    }

    @MainActor
    private func save(_ item: MediaItem) {
        if item.kind == .caption {
            UIPasteboard.general.string = item.text ?? ""
            finishedIds.insert(item.id)
            return
        }
        let referer = headers(for: result?.platform ?? .unknown)
        Task {
            await MainActor.run { _ = savingIds.insert(item.id) }
            do {
                guard await PhotoSaver.requestAuthorization() else {
                    throw ParseError("没有相册权限，请在系统设置里允许访问相册")
                }
                switch item.kind {
                case .image:
                    let data = try await DownloadManager.shared.data(from: item, headers: referer)
                    try await PhotoSaver.saveImage(data)
                case .video:
                    let local: URL
                    if item.isHls, let url = item.url {
                        local = try await VideoExporter.exportHls(url)
                    } else {
                        local = try await DownloadManager.shared.download(item: item, headers: referer)
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
}
