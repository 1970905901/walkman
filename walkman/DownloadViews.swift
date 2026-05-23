import SwiftUI

// MARK: - Download sheet (pick quality + sub-playlist)

struct DownloadSheet: View {
    let track: Track
    @EnvironmentObject var downloads: DownloadStore
    @Environment(\.dismiss) private var dismiss

    @State private var quality: Quality
    @State private var folderID: UUID
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    init(track: Track) {
        self.track = track
        let qs = track.qualities.isEmpty ? [.k320] : track.qualities
        let best: Quality = qs.contains(.flac24) ? .flac24 : qs.contains(.flac) ? .flac : qs.contains(.k320) ? .k320 : .k128
        _quality = State(initialValue: best)
        _folderID = State(initialValue: DownloadStore.shared.folders.first?.id ?? UUID())
    }

    private var availableQualities: [Quality] {
        let qs = Set(track.qualities.isEmpty ? [.k320] : track.qualities)
        return [.flac24, .flac, .k320, .k128].filter { qs.contains($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("歌曲") {
                    HStack(spacing: 12) {
                        Artwork(url: track.picURL, size: 48, radius: DS.Radius.small)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text(track.singer).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
                Section("音质") {
                    Picker("音质", selection: $quality) {
                        ForEach(availableQualities, id: \.self) { q in
                            Text(q.displayName).tag(q)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("下载到子歌单") {
                    Picker("子歌单", selection: $folderID) {
                        ForEach(downloads.folders) { f in
                            Text(f.name).tag(f.id)
                        }
                    }
                    Button {
                        showNewFolder = true
                    } label: {
                        Label("新建子歌单", systemImage: "folder.badge.plus")
                    }
                }
                Section {
                    Button {
                        downloads.download(track: track, quality: quality, folderID: folderID)
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Label("开始下载", systemImage: "arrow.down.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                        }
                    }
                    .disabled(downloads.folders.isEmpty)
                }
            }
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("新建子歌单", isPresented: $showNewFolder) {
                TextField("名称", text: $newFolderName)
                Button("取消", role: .cancel) { newFolderName = "" }
                Button("创建") {
                    let n = newFolderName.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty {
                        let f = downloads.createFolder(name: n)
                        folderID = f.id
                    }
                    newFolderName = ""
                }
            }
        }
    }
}

// MARK: - 已下载 (sub-playlists)

struct DownloadedView: View {
    @EnvironmentObject var downloads: DownloadStore
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(downloads.folders) { folder in
                    let folderTracks = downloads.tracks(in: folder)
                    NavigationLink {
                        DownloadFolderView(folderID: folder.id)
                    } label: {
                        DownloadFolderCard(folder: folder, coverURLs: Array(folderTracks.prefix(4).map { $0.picURL }), count: folderTracks.count)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { downloads.deleteFolder(folder.id) } label: {
                            Label("删除子歌单", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(DS.Spacing.l)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("已下载")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { DownloadsStatusView() } label: { Image(systemName: "arrow.down.circle") }
            }
        }
        .alert("新建子歌单", isPresented: $showNewFolder) {
            TextField("名称", text: $newFolderName)
            Button("取消", role: .cancel) { newFolderName = "" }
            Button("创建") {
                let n = newFolderName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { downloads.createFolder(name: n) }
                newFolderName = ""
            }
        }
    }
}

private struct DownloadFolderCard: View {
    let folder: DownloadFolder
    let coverURLs: [String?]
    let count: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CoverMosaic(urls: coverURLs)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.system(size: 14, weight: .semibold)).foregroundColor(.primary).lineLimit(1)
                Text("\(count) 首").font(.caption2).foregroundColor(.secondary)
            }
        }
    }
}

struct DownloadFolderView: View {
    let folderID: UUID
    @EnvironmentObject var downloads: DownloadStore
    @EnvironmentObject var playback: PlaybackEngine

    private var folder: DownloadFolder? { downloads.folders.first { $0.id == folderID } }

    var body: some View {
        let tracks = folder.map { downloads.tracks(in: $0) } ?? []
        List {
            if !tracks.isEmpty {
                Section {
                    Button {
                        playback.play(track: tracks[0], in: tracks, startIndex: 0)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                            Text("播放全部")
                        }
                        .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, t in
                    HStack(spacing: 4) {
                        TrackRow(track: t)
                        if let q = downloads.quality(for: t.id) {
                            Text(q.displayName).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { playback.play(track: t, in: tracks, startIndex: idx) }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { downloads.removeDownload(trackID: t.id) } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(folder?.name ?? "子歌单")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView("还没有下载", systemImage: "arrow.down.circle", description: Text("在播放器或歌曲菜单里下载到这个子歌单"))
            }
        }
    }
}

// MARK: - Download status

struct DownloadsStatusView: View {
    @EnvironmentObject var downloads: DownloadStore

    private var active: [DownloadRecord] { records(.downloading) }
    private var failed: [DownloadRecord] { records(.failed) }
    private var completed: [DownloadRecord] { records(.completed) }

    private func records(_ status: DownloadStatus) -> [DownloadRecord] {
        downloads.records.values.filter { $0.status == status }.sorted { $0.track.name < $1.track.name }
    }

    var body: some View {
        List {
            if !active.isEmpty {
                Section("下载中") {
                    ForEach(active, id: \.track.id) { rec in
                        statusRow(rec, trailing: AnyView(
                            ProgressView(value: downloads.progress[rec.track.id] ?? 0)
                                .frame(width: 60)
                        ))
                    }
                }
            }
            if !failed.isEmpty {
                Section("失败") {
                    ForEach(failed, id: \.track.id) { rec in
                        statusRow(rec, trailing: AnyView(
                            Button { downloads.retry(trackID: rec.track.id) } label: {
                                Image(systemName: "arrow.clockwise.circle")
                            }.buttonStyle(.borderless)
                        ))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { downloads.removeDownload(trackID: rec.track.id) } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            if !completed.isEmpty {
                Section("已完成 (\(completed.count))") {
                    ForEach(completed, id: \.track.id) { rec in
                        statusRow(rec, trailing: AnyView(
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        ))
                    }
                }
            }
        }
        .navigationTitle("下载状态")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if downloads.records.isEmpty {
                ContentUnavailableView("暂无下载", systemImage: "arrow.down.circle")
            }
        }
    }

    private func statusRow(_ rec: DownloadRecord, trailing: AnyView) -> some View {
        HStack(spacing: 12) {
            Artwork(url: rec.track.picURL, size: 40, radius: DS.Radius.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.track.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(rec.track.singer).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    Text(rec.quality.displayName).font(.caption2).foregroundColor(.secondary)
                    if let e = rec.errorMessage { Text(e).font(.caption2).foregroundColor(.orange).lineLimit(1) }
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}
