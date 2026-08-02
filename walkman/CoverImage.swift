import SwiftUI
import ImageIO
import UIKit

// MARK: - 封面加载与缓存
//
// SwiftUI 的 AsyncImage 没有解码后的内存缓存:每次 cell/卡片出现都会从 .empty
// 相位重新开始,先画占位图再异步加载 —— 表现为"进界面封面先空一下"。这里补一层
// 内存缓存,命中时在**同一帧**同步拿到图,不再闪。
//
// 磁盘层刻意不自己实现,交给 URLCache(容量在 walkmanApp 启动时调大):
// 各家封面 CDN 都返回 Cache-Control: max-age 与 Last-Modified,并正确响应
// If-Modified-Since(实测 gtimg / qpic 均回 304),所以过期重新校验、封面换图后
// 自动更新这些语义由 URLSession 按 HTTP 规范处理,比自己发明一套失效规则可靠。

enum CoverImageCache {

    /// 解码后的图片缓存。cost 用字节数,让 iOS 在内存紧张时按真实占用回收。
    private static let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    /// 同一张图可能在列表(小)和详情页(大)两处用,按目标像素分别缓存,
    /// 否则列表的小缩略图会被详情页复用成一张糊图。
    private static func key(_ url: String, _ maxPixel: CGFloat) -> NSString {
        "\(url)|\(Int(maxPixel))" as NSString
    }

    /// 同步查缓存 —— 命中就能在首帧直接渲染,这是"不闪"的关键。
    static func cached(_ url: String?, maxPixel: CGFloat) -> UIImage? {
        guard let url else { return nil }
        return memory.object(forKey: key(url, maxPixel))
    }

    /// 未命中时下载 + 按目标尺寸解码。网络层走 URLSession,自动吃 URLCache。
    static func load(_ url: String?, maxPixel: CGFloat) async -> UIImage? {
        guard let url, let remote = URL(string: url) else { return nil }
        if let hit = cached(url, maxPixel: maxPixel) { return hit }
        var req = URLRequest(url: remote)
        // 默认策略即可:有本地副本且未过期就直接用,过期则带 If-Modified-Since 校验
        req.cachePolicy = .useProtocolCachePolicy
        req.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let image = downsample(data, maxPixel: maxPixel) else { return nil }
        memory.setObject(image, forKey: key(url, maxPixel), cost: cost(of: image))
        return image
    }

    /// 用 ImageIO 直接解出目标尺寸的位图 —— 列表里 40pt 的缩略图不必把 600px
    /// 原图整张解进内存(那是 ~1.4MB/张),省内存也省解码时间。
    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let scale = UITraitCollection.current.displayScale
        let pixels = max(maxPixel * scale, 1)
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }

    static func clearMemory() {
        memory.removeAllObjects()
    }
}

// MARK: - 缓存总览与清理(设置页用)

enum AppCache {

    /// 当前占用:URLCache 的磁盘部分 + 小组件封面目录。
    /// 内存缓存不计入 —— 它随时会被系统回收,报给用户只会造成困惑。
    static func diskUsage() -> Int {
        URLCache.shared.currentDiskUsage + widgetCoversSize()
    }

    /// 清掉所有图片/接口缓存。歌单、下载的歌曲、脚本、设置都不受影响 ——
    /// 这里删掉的东西都能重新下载。
    static func clear() {
        URLCache.shared.removeAllCachedResponses()
        CoverImageCache.clearMemory()
        clearWidgetCovers()
    }

    private static func widgetCoversSize() -> Int {
        guard let dir = SharedAppGroup.coversDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { sum, f in
            sum + ((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private static func clearWidgetCovers() {
        guard let dir = SharedAppGroup.coversDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    static func formatted(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useKB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - 按显示尺寸挑 CDN 封面规格

enum CoverURL {
    /// 各平台封面 URL 里都带尺寸,列表却常常拿 600px 原图去画 40pt 缩略图 ——
    /// 白白多占 10 倍缓存、多花解码时间。这里按需要的像素换成就近的档位;
    /// 认不出的 URL 原样返回,绝不猜。
    static func sized(_ url: String?, maxPixel: CGFloat) -> String? {
        guard let url, !url.isEmpty else { return url }
        let want = Int(maxPixel * UITraitCollection.current.displayScale)

        // QQ 专辑图:.../T002R300x300M000<mid>.jpg,尺寸档位夹在 R 和 M 之间
        if url.contains("gtimg"), let r = url.range(of: #"(?<=T00\dR)\d+x\d+"#, options: .regularExpression) {
            let tier = pick(want, from: [90, 150, 300, 500, 800])
            return url.replacingCharacters(in: r, with: "\(tier)x\(tier)")
        }
        // QQ 歌单图:http://p.qpic.cn/music_cover/<hash>/600?n=1,尺寸是路径末段
        if url.contains("qpic.cn"), let r = url.range(of: #"(?<=/)(150|300|600|800)(?=\?|$)"#, options: .regularExpression) {
            return url.replacingCharacters(in: r, with: "\(pick(want, from: [150, 300, 600, 800]))")
        }
        // 酷狗:目录解析时把模板里的 {size} 统一填成了 240,按需要再调档
        if url.contains("kugou"), let r = url.range(of: "/240/") {
            return url.replacingCharacters(in: r, with: "/\(pick(want, from: [100, 240, 480]))/")
        }
        return url
    }

    /// 取第一个 ≥ want 的档位,没有就用最大的 —— 宁可稍大也不要糊。
    private static func pick(_ want: Int, from tiers: [Int]) -> Int {
        tiers.first { $0 >= want } ?? tiers.last ?? want
    }
}

// MARK: - 视图

/// AsyncImage 的替代品,用法一致:
/// ```
/// CoverImage(url: t.picURL, maxPixel: 56) { img in
///     img.resizable().scaledToFill()
/// } placeholder: {
///     Color.gray
/// }
/// ```
/// 与 AsyncImage 的差别:内存里已有的图在首帧同步显示,不再先闪占位图。
struct CoverImage<Content: View, Placeholder: View>: View {
    private let url: String?
    private let maxPixel: CGFloat
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var image: UIImage?

    init(url: String?,
         maxPixel: CGFloat,
         @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        let resolved = CoverURL.sized(url, maxPixel: maxPixel)
        self.url = resolved
        self.maxPixel = maxPixel
        self.content = content
        self.placeholder = placeholder
        // 关键:在 init 里同步查一次缓存,命中则首帧就有图
        _image = State(initialValue: CoverImageCache.cached(resolved, maxPixel: maxPixel))
    }

    var body: some View {
        Group {
            if let image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard image == nil else { return }
            let loaded = await CoverImageCache.load(url, maxPixel: maxPixel)
            if !Task.isCancelled { image = loaded }
        }
    }
}
