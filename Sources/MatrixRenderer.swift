import AppKit
import MetalKit
import simd

private struct Uniforms {
    var viewProjection: simd_float4x4
    var time: Float
    var viewport: SIMD2<Float>
    var fog: Float
    var glyphUVSize: SIMD2<Float>
    var realCharRows: Float
    var padding: Float
}

private struct FrameResources {
    var uniformBuffer: MTLBuffer
}

private struct RendererSimulationBinding {
    let coordinator: MatrixSimulationCoordinator
    let consumerToken: UInt64
    var settings: MatrixSettings
    var active: Bool
    let epoch: UInt64
}

struct MatrixRendererDiagnostics {
    var submittedFrames: UInt64 = 0
    var completedFrames: UInt64 = 0
    var presentedFrames: UInt64 = 0
    var skippedPresentations: UInt64 = 0
    var commandErrors: UInt64 = 0
    var drawableMisses: UInt64 = 0
    var commandBufferMisses: UInt64 = 0
    var encoderMisses: UInt64 = 0
    var resourceMisses: UInt64 = 0
    var inFlightSkips: UInt64 = 0
    var inFlightFrames: Int = 0
    var peakInFlightFrames: Int = 0
    var instanceCount: Int = 0
    var instanceCapacity: Int = 0
    var stripCount: Int = 0
    var frameSlot: Int = 0
    var simulationSlot: Int = 0
    var simulationSequence: UInt64 = 0
    var drawableSize: CGSize = .zero
    var gpuMilliseconds: Double = 0
    var lastPresentedTime: CFTimeInterval = 0
    var lastError: String?
    var simulation = MatrixSimulationDiagnostics()
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
    private let simulationLock = NSLock()
    private var simulationBinding: RendererSimulationBinding?
    private var nextSimulationEpoch: UInt64 = 1
    private var frameResources: [FrameResources] = []
    private var availableFrameSlots: [Int] = []
    private var frameResourceGeneration: UInt64 = 0
    private let frameSlotLock = NSLock()
    private let diagnosticsLock = NSLock()
    private var diagnostics = MatrixRendererDiagnostics()
    private let callbackLock = NSLock()
    private var framePresentedHandler: ((CFTimeInterval) -> Void)?
    private var framePresentedMinimumInterval: CFTimeInterval = 0
    private var lastFramePresentedNotification: CFTimeInterval = 0
    private let maxFramesInFlight = 3

    public init(view: MTKView, isPreview: Bool) throws {
        guard let device = view.device else { throw MatrixError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw MatrixError.noCommandQueue }
        let initialSettings = MatrixSettings.load()
        let library = try device.makeLibrary(source: MatrixRenderer.shaderSource, options: nil)
        guard let vertex = library.makeFunction(name: "matrixVertex"),
              let fragment = library.makeFunction(name: "matrixFragment") else {
            throw MatrixError.noShaderLibrary
        }

        let atlas = try MatrixRenderer.makeGlyphAtlas(device: device)

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
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw MatrixError.noSampler
        }

        let initialFrameResources = try MatrixRenderer.makeFrameResources(device: device,
                                                                          count: 3)
        let simulationSession = try MatrixSimulationCoordinatorRegistry.shared.session(
            device: device,
            settings: initialSettings,
            isPreview: isPreview,
            active: true
        )

        self.device = device
        self.commandQueue = queue
        self.pipeline = pipeline
        self.sampler = sampler
        self.glyphTexture = atlas.texture
        self.glyphUVSize = atlas.glyphUVSize
        self.realCharRows = Float(atlas.realCharRows)
        self.isPreview = isPreview
        self.simulationBinding = RendererSimulationBinding(
            coordinator: simulationSession.coordinator,
            consumerToken: simulationSession.consumerToken,
            settings: initialSettings,
            active: true,
            epoch: 1
        )
        self.frameResources = initialFrameResources

        super.init()
        DebugLifetimeRegistry.shared.register(renderer: self)
        installFrameResources(initialFrameResources)
    }

    deinit {
        shutdown()
        DebugLifetimeRegistry.shared.unregister(renderer: self)
    }

    public func apply(settings newSettings: MatrixSettings) {
        simulationLock.lock()
        guard let currentBinding = simulationBinding else {
            simulationLock.unlock()
            return
        }
        let oldConfiguration = MatrixSimulationConfiguration(device: device,
                                                              settings: currentBinding.settings,
                                                              isPreview: isPreview)
        let newConfiguration = MatrixSimulationConfiguration(device: device,
                                                              settings: newSettings,
                                                              isPreview: isPreview)
        guard oldConfiguration != newConfiguration else {
            var updatedBinding = currentBinding
            updatedBinding.settings = newSettings
            simulationBinding = updatedBinding
            simulationLock.unlock()
            return
        }
        let expectedEpoch = currentBinding.epoch
        simulationLock.unlock()

        do {
            let session = try MatrixSimulationCoordinatorRegistry.shared.session(
                device: device,
                settings: newSettings,
                isPreview: isPreview,
                active: false
            )

            simulationLock.lock()
            guard let latestBinding = simulationBinding,
                  latestBinding.epoch == expectedEpoch else {
                simulationLock.unlock()
                session.coordinator.unregisterConsumer(session.consumerToken)
                return
            }
            nextSimulationEpoch &+= 1
            if latestBinding.active {
                session.coordinator.setConsumer(session.consumerToken, active: true)
            }
            simulationBinding = RendererSimulationBinding(
                coordinator: session.coordinator,
                consumerToken: session.consumerToken,
                settings: newSettings,
                active: latestBinding.active,
                epoch: nextSimulationEpoch
            )
            simulationLock.unlock()
            latestBinding.coordinator.unregisterConsumer(latestBinding.consumerToken)
        } catch {
            NSLog("MetalMatrix: unable to rebuild shared simulation ring: \(error)")
        }
    }

    public func resume(size: CGSize) {
        _ = size
        if frameResources.count != maxFramesInFlight {
            if let resources = try? MatrixRenderer.makeFrameResources(device: device,
                                                                       count: maxFramesInFlight) {
                installFrameResources(resources)
            }
        }
        setSimulationActive(true)
    }

    public func resize(size: CGSize) {
        _ = size
    }

    public func setSimulationActive(_ active: Bool) {
        simulationLock.lock()
        guard var binding = simulationBinding,
              binding.active != active else {
            simulationLock.unlock()
            return
        }
        binding.active = active
        simulationBinding = binding
        binding.coordinator.setConsumer(binding.consumerToken, active: active)
        simulationLock.unlock()
    }

    public func shutdown() {
        simulationLock.lock()
        guard let binding = simulationBinding else {
            simulationLock.unlock()
            return
        }
        simulationBinding = nil
        nextSimulationEpoch &+= 1
        simulationLock.unlock()
        binding.coordinator.unregisterConsumer(binding.consumerToken)
    }

    public func whenSimulationReady(_ callback: @escaping () -> Void) {
        simulationLock.lock()
        guard let binding = simulationBinding else {
            simulationLock.unlock()
            return
        }
        simulationLock.unlock()
        binding.coordinator.whenReady { [weak self] in
            guard let self else { return }
            self.simulationLock.lock()
            let isCurrent = self.simulationBinding?.epoch == binding.epoch
            self.simulationLock.unlock()
            if isCurrent {
                callback()
            }
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        resize(size: size)
    }

    public func draw(in view: MTKView) {
        guard frameResources.count == maxFramesInFlight else {
            recordResourceMiss()
            return
        }
        guard let acquiredSlot = acquireFrameSlot() else {
            recordInFlightSkip()
            return
        }

        let frameSlot = acquiredSlot.index
        let resources = frameResources[frameSlot]
        simulationLock.lock()
        let binding = simulationBinding
        simulationLock.unlock()
        guard let binding,
              let sharedFrame = binding.coordinator.acquireFrame(consumer: binding.consumerToken,
                                                                 at: CACurrentMediaTime()) else {
            releaseFrameSlot(frameSlot, generation: acquiredSlot.generation)
            return
        }
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            recordDrawableMiss()
            sharedFrame.release()
            releaseFrameSlot(frameSlot, generation: acquiredSlot.generation)
            return
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            recordCommandBufferMiss()
            sharedFrame.release()
            releaseFrameSlot(frameSlot, generation: acquiredSlot.generation)
            return
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            recordEncoderMiss()
            sharedFrame.release()
            releaseFrameSlot(frameSlot, generation: acquiredSlot.generation)
            return
        }

        let time = Float(CACurrentMediaTime() - startTime)
        var uniforms = Uniforms(
            viewProjection: makeViewProjection(size: view.drawableSize,
                                               viewX: sharedFrame.viewX,
                                               viewY: sharedFrame.viewY,
                                               rotate: binding.settings.rotate),
            time: time,
            viewport: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            fog: binding.settings.fog ? 1 : 0,
            glyphUVSize: glyphUVSize,
            realCharRows: realCharRows,
            padding: 0
        )
        memcpy(resources.uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.stride)

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(sharedFrame.instanceBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(resources.uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentTexture(glyphTexture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        if sharedFrame.instanceCount > 0 {
            encoder.drawPrimitives(type: .triangleStrip,
                                   vertexStart: 0,
                                   vertexCount: 4,
                                   instanceCount: sharedFrame.instanceCount)
        }
        encoder.endEncoding()
        recordSubmission(instanceCount: sharedFrame.instanceCount,
                         instanceCapacity: sharedFrame.instanceCapacity,
                         stripCount: sharedFrame.stripCount,
                         frameSlot: frameSlot,
                         simulationSlot: sharedFrame.slotIndex,
                         simulationSequence: sharedFrame.sequence,
                         drawableSize: view.drawableSize)
        drawable.addPresentedHandler { [weak self] drawable in
            guard drawable.presentedTime > 0 else {
                self?.recordSkippedPresentation()
                return
            }
            self?.recordPresentation(time: drawable.presentedTime)
            self?.notifyFramePresented(drawable.presentedTime)
        }
        commandBuffer.addCompletedHandler { [weak self, sharedFrame] commandBuffer in
            self?.recordCompletion(commandBuffer)
            self?.releaseFrameSlot(frameSlot, generation: acquiredSlot.generation)
            sharedFrame.release()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func setFramePresentedHandler(minimumInterval: CFTimeInterval,
                                  handler: ((CFTimeInterval) -> Void)?) {
        callbackLock.lock()
        framePresentedHandler = handler
        framePresentedMinimumInterval = max(0, minimumInterval)
        lastFramePresentedNotification = 0
        callbackLock.unlock()
    }

    private func notifyFramePresented(_ time: CFTimeInterval) {
        callbackLock.lock()
        guard framePresentedHandler != nil,
              lastFramePresentedNotification == 0 ||
              time - lastFramePresentedNotification >= framePresentedMinimumInterval else {
            callbackLock.unlock()
            return
        }
        let callback = framePresentedHandler
        lastFramePresentedNotification = time
        callbackLock.unlock()
        callback?(time)
    }

    func diagnosticsSnapshot() -> MatrixRendererDiagnostics {
        diagnosticsLock.lock()
        var snapshot = diagnostics
        diagnosticsLock.unlock()
        simulationLock.lock()
        let coordinator = simulationBinding?.coordinator
        simulationLock.unlock()
        if let coordinator {
            snapshot.simulation = coordinator.diagnosticsSnapshot()
        }
        return snapshot
    }

    private func recordSubmission(instanceCount: Int,
                                  instanceCapacity: Int,
                                  stripCount: Int,
                                  frameSlot: Int,
                                  simulationSlot: Int,
                                  simulationSequence: UInt64,
                                  drawableSize: CGSize) {
        diagnosticsLock.lock()
        diagnostics.submittedFrames &+= 1
        diagnostics.instanceCount = instanceCount
        diagnostics.instanceCapacity = instanceCapacity
        diagnostics.stripCount = stripCount
        diagnostics.frameSlot = frameSlot
        diagnostics.simulationSlot = simulationSlot
        diagnostics.simulationSequence = simulationSequence
        diagnostics.drawableSize = drawableSize
        diagnosticsLock.unlock()
    }

    private func recordCompletion(_ commandBuffer: MTLCommandBuffer) {
        diagnosticsLock.lock()
        diagnostics.completedFrames &+= 1
        if commandBuffer.status == .error {
            diagnostics.commandErrors &+= 1
            diagnostics.lastError = commandBuffer.error.map { sanitizeDiagnostic($0.localizedDescription) } ?? "unknown Metal error"
        }
        let duration = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        if duration.isFinite && duration >= 0 {
            diagnostics.gpuMilliseconds = duration * 1_000
        }
        diagnosticsLock.unlock()
    }

    private func recordInFlightAcquired() {
        diagnosticsLock.lock()
        diagnostics.inFlightFrames += 1
        diagnostics.peakInFlightFrames = max(diagnostics.peakInFlightFrames, diagnostics.inFlightFrames)
        diagnosticsLock.unlock()
    }

    private func recordInFlightReleased() {
        diagnosticsLock.lock()
        diagnostics.inFlightFrames = max(0, diagnostics.inFlightFrames - 1)
        diagnosticsLock.unlock()
    }

    private func recordInFlightSkip() {
        diagnosticsLock.lock()
        diagnostics.inFlightSkips &+= 1
        diagnosticsLock.unlock()
    }

    private func recordPresentation(time: CFTimeInterval) {
        diagnosticsLock.lock()
        diagnostics.presentedFrames &+= 1
        diagnostics.lastPresentedTime = time
        diagnosticsLock.unlock()
    }

    private func recordSkippedPresentation() {
        diagnosticsLock.lock()
        diagnostics.skippedPresentations &+= 1
        diagnosticsLock.unlock()
    }

    private func recordDrawableMiss() {
        diagnosticsLock.lock()
        diagnostics.drawableMisses &+= 1
        diagnosticsLock.unlock()
    }

    private func recordCommandBufferMiss() {
        diagnosticsLock.lock()
        diagnostics.commandBufferMisses &+= 1
        diagnosticsLock.unlock()
    }

    private func recordEncoderMiss() {
        diagnosticsLock.lock()
        diagnostics.encoderMisses &+= 1
        diagnosticsLock.unlock()
    }

    private func recordResourceMiss() {
        diagnosticsLock.lock()
        diagnostics.resourceMisses &+= 1
        diagnosticsLock.unlock()
    }

    private func sanitizeDiagnostic(_ text: String) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        return String(singleLine.prefix(120))
    }

    private static func makeFrameResources(device: MTLDevice,
                                           count: Int) throws -> [FrameResources] {
        var resources: [FrameResources] = []
        resources.reserveCapacity(count)
        for _ in 0..<count {
            guard let uniformBuffer = device.makeBuffer(
                length: MemoryLayout<Uniforms>.stride,
                options: .storageModeShared
            ) else {
                throw MatrixError.noUniformBuffer
            }
            resources.append(FrameResources(uniformBuffer: uniformBuffer))
        }
        return resources
    }

    private func installFrameResources(_ resources: [FrameResources]) {
        frameResources = resources
        frameSlotLock.lock()
        frameResourceGeneration &+= 1
        availableFrameSlots = Array(resources.indices)
        frameSlotLock.unlock()

        diagnosticsLock.lock()
        diagnostics.inFlightFrames = 0
        diagnosticsLock.unlock()
    }

    private func acquireFrameSlot() -> (index: Int, generation: UInt64)? {
        frameSlotLock.lock()
        guard let index = availableFrameSlots.popLast() else {
            frameSlotLock.unlock()
            return nil
        }
        let generation = frameResourceGeneration
        frameSlotLock.unlock()
        recordInFlightAcquired()
        return (index, generation)
    }

    private func releaseFrameSlot(_ index: Int, generation: UInt64) {
        frameSlotLock.lock()
        guard generation == frameResourceGeneration else {
            frameSlotLock.unlock()
            return
        }
        availableFrameSlots.append(index)
        frameSlotLock.unlock()
        recordInFlightReleased()
    }

    private func makeViewProjection(size: CGSize,
                                    viewX: Float,
                                    viewY: Float,
                                    rotate: Bool) -> simd_float4x4 {
        let width = Float(max(size.width, 1))
        let height = Float(max(size.height, 1))
        let aspect = width / height
        let projection = simd_float4x4.perspective(fovyRadians: 80 * .pi / 180, aspect: aspect, near: 1, far: 100)
        let camera = simd_float4x4.lookAt(eye: SIMD3<Float>(0, 0, 25),
                                          center: SIMD3<Float>(0, 0, 0),
                                          up: SIMD3<Float>(0, 1, 0))
        let rotation = rotate
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

}

private enum MatrixError: Error {
    case noDevice
    case noCommandQueue
    case noShaderLibrary
    case noSampler
    case noUniformBuffer
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
        float4 sample = glyphTexture.sample(glyphSampler, in.uv);
        return float4(sample.rgb, clamp(sample.a * in.brightness, 0.0, 1.0));
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
