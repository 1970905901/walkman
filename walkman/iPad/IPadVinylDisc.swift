import SwiftUI

// MARK: - iPad vinyl disc (彩胶 / colored translucent gel)
struct IPadVinylDisc: View {
    let imageURL: String?
    let isPlaying: Bool
    /// 彩胶染色
    var vinylTint: Color = .blue // 替换为你的真实颜色 DS.Palette.brandStart
    var size: CGFloat = 520
    /// 播放进度 0...1
    var progress: Double = 0

    @State private var angle: Double = 0
    @State private var lastTickAt: Date = Date()
    @State private var ticker: Timer?

    /// Disc 实际直径(去掉外圈光晕的空间)
    private var discSize: CGFloat { size * 0.82 }
    /// 封面圆形大小(嵌在唱片中心)
    private var coverSize: CGFloat { discSize * 0.55 }

    // MARK: - 唱针关键参数
    /// 唱针总扫过角度：改成负数（-18度），实现从外圈向内圈的逆时针优雅推进
    private let armSweepDegrees: Double = -18

    var body: some View {
        ZStack {
            // 1. 外圈染色光晕(染色 bloom)
            bloom

            // 2. 唱片本体 + 封面 — 一起旋转
            ZStack {
                discBody
                cover
            }
            .frame(width: discSize, height: discSize)
            .rotationEffect(.degrees(angle))

            // 3. 顶部 glossy 反光 — 不旋转
            glossyHighlight
                .frame(width: discSize, height: discSize)
                .blendMode(.screen)
                .allowsHitTesting(false)

            // 4. 中心轴孔 — 不旋转
            spindle
            
            // 5. 优雅的长唱针 — 放在最上层，轴心对齐 (0.92, 0.08)
            tonearmCanvas
                .frame(width: size, height: size)
                .rotationEffect(
                    .degrees(armSweepDegrees * max(0, min(1, progress))),
                    anchor: UnitPoint(x: 0.92, y: 0.08)
                )
                .allowsHitTesting(false)
                .zIndex(10)
        }
        .frame(width: size, height: size)
        .onAppear {
            if isPlaying { startTicker() }
        }
        .onDisappear { stopTicker() }
        .onChange(of: isPlaying) { _, newPlaying in
            if newPlaying {
                startTicker()
            } else {
                stopTicker()
            }
        }
    }

    // MARK: - Disc body
    private var discBody: some View {
        Canvas { ctx, sz in
            let center = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let outer = min(sz.width, sz.height) / 2
            let inner = outer * 0.55 + 4

            // 1. 染色 base
            ctx.fill(
                Path(ellipseIn: CGRect(x: 0, y: 0, width: sz.width, height: sz.height)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: vinylTint.opacity(0.85), location: 0.0),
                        .init(color: vinylTint.opacity(0.70), location: 0.5),
                        .init(color: vinylTint.opacity(0.55), location: 0.85),
                        .init(color: vinylTint.opacity(0.45), location: 1.0),
                    ]),
                    center: center,
                    startRadius: 0,
                    endRadius: outer
                )
            )

            // 2. 沟槽
            let grooveCount = 48
            for i in 0..<grooveCount {
                let frac = CGFloat(i) / CGFloat(grooveCount - 1)
                let r = inner + (outer - inner - 4) * frac
                let alpha = 0.18 + 0.10 * Double(i % 5) / 5.0
                let w: CGFloat = (i % 8 == 0) ? 1.3 : 0.55
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                    with: .color(.black.opacity(alpha)),
                    lineWidth: w
                )
            }

            // 3. 标签环
            let labelOuter = inner + 2
            ctx.stroke(
                Path(ellipseIn: CGRect(x: center.x - labelOuter, y: center.y - labelOuter, width: labelOuter * 2, height: labelOuter * 2)),
                with: .color(.white.opacity(0.55)),
                lineWidth: 2
            )

            // 4. 内圈边界
            ctx.stroke(
                Path(ellipseIn: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2)),
                with: .color(.black.opacity(0.35)),
                lineWidth: 1
            )

            // 5. 外沿镜面边
            ctx.stroke(
                Path(ellipseIn: CGRect(x: 1.5, y: 1.5, width: sz.width - 3, height: sz.height - 3)),
                with: .color(.white.opacity(0.45)),
                lineWidth: 2.5
            )
            ctx.stroke(
                Path(ellipseIn: CGRect(x: 4, y: 4, width: sz.width - 8, height: sz.height - 8)),
                with: .color(.black.opacity(0.25)),
                lineWidth: 0.8
            )
        }
    }

    // MARK: - Cover
    private var cover: some View {
        Group {
            if let urlStr = imageURL, let url = URL(string: urlStr) {
                AsyncImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    coverPlaceholder
                }
            } else {
                coverPlaceholder
            }
        }
        .frame(width: coverSize, height: coverSize)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(.black.opacity(0.4), lineWidth: 2)
                .blur(radius: 1)
        )
        .overlay(
            Circle()
                .stroke(.white.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
    }

    private var coverPlaceholder: some View {
        LinearGradient(
            colors: [vinylTint.opacity(0.6), vinylTint.opacity(0.25)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "music.note")
                .font(.system(size: coverSize * 0.3, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        )
    }

    // MARK: - Bloom
    private var bloom: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        vinylTint.opacity(0.65),
                        vinylTint.opacity(0.35),
                        vinylTint.opacity(0.10),
                        .clear,
                    ],
                    center: .center,
                    startRadius: discSize * 0.35,
                    endRadius: size * 0.55
                )
            )
            .blur(radius: 22)
            .frame(width: size, height: size)
    }

    // MARK: - Glossy highlight
    private var glossyHighlight: some View {
        ZStack {
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.10), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: discSize * 1.05, height: discSize * 0.55)
                .offset(y: -discSize * 0.22)
                .rotationEffect(.degrees(-15))
                .blur(radius: 8)

            Circle()
                .fill(.white.opacity(0.35))
                .frame(width: discSize * 0.22, height: discSize * 0.22)
                .offset(x: -discSize * 0.22, y: -discSize * 0.30)
                .blur(radius: 18)
        }
        .mask(Circle())
    }

    // MARK: - Spindle
    private var spindle: some View {
        ZStack {
            Circle()
                .fill(.black)
                .frame(width: 16, height: 16)
            Circle()
                .stroke(.white.opacity(0.45), lineWidth: 0.6)
                .frame(width: 16, height: 16)
        }
    }

    // MARK: - Tonearm (精心优化的长唱针绘制)
    private var tonearmCanvas: some View {
        Canvas { ctx, sz in
            // 保持与外层 UnitPoint(0.92, 0.08) 绝对一致的旋转基准点
            let pivot = CGPoint(x: sz.width * 0.92, y: sz.height * 0.08)
            
            // L形短边：向下稍微延伸，形成机械转轴基座感
            let bend = CGPoint(x: pivot.x, y: pivot.y + sz.height * 0.07)
            
            // 核心修改：重新指定 progress = 0 时针尖（stylus）的静态坐标
            // 将其拉长至唱片左上方（约 11 点钟方向的沟槽最外圈），使整个唱针极其修长、逼真
            let stylus = CGPoint(x: sz.width * 0.43, y: sz.height * 0.11)

            // 1. 绘制阴影（给唱针整体加一个右下方的软阴影，增强立体感）
            var shadowRod = Path()
            shadowRod.move(to: CGPoint(x: pivot.x + 4, y: pivot.y + 6))
            shadowRod.addLine(to: CGPoint(x: bend.x + 4, y: bend.y + 6))
            shadowRod.addLine(to: CGPoint(x: stylus.x + 4, y: stylus.y + 6))
            ctx.stroke(shadowRod, with: .color(.black.opacity(0.25)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))

            // 2. pivot 底座
            let pivotR: CGFloat = sz.width * 0.028
            ctx.fill(
                Path(ellipseIn: CGRect(x: pivot.x - pivotR, y: pivot.y - pivotR, width: pivotR * 2, height: pivotR * 2)),
                with: .linearGradient(
                    Gradient(colors: [.white, .init(white: 0.8)]),
                    startPoint: CGPoint(x: pivot.x - pivotR, y: pivot.y - pivotR),
                    endPoint: CGPoint(x: pivot.x + pivotR, y: pivot.y + pivotR)
                )
            )
            ctx.stroke(Path(ellipseIn: CGRect(x: pivot.x - pivotR, y: pivot.y - pivotR, width: pivotR * 2, height: pivotR * 2)), with: .color(.black.opacity(0.15)), lineWidth: 0.5)
            
            ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - 4, y: pivot.y - 4, width: 8, height: 8)), with: .color(.init(white: 0.2)))

            // 3. 唱针金属杆 (使用更高级的银白色双层描边模拟金属高光质感)
            var rod = Path()
            rod.move(to: pivot)
            rod.addLine(to: bend)
            rod.addLine(to: stylus)
            
            // 底层深色粗边
            ctx.stroke(rod, with: .color(.init(white: 0.6)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            // 表层白色高光细边
            ctx.stroke(rod, with: .color(.white), style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))

            // 4. Cartridge (唱头 - 顺应长杆方向做水平长方形微调)
            let cartW: CGFloat = 20, cartH: CGFloat = 10
            let cartRect = CGRect(
                x: stylus.x - cartW + 2,
                y: stylus.y - cartH / 2,
                width: cartW, height: cartH
            )
            ctx.fill(Path(roundedRect: cartRect, cornerSize: CGSize(width: 1, height: 1)), with: .color(.init(white: 0.95)))
            ctx.stroke(Path(roundedRect: cartRect, cornerSize: CGSize(width: 1, height: 1)), with: .color(.black.opacity(0.2)), lineWidth: 0.5)
            
            // 唱头标志红点
            ctx.fill(Path(ellipseIn: CGRect(x: cartRect.minX + 4, y: cartRect.midY - 1.5, width: 3, height: 3)), with: .color(.red.opacity(0.8)))

            // 5. Stylus 针尖
            ctx.fill(Path(ellipseIn: CGRect(x: stylus.x - 2, y: stylus.y - 2, width: 4, height: 4)), with: .color(.black.opacity(0.8)))
        }
    }

    // MARK: - Rotation ticker
    private func startTicker() {
        stopTicker()
        lastTickAt = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            let now = Date()
            let dt = now.timeIntervalSince(lastTickAt)
            lastTickAt = now
            angle += dt * 12.0
            if angle >= 360 { angle -= 360 }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
