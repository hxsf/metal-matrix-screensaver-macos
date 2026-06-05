import AppKit
import MetalKit
import simd

private struct GlyphInstance {
    var position: SIMD3<Float>
    var size: SIMD2<Float>
    var glyph: UInt32
    var brightness: Float
    var highlight: Float
}

private struct Uniforms {
    var viewProjection: simd_float4x4
    var time: Float
    var viewport: SIMD2<Float>
    var fog: Float
    var glyphUVSize: SIMD2<Float>
    var realCharRows: Float
    var padding: Float
}

private struct MatrixStrip {
    var x: Float
    var y: Float
    var z: Float
    var dx: Float
    var dy: Float
    var dz: Float
    var erasing: Bool
    var spinnerGlyph: Int
    var spinnerY: Float
    var spinnerSpeed: Float
    var glyphs: [Int]
    var highlights: [Bool]
    var spinSpeed: Int
    var spinTick: Int
    var wavePosition: Int
    var waveSpeed: Int
    var waveTick: Int
}

public final class MatrixRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let glyphTexture: MTLTexture
    private let glyphUVSize: SIMD2<Float>
    private let realCharRows: Float
    private let startTime = CACurrentMediaTime()
    private let isPreview: Bool

    private var settings = MatrixSettings.load()
    private var strips: [MatrixStrip] = []
    private var instanceBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?
    private var instanceCapacity = 0
    private var currentSize: CGSize = .zero
    private var rng: UInt64 = 0x4d6574616c4d6174
    private var brightnessRamp: [Float] = []
    private var viewX: Float = 0
    private var viewY: Float = 0
    private var lastView = 0
    private var targetView = 0
    private var viewSteps = 100
    private var viewTick = 0
    private var autoTracking = false
    private var trackTick = 0

    private let gridSize = 70
    private let gridDepth: Float = 35
    private let waveSize = 22
    private let splashRatio: Float = 0.7
    private let niceViews: [(x: Float, y: Float)] = [
        (0, 0), (0, -20), (0, 20), (25, 0), (-25, 0), (25, 20), (-25, 20), (25, -20), (-25, -20),
        (10, 0), (-10, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0)
    ]

    public init(view: MTKView, isPreview: Bool) throws {
        guard let device = view.device else { throw MatrixError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw MatrixError.noCommandQueue }
        let library = try device.makeLibrary(source: MatrixRenderer.shaderSource, options: nil)
        guard let vertex = library.makeFunction(name: "matrixVertex"),
              let fragment = library.makeFunction(name: "matrixFragment") else {
            throw MatrixError.noShaderLibrary
        }

        self.device = device
        self.commandQueue = queue
        self.isPreview = isPreview
        let atlas = try MatrixRenderer.makeGlyphAtlas(device: device)
        self.glyphTexture = atlas.texture
        self.glyphUVSize = atlas.glyphUVSize
        self.realCharRows = Float(atlas.realCharRows)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw MatrixError.noSampler
        }
        self.sampler = sampler

        super.init()
        buildBrightnessRamp()
        resetTracking()
        reset(size: view.bounds.size)
    }

    public func apply(settings newSettings: MatrixSettings) {
        let shouldReset = settings.density != newSettings.density ||
            settings.speed != newSettings.speed ||
            settings.mode != newSettings.mode
        settings = newSettings
        if shouldReset {
            reset(size: currentSize)
        }
    }

    public func resume(size: CGSize) {
        let validSize = size.width > 0 && size.height > 0
        if strips.isEmpty || instanceBuffer == nil || uniformBuffer == nil {
            reset(size: validSize ? size : currentSize)
        } else if validSize && currentSize != size {
            currentSize = size
        }
    }

    public func resize(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        currentSize = size
    }

    public func reset(size: CGSize) {
        currentSize = size
        resetTracking()
        let stripCount = min(2_000, max(1, Int(settings.density * 2.2)))
        strips = (0..<stripCount).map { _ in
            var strip = makeStrip()
            strip.erasing = true
            strip.spinnerY = randomFloat(Float(gridSize))
            strip.glyphs = Array(repeating: 0, count: gridSize)
            return strip
        }

        let maxGlyphs = stripCount * (gridSize + 1)
        if maxGlyphs > instanceCapacity {
            instanceCapacity = maxGlyphs
            instanceBuffer = device.makeBuffer(length: maxGlyphs * MemoryLayout<GlyphInstance>.stride,
                                               options: .storageModeShared)
        }
        if uniformBuffer == nil {
            uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride,
                                              options: .storageModeShared)
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        resize(size: size)
    }

    public func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
              let instanceBuffer,
              let uniformBuffer else {
            return
        }

        let time = Float(CACurrentMediaTime() - startTime)
        let instanceCount = updateInstances(buffer: instanceBuffer)

        var uniforms = Uniforms(
            viewProjection: makeViewProjection(size: view.drawableSize),
            time: time,
            viewport: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            fog: settings.fog ? 1 : 0,
            glyphUVSize: glyphUVSize,
            realCharRows: realCharRows,
            padding: 0
        )
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.stride)

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentTexture(glyphTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        if instanceCount > 0 {
            encoder.drawPrimitives(type: .triangleStrip,
                                   vertexStart: 0,
                                   vertexCount: 4,
                                   instanceCount: instanceCount)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func updateInstances(buffer: MTLBuffer) -> Int {
        let pointer = buffer.contents().bindMemory(to: GlyphInstance.self, capacity: instanceCapacity)
        var count = 0
        let glyphSize = SIMD2<Float>(1, 1)
        let sortedIndexes = strips.indices.sorted { strips[$0].z < strips[$1].z }

        for index in sortedIndexes {
            tickStrip(index: index)
            let strip = strips[index]

            for glyphIndex in 0..<gridSize {
                let glyph = strip.glyphs[glyphIndex]
                var below = strip.spinnerY >= Float(glyphIndex)
                if strip.erasing { below.toggle() }
                guard glyph != 0 && below && count < instanceCapacity else { continue }

                let brightness = stripBrightness(strip, glyphIndex: glyphIndex, glyph: glyph)
                pointer[count] = GlyphInstance(
                    position: SIMD3(strip.x, strip.y - Float(glyphIndex), strip.z),
                    size: glyphSize,
                    glyph: UInt32(abs(glyph) - 1),
                    brightness: brightness,
                    highlight: strip.highlights[glyphIndex] ? 1 : 0
                )
                count += 1
            }

            if !strip.erasing && count < instanceCapacity {
                pointer[count] = GlyphInstance(
                    position: SIMD3(strip.x, strip.y - strip.spinnerY, strip.z),
                    size: glyphSize,
                    glyph: UInt32(abs(strip.spinnerGlyph) - 1),
                    brightness: glyphBrightness(glyph: strip.spinnerGlyph, highlight: false, z: strip.z, baseBrightness: 1),
                    highlight: 0
                )
                count += 1
            }
        }

        autoTrack()
        return count
    }

    private func makeStrip() -> MatrixStrip {
        var glyphs = Array(repeating: 0, count: gridSize)
        var highlights = Array(repeating: false, count: gridSize)

        for index in 0..<gridSize {
            let draw = randomInt(7) != 0
            let spin = draw && randomInt(20) == 0
            var glyph = draw ? randomGlyph() + 1 : 0
            if spin { glyph = -glyph }
            glyphs[index] = glyph
            highlights[index] = false
        }

        let speed = max(settings.speed, 0.1)
        return MatrixStrip(
            x: randomFloat(Float(gridSize)) - Float(gridSize) / 2,
            y: Float(gridSize) / 2 + bellRandom(0.5),
            z: gridDepth * 0.2 - randomFloat(gridDepth * 0.7),
            dx: 0,
            dy: 0,
            dz: bellRandom(0.02) * speed,
            erasing: false,
            spinnerGlyph: -(randomGlyph() + 1),
            spinnerY: 0,
            spinnerSpeed: bellRandom(0.3) * speed,
            glyphs: glyphs,
            highlights: highlights,
            spinSpeed: max(1, Int(bellRandom(2 / speed)) + 1),
            spinTick: 0,
            wavePosition: 0,
            waveSpeed: max(1, Int(bellRandom(3 / speed)) + 1),
            waveTick: 0
        )
    }

    private func tickStrip(index: Int) {
        strips[index].x += strips[index].dx
        strips[index].y += strips[index].dy
        strips[index].z += strips[index].dz

        if strips[index].z > gridDepth * splashRatio {
            strips[index] = makeStrip()
            return
        }

        strips[index].spinnerY += strips[index].spinnerSpeed
        if strips[index].spinnerY >= Float(gridSize) {
            if strips[index].erasing {
                strips[index] = makeStrip()
                return
            } else {
                strips[index].erasing = true
                strips[index].spinnerY = 0
                strips[index].spinnerSpeed /= 2
            }
        }

        strips[index].spinTick += 1
        if strips[index].spinTick > strips[index].spinSpeed {
            strips[index].spinTick = 0
            strips[index].spinnerGlyph = -(randomGlyph() + 1)
            for glyphIndex in 0..<strips[index].glyphs.count where strips[index].glyphs[glyphIndex] < 0 {
                strips[index].glyphs[glyphIndex] = -(randomGlyph() + 1)
                if randomInt(800) == 0 {
                    strips[index].glyphs[glyphIndex] = -strips[index].glyphs[glyphIndex]
                }
            }
        }

        strips[index].waveTick += 1
        if strips[index].waveTick > strips[index].waveSpeed {
            strips[index].waveTick = 0
            strips[index].wavePosition = (strips[index].wavePosition + 1) % waveSize
        }
    }

    private func stripBrightness(_ strip: MatrixStrip, glyphIndex: Int, glyph: Int) -> Float {
        let base: Float
        if settings.waves {
            let rampIndex = waveSize - ((glyphIndex + (gridSize - strip.wavePosition)) % waveSize)
            base = brightnessRamp[max(0, min(waveSize - 1, rampIndex))]
        } else {
            base = 1
        }
        return glyphBrightness(glyph: glyph, highlight: strip.highlights[glyphIndex], z: strip.z, baseBrightness: base)
    }

    private func glyphBrightness(glyph: Int, highlight: Bool, z: Float, baseBrightness: Float) -> Float {
        var brightness = baseBrightness
        if glyph < 0 { brightness *= 1.5 }
        if settings.fog {
            let depth = 0.2 + (((z / gridDepth) + 0.5) * 0.8)
            brightness *= depth
        }
        if highlight { brightness *= 2 }
        if z > gridDepth / 2 {
            let ratio = (z - gridDepth / 2) / ((gridDepth * splashRatio) - gridDepth / 2)
            let index = max(0, min(waveSize - 1, Int(ratio * Float(waveSize))))
            brightness *= brightnessRamp[index]
        }
        return min(brightness, 3)
    }

    private func makeViewProjection(size: CGSize) -> simd_float4x4 {
        let width = Float(max(size.width, 1))
        let height = Float(max(size.height, 1))
        let aspect = width / height
        let projection = simd_float4x4.perspective(fovyRadians: 80 * .pi / 180, aspect: aspect, near: 1, far: 100)
        let camera = simd_float4x4.lookAt(eye: SIMD3<Float>(0, 0, 25),
                                          center: SIMD3<Float>(0, 0, 0),
                                          up: SIMD3<Float>(0, 1, 0))
        let rotation = settings.rotate
            ? simd_float4x4.rotation(radians: viewY * .pi / 180, axis: SIMD3<Float>(0, 1, 0)) *
              simd_float4x4.rotation(radians: viewX * .pi / 180, axis: SIMD3<Float>(1, 0, 0))
            : matrix_identity_float4x4
        return projection * camera * rotation
    }

    private static func makeGlyphAtlas(device: MTLDevice) throws -> (texture: MTLTexture, glyphUVSize: SIMD2<Float>, realCharRows: Int) {
        let columns = 16
        let rows = 13
        var atlas = try XPMAtlas.load(resource: "matrix3")
        let originalWidth = atlas.width
        let originalHeight = atlas.height
        var realRows = rows
        spankImage(pixels: &atlas.pixels, width: atlas.width, height: &atlas.height, realRows: &realRows, rows: rows)

        let paddedHeight = atlas.height < 512 ? 512 : 1024
        if atlas.height != paddedHeight {
            var padded = [UInt8](repeating: 0, count: atlas.width * paddedHeight * 4)
            for row in 0..<atlas.height {
                let source = row * atlas.width * 4
                let target = row * atlas.width * 4
                padded[target..<(target + atlas.width * 4)] = atlas.pixels[source..<(source + atlas.width * 4)]
            }
            atlas.pixels = padded
            atlas.height = paddedHeight
        }

        let charWidth = originalWidth / columns
        let charHeight = originalHeight / rows
        flipCharactersHorizontally(pixels: &atlas.pixels, width: atlas.width, height: atlas.height, charWidth: charWidth, columns: columns)

        for index in stride(from: 0, to: atlas.pixels.count, by: 4) {
            let alpha = atlas.pixels[index + 1]
            atlas.pixels[index + 1] = 255
            atlas.pixels[index + 3] = alpha
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: atlas.width,
                                                                  height: atlas.height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw MatrixError.noGlyphTexture }
        texture.replace(region: MTLRegionMake2D(0, 0, atlas.width, atlas.height),
                        mipmapLevel: 0,
                        withBytes: atlas.pixels,
                        bytesPerRow: atlas.width * 4)
        return (texture, SIMD2(Float(charWidth) / Float(atlas.width), Float(charHeight) / Float(atlas.height)), realRows)
    }

    private func buildBrightnessRamp() {
        brightnessRamp = (0..<waveSize).map { index in
            var value = Float(waveSize - index) / Float(waveSize - 1)
            value *= .pi / 2
            value = sinf(value)
            return 0.2 + value * 0.8
        }
    }

    private func resetTracking() {
        lastView = 0
        targetView = 0
        viewX = niceViews[0].x
        viewY = niceViews[0].y
        viewSteps = 100
        viewTick = 0
        autoTracking = false
        trackTick = 0
    }

    private func autoTrack() {
        guard settings.rotate else { return }
        if !autoTracking {
            trackTick += 1
            guard trackTick >= Int(20 / max(settings.speed, 0.1)) else { return }
            trackTick = 0
            guard randomInt(20) == 0 else { return }
            autoTracking = true
        }

        let origin = niceViews[lastView]
        let target = niceViews[targetView]
        let theta = sinf((.pi / 2) * Float(viewTick) / Float(viewSteps))
        viewX = origin.x + (target.x - origin.x) * theta
        viewY = origin.y + (target.y - origin.y) * theta
        viewTick += 1

        if viewTick >= viewSteps {
            viewTick = 0
            viewSteps = max(1, Int(350 / max(settings.speed, 0.1)))
            lastView = targetView
            targetView = randomInt(niceViews.count - 1) + 1
            autoTracking = false
        }
    }

    private func randomGlyph() -> Int {
        let glyphs: [Int]
        switch settings.mode {
        case .matrix:
            glyphs = [16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175]
        case .binary:
            glyphs = [16, 17]
        case .hexadecimal:
            glyphs = [16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 33, 34, 35, 36, 37, 38]
        case .dna:
            glyphs = [33, 35, 39, 52]
        }
        return glyphs[randomInt(glyphs.count)]
    }

    private func randomInt(_ upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(nextRandom() % UInt64(upperBound))
    }

    private func randomFloat(_ upperBound: Float) -> Float {
        Float(nextRandom() & 0x00ff_ffff) / Float(0x0100_0000) * upperBound
    }

    private func bellRandom(_ upperBound: Float) -> Float {
        (randomFloat(upperBound) + randomFloat(upperBound) + randomFloat(upperBound)) / 3
    }

    private func nextRandom() -> UInt64 {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return rng
    }
}

private enum MatrixError: Error {
    case noDevice
    case noCommandQueue
    case noShaderLibrary
    case noSampler
    case noGlyphTexture
    case missingXPMResource
    case invalidXPM
}

private struct XPMAtlas {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    static func load(resource: String) throws -> XPMAtlas {
        let bundle = Bundle(identifier: "com.hxsf.MetalMatrix") ?? Bundle(for: MatrixRenderer.self)
        guard let url = bundle.url(forResource: resource, withExtension: "xpm") else {
            throw MatrixError.missingXPMResource
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let entries = text.components(separatedBy: .newlines).compactMap { line -> String? in
            guard let first = line.firstIndex(of: "\""),
                  let last = line.lastIndex(of: "\""),
                  first < last else { return nil }
            return String(line[line.index(after: first)..<last])
        }
        guard let header = entries.first else { throw MatrixError.invalidXPM }
        let headerParts = header.split { $0 == " " || $0 == "\t" }.compactMap { Int($0) }
        guard headerParts.count >= 4 else { throw MatrixError.invalidXPM }
        let width = headerParts[0]
        let height = headerParts[1]
        let colorCount = headerParts[2]
        let charsPerPixel = headerParts[3]
        guard width > 0, height > 0, colorCount > 0, charsPerPixel == 1,
              entries.count >= 1 + colorCount + height else {
            throw MatrixError.invalidXPM
        }

        var palette = Array(repeating: SIMD4<UInt8>(0, 0, 0, 0), count: 256)
        for colorIndex in 0..<colorCount {
            let line = entries[1 + colorIndex]
            guard let key = line.utf8.first else { throw MatrixError.invalidXPM }
            let rest = String(line.dropFirst()).replacingOccurrences(of: "\t", with: " ")
            guard let marker = rest.range(of: " c ") else { throw MatrixError.invalidXPM }
            let color = rest[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            palette[Int(key)] = parseColor(String(color))
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = Array(entries[1 + colorCount + y].utf8)
            guard row.count >= width else { throw MatrixError.invalidXPM }
            for x in 0..<width {
                let color = palette[Int(row[x])]
                let offset = (y * width + x) * 4
                pixels[offset] = color.x
                pixels[offset + 1] = color.y
                pixels[offset + 2] = color.z
                pixels[offset + 3] = color.w
            }
        }
        return XPMAtlas(width: width, height: height, pixels: pixels)
    }

    private static func parseColor(_ color: String) -> SIMD4<UInt8> {
        guard color != "None", color.hasPrefix("#"), color.count >= 7 else {
            return SIMD4<UInt8>(0, 0, 0, 0)
        }
        let start = color.index(after: color.startIndex)
        let rStart = start
        let gStart = color.index(rStart, offsetBy: 2)
        let bStart = color.index(gStart, offsetBy: 2)
        let r = UInt8(color[rStart..<gStart], radix: 16) ?? 0
        let gEnd = color.index(gStart, offsetBy: 2)
        let g = UInt8(color[gStart..<gEnd], radix: 16) ?? 0
        let bEnd = color.index(bStart, offsetBy: 2)
        let b = UInt8(color[bStart..<bEnd], radix: 16) ?? 0
        return SIMD4<UInt8>(r, g, b, 255)
    }
}

private func spankImage(pixels: inout [UInt8], width: Int, height: inout Int, realRows: inout Int, rows: Int) {
    let charHeight = height / rows
    let cut = 2
    let bandBytes = width * 4 * charHeight
    let copiedFirstBand = Array(pixels[0..<bandBytes])
    let copyTarget = (bandBytes * cut)..<(bandBytes * cut + bandBytes)
    pixels.replaceSubrange(copyTarget, with: copiedFirstBand)

    let shifted = Array(pixels[(bandBytes * cut)..<(bandBytes * rows)])
    pixels.replaceSubrange(0..<shifted.count, with: shifted)

    let clearStart = bandBytes * (rows - cut)
    let clearEnd = bandBytes * rows
    if clearStart < clearEnd && clearEnd <= pixels.count {
        pixels.replaceSubrange(clearStart..<clearEnd, with: repeatElement(UInt8(0), count: clearEnd - clearStart))
    }
    height -= cut * charHeight
    realRows -= cut
}

private func flipCharactersHorizontally(pixels: inout [UInt8], width: Int, height: Int, charWidth: Int, columns: Int) {
    for y in 0..<height {
        for column in 0..<columns {
            let baseX = column * charWidth
            for x in 0..<(charWidth / 2) {
                let left = (y * width + baseX + x) * 4
                let right = (y * width + baseX + (charWidth - x - 1)) * 4
                for channel in 0..<4 {
                    pixels.swapAt(left + channel, right + channel)
                }
            }
        }
    }
}

private extension MatrixRenderer {
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct GlyphInstance {
        float3 position;
        float2 size;
        uint glyph;
        float brightness;
        float highlight;
    };

    struct Uniforms {
        float4x4 viewProjection;
        float time;
        float2 viewport;
        float fog;
        float2 glyphUVSize;
        float realCharRows;
        float padding;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float brightness;
        float highlight;
    };

    vertex VertexOut matrixVertex(uint vertexID [[vertex_id]],
                                  uint instanceID [[instance_id]],
                                  constant GlyphInstance *instances [[buffer(0)]],
                                  constant Uniforms &uniforms [[buffer(1)]]) {
        constexpr float2 corners[4] = {
            float2(0.0, 0.0),
            float2(1.0, 0.0),
            float2(0.0, 1.0),
            float2(1.0, 1.0)
        };
        constexpr float2 quadUV[4] = {
            float2(0.0, 0.0),
            float2(1.0, 0.0),
            float2(0.0, 1.0),
            float2(1.0, 1.0)
        };

        GlyphInstance instance = instances[instanceID];
        float2 corner = corners[vertexID] * instance.size;
        float4 world = float4(instance.position + float3(corner.x, corner.y, 0.0), 1.0);

        uint glyph = instance.glyph;
        float ccx = float(glyph % 16);
        float ccy = float(glyph / 16);
        float2 glUV = float2(ccx * uniforms.glyphUVSize.x,
                             (uniforms.realCharRows - ccy - 1.0) * uniforms.glyphUVSize.y) +
                      quadUV[vertexID] * uniforms.glyphUVSize;

        VertexOut out;
        out.position = uniforms.viewProjection * world;
        out.uv = float2(glUV.x, 1.0 - glUV.y);
        out.brightness = instance.brightness;
        out.highlight = instance.highlight;
        return out;
    }

    fragment float4 matrixFragment(VertexOut in [[stage_in]],
                                   texture2d<float> glyphTexture [[texture(0)]],
                                   sampler glyphSampler [[sampler(0)]]) {
        float alpha = glyphTexture.sample(glyphSampler, in.uv).a;
        float4 sample = glyphTexture.sample(glyphSampler, in.uv);
        return float4(sample.rgb, clamp(alpha * in.brightness, 0.0, 1.0));
    }
    """
}

private extension simd_float4x4 {
    static func orthographic(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(2 / (right - left), 0, 0, 0),
            SIMD4<Float>(0, 2 / (top - bottom), 0, 0),
            SIMD4<Float>(0, 0, 1 / (near - far), 0),
            SIMD4<Float>((left + right) / (left - right), (top + bottom) / (bottom - top), near / (near - far), 1)
        ))
    }

    static func perspective(fovyRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tanf(fovyRadians * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        ))
    }

    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - center)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        ))
    }

    static func rotation(radians: Float, axis: SIMD3<Float>) -> simd_float4x4 {
        let a = simd_normalize(axis)
        let c = cosf(radians)
        let s = sinf(radians)
        let t = 1 - c
        return simd_float4x4(columns: (
            SIMD4<Float>(t * a.x * a.x + c, t * a.x * a.y + s * a.z, t * a.x * a.z - s * a.y, 0),
            SIMD4<Float>(t * a.x * a.y - s * a.z, t * a.y * a.y + c, t * a.y * a.z + s * a.x, 0),
            SIMD4<Float>(t * a.x * a.z + s * a.y, t * a.y * a.z - s * a.x, t * a.z * a.z + c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }
}
