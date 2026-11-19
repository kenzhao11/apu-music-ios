import SwiftUI

@main
struct ApuMusicApp: App {
    @StateObject private var player = Player()
    var body: some Scene {
        WindowGroup { MusicShell().environmentObject(player).preferredColorScheme(.dark) }
    }
}

struct MusicShell: View {
    @EnvironmentObject private var player: Player
    @State private var selectedTab = 0
    @State private var playerPresented = false
    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case 0: HomeScreen(openPlayer: { playerPresented = true })
                case 1: SearchScreen(openPlayer: { playerPresented = true })
                default: LibraryScreen(openPlayer: { playerPresented = true })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if player.current != nil {
                HStack(spacing: 12) {
                    Button { playerPresented = true } label: {
                        HStack(spacing: 12) {
                        Artwork(url: player.current?.artwork, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(player.current?.song ?? "").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text(player.current?.singer ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        }.foregroundStyle(.white)
                    }.buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Button { Task { await player.previous() } } label: { Image(systemName: "backward.end.fill") }
                    Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                        .frame(width: 42, height: 42)
                    Button { Task { await player.next() } } label: { Image(systemName: "forward.end.fill") }
                }
                .font(.system(size: 18)).foregroundStyle(.white).padding(.horizontal, 18).frame(height: 64)
                .background(Color(uiColor: .secondarySystemBackground))
                .buttonStyle(.plain)
            }
            HStack(spacing: 0) {
                tab("house.fill", "首页", 0)
                tab("magnifyingglass", "搜索", 1)
                tab("square.stack.fill", "我的收藏", 2)
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
            .background(Color(uiColor: .systemBackground))
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $playerPresented) { NowPlayingScreen().environmentObject(player) }
    }
    private func tab(_ icon: String, _ title: String, _ index: Int) -> some View {
        Button { selectedTab = index } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 19, weight: .medium))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(selectedTab == index ? Color(red: 0.60, green: 0.88, blue: 0.52) : .secondary)
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
    @EnvironmentObject private var player: Player
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    HStack(spacing: 10) {
                        Image(systemName: "sun.max.fill").foregroundStyle(Color(red: 0.72, green: 0.92, blue: 0.56))
                        Text(Date.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).capitalized)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                    sectionTitle("为你精选", trailing: "全部")
                    LazyVGrid(columns: columns, spacing: 15) {
                        ForEach(Array(tracks.prefix(8))) { track in
                            Button { player.setQueue(tracks, start: track); openPlayer() } label: { FeaturedTrack(track: track) }
                                .buttonStyle(.plain)
                        }
                    }
                    if !playlists.isEmpty {
                        sectionTitle("为你挑选的歌单", trailing: "")
                        ScrollView(.horizontal) {
                            HStack(spacing: 14) {
                                ForEach(playlists) { playlist in
                                    NavigationLink { PlaylistScreen(id: playlist.id, title: playlist.name, openPlayer: openPlayer) } label: {
                                        VStack(alignment: .leading, spacing: 9) {
                                            Artwork(url: playlist.cover.flatMap(URL.init(string:)), size: 164)
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
                .padding(.horizontal, 20).padding(.bottom, 30)
            }
            .refreshable { await load() }
            .task { if tracks.isEmpty { await load() } }
            .background(Color(uiColor: .systemBackground))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 7) {
                        Image("AppIcon").resizable().scaledToFit().frame(width: 22, height: 22)
                        Text("阿噗音乐").font(.system(size: 19, weight: .bold))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SearchScreen(openPlayer: openPlayer) } label: { Image(systemName: "magnifyingglass") }
                }
            }
        }
    }
    private func sectionTitle(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title).font(.system(size: 23, weight: .bold))
            Spacer()
            if !trailing.isEmpty { Button(trailing) {}.font(.system(size: 13)).foregroundStyle(.secondary) }
        }
    }
    @MainActor private func load() async {
        do {
            let home: HomeResponse = try await MusicAPI.get("recommendations/home?platform=applemusic&limit=30")
            tracks = home.tracks
            let collection: PlaylistResponse = try await MusicAPI.get("local/imported-playlists")
            playlists = collection.playlists
            error = tracks.isEmpty ? "暂时没有推荐歌曲" : ""
        } catch { error = "暂时无法加载内容，请下拉重试。" }
    }
}

struct SearchScreen: View {
    var openPlayer: () -> Void
    @EnvironmentObject private var player: Player
    @State private var query = ""
    @State private var platforms: [Platform] = []
    @State private var selectedPlatform = ""
    @State private var tracks: [Track] = []
    @State private var error = ""
    private var requestKey: String { query.trimmingCharacters(in: .whitespacesAndNewlines) + "|" + selectedPlatform }

    var body: some View {
        NavigationStack {
            ScrollView {
                if !query.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            platformButton("全部", id: "")
                            ForEach(platforms) { platform in platformButton(platform.label, id: platform.id) }
                        }.padding(.horizontal, 20)
                    }.scrollIndicators(.hidden).padding(.vertical, 12)
                }
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track, index: index + 1, active: !track.canPlay) {
                            guard track.canPlay else { return }
                            player.setQueue(tracks, start: track); openPlayer()
                        }
                    }
                }.padding(.horizontal, 18)
                if !error.isEmpty { Text(error).font(.subheadline).foregroundStyle(.secondary).padding(28) }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("搜索")
            .searchable(text: $query, prompt: "歌曲、歌手或专辑")
            .task { await loadPlatforms() }
            .task(id: requestKey) {
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { tracks = []; return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await search()
            }
        }
    }
    private func platformButton(_ title: String, id: String) -> some View {
        Button(title) { selectedPlatform = id }
            .font(.system(size: 13, weight: selectedPlatform == id ? .semibold : .regular))
            .foregroundStyle(selectedPlatform == id ? Color.black : .white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(selectedPlatform == id ? Color(red: 0.72, green: 0.92, blue: 0.56) : Color(uiColor: .secondarySystemBackground))
            .clipShape(Capsule())
    }
    private func loadPlatforms() async {
        do {
            let value: [Platform] = try await MusicAPI.get("platforms")
            platforms = value
        } catch { }
    }
    private func search() async {
        do {
            var components = URLComponents(url: MusicAPI.base.appending(path: "search"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "30")]
            if !selectedPlatform.isEmpty { components.queryItems?.append(URLQueryItem(name: "platform", value: selectedPlatform)) }
            let (data, _) = try await URLSession.shared.data(from: components.url!)
            if let list = try? JSONDecoder().decode([Track].self, from: data) { tracks = list }
            else { tracks = try JSONDecoder().decode(SearchResponse.self, from: data).tracks }
            error = tracks.isEmpty ? "没有找到歌曲" : ""
        } catch { tracks = []; error = "搜索暂时不可用" }
    }
}

struct LibraryScreen: View {
    var openPlayer: () -> Void
    @EnvironmentObject private var player: Player
    @State private var favorites = LibraryStore.favorites
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
                            .overlay(alignment: .trailing) { Text("\(favorites.count) 首").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Section("你的歌单") {
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
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemBackground))
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
    }
    private func load() async {
        favorites = LibraryStore.favorites
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
            VStack(alignment: .leading, spacing: 20) {
                if let detail {
                    HStack(spacing: 20) {
                        Artwork(url: detail.cover.flatMap(URL.init(string:)) ?? detail.items.first?.artwork, size: 132)
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
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
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
        .listStyle(.plain).scrollContentBackground(.hidden).background(Color(uiColor: .systemBackground))
        .navigationTitle(playlist.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        .onAppear { tracks = playlist.tracks }
    }
}

struct FavoriteScreen: View {
    var openPlayer: () -> Void
    @EnvironmentObject private var player: Player
    @State private var tracks: [Track] = []
    var body: some View {
        List {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, index: index + 1, active: !track.canPlay) {
                    guard track.canPlay else { return }
                    player.setQueue(tracks, start: track)
                    openPlayer()
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
            .onDelete { offsets in tracks.remove(atOffsets: offsets); LibraryStore.favorites = tracks }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("喜欢的歌曲")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        .onAppear { tracks = LibraryStore.favorites }
    }
}

struct NowPlayingScreen: View {
    @EnvironmentObject private var player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var showingLyrics = false
    @State private var showingQueue = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Capsule().fill(.white.opacity(0.25)).frame(width: 38, height: 5).padding(.top, 9)
                    Artwork(url: player.current?.artwork, size: min(UIScreen.main.bounds.width - 46, 376))
                        .padding(.top, 4)
                    HStack(spacing: 15) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(player.current?.song ?? "").font(.system(size: 22, weight: .bold)).lineLimit(2)
                            Text(player.current?.singer ?? "").font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button(action: toggleFavorite) {
                            Image(systemName: LibraryStore.favorites.contains(player.current ?? emptyTrack) ? "heart.fill" : "heart")
                                .font(.system(size: 23)).foregroundStyle(LibraryStore.favorites.contains(player.current ?? emptyTrack) ? Color.pink : .white)
                        }
                    }
                    Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
                        .tint(Color(red: 0.72, green: 0.92, blue: 0.56))
                    HStack {
                        Text(time(player.position)); Spacer(); Text("-\(time(max(0, player.duration - player.position)))")
                    }.font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary).padding(.top, -24)
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
                        Text(player.lyricText.isEmpty ? "暂无歌词" : player.lyricText)
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
                .padding(.horizontal, 23).padding(.bottom, 22)
            }
            .background(Color(uiColor: .systemBackground))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.down").font(.system(size: 15, weight: .semibold)) } }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 3) {
                        Text("正在播放").font(.system(size: 13, weight: .semibold))
                        Text(player.current?.album ?? "阿噗音乐").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .sheet(isPresented: $showingQueue) {
                NavigationStack {
                    List {
                        ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
                            Button {
                                player.setQueue(player.queue, start: track); showingQueue = false
                            } label: { TrackRow(track: track, index: index + 1, active: index == player.currentIndex) { } }
                                .foregroundStyle(.white).listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                        }.onMove(perform: player.move)
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                    .navigationTitle("播放队列").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .presentationDragIndicator(.hidden)
    }
    private var emptyTrack: Track { Track(id: "", platform: "", song: "", singer: "") }
    private func toggleFavorite() {
        guard let track = player.current else { return }
        var items = LibraryStore.favorites
        if let existing = items.firstIndex(of: track) { items.remove(at: existing) } else { items.insert(track, at: 0) }
        LibraryStore.favorites = items
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
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(active ? "♪" : "\(index)")
                    .font(.system(size: active ? 15 : 12, weight: .medium, design: .rounded))
                    .foregroundStyle(active ? Color(red: 0.72, green: 0.92, blue: 0.56) : .secondary)
                    .frame(width: 22)
                Artwork(url: track.artwork, size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.song).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Text(track.singer).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if !track.canPlay { Image(systemName: "speaker.slash").font(.system(size: 12)).foregroundStyle(.tertiary) }
                else if let seconds = track.duration, seconds > 0 {
                    Text("\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))")
                        .font(.system(size: 11, design: .rounded)).foregroundStyle(.tertiary)
                }
                Menu {
                    Button { addFavorite() } label: { Label("加入喜欢的歌曲", systemImage: "heart") }
                    ForEach(LibraryStore.playlists) { playlist in
                        Button(playlist.name) { addToPlaylist(playlist) }
                    }
                } label: { Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 32, height: 40) }
            }
            .contentShape(Rectangle())
            .foregroundStyle(track.canPlay ? .white : .secondary)
        }.buttonStyle(.plain).disabled(!track.canPlay)
    }
    private func addFavorite() {
        var items = LibraryStore.favorites
        if !items.contains(track) { items.insert(track, at: 0); LibraryStore.favorites = items }
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
            Artwork(url: track.artwork, size: 58)
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
    var body: some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
            ZStack {
                Color(red: 0.16, green: 0.19, blue: 0.17)
                Image(systemName: "waveform").font(.system(size: size * 0.32)).foregroundStyle(Color(red: 0.72, green: 0.92, blue: 0.56))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
