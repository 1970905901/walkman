import SwiftUI

// MARK: - iPad vinyl disc (彩胶 / colored translucent gel)
//
// 参照 QQ 音乐桌面端"透明彩胶"效果 + walkman-tv VinylDisc 思路重写。
// 关键视觉:
//   1. 大体积(~520pt),占左半屏视觉重心
//   2. 染色半透明感 — 不是黑胶,是 colored gel (透明彩胶)
//   3. 顶部 glossy 反光 (radial highlight 模拟塑料表面光泽)
//   4. 沟槽 = 浅色暗线在半透 base 上,看起来像光在沟里散射
//   5. 外圈柔光晕 (染色 bloom),延伸到唱片外
//   6. L 形唱针,自然下落角度,带阴影
//
// 渲染层级(从外到内,各层用 ZStack 叠):
//   - bloom (染色外光晕,blur 重)
//   - tonearm (画布,坐标显式)
//   - disc body + cover (一起 rotationEffect,30s/圈)
//   - glossy highlight (染色顶部反光,不旋转 — 反光是相对光源固定的)
//   - spindle (中心黑色轴孔,不旋转)

struct IPadVinylDisc: View {
    let imageURL: String?
    let isPlaying: Bool
    /// 彩胶染色 — QQ 默认 light blue,我们用从封面提取的 primary color,
    /// 但会被 saturated 处理以确保彩胶感(灰色封面会被推到更鲜艳的方向)。
    var vinylTint: Color = DS.Palette.brandStart
    var size: CGFloat = 520
    /// 播放进度 0...1。控制唱针在唱片上的位置 — 0 时唱针在最外圈(歌曲开始
    /// 落针),1 时在最内圈(歌曲结束 = 接近封面边缘)。歌曲切换时由调用方
    /// 重置为 0,这里加 withAnimation 让回弹是个连续动画而不是瞬移。
    var progress: Double = 0

    @State private var angle: Double = 0
    @State private var lastTickAt: Date = Date()
    @State private var ticker: Timer?

    /// Disc 实际直径(去掉外圈光晕的空间)
    private var discSize: CGFloat { size * 0.82 }
    /// 封面圆形大小(嵌在唱片中心)
    private var coverSize: CGFloat { discSize * 0.55 }

    var body: some View {
        ZStack {
            // 1. 外圈染色光晕(染色 bloom)
            bloom

            // 2. 唱针 — Canvas 画 progress=0 时的固定几何,然后整个 view 用
            // .rotationEffect 绕 pivot 旋转 armSweep 角。这样 arm 长度恒定。
            // pivot 在 (0.92, 0.08) — 比之前 (0.97, 0.04) 往左下移一点,让根部
            // 视觉上不那么贴边角。anchor 必须跟 Canvas 内画 pivot 的位置一致,
            // 否则旋转中心点跟视觉 pivot 不重合。
            tonearmCanvas
                .frame(width: size, height: size)
                .rotationEffect(
                    .degrees(armSweepDegrees * max(0, min(1, progress))),
                    anchor: UnitPoint(x: 0.92, y: 0.08)
                )
                .allowsHitTesting(false)
                .zIndex(10)   // 总在唱片上方

            // 3. 唱片本体 + 封面 — 一起旋转
            ZStack {
                discBody
                cover
            }
            .frame(width: discSize, height: discSize)
            .rotationEffect(.degrees(angle))

            // 4. 顶部 glossy 反光 — 不旋转(反光相对光源固定)
            //    淡白色 radial,从左上 ~30° 入射,只覆盖唱片上半
            glossyHighlight
                .frame(width: discSize, height: discSize)
                .blendMode(.screen)
                .allowsHitTesting(false)

            // 5. 中心轴孔 — 不旋转,保持锐利
            spindle
        }
        .frame(width: size, height: size)
        .onAppear {
            if isPlaying { startTicker() }
        }
        .onDisappear { stopTicker() }
        // isPlaying 切换时启停 ticker — 之前 Timer closure 捕获的是初始
        // isPlaying 值,playback.isPlaying 变化时 closure 看不到新值,导致
        // 暂停后唱片还在转。改成显式 onChange 控制 timer 生命周期就干净了。
        .onChange(of: isPlaying) { _, newPlaying in
            if newPlaying {
                startTicker()
            } else {
                stopTicker()   // 保留当前 angle,resume 时从这继续
            }
        }
    }

    // MARK: - Disc body
    //
    // 半透明彩胶视觉:用 multiple Canvas pass 堆出"染色 base + 沟槽阴影 + 内
    // 沿边缘高光 + 外沿镜面边"。比"染色 + 黑色沟槽"看上去更有 gel 质感。

    private var discBody: some View {
        Canvas { ctx, sz in
            let center = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let outer = min(sz.width, sz.height) / 2
            let inner = outer * 0.55 + 4

            // 1. 染色 base — 中心略亮、边缘略深,模拟塑料厚度的光透过感
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

            // 2. 沟槽 — 在彩胶上画半透明深色细线;变化的 alpha/线宽 模拟手工感
            let grooveCount = 48
            for i in 0..<grooveCount {
                let frac = CGFloat(i) / CGFloat(grooveCount - 1)
                let r = inner + (outer - inner - 4) * frac
                let alpha = 0.18 + 0.10 * Double(i % 5) / 5.0
                let w: CGFloat = (i % 8 == 0) ? 1.3 : 0.55
                ctx.stroke(
                    Path(ellipseIn: CGRect(
                        x: center.x - r, y: center.y - r,
                        width: r * 2, height: r * 2)),
                    with: .color(.black.opacity(alpha)),
                    lineWidth: w
                )
            }

            // 3. 封面边沿外的"标签"环 — 跟封面色调对比,让眼睛区分"唱片标签"
            //    跟"沟槽区"。彩胶 app 通常用一圈更亮的染色环作为标签底。
            let labelOuter = inner + 2
            ctx.stroke(
                Path(ellipseIn: CGRect(
                    x: center.x - labelOuter, y: center.y - labelOuter,
                    width: labelOuter * 2, height: labelOuter * 2)),
                with: .color(.white.opacity(0.55)),
                lineWidth: 2
            )

            // 4. 内圈深色沟槽边界
            ctx.stroke(
                Path(ellipseIn: CGRect(
                    x: center.x - inner, y: center.y - inner,
                    width: inner * 2, height: inner * 2)),
                with: .color(.black.opacity(0.35)),
                lineWidth: 1
            )

            // 5. 外沿镜面边 — 让唱片边缘"锐利"地切开背景
            ctx.stroke(
                Path(ellipseIn: CGRect(
                    x: 1.5, y: 1.5,
                    width: sz.width - 3, height: sz.height - 3)),
                with: .color(.white.opacity(0.45)),
                lineWidth: 2.5
            )
            // 外沿内侧细暗线 — 模拟边缘倒角
            ctx.stroke(
                Path(ellipseIn: CGRect(
                    x: 4, y: 4,
                    width: sz.width - 8, height: sz.height - 8)),
                with: .color(.black.opacity(0.25)),
                lineWidth: 0.8
            )
        }
    }

    // MARK: - Cover
    //
    // 大封面占 discSize 的 55%,圆形剪裁,跟随唱片旋转。封面四周加一圈细环
    // 强调"贴在唱片上"的感觉。

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
            // 双层细环:外层深色阴影 + 内层亮白边
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

    // MARK: - Bloom (外圈光晕)

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

    // MARK: - Glossy highlight (顶部反光)
    //
    // QQ 彩胶最关键的视觉:从左上斜下方向的弧形反光,模拟塑料表面光泽。
    // 这里用一个旋转的椭圆 + 高斯模糊 + screen blend 实现。不随唱片旋转。

    private var glossyHighlight: some View {
        ZStack {
            // 大块顶部反光
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.55),
                            .white.opacity(0.10),
                            .clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: discSize * 1.05, height: discSize * 0.55)
                .offset(y: -discSize * 0.22)
                .rotationEffect(.degrees(-15))
                .blur(radius: 8)

            // 小亮点
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

    // MARK: - Tonearm
    //
    // L 形唱针:
    //   - 右上角 pivot(轴),固定不动
    //   - 杆从 pivot 先垂直短一段(L 的短边),再斜向唱片(L 的长边)
    //   - 末端 cartridge(唱头,一个小方块) + stylus 针尖落在唱片沟槽位置
    //
    // 全部画在跟唱片同尺寸的画布上 — 这样所有坐标都相对画布左上角,显式可算。

    /// 唱针在 progress=0(歌曲起点)和 progress=1(歌曲结尾)之间扫过的总角度。
    /// 30° — 让 stylus 从沟槽最外圈(disc 外沿减 8pt)扫到接近 cover 外沿。
    /// 经验值,跟 pivot 位置 (0.92, 0.08) 和 outerR 配合后视觉上明显从外到内。
    private let armSweepDegrees: Double = 30

    private var tonearmCanvas: some View {
        // 画 progress=0 时的固定 tonearm 几何 — stylus 落在沟槽最外圈。
        // 旋转完全由外层 .rotationEffect 处理。
        Canvas { ctx, sz in
            // pivot 跟外层 anchor (0.92, 0.08) 对齐 — 视觉上根部圆稍稍内移,
            // 不挨着画布边角。
            let pivot = CGPoint(x: sz.width * 0.92, y: sz.height * 0.08)
            // L 短边:垂直向下 36pt,让 L 形外观明显
            let bend = CGPoint(x: pivot.x, y: pivot.y + 36)
            // 长边末端:从 bend 沿"朝唱片 center"方向延伸,落在沟槽最外圈
            // (disc 外沿减 8pt — 视觉上能明显看到 stylus 真在轨道里)。
            let center = CGPoint(x: sz.width / 2, y: sz.height / 2)
            let dx = center.x - bend.x
            let dy = center.y - bend.y
            let dist = sqrt(dx * dx + dy * dy)
            let outerR = discSize / 2 - 8
            let t = max(0, (dist - outerR) / dist)
            let stylus = CGPoint(x: bend.x + dx * t, y: bend.y + dy * t)

            // 1. pivot 底座(大白色圆盘)
            let pivotR: CGFloat = 14
            ctx.fill(
                Path(ellipseIn: CGRect(
                    x: pivot.x - pivotR, y: pivot.y - pivotR,
                    width: pivotR * 2, height: pivotR * 2)),
                with: .linearGradient(
                    Gradient(colors: [.white, .white.opacity(0.75)]),
                    startPoint: CGPoint(x: pivot.x - pivotR, y: pivot.y - pivotR),
                    endPoint: CGPoint(x: pivot.x + pivotR, y: pivot.y + pivotR)
                )
            )
            ctx.stroke(
                Path(ellipseIn: CGRect(
                    x: pivot.x - pivotR, y: pivot.y - pivotR,
                    width: pivotR * 2, height: pivotR * 2)),
                with: .color(.black.opacity(0.25)),
                lineWidth: 0.5
            )
            // pivot 中心螺丝
            ctx.fill(
                Path(ellipseIn: CGRect(
                    x: pivot.x - 4, y: pivot.y - 4,
                    width: 8, height: 8)),
                with: .color(.black.opacity(0.6))
            )

            // 2. 杆 — 两段 (pivot→bend→stylus). 主体白色 + 内阴影
            var rod = Path()
            rod.move(to: pivot)
            rod.addLine(to: bend)
            rod.addLine(to: stylus)
            ctx.stroke(
                rod,
                with: .color(.white.opacity(0.95)),
                style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round)
            )
            ctx.stroke(
                rod,
                with: .color(.black.opacity(0.22)),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            )

            // 3. cartridge — 一个小白色方块在 stylus 上方,模拟唱头外壳
            let cartW: CGFloat = 14, cartH: CGFloat = 18
            let cartRect = CGRect(
                x: stylus.x - cartW / 2 - 2,
                y: stylus.y - cartH,
                width: cartW, height: cartH
            )
            ctx.fill(
                Path(roundedRect: cartRect, cornerSize: CGSize(width: 2, height: 2)),
                with: .color(.white.opacity(0.92))
            )
            ctx.stroke(
                Path(roundedRect: cartRect, cornerSize: CGSize(width: 2, height: 2)),
                with: .color(.black.opacity(0.25)),
                lineWidth: 0.5
            )
            // cartridge 上的接触点
            ctx.fill(
                Path(ellipseIn: CGRect(
                    x: cartRect.midX - 1.5, y: cartRect.minY + 4,
                    width: 3, height: 3)),
                with: .color(.red.opacity(0.7))
            )

            // 4. stylus 针尖 — 极小的金属点
            ctx.fill(
                Path(ellipseIn: CGRect(
                    x: stylus.x - 2.5, y: stylus.y - 2.5,
                    width: 5, height: 5)),
                with: .color(.black.opacity(0.85))
            )
        }
    }

    // MARK: - Rotation ticker

    private func startTicker() {
        stopTicker()
        lastTickAt = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            // ticker 只在 isPlaying=true 时跑(由 onChange 启停),所以这里
            // 不再检查 isPlaying — 推进就行。30s 一圈 = 12°/秒。
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
