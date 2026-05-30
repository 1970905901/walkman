import SwiftUI
import UIKit
import Combine

// MARK: - Tokens

enum DS {
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }
    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 18
        static let xlarge: CGFloat = 28
    }
    enum Typography {
        static let largeTitle = Font.system(size: 32, weight: .heavy, design: .rounded)
        static let sectionTitle = Font.system(size: 22, weight: .bold, design: .rounded)
        static let trackTitle = Font.system(size: 16, weight: .semibold)
        static let trackSubtitle = Font.system(size: 13, weight: .regular)
        static let chip = Font.system(size: 11, weight: .semibold)
    }
}

// MARK: - Source theming

extension SourceID {
    var tint: Color {
        switch self {
        case .kw: return Color(red: 0.95, green: 0.43, blue: 0.30)   // 橙
        case .kg: return Color(red: 0.10, green: 0.69, blue: 0.94)   // 蓝
        case .tx: return Color(red: 0.20, green: 0.80, blue: 0.55)   // 绿
        case .wy: return Color(red: 0.95, green: 0.27, blue: 0.32)   // 红
        case .mg: return Color(red: 0.95, green: 0.54, blue: 0.10)   // 橙黄
        case .local: return Color(.systemGray)
        }
    }
}

// MARK: - Source chip

struct SourceChip: View {
    let source: SourceID
    var body: some View {
        Text(source.displayName)
            .font(DS.Typography.chip)
            .foregroundColor(source.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(source.tint.opacity(0.14))
            )
    }
}

// MARK: - Horizontal chip selector

/// A horizontally-scrolling row of selectable pills. Use when there are too many options
/// for a segmented control (e.g. 4 platforms, or 5 sort categories).
struct ChipBar<T: Hashable>: View {
    let items: [T]
    let title: (T) -> String
    @Binding var selection: T

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    let on = item == selection
                    Text(title(item))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(on ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(on ? Color.accentColor : Color(.secondarySystemBackground))
                        )
                        .contentShape(Capsule())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) { selection = item }
                        }
                }
            }
            .padding(.horizontal, DS.Spacing.l)
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Quality badge

/// Mirrors lx-music-mobile's `useQualityTag` (components/OnlineList/ListItem.tsx#15):
/// pick the highest available quality and render it as a coloured pill.
/// Returns nil for 128k (no badge in the official UI).
enum QualityBadgeStyle {
    case hires      // flac24bit
    case lossless   // flac
    case hq         // 320k
    case sq         // 128k (rendered only when forced, e.g. in player)

    var label: String {
        switch self {
        case .hires:    return "Hi-Res"
        case .lossless: return "SQ"
        case .hq:       return "HQ"
        case .sq:       return "STD"
        }
    }
    var tint: Color {
        switch self {
        case .hires:    return Color(red: 0.85, green: 0.62, blue: 0.13)  // 金
        case .lossless: return Color(red: 0.40, green: 0.30, blue: 0.85)  // 紫
        case .hq:       return Color(red: 0.10, green: 0.55, blue: 0.42)  // 青绿
        case .sq:       return Color(.systemGray)
        }
    }
    init?(highestIn qualities: [Quality]) {
        if qualities.contains(.flac24) { self = .hires }
        else if qualities.contains(.flac) { self = .lossless }
        else if qualities.contains(.k320) { self = .hq }
        else { return nil }   // 128k or empty → no badge in list rows
    }
    init(quality: Quality) {
        switch quality {
        case .flac24: self = .hires
        case .flac:   self = .lossless
        case .k320:   self = .hq
        case .k128:   self = .sq
        }
    }
}

struct QualityBadge: View {
    let style: QualityBadgeStyle
    var body: some View {
        Text(style.label)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .foregroundColor(style.tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(style.tint, lineWidth: 1)
            )
    }
}

// MARK: - Artwork view

struct Artwork: View {
    let url: String?
    var size: CGFloat = 50
    var radius: CGFloat = DS.Radius.small

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFill()
            default:
                LinearGradient(
                    colors: [Color(.tertiarySystemFill), Color(.quaternarySystemFill)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.4, weight: .medium))
                        .foregroundColor(.secondary)
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Loading placeholder
//
// We bridge `UIActivityIndicatorView` directly instead of using SwiftUI's
// `ProgressView()`. On iOS 26 the latter is rendered as an indeterminate linear
// capsule (even with `.progressViewStyle(.circular)`), which combined with our
// `maxWidth: .infinity` produced a bar stretching edge to edge. The UIKit
// indicator has a fixed intrinsic size and is always a circular spinner.
struct UIKitSpinner: UIViewRepresentable {
    var style: UIActivityIndicatorView.Style = .medium
    var color: UIColor? = nil

    func makeUIView(context: Context) -> UIActivityIndicatorView {
        let v = UIActivityIndicatorView(style: style)
        v.hidesWhenStopped = false
        if let color { v.color = color }
        v.startAnimating()
        return v
    }
    func updateUIView(_ uiView: UIActivityIndicatorView, context: Context) {
        uiView.startAnimating()
    }
}

struct LoadingPlaceholder: View {
    var label: LocalizedStringKey?
    var topPadding: CGFloat = 60

    var body: some View {
        VStack(spacing: 10) {
            UIKitSpinner(style: .medium)
            if let label {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, topPadding)
    }
}

// MARK: - Pretty card for grid items

struct GridCard<Content: View>: View {
    let content: () -> Content
    var body: some View {
        content()
            .padding(DS.Spacing.m)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.large, style: .continuous))
    }
}

// MARK: - Color extraction from album art for player background

@MainActor
final class ArtworkColors: ObservableObject {
    @Published var primary: Color = .accentColor
    @Published var secondary: Color = Color(.systemBackground)

    private var inflightURL: String?

    func extract(from url: String?) {
        guard let url, url != inflightURL else { return }
        inflightURL = url
        guard let u = URL(string: url) else { return }
        Task.detached { [weak self] in
            guard let data = try? Data(contentsOf: u),
                  let img = UIImage(data: data) else { return }
            let cols = ArtworkColors.dominantColors(from: img)
            await MainActor.run { [weak self] in
                guard let self else { return }
                withAnimation(.easeInOut(duration: 0.6)) {
                    self.primary = cols.primary
                    self.secondary = cols.secondary
                }
            }
        }
    }

    func reset() {
        inflightURL = nil
        withAnimation { primary = .accentColor; secondary = Color(.systemBackground) }
    }

    nonisolated static func dominantColors(from image: UIImage) -> (primary: Color, secondary: Color) {
        // Downsample heavily and average top quadrants for two distinct colors.
        let target = CGSize(width: 24, height: 24)
        UIGraphicsBeginImageContextWithOptions(target, true, 1)
        image.draw(in: CGRect(origin: .zero, size: target))
        let small = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        guard let cg = small?.cgImage,
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return (.accentColor, Color(.systemBackground))
        }
        let bpp = cg.bitsPerPixel / 8
        let bpr = cg.bytesPerRow
        var topR = 0, topG = 0, topB = 0, topN = 0
        var botR = 0, botG = 0, botB = 0, botN = 0
        let h = cg.height, w = cg.width
        for y in 0..<h {
            for x in 0..<w {
                let p = bytes + y * bpr + x * bpp
                let r = Int(p[0]); let g = Int(p[1]); let b = Int(p[2])
                if y < h / 2 { topR += r; topG += g; topB += b; topN += 1 }
                else { botR += r; botG += g; botB += b; botN += 1 }
            }
        }
        guard topN > 0, botN > 0 else { return (.accentColor, Color(.systemBackground)) }
        let primary = Color(red: Double(topR) / Double(topN) / 255,
                            green: Double(topG) / Double(topN) / 255,
                            blue: Double(topB) / Double(topN) / 255)
        let secondary = Color(red: Double(botR) / Double(botN) / 255,
                              green: Double(botG) / Double(botN) / 255,
                              blue: Double(botB) / Double(botN) / 255)
        return (primary, secondary)
    }
}

// MARK: - Background gradient for the player

struct PlayerBackdrop: View {
    let primary: Color
    let secondary: Color
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [primary, secondary, Color.black.opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            )
            // Soft noise / depth
            Color.black.opacity(0.15)
        }
        .ignoresSafeArea()
    }
}
