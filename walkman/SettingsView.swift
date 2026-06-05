import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var sources: SourceManager
    @ObservedObject private var cloud = CloudSync.shared

    var body: some View {
        Form {
            Section {
                Picker("默认音质", selection: $settings.preferredQuality) {
                    ForEach(Quality.allCases, id: \.self) { q in
                        Label(q.displayName, systemImage: iconForQuality(q)).tag(q)
                    }
                }
                Toggle("车机/锁屏用专辑栏显示歌词", isOn: $settings.showLyricsOnNowPlaying)
                NavigationLink {
                    EQView()
                } label: {
                    Label("均衡器", systemImage: "slider.vertical.3")
                }
            } header: {
                Text("播放")
            } footer: {
                Text("脚本会按此优先级请求音源 URL,若该音质不可用,会自动降级。开启「用专辑栏显示歌词」后,CarPlay 和锁屏原本显示专辑名的位置,会随播放进度显示当前歌词(参考 QQ / 网易云);无歌词时仍显示专辑名")
            }

            Section {
                Toggle("脚本失败时走内置直连 (非官方)", isOn: $settings.enableDirectFallback)
                NavigationLink {
                    ScriptManagerView()
                } label: {
                    HStack {
                        Label("自定义音源", systemImage: "doc.text.magnifyingglass")
                        Spacer()
                        Text("\(sources.loadedScripts.count) 个已加载")
                            .foregroundColor(.secondary).font(.caption)
                    }
                }
            } header: {
                Text("音源")
            } footer: {
                Text("脚本失败或未配置音源时,回落到内置直连(仅支持酷我/网易云)。如果你添加的音源能正常解析,可关闭此项严格走脚本")
            }

            // iPad / Mac 发现页源选择 — iPhone 也有这个 setting 但首页是 4 个
            // tab 各自独立,这里主要影响 IPadHomeView 拉哪些源的推荐/排行。
            Section {
                ForEach(homeSourceOptions, id: \.self) { src in
                    Toggle(isOn: bindingFor(src)) {
                        HStack(spacing: 8) {
                            Circle().fill(src.tint).frame(width: 8, height: 8)
                            Text(src.displayName)
                        }
                    }
                }
            } header: {
                Text("发现页信息来源")
            } footer: {
                Text("勾选哪些平台的推荐歌单 / 排行榜出现在 iPad 首页。至少保留一个,否则会自动恢复全选")
            }

            if !sources.loadedScripts.isEmpty {
                Section("已加载的源") {
                    ForEach(sources.loadedScripts, id: \.id) { ls in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(ls.script.name).font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Text("v\(ls.script.version)").font(.caption).foregroundColor(.secondary)
                            }
                            if !ls.script.description.isEmpty {
                                Text(ls.script.description).font(.caption).foregroundColor(.secondary).lineLimit(2)
                            }
                            HStack(spacing: 4) {
                                ForEach(SourceID.allCases.filter { ls.capabilities.sources[$0] != nil }, id: \.self) { src in
                                    SourceChip(source: src)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section {
                Toggle("使用 iCloud 同步", isOn: $cloud.enabled)
                if let last = cloud.lastSyncedAt {
                    HStack {
                        Text("上次同步")
                        Spacer()
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                            .foregroundColor(.secondary).font(.caption)
                    }
                }
            } header: {
                Text("云端")
            } footer: {
                Text("使用 iCloud Key-Value 同步歌单和设置(脚本本身不上传)")
            }

            Section {
                Toggle("显示调试提示", isOn: $settings.showDebugNotices)
            } header: {
                Text("调试")
            } footer: {
                Text("开启后,播放时会显示「换源播放」「音质降级」「使用内置 Hi-Res 解码」等提示横幅。真正的播放错误始终显示,不受此开关影响")
            }

            Section("关于") {
                LabeledContent("版本", value: appVersion)
            }
        }
        // Let Form translucently overlay brandedSurface so settings doesn't
        // feel like a separate iOS shell — keeps the gradient continuity.
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .brandedSurface()
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func iconForQuality(_ q: Quality) -> String {
        switch q {
        case .k128: return "waveform"
        case .k320: return "waveform.badge.plus"
        case .flac: return "waveform.path.ecg"
        case .flac24: return "waveform.path.ecg.rectangle"
        }
    }

    // MARK: - 发现页源 toggles

    /// Order matches the iPad sidebar / search tabs:酷我 / 网易云 / 酷狗 / QQ.
    private var homeSourceOptions: [SourceID] { [.kw, .wy, .kg, .tx] }

    /// Toggle binding that prevents the user from de-selecting the last source —
    /// an empty `homeSources` would render an empty 发现 页. Falling back to
    /// the full set is less surprising than silently re-enabling a single source.
    private func bindingFor(_ src: SourceID) -> Binding<Bool> {
        Binding(
            get: { settings.homeSources.contains(src) },
            set: { on in
                var s = settings.homeSources
                if on {
                    s.insert(src)
                } else {
                    s.remove(src)
                    if s.isEmpty { s = Set(homeSourceOptions) }
                }
                settings.homeSources = s
            }
        )
    }
}
