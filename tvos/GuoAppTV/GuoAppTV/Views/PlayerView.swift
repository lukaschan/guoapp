import AVKit
import CoreMedia
import SwiftUI
import UIKit

// MARK: - 弹幕浮层

/// 透明浮层，加到 AVPlayerViewController 的 contentOverlayView 上。
/// 弹幕从右向左匀速滚动，分 6 行轮换，最多同时显示 40 条。
final class DanmakuOverlayView: UIView {
    private var rowCounter = 0

    func clear() {
        subviews.forEach { $0.removeFromSuperview() }
    }

    func emit(text: String) {
        guard bounds.width > 0, subviews.count < 40 else { return }
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 30, weight: .semibold)
        label.textColor = .white
        label.shadowColor = .black
        label.shadowOffset = CGSize(width: 1, height: 1)
        label.sizeToFit()
        let row = rowCounter % 6
        rowCounter += 1
        label.frame = CGRect(x: bounds.width, y: CGFloat(row) * 44 + 20, width: label.bounds.width, height: 40)
        addSubview(label)
        UIView.animate(withDuration: 9, delay: 0, options: .curveLinear) {
            label.frame.origin.x = -label.bounds.width
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
}

// MARK: - 弹幕拉取

/// 按播放进度拉取弹幕页并在时间到达时投递到浮层。
/// 核心返回一页弹幕（`nextMs` 为下一页起点），与 Dart 侧 DanmakuPage 一致。
@MainActor
final class DanmakuEngine {
    private weak var overlay: DanmakuOverlayView?
    private var plan: PlaybackPlan?
    private var enabled = true
    private var page: DanmakuPage?
    private var fetching = false
    private var shown = Set<String>()

    func attach(_ overlay: DanmakuOverlayView) {
        self.overlay = overlay
    }

    func configure(plan: PlaybackPlan, enabled: Bool) {
        self.plan = plan
        self.enabled = enabled
        page = nil
        fetching = false
        shown.removeAll()
    }

    func reset() {
        plan = nil
        page = nil
        shown.removeAll()
    }

    func tick(positionMs: Int) {
        guard enabled, let plan else { return }
        if page == nil || positionMs >= page!.nextMs - 2000 {
            fetchPage(from: positionMs, plan: plan)
        }
        guard let page else { return }
        for item in page.items where !shown.contains(item.id) && item.timeMs >= positionMs
            && item.timeMs < positionMs + 1000
        {
            shown.insert(item.id)
            overlay?.emit(text: item.text)
        }
        if shown.count > 2000 { shown.removeAll() }
    }

    private func fetchPage(from positionMs: Int, plan: PlaybackPlan) {
        guard !fetching else { return }
        fetching = true
        Task {
            defer { fetching = false }
            if let result = try? await CoreClient.shared.danmaku(
                plan: plan, startMs: positionMs, durationMs: 60_000
            ), self.plan?.session == plan.session {
                page = result
            }
        }
    }
}

/// 可比较的播放进度（Swift 元组无法遵循 Equatable，onChange 不能直接监听元组）。
struct PlaybackProgress: Equatable {
    var position: Double
    var duration: Double
}

// MARK: - 播放控制器

/// 持有 AVPlayer，负责换集、进度上报、播完 / 失败通知、弹幕调度。
@MainActor
final class PlayerController: NSObject, ObservableObject {
    @Published var progress = PlaybackProgress(position: 0, duration: 0)
    @Published var endedToken = 0
    @Published var failedToken = 0
    /// 临时诊断面板内容：播放状态、等待原因、音视频编码、播放地址。
    @Published var debugInfo = ""

    let player = AVPlayer()
    private var currentURL: URL?
    private var currentHeaderCount = 0
    private let overlay = DanmakuOverlayView()
    private let danmaku = DanmakuEngine()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var overlayAttached = false

    func attach(to controller: AVPlayerViewController) {
        controller.player = player
        if !overlayAttached, let container = controller.contentOverlayView {
            overlay.frame = container.bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(overlay)
            danmaku.attach(overlay)
            overlayAttached = true
        }
    }

    func play(plan: PlaybackPlan, start: Double, danmakuEnabled: Bool) {
        danmaku.configure(plan: plan, enabled: danmakuEnabled)
        guard let url = URL(string: plan.url) else { return }
        currentURL = url
        currentHeaderCount = plan.headers.count
        debugInfo = "正在加载…"
        let asset: AVURLAsset
        if plan.headers.isEmpty {
            asset = AVURLAsset(url: url)
        } else {
            // AVPlayer 无法像 mpv 那样任意挂 header；
            // AVURLAssetHTTPHeaderFieldsKey 可把 Referer / User-Agent 这类头带给
            // 播放列表与分片请求，覆盖本应用站源的实际需求。
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": plan.headers])
        }
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        if start > 0 {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
        }
        player.play()
        installObservers()
    }

    func stop() {
        player.pause()
        removeObservers()
        danmaku.reset()
        overlay.clear()
    }

    private func installObservers() {
        removeObservers()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let position = time.seconds
            let duration = player.currentItem?.duration.seconds ?? 0
            progress = PlaybackProgress(
                position: position.isFinite ? position : 0,
                duration: duration.isFinite ? duration : 0
            )
            danmaku.tick(positionMs: Int(position * 1000))
            updateDebugInfo()
        }
        if let item = player.currentItem {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                self?.endedToken += 1
            }
            failObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                self?.failedToken += 1
            }
        }
    }

    /// 每秒刷新诊断面板：状态、等待原因、缓冲、音视频编码、播放地址。
    /// 关键区分：playing + 无轨道/不支持的编码 = 流格式问题；
    /// waitingToPlayAtSpecifiedRate + 缓冲空 = 分片拉不到（请求头/鉴权问题）。
    private func updateDebugInfo() {
        guard let item = player.currentItem else {
            debugInfo = "无播放项"
            return
        }
        var lines: [String] = []
        let itemStatus: String
        switch item.status {
        case .unknown: itemStatus = "未知"
        case .readyToPlay: itemStatus = "就绪"
        case .failed: itemStatus = "失败"
        @unknown default: itemStatus = "其他(\(item.status.rawValue))"
        }
        lines.append("条目状态: \(itemStatus)")
        lines.append("播放控制: \(player.timeControlStatus.rawValue) 等待原因: \(player.reasonForWaitingToPlay?.rawValue ?? "-")")
        lines.append("速率: \(player.rate) 缓冲空: \(item.isPlaybackBufferEmpty) 大概率流畅: \(item.isPlaybackLikelyToKeepUp)")
        if let error = item.error {
            lines.append("错误: \(error.localizedDescription)")
        }
        let asset = item.asset
        lines.append("资产可播: \(asset.isPlayable ? "是" : "否")")
        for mediaType in [AVMediaType.video, AVMediaType.audio] {
            let tracks = asset.tracks(withMediaType: mediaType)
            if tracks.isEmpty {
                lines.append("\(mediaType.rawValue): 无轨道")
            }
            for track in tracks {
                var codec = "?"
                if let first = track.formatDescriptions.first {
                    // 元素必为 CMFormatDescription；先判空再强转，
                    // 直接对 Optional 做 as! 会在数组为空时闪退。
                    let desc = first as! CMFormatDescription
                    let sub = CMFormatDescriptionGetMediaSubType(desc)
                    let bytes: [UInt8] = [
                        UInt8((sub >> 24) & 0xff), UInt8((sub >> 16) & 0xff),
                        UInt8((sub >> 8) & 0xff), UInt8(sub & 0xff),
                    ]
                    codec = String(bytes: bytes, encoding: .ascii) ?? "?"
                }
                if mediaType == .video {
                    let name: String
                    switch codec {
                    case "avc1", "h264": name = "H.264"
                    case "hvc1", "hev1": name = "H.265/HEVC"
                    case "av01": name = "AV1"
                    case "mp4v": name = "MPEG-4"
                    default: name = codec
                    }
                    lines.append("视频: \(name) (\(codec)) \(Int(track.naturalSize.width))x\(Int(track.naturalSize.height)) 可播: \(track.isPlayable ? "是" : "否")")
                } else {
                    let name: String
                    switch codec {
                    case "mp4a": name = "AAC"
                    case "ac-3": name = "杜比 AC-3"
                    case "ec-3": name = "杜比 E-AC-3"
                    case "opus": name = "Opus"
                    default: name = codec
                    }
                    lines.append("音频: \(name) (\(codec)) 可播: \(track.isPlayable ? "是" : "否")")
                }
            }
        }
        if let url = currentURL {
            lines.append("地址: \(url.host ?? "-")\(url.path)")
            lines.append("请求头: \(currentHeaderCount) 个")
        }
        debugInfo = lines.joined(separator: "\n")
    }

    private func removeObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
            self.failObserver = nil
        }
    }
}

private struct PlayerHostView: UIViewControllerRepresentable {
    let controller: PlayerController

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let viewController = AVPlayerViewController()
        controller.attach(to: viewController)
        return viewController
    }

    func updateUIViewController(_ viewController: AVPlayerViewController, context: Context) {}
}

// MARK: - 播放页

struct PlayerView: View {
    let drama: Drama
    let episodes: [Episode]
    let startIndex: Int
    let startPosition: Double

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: Store
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("autoAdvance") private var autoAdvance = true

    @StateObject private var controller = PlayerController()
    @State private var currentIndex: Int
    @State private var start: Double
    @State private var plan: PlaybackPlan?
    @State private var error: String?
    @State private var lastSavedPosition = -1.0

    init(drama: Drama, episodes: [Episode], startIndex: Int, startPosition: Double) {
        self.drama = drama
        self.episodes = episodes
        self.startIndex = startIndex
        self.startPosition = startPosition
        _currentIndex = State(initialValue: startIndex)
        _start = State(initialValue: startPosition)
    }

    var body: some View {
        ZStack {
            if plan != nil {
                PlayerHostView(controller: controller)
                    .ignoresSafeArea()
                if !controller.debugInfo.isEmpty {
                    Text(controller.debugInfo)
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.leading)
                        .padding(16)
                        .background(Color.black.opacity(0.65))
                        .cornerRadius(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(48)
                        .allowsHitTesting(false)
                }
            } else if let error {
                VStack(spacing: 24) {
                    Text("播放失败").font(.title)
                    Text(error).foregroundColor(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 20) {
                        Button("重试") { Task { await load() } }
                        Button("返回") { dismiss() }
                    }
                }
                .padding(60)
            } else {
                ProgressView("正在解析播放地址…")
            }
        }
        .task {
            await load()
        }
        .onChange(of: controller.endedToken) { token in
            guard token > 0 else { return }
            handleEnded()
        }
        .onChange(of: controller.failedToken) { token in
            guard token > 0 else { return }
            Task { await handleFailed() }
        }
        .onChange(of: controller.progress) { value in
            handleProgress(position: value.position, duration: value.duration)
        }
        .onDisappear {
            saveProgress()
            controller.stop()
            Task {
                if let plan {
                    try? await CoreClient.shared.release(session: plan.session)
                }
            }
        }
    }

    private func load() async {
        guard currentIndex < episodes.count else {
            dismiss()
            return
        }
        error = nil
        let episode = episodes[currentIndex]
        do {
            let resolved = try await CoreClient.shared.resolve(drama: drama, episode: episode)
            guard !Task.isCancelled else { return }
            plan = resolved
            controller.play(plan: resolved, start: start, danmakuEnabled: danmakuEnabled)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func handleEnded() {
        if autoAdvance, currentIndex + 1 < episodes.count {
            currentIndex += 1
            start = 0
            lastSavedPosition = -1
            Task { await load() }
        } else {
            dismiss()
        }
    }

    private func handleFailed() async {
        guard let plan else { return }
        if plan.hasAlternative {
            do {
                let next = try await CoreClient.shared.fallback(plan: plan)
                self.plan = next
                controller.play(plan: next, start: 0, danmakuEnabled: danmakuEnabled)
            } catch {
                self.error = error.localizedDescription
            }
        } else {
            self.error = "播放失败，请返回重试"
        }
    }

    private func handleProgress(position: Double, duration: Double) {
        guard position > 0, duration > 0 else { return }
        // 与 Dart 侧一致：约每 5 秒落一次进度，避免频繁写盘。
        guard abs(position - lastSavedPosition) >= 5 else { return }
        lastSavedPosition = position
        saveProgress(position: position, duration: duration)
    }

    private func saveProgress(position: Double? = nil, duration: Double? = nil) {
        guard currentIndex < episodes.count else { return }
        let position = position ?? controller.progress.position
        let duration = duration ?? controller.progress.duration
        guard position > 0, duration > 0 else { return }
        let episode = episodes[currentIndex]
        store.saveProgress(WatchProgress(
            drama: drama,
            episode: episode.number,
            episodeTitle: episode.title,
            position: position,
            duration: duration,
            updatedAt: Date()
        ))
    }
}
