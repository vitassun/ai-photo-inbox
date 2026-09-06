// MARK: - MediaPreviewView
// 统一的照片、视频和 Live Photo 预览。预览只读且禁止主动下载 iCloud 原件；
// 加载失败提供重试入口，避免详情页把空白缩略图误当成资产消失。

import SwiftUI
import Photos
import PhotosUI
import AVKit

struct MediaPreviewView: View {
    let localIdentifier: String
    let mediaType: AssetMediaType
    let isLivePhoto: Bool

    @State private var image: UIImage?
    @State private var livePhoto: PHLivePhoto?
    @State private var player: AVPlayer?
    @State private var failed = false
    @State private var loadToken = UUID()

    var body: some View {
        ZStack {
            Color(.systemBackground)
            if let livePhoto {
                LivePhotoPreview(livePhoto: livePhoto)
                    .padding()
            } else if let player {
                VideoPlayer(player: player)
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }
            } else if let image {
                ZoomablePhoto(image: image)
            } else if failed {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("无法加载预览")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Button("重试") { retry() }
                        .buttonStyle(.bordered)
                }
            } else {
                ProgressView()
            }
        }
        .id(loadToken)
        .onAppear(perform: load)
        .accessibilityLabel(isLivePhoto ? "Live Photo 预览" : (mediaType == .video ? "视频预览" : "照片预览"))
    }

    private func retry() {
        image = nil
        livePhoto = nil
        player = nil
        failed = false
        loadToken = UUID()
        load()
    }

    private func load() {
        guard image == nil, livePhoto == nil, player == nil, !failed else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [localIdentifier], options: nil
            ).firstObject else {
                DispatchQueue.main.async { self.failed = true }
                return
            }
            if isLivePhoto {
                let options = PHLivePhotoRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = false
                PHImageManager.default().requestLivePhoto(
                    for: asset,
                    targetSize: CGSize(width: 1600, height: 1600),
                    contentMode: .aspectFit,
                    options: options
                ) { photo, _ in
                    DispatchQueue.main.async {
                        if let photo { self.livePhoto = photo } else { self.failed = true }
                    }
                }
            } else if mediaType == .video {
                let options = PHVideoRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = false
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                    DispatchQueue.main.async {
                        if let avAsset {
                            self.player = AVPlayer(playerItem: AVPlayerItem(asset: avAsset))
                        } else {
                            self.failed = true
                        }
                    }
                }
            } else {
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = false
                options.isSynchronous = true
                var delivered: UIImage?
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: 1600, height: 1600),
                    contentMode: .aspectFit,
                    options: options
                ) { img, _ in delivered = img }
                DispatchQueue.main.async {
                    if let delivered { self.image = delivered } else { self.failed = true }
                }
            }
        }
    }
}

/// 大图预览支持双指缩放和双击放大；缩放状态只存在于当前查看器，
/// 不会把临时图片数据或用户相册内容写入本地存储。
private struct ZoomablePhoto: View {
    let image: UIImage

    @State private var scale: CGFloat = 1
    @GestureState private var pinchScale: CGFloat = 1

    private var effectiveScale: CGFloat {
        min(max(scale * pinchScale, 1), 4)
    }

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(effectiveScale)
                .frame(minWidth: 1, minHeight: 1)
                .padding()
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .updating($pinchScale) { value, state, _ in
                            state = value
                        }
                        .onEnded { value in
                            scale = min(max(scale * value, 1), 4)
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scale = scale > 1 ? 1 : 2
                    }
                }
        }
        .accessibilityLabel("照片预览，可双指缩放")
    }
}

private struct LivePhotoPreview: UIViewRepresentable {
    let livePhoto: PHLivePhoto

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        view.livePhoto = livePhoto
        view.startPlayback(with: .full)
    }
}
