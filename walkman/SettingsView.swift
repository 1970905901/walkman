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
            } header: {
                Text("播放")
            } footer: {
                Text("脚本会按此优先级请求音源 URL,若该音质不可用,会自动降级")
            }

            Section {
                Toggle("启动时加载内置脚本", isOn: $settings.loadBundledOnLaunch)
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
                Text("脚本失败时是否回落到内置直连(只支持酷我/网易云)。如果你的脚本指向真正可用的 API 服务器,可关闭此项严格走脚本;默认 v4 脚本指向的 88.lxmusic.世界 仅提供版本检查,实际 URL 解析需要靠这里")
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

            Section("关于") {
                LabeledContent("版本", value: "0.2.0")
                LabeledContent("基于", value: "lx-music v4 协议")
                Text("基于 lx-music 移动版协议复刻的 iOS 客户端,使用 SwiftUI + JavaScriptCore + AVFoundation 实现")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
    }

    private func iconForQuality(_ q: Quality) -> String {
        switch q {
        case .k128: return "waveform"
        case .k320: return "waveform.badge.plus"
        case .flac: return "waveform.path.ecg"
        case .flac24: return "waveform.path.ecg.rectangle"
        }
    }
}
