import AppKit
import AVFoundation
import MediaPlayer

/// Tiny toolbar music player: double-click a song to play the list it's in.
@MainActor
@Observable
final class MusicPlayer {
    static let shared = MusicPlayer()

    var queue: [FileItem] = []
    var index = 0
    var isPlaying = false
    var position: Double = 0
    var duration: Double = 0
    var title = ""
    var artist = ""
    var artwork: NSImage?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var remoteReady = false

    var current: FileItem? { queue.indices.contains(index) ? queue[index] : nil }
    var progress: Double { duration > 0 ? min(1, position / duration) : 0 }

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { t in
            MainActor.assumeIsolated {
                let p = MusicPlayer.shared
                p.position = t.seconds.isFinite ? t.seconds : 0
                if let d = p.player.currentItem?.duration.seconds, d.isFinite { p.duration = d }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MusicPlayer.shared.next(auto: true) }
        }
    }

    func play(_ item: FileItem, in list: [FileItem]) {
        let songs = list.filter { $0.category == .music }
        queue = songs.isEmpty ? [item] : songs
        index = queue.firstIndex { $0.id == item.id } ?? 0
        load()
        setupRemoteCommands()
    }

    private func load() {
        guard let item = current else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: item.url))
        player.play()
        isPlaying = true
        position = 0
        duration = item.duration ?? 0
        title = item.baseName
        artist = ""
        artwork = nil
        let url = item.url
        Task {
            let asset = AVURLAsset(url: url)
            guard let md = try? await asset.load(.commonMetadata) else { return }
            var t: String?, a: String?, art: NSImage?
            if let i = AVMetadataItem.metadataItems(from: md, filteredByIdentifier: .commonIdentifierTitle).first {
                t = try? await i.load(.stringValue)
            }
            if let i = AVMetadataItem.metadataItems(from: md, filteredByIdentifier: .commonIdentifierArtist).first {
                a = try? await i.load(.stringValue)
            }
            if let i = AVMetadataItem.metadataItems(from: md, filteredByIdentifier: .commonIdentifierArtwork).first,
               let data = try? await i.load(.dataValue) {
                art = NSImage(data: data)
            }
            guard self.current?.url == url else { return }
            if let t, !t.isEmpty { self.title = t }
            self.artist = a ?? ""
            self.artwork = art
            self.updateNowPlaying()
        }
        updateNowPlaying()
    }

    func toggle() {
        guard current != nil else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
        updateNowPlaying()
    }

    func next(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            index += 1
            load()
        } else if auto {
            isPlaying = false
            player.pause()
            player.seek(to: .zero)
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if position > 3 || index == 0 {
            player.seek(to: .zero)
        } else {
            index -= 1
            load()
        }
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: fraction * duration, preferredTimescale: 600))
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private func setupRemoteCommands() {
        guard !remoteReady else { return }
        remoteReady = true
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { _ in
            DispatchQueue.main.async { MusicPlayer.shared.toggle() }; return .success
        }
        c.playCommand.addTarget { _ in
            DispatchQueue.main.async { if !MusicPlayer.shared.isPlaying { MusicPlayer.shared.toggle() } }; return .success
        }
        c.pauseCommand.addTarget { _ in
            DispatchQueue.main.async { if MusicPlayer.shared.isPlaying { MusicPlayer.shared.toggle() } }; return .success
        }
        c.nextTrackCommand.addTarget { _ in
            DispatchQueue.main.async { MusicPlayer.shared.next() }; return .success
        }
        c.previousTrackCommand.addTarget { _ in
            DispatchQueue.main.async { MusicPlayer.shared.previous() }; return .success
        }
    }
}
