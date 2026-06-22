import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var sources: SourceManager
    @ObservedObject private var cloud = CloudSync.shared

    // 辅助编译期环境判断
    private var isMacCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

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
                Toggle("批量下载时升级已下载音质", isOn: $settings.batchUpgradeQuality)
                Stepper(value: $settings.downloadConcurrency, in: 1...32) {
                    HStack {
                        Text("同时下载数")
                        Spacer()
                        Text("\(settings.downloadConcurrency)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("下载")
            } footer: {
                Text("「全部下载」时,如果歌单里有已下载但音质低于这次选的目标档的歌曲,自动重下升级。同时下载数控制并发上限(1–32,默认 10),太大可能拖慢播放和搜索")
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
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .brandedSurface()
        .navigationTitle("设置")
        // 在 Mac Catalyst 桌面端下，inline 模式配合透明背景能展现出最完美的居中标题栏
        .navigationBarTitleDisplayMode(isMacCatalyst ? .inline : .large)
        
        // MARK: - Mac Catalyst 专属：动态导航栏渲染重刷
        #if targetEnvironment(macCatalyst)
        .onAppear {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground() // 彻底把暗红底色刷成 100% 透明
            
            // 🛠️ 修正这里：标题改为深色（Label 色），确保在浅色背景上清晰可见
            appearance.titleTextAttributes = [
                .foregroundColor: UIColor.label,
                .font: UIFont.systemFont(ofSize: 16, weight: .semibold)
            ]
            
            UINavigationBar.appearance().standardAppearance = appearance
            UINavigationBar.appearance().scrollEdgeAppearance = appearance
        }
        .onDisappear {
            // 关闭时恢复到 walkmanApp 启动时设的默认外观 —— 之前这里把全局 UINavigationBar
            // 改成品牌红 + 白字,但应用根本就没有红色导航栏的设计,这个"恢复"是凭空造出来
            // 的状态,会污染后续所有 NavigationStack(包括 sheet 里的导航栏,典型表现就是
            // 收藏/下载弹窗顶部出现一条丑陋的暗红色 bar 配白字标题)。
            AppNavBarAppearance.applyDefault()
        }
        #endif
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
        case .hires: return "sparkles.rectangle.stack"
        // "spatial.audio" 不是合法 SF Symbol(渲染为空白),全景声系列用 person.spatialaudio。
        case .atmos: return "person.spatialaudio.fill"
        case .atmosPlus: return "person.spatialaudio.stereo.fill"
        case .master: return "crown"
        }
    }

    private var homeSourceOptions: [SourceID] { [.kw, .wy, .kg, .tx] }

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
