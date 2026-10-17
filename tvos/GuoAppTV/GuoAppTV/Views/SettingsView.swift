import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("autoAdvance") private var autoAdvance = true

    var body: some View {
        NavigationStack {
            List {
                Section("站源") {
                    ForEach(SourceSite.available(allSources: appState.allSources)) { site in
                        Button {
                            appState.selectedSource = site.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(site.name)
                                    Text(site.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if site.id == appState.selectedSource {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Section("播放") {
                    Toggle("弹幕", isOn: $danmakuEnabled)
                    Toggle("播完自动连播下一集", isOn: $autoAdvance)
                }
                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(appVersion).foregroundColor(.secondary)
                    }
                    Text("原生 tvOS 应用 · Go 核心 · mpv 播放")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("未签名包需在 Mac 上用 Xcode 签名后安装到 Apple TV。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return short.isEmpty ? build : "\(short) (\(build))"
    }
}
