import SwiftUI
import UIKit

@MainActor
final class ApuMusicAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundAudioDownload.sessionIdentifier else { completionHandler(); return }
        BackgroundAudioDownload.shared.reconnect(completion: completionHandler)
    }
}

@main
struct ApuMusicApp: App {
    @UIApplicationDelegateAdaptor(ApuMusicAppDelegate.self) private var appDelegate
    @StateObject private var player = Player()
    @StateObject private var downloads = DownloadManager()
    @StateObject private var favorites = FavoriteLibrary()
    var body: some Scene {
        WindowGroup { MusicShell().environmentObject(player).environmentObject(downloads).environmentObject(favorites).preferredColorScheme(.dark) }
    }
}

private enum ApuTheme {
    static let background = Color.black
    static let accent = Color(red: 0.0, green: 0.87, blue: 0.90)
}

struct MusicShell: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var favorites: FavoriteLibrary
    @State private var selectedTab = 0
    @State private var playerPresented = false
    private let tabs: [(String, String, Int)] = [
        ("house", "首页", 0), ("safari", "探索", 1), ("magnifyingglass", "搜索", 2), ("square.stack", "我的收藏", 3)
    ]
    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case 0: HomeScreen(openPlayer: { playerPresented = true })
                case 1: HomeScreen(openPlayer: { playerPresented = true })
                case 2: SearchScreen(openPlayer: { playerPresented = true })
                default: LibraryScreen(openPlayer: { playerPresented = true })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let current = player.current {
                Button { playerPresented = true } label: {
                    HStack(spacing: 11) {
                        Artwork(url: current.artwork, size: 42, thumbnailURL: current.thumbnail)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(current.song).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(player.playbackFailed ? player.playbackMessage : current.singer)
                                .font(.system(size: 11)).foregroundStyle(player.playbackFailed ? Color.orange : Color.gray).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .semibold)).frame(width: 42, height: 42)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
                        .accessibilityIdentifier("迷你播放控制")
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .frame(height: 58)
                    .foregroundStyle(.white)
                    .background(Color.black)
                    .overlay(alignment: .bottomLeading) {
                        GeometryReader { proxy in
                            Rectangle().fill(ApuTheme.accent)
                                .frame(width: proxy.size.width * progressFraction, height: 2)
                        }
                        .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("迷你播放条")
            }
            HStack(spacing: 0) {
                ForEach(tabs, id: \.2) { icon, title, index in
                    tab(icon, title, index)
                        .accessibilityIdentifier(title == "我的收藏" ? "我的收藏" : "导航-\(title)")
                }
            }
            .padding(.top, 7)
            .frame(height: 58)
            .background(Color.black.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $playerPresented) {
            NowPlayingScreen().environmentObject(player).accessibilityIdentifier("正在播放")
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .alert("下载提示", isPresented: Binding(
            get: { downloads.alertMessage != nil },
            set: { if !$0 { downloads.alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { downloads.alertMessage = nil }
        } message: {
            Text(downloads.alertMessage ?? "")
        }
        .alert("收藏提示", isPresented: Binding(
            get: { favorites.errorMessage != nil },
            set: { if !$0 { favorites.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { favorites.errorMessage = nil }
        } message: {
            Text(favorites.errorMessage ?? "")
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("-ui-testing") { player.volume = 0 }
        }
    }

    private var progressFraction: CGFloat {
        let timing = player.progress.timing
        guard timing.duration.isFinite, timing.duration > 0 else { return 0 }
        return min(max(timing.position / timing.duration, 0), 1)
    }

    private func tab(_ icon: String, _ title: String, _ index: Int) -> some View {
        Button { selectedTab = index } label: {
            VStack(spacing: 4) {
                Image(systemName: selectedTab == index ? "\(icon).fill" : icon).font(.system(size: 18, weight: .regular))
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(selectedTab == index ? ApuTheme.accent : Color.gray)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct HomeScreen: View {
    var openPlayer: () -> Void
    @State private var tracks: [Track] = []
    @State private var playlists: [PlaylistSummary] = []
    @State private var error = ""
    @State private var isLoading = true
    @EnvironmentObject private var player: Player

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    HStack(spacing: 10) {
                        Image("ApuMascot")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Text(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).capitalized)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                    sectionTitle("为你精选", trailing: "")
                    if isLoading && tracks.isEmpty {
                        ForEach(0..<6, id: \.self) { _ in TrackSkeletonRow() }
                    } else {
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 15) {
                                ForEach(tracks) { track in
                                    Button { player.setQueue(tracks, start: track); openPlayer() } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Artwork(url: track.artwork, size: 158, thumbnailURL: track.thumbnail)
                                            Text(track.song).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                            Text(track.singer).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        .frame(width: 158, alignment: .leading)
                                        .opacity(track.canPlay ? 1 : 0.48)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("歌曲-\(track.song)")
                                }
                            }
                            .padding(.vertical, 2)
                        }.scrollIndicators(.hidden)
                    }
                    if !playlists.isEmpty {
                        sectionTitle("为你挑选的歌单", trailing: "")
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 14) {
                                ForEach(playlists) { playlist in
                                    NavigationLink { PlaylistScreen(id: playlist.id, title: playlist.name, openPlayer: openPlayer) } label: {
                                        VStack(alignment: .leading, spacing: 9) {
                                        PlaylistArtwork(url: playlist.cover.flatMap(URL.init(string:)), tracks: tracks, size: 164)
                                            Text(playlist.name).font(.system(size: 14, weight: .medium)).lineLimit(2)
                                        }.frame(width: 164, alignment: .leading)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.scrollIndicators(.hidden)
                    }
                    if let current = player.current {
                        sectionTitle("接着听", trailing: "")
                        TrackRow(track: current, index: 1, active: true) { openPlayer() }
                    }
                    if !error.isEmpty { Text(error).foregroundStyle(.secondary).font(.subheadline) }
                }
                .padding(.horizontal, 16).padding(.bottom, 20)
            }
            .refreshable { await load() }
        .task {
            guard tracks.isEmpty else { return }
            if ProcessInfo.processInfo.arguments.contains("--uitesting-preview") {
                tracks = [
                    Track(id: "preview-1", platform: "tencent", song: "夜空中最亮的星", singer: "逃跑计划",
                          album: "世界", duration: 276, cover: ""),
                    Track(id: "preview-2", platform: "netease", song: "晴天", singer: "周杰伦",
                          album: "叶惠美", duration: 269, cover: ""),
                    Track(id: "preview-3", platform: "kugou", song: "若把你", singer: "Kirsty刘瑾睿",
                          album: "若把你", duration: 208, cover: "")
                ]
                isLoading = false
            } else {
                await load()
            }
        }
            .background(Color.black.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 7) {
                        Image("ApuMascot").resizable().scaledToFill().frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("阿噗音乐").font(.system(size: 19, weight: .bold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SearchScreen(openPlayer: openPlayer) } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("搜索音乐")
                        .accessibilityIdentifier("搜索音乐")
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .accessibilityIdentifier("首页")
    }
    private func sectionTitle(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title).font(.system(size: 23, weight: .bold)).accessibilityIdentifier(title)
            Spacer()
            if !trailing.isEmpty { Button(trailing) {}.font(.system(size: 13)).foregroundStyle(.secondary) }
        }
    }
    @MainActor private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let homeResponse: HomeResponse = MusicAPI.get("recommendations/home?platform=applemusic&limit=30")
            async let playlistResponse: PlaylistResponse = MusicAPI.get("local/imported-playlists")
            let home = try await homeResponse
            let collection = try await playlistResponse
            tracks = TrackDeduplicator.merge(home.tracks)
            playlists = collection.playlists
            error = tracks.isEmpty ? "暂时没有推荐歌曲" : ""
        } catch { self.error = "暂时无法加载内容，请下拉重试。" }
    }
}

struct SearchScreen: View {
    var openPlayer: () -> Void
    @EnvironmentObject private var player: Player
    @State private var query = ""
    @State private var tracks: [Track] = []
    @State private var error = ""
    @State private var isLoading = false
    @State private var selectedGroup = "歌曲"
    @State private var cachedResults: [String: [Track]] = [:]
    private var requestKey: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var groups: [SearchGroup] { SearchGrouping.groups(for: tracks, query: query) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !groups.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 21) {
                            ForEach(groups) { group in
                                Button {
                                    selectedGroup = group.title
                                } label: {
                                    VStack(spacing: 9) {
                                        Text(group.title).font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(selectedGroup == group.title ? .white : Color.gray)
                                        Rectangle().fill(selectedGroup == group.title ? ApuTheme.accent : .clear)
                                            .frame(height: 2)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(height: 42)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if isLoading && tracks.isEmpty {
                            ForEach(0..<8, id: \.self) { _ in TrackSkeletonRow() }
                        } else if let group = groups.first(where: { $0.title == selectedGroup }) {
                            if group.title == "专辑" || group.title == "歌手" {
                                ForEach(Array(group.names.enumerated()), id: \.offset) { _, name in
                                    Text(name).font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.white).frame(height: 60, alignment: .leading)
                                        .padding(.horizontal, 16)
                                }
                            } else {
                                ForEach(Array(group.tracks.enumerated()), id: \.element.id) { index, track in
                                    TrackRow(track: track, index: index + 1, active: !track.canPlay) {
                                        guard track.canPlay else { return }
                                        player.setQueue(tracks, start: track)
                                        openPlayer()
                                    }
                                }
                            }
                        } else if !query.isEmpty && !isLoading {
                            Text(error.isEmpty ? "没有找到歌曲" : error)
                                .font(.system(size: 14)).foregroundStyle(Color.gray).padding(16)
                        } else if query.isEmpty {
                            Text("搜索歌曲、专辑或歌手")
                                .font(.system(size: 14)).foregroundStyle(Color.gray).padding(.horizontal, 16).padding(.top, 16)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .background(Color.black)
            .navigationTitle("搜索").navigationBarTitleDisplayMode(.large).accessibilityIdentifier("搜索页面")
            .searchable(text: $query, prompt: "歌曲、歌手或专辑")
            .task(id: requestKey) {
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { tracks = []; return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await search()
            }
        }
    }

    private func search() async {
        isLoading = true
        defer { isLoading = false }
        if let cached = cachedResults[requestKey] {
            tracks = cached
            error = ""
            return
        }
        do {
            let result = TrackDeduplicator.merge(try await MusicAPI.searchTracks(requestKey))
            guard !Task.isCancelled else { return }
            tracks = result
            cachedResults[requestKey] = result
            error = tracks.isEmpty ? "没有找到歌曲" : ""
            if !groups.contains(where: { $0.title == selectedGroup }) { selectedGroup = groups.first?.title ?? "歌曲" }
        } catch {
            guard !Task.isCancelled else { return }
            tracks = []
            self.error = "搜索暂时不可用"
        }
    }
}

struct LibraryScreen: View {
    var openPlayer: () -> Void
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var favoriteLibrary: FavoriteLibrary
    @State private var summaries: [PlaylistSummary] = []
    @State private var localPlaylists = LibraryStore.playlists
    @State private var creatingPlaylist = false
    @State private var playlistName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                        NavigationLink { FavoriteScreen(openPlayer: openPlayer) } label: {
                        Label("喜欢的歌曲", systemImage: "heart.fill")
                            .foregroundStyle(.white)
                                .overlay(alignment: .trailing) { Text("\(favoriteLibrary.tracks.count) 首").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section("你的歌单") {
                    NavigationLink { DownloadedScreen(openPlayer: openPlayer) } label: {
                        Label("已下载", systemImage: "arrow.down.circle")
                            .overlay(alignment: .trailing) { Text("\(DownloadStore.tracks.count) 首").font(.caption).foregroundStyle(.secondary) }
                    }
                    ForEach(localPlaylists) { playlist in
                        NavigationLink { LocalPlaylistScreen(playlist: playlist, openPlayer: openPlayer) } label: {
                            HStack(spacing: 12) {
                                Artwork(url: playlist.tracks.first?.artwork, size: 50)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playlist.name).font(.system(size: 15, weight: .medium))
                                    Text("\(playlist.tracks.count) 首歌曲").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 2)
                        }
                    }
                    ForEach(summaries) { playlist in
                        NavigationLink { PlaylistScreen(id: playlist.id, title: playlist.name, openPlayer: openPlayer) } label: {
                            HStack(spacing: 12) {
                                Artwork(url: playlist.cover.flatMap(URL.init(string:)), size: 50)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(playlist.name).font(.system(size: 15, weight: .medium))
                                    Text("\(playlist.trackCount ?? 0) 首歌曲").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 2)
                        }.accessibilityIdentifier("导入歌单-\(playlist.id)")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("我的收藏")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { creatingPlaylist = true } label: { Image(systemName: "plus") } } }
            .task { await load() }
            .alert("新建歌单", isPresented: $creatingPlaylist) {
                TextField("歌单名称", text: $playlistName)
                Button("取消", role: .cancel) { }
                Button("创建") {
                    let name = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { localPlaylists.append(LocalPlaylist(name: name, tracks: [])); LibraryStore.playlists = localPlaylists }
                    playlistName = ""
                }
            }
        }
        .accessibilityIdentifier("我的收藏页面")
    }
    private func load() async {
        favoriteLibrary.refresh()
        localPlaylists = LibraryStore.playlists
        do { let value: PlaylistResponse = try await MusicAPI.get("local/imported-playlists"); summaries = value.playlists }
        catch { }
    }
}

struct PlaylistScreen: View {
    var id: String
    var title: String
    var openPlayer: () -> Void
    @EnvironmentObject private var player: Player
    @State private var detail: PlaylistDetail?
    @State private var message = ""
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if let detail {
                    HStack(spacing: 20) {
                        PlaylistArtwork(url: detail.cover.flatMap(URL.init(string:)), tracks: detail.items, size: 132)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(detail.name).font(.system(size: 21, weight: .bold)).lineLimit(3)
                            Text("\(detail.items.count) 首歌曲").font(.subheadline).foregroundStyle(.secondary)
                            Button { if let first = detail.items.first(where: \.canPlay) { player.setQueue(detail.items, start: first); openPlayer() } } label: {
                                Label("播放全部", systemImage: "play.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                                    .padding(.horizontal, 16).padding(.vertical, 10).background(Color(red: 0.72, green: 0.92, blue: 0.56)).clipShape(Capsule())
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(.top, 14)
                    ForEach(Array(detail.items.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, index: index + 1, active: !track.canPlay) {
                            guard track.canPlay else { return }
                            player.setQueue(detail.items, start: track); openPlayer()
                        }
                    }
                } else if !message.isEmpty { Text(message).foregroundStyle(.secondary).padding(.top, 40) }
            }.padding(.horizontal, 18)
        }
            .background(Color.black)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("歌单详情")
        .task {
            do { detail = try await MusicAPI.get("local/imported-playlists/\(id)") }
            catch { message = "歌单暂时无法加载" }
        }
    }
}

struct LocalPlaylistScreen: View {
    var playlist: LocalPlaylist
    var openPlayer: () -> Void
    @EnvironmentObject private var player: Player
    @State private var tracks: [Track] = []
    var body: some View {
        List {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, index: index + 1, active: !track.canPlay) {
                    guard track.canPlay else { return }; player.setQueue(tracks, start: track); openPlayer()
                }.listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
            .onDelete { indexes in
                tracks.remove(atOffsets: indexes)
                guard let playlistIndex = LibraryStore.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
                var all = LibraryStore.playlists; all[playlistIndex].tracks = tracks; LibraryStore.playlists = all
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Color.black)
        .navigationTitle(playlist.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        .onAppear { tracks = playlist.tracks }
    }
}

struct FavoriteScreen: View {
    var openPlayer: () -> Void
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var favorites: FavoriteLibrary
    var body: some View {
        List {
            ForEach(Array(favorites.tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, index: index + 1, active: !track.canPlay) {
                    guard track.canPlay else { return }
                    player.setQueue(favorites.tracks, start: track)
                    openPlayer()
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
            .onDelete(perform: favorites.remove)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .navigationTitle("喜欢的歌曲")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        .onAppear { favorites.refresh() }
    }
}

private struct PageSwipeState {
    var excluded: Bool?
    var dragging = false
}

private struct PlayerExclusionFramesKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    /// Registers a region that must not start a page-wide song swipe.
    func playerExclusionZone() -> some View {
        background(GeometryReader { proxy in
            Color.clear
                .preference(key: PlayerExclusionFramesKey.self,
                            value: [proxy.frame(in: .named("player"))])
                .allowsHitTesting(false)
        })
    }
}

struct NowPlayingScreen: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var favorites: FavoriteLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var showingLyrics = false
    @State private var showingQueue = false
    @State private var coverOffset: CGFloat = 0
    @State private var coverOpacity: Double = 1
    @State private var coverSwitching = false
    @State private var exclusionFrames: [CGRect] = []
    @GestureState private var pageSwipeState = PageSwipeState()

    private var coverSize: CGFloat { min(UIScreen.main.bounds.width - 46, 376) }

    var body: some View {
        VStack(spacing: 0) {
            playerHeader
            ScrollView {
                VStack(spacing: 22) {
                    ZStack {
                        Artwork(url: player.current?.artwork, size: coverSize)
                            .id(player.current?.id ?? "")
                            .offset(y: coverOffset)
                            .opacity(coverOpacity)
                    }
                    .frame(width: coverSize, height: coverSize)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                    .accessibilityLabel("歌曲封面")
                    .accessibilityHint("上滑下一首，下滑上一首")
                    .padding(.top, 4)
                    HStack(spacing: 15) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(player.current?.song ?? "").font(.system(size: 22, weight: .bold)).lineLimit(2)
                            Text(player.current?.singer ?? "").font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button(action: toggleFavorite) {
                            Image(systemName: isFavorite ? "heart.fill" : "heart")
                                .font(.system(size: 23)).foregroundStyle(isFavorite ? Color.pink : .white)
                        }
                        Button { if let current = player.current { downloads.download(current) } } label: {
                            if let progress = downloads.progress[player.current?.id ?? ""] {
                                if downloads.preparing.contains(player.current?.id ?? "") { ProgressView() }
                                else { ProgressView(value: progress).frame(width: 22) }
                            } else {
                                Image(systemName: "arrow.down.to.line").font(.system(size: 20)).foregroundStyle(.white)
                            }
                        }
                        .accessibilityLabel("下载歌曲")
                    }
                    PlaybackProgressControls(progress: player.progress, seek: player.seek)
                        .playerExclusionZone()
                    if let current = player.current, let progress = downloads.progress[current.id] {
                        ProgressView(value: progress).frame(width: 110)
                    }
                    HStack {
                        Button { player.shuffled.toggle() } label: {
                            Image(systemName: "shuffle").foregroundStyle(player.shuffled ? Color(red: 0.72, green: 0.92, blue: 0.56) : .white)
                        }
                        Spacer()
                        Button { Task { await player.previous() } } label: { Image(systemName: "backward.end.fill").font(.system(size: 26)) }
                        Spacer()
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 25, weight: .bold))
                                .frame(width: 68, height: 68).background(.white).foregroundStyle(.black).clipShape(Circle())
                        }
                        .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
                        .accessibilityIdentifier("全屏播放控制")
                        Spacer()
                        Button { Task { await player.next() } } label: { Image(systemName: "forward.end.fill").font(.system(size: 26)) }
                        Spacer()
                        Button { player.repeatMode = (player.repeatMode + 1) % 3 } label: {
                            Image(systemName: player.repeatMode == 2 ? "repeat.1" : "repeat")
                                .foregroundStyle(player.repeatMode > 0 ? Color(red: 0.72, green: 0.92, blue: 0.56) : .white)
                        }
                    }
                    HStack {
                        Button { showingLyrics.toggle() } label: { Label("歌词", systemImage: "quote.bubble").foregroundStyle(.white) }
                        Spacer()
                        Button { showingQueue = true } label: { Label("播放队列", systemImage: "list.bullet").foregroundStyle(.white) }
                    }.font(.system(size: 14)).padding(.top, 12)
                    if showingLyrics {
                        PlayingLyrics(lyrics: player.lyrics)
                            .playerExclusionZone()
                    }
                }
                .padding(.horizontal, 23).padding(.bottom, 22)
            }
            .scrollDisabled(pageSwipeState.dragging)
            if !player.playbackMessage.isEmpty {
                Text(player.playbackMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(player.playbackFailed ? Color.orange : Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .accessibilityIdentifier("播放状态")
            }
        }
        .background(Color.black.ignoresSafeArea())
        .coordinateSpace(name: "player")
        .onPreferenceChange(PlayerExclusionFramesKey.self) { exclusionFrames = $0 }
        .simultaneousGesture(pageSwipe)
        .sheet(isPresented: $showingQueue) {
            NavigationStack {
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
                        Button {
                            player.setQueue(player.queue, start: track)
                            showingQueue = false
                        } label: {
                            TrackRow(track: track, index: index + 1, active: index == player.currentIndex) { }
                        }
                        .foregroundStyle(.white)
                        .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                    }
                    .onMove(perform: player.move)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .navigationTitle("播放队列")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
            }
        }
    }

    private var pageSwipe: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named("player"))
            .updating($pageSwipeState) { value, state, _ in
                if state.excluded == nil {
                    state.excluded = gestureStartsInExcludedZone(value.startLocation)
                }
                guard !coverSwitching,
                      state.excluded == false,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                state.dragging = true
            }
            .onChanged { value in
                guard !coverSwitching,
                      !pageSwipeBlocked(at: value.startLocation) else { return }
                let vertical = value.translation.height
                guard abs(vertical) > abs(value.translation.width) else { return }
                coverOffset = vertical
                coverOpacity = 1 - min(abs(vertical) / (coverSize * 3), 0.22)
            }
            .onEnded { value in
                guard !coverSwitching,
                      !pageSwipeBlocked(at: value.startLocation) else { return }
                let vertical = value.translation.height
                let horizontal = value.translation.width
                let predicted = value.predictedEndTranslation.height
                let predictedHorizontal = value.predictedEndTranslation.width
                let verticalDominant = abs(vertical) > abs(horizontal) * 1.35
                let predictedDominant = abs(predicted) > abs(predictedHorizontal) * 1.35
                let shouldSwitch = verticalDominant
                    && (abs(vertical) > 60 || (predictedDominant && abs(predicted) > 140))
                guard shouldSwitch else {
                    bounceCover(up: vertical < 0)
                    return
                }
                if vertical < 0 { nextFromCover() } else { previousFromCover() }
            }
    }

    private func pageSwipeBlocked(at start: CGPoint) -> Bool {
        pageSwipeState.excluded ?? gestureStartsInExcludedZone(start)
    }

    private func gestureStartsInExcludedZone(_ point: CGPoint) -> Bool {
        // The sheet header/dismiss strip is the first 80pt of this page.
        if point.y < 80 { return true }
        // The progress slider is the only horizontal control on this screen;
        // there is no volume slider or horizontal carousel. Any future control
        // that must own horizontal drags uses `playerExclusionZone()`.
        return exclusionFrames.contains { $0.contains(point) }
    }

    private func nextFromCover() {
        guard !player.queue.isEmpty else { return }
        let canAdvance = player.shuffled || player.repeatMode == 1 || player.currentIndex < player.queue.count - 1
        guard canAdvance else {
            bounceCover(up: true)
            return
        }
        moveCover(direction: -1) { await player.next() }
    }

    private func previousFromCover() {
        guard !player.queue.isEmpty else { return }
        if !player.shuffled && player.currentIndex == 0 {
            bounceCover(up: false)
            player.restartCurrent()
            return
        }
        moveCover(direction: 1) { await player.previous() }
    }

    private func moveCover(direction: CGFloat, action: @escaping () async -> Void) {
        coverSwitching = true
        withAnimation(.easeOut(duration: 0.16)) {
            coverOffset = direction * coverSize * 0.55
            coverOpacity = 0
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            let before = player.current?.id
            await action()
            let changed = player.current?.id != before
            coverOffset = -direction * coverSize * 0.38
            coverOpacity = 0
            // Let the new artwork identity commit at the incoming edge before
            // animating it into place.
            try? await Task.sleep(for: .milliseconds(16))
            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                coverOffset = 0
                coverOpacity = 1
            }
            if changed {
                let feedback = UIImpactFeedbackGenerator(style: .light)
                feedback.impactOccurred()
            }
            coverSwitching = false
        }
    }

    private func bounceCover(up: Bool) {
        guard !coverSwitching else { return }
        // A horizontal or tap-like gesture never moved the cover, so there is
        // nothing to spring back from.
        guard abs(coverOffset) > 1 else { return }
        coverSwitching = true
        withAnimation(.easeOut(duration: 0.12)) {
            coverOffset = up ? -24 : 24
            coverOpacity = 0.86
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(110))
            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                coverOffset = 0
                coverOpacity = 1
            }
            coverSwitching = false
        }
    }

    private var playerHeader: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 3) {
                Text("正在播放").font(.system(size: 13, weight: .semibold))
                Text(player.current?.album ?? "阿噗音乐").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 55)
            .frame(maxWidth: .infinity)

            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold))
                    .frame(width: 48, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起播放器")
            .accessibilityIdentifier("收起播放器")
        }
        .frame(height: 52)
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 44).onEnded { gesture in
            guard gesture.translation.height > 110,
                  gesture.translation.height > abs(gesture.translation.width) * 1.15 else { return }
            dismiss()
        })
    }
    private var isFavorite: Bool { player.current.map(favorites.contains) ?? false }
    private func toggleFavorite() {
        guard let track = player.current else { return }
        favorites.toggle(track)
    }
}

struct DownloadedScreen: View {
    var openPlayer: () -> Void
    @EnvironmentObject private var player: Player
    @State private var items = DownloadStore.tracks
    var body: some View {
        List {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                TrackRow(track: item.track, index: index + 1) {
                    player.setQueue(items.map(\.track), start: item.track)
                    openPlayer()
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
            .onDelete { offsets in
                for index in offsets { DownloadStore.remove(items[index]) }
                items = DownloadStore.tracks
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Color.black)
        .navigationTitle("已下载").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        .onAppear { items = DownloadStore.tracks }
    }
}

struct PlayingLyrics: View {
    @ObservedObject var lyrics: PlaybackLyrics

    var body: some View {
        if lyrics.lines.isEmpty {
            Text(lyrics.text.isEmpty ? "暂无歌词" : lyrics.text)
                .font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                            let active = index == lyrics.currentIndex
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: active ? 19 : 15, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? .white : .secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .id(index)
                        }
                    }.padding(.vertical, 30)
                }
                .frame(height: 150)
                .onAppear { proxy.scrollTo(lyrics.currentIndex, anchor: .center) }
                .onChange(of: lyrics.currentIndex) { index in
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
        }
    }
}

struct PlaybackProgressControls: View {
    @ObservedObject var progress: PlaybackProgress
    var seek: (Double) -> Void
    private let accent = ApuTheme.accent

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { progress.timing.position }, set: seek),
                   in: 0...max(progress.timing.duration, 1))
                .tint(accent)
            HStack {
                Text(time(progress.timing.position)).accessibilityIdentifier("已播放时间")
                Spacer()
                Text("-\(time(max(0, progress.timing.duration - progress.timing.position)))")
            }
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(.secondary)
        }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        return "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))"
    }
}

struct TrackRow: View {
    var track: Track
    var index: Int
    var active = false
    var action: () -> Void
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var favorites: FavoriteLibrary
    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 11) {
                Artwork(url: track.artwork, size: 42, thumbnailURL: track.thumbnail)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.song).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text(track.singer).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if let album = track.album, !album.isEmpty {
                        Text(album).font(.system(size: 11)).foregroundStyle(Color.gray).lineLimit(1)
                    }
                }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!track.canPlay)
            .accessibilityIdentifier("歌曲-\(track.song)")
            if let seconds = track.duration, seconds > 0 {
                Text("\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.tertiary)
            }
            Button { downloads.download(track) } label: {
                if let progress = downloads.progress[track.id] {
                    if downloads.preparing.contains(track.id) { ProgressView() }
                    else { ProgressView(value: progress).frame(width: 21) }
                } else if downloads.errors[track.id] != nil {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 15)).foregroundStyle(Color.orange)
                } else {
                    Image(systemName: DownloadStore.localURL(for: track) == nil ? "arrow.down.to.line" : "checkmark.circle.fill")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 44)
            .buttonStyle(.plain)
            .disabled(!track.canPlay || DownloadStore.localURL(for: track) != nil)
            .accessibilityLabel("下载\(track.song)")
            Menu {
                Button { addFavorite() } label: { Label(favorites.contains(track) ? "从喜欢的歌曲移除" : "加入喜欢的歌曲", systemImage: "heart") }
                ForEach(LibraryStore.playlists) { playlist in
                    Button(playlist.name) { addToPlaylist(playlist) }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 30, height: 40)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 64)
        .foregroundStyle(track.canPlay ? .white : .secondary)
    }
    private func addFavorite() {
        favorites.toggle(track)
    }
    private func addToPlaylist(_ playlist: LocalPlaylist) {
        var items = LibraryStore.playlists
        guard let index = items.firstIndex(where: { $0.id == playlist.id }) else { return }
        if !items[index].tracks.contains(track) { items[index].tracks.append(track); LibraryStore.playlists = items }
    }
}

struct FeaturedTrack: View {
    var track: Track
    var body: some View {
        HStack(spacing: 10) {
            Artwork(url: track.artwork, size: 58, thumbnailURL: track.thumbnail)
            VStack(alignment: .leading, spacing: 5) {
                Text(track.song).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text(track.singer).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxWidth: .infinity, minHeight: 74)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .opacity(track.canPlay ? 1 : 0.48)
    }
}

struct Artwork: View {
    var url: URL?
    var size: CGFloat
    var thumbnailURL: URL? = nil
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.09)
                    Image(systemName: "waveform")
                        .font(.system(size: size * 0.32))
                        .foregroundStyle(ApuTheme.accent)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .task(id: url) {
            image = nil
            guard let url else { return }
            let thumbnail = await ArtworkCache.shared.image(for: thumbnailURL ?? url,
                                                              pixelSize: Int((size * UIScreen.main.scale).rounded()))
            if !Task.isCancelled { image = thumbnail }
        }
    }
}

struct PlaylistArtwork: View {
    var url: URL?
    var tracks: [Track]
    var size: CGFloat

    var body: some View {
        Group {
            if let url {
                Artwork(url: url, size: size, thumbnailURL: url)
            } else if let firstCover = tracks.first(where: { $0.artwork != nil })?.artwork {
                Artwork(url: firstCover, size: size, thumbnailURL: tracks.first(where: { $0.artwork != nil })?.thumbnail)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "music.note.list").font(.system(size: size * 0.23, weight: .light))
                    Text("歌单").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color.gray)
                .frame(width: size, height: size)
                .background(Color(white: 0.09))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

struct TrackSkeletonRow: View {
    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.09)).frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.12)).frame(width: 178, height: 11)
                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.07)).frame(width: 116, height: 9)
            }
            Spacer()
        }
        .frame(height: 64)
        .accessibilityHidden(true)
    }
}
