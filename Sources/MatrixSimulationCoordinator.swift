import AppKit
import Metal
import os.lock
import QuartzCore

struct GlyphInstance {
    var position: SIMD3<Float>
    var size: SIMD2<Float>
    var glyph: UInt32
    var brightness: Float
    var highlight: Float
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

struct MatrixSimulationDiagnostics {
    var ringCapacity = 0
    var readyFrames = 0
    var preparingFrames = 0
    var gpuReaders = 0
    var activeConsumers = 0
    var liveCoordinators = 0
    var producedFrames: UInt64 = 0
    var consumedFrames: UInt64 = 0
    var staleFrames: UInt64 = 0
    var starvedFrames: UInt64 = 0
    var lastSequence: UInt64 = 0
    var lastPreparationMilliseconds: Double = 0
    var averagePreparationMilliseconds: Double = 0
}

struct MatrixSimulationConfiguration: Hashable {
    let deviceRegistryID: UInt64
    let densityBits: UInt32
    let speedBits: UInt32
    let mode: Int
    let fog: Bool
    let waves: Bool
    let rotate: Bool
    let frameRate: Int
    let isPreview: Bool

    init(device: MTLDevice, settings: MatrixSettings, isPreview: Bool) {
        deviceRegistryID = device.registryID
        densityBits = settings.density.bitPattern
        speedBits = settings.speed.bitPattern
        mode = settings.mode.rawValue
        fog = settings.fog
        waves = settings.waves
        rotate = settings.rotate
        frameRate = max(1, settings.frameRate)
        self.isPreview = isPreview
    }
}

final class MatrixSharedFrame {
    let instanceBuffer: MTLBuffer
    let instanceCount: Int
    let instanceCapacity: Int
    let stripCount: Int
    let viewX: Float
    let viewY: Float
    let sequence: UInt64
    let slotIndex: Int

    private let coordinator: MatrixSimulationCoordinator
    private let generation: UInt64
    private var releaseLock = os_unfair_lock_s()
    private var released = false

    init(coordinator: MatrixSimulationCoordinator,
         generation: UInt64,
         slotIndex: Int,
         instanceBuffer: MTLBuffer,
         instanceCount: Int,
         instanceCapacity: Int,
         stripCount: Int,
         viewX: Float,
         viewY: Float,
         sequence: UInt64) {
        self.coordinator = coordinator
        self.generation = generation
        self.slotIndex = slotIndex
        self.instanceBuffer = instanceBuffer
        self.instanceCount = instanceCount
        self.instanceCapacity = instanceCapacity
        self.stripCount = stripCount
        self.viewX = viewX
        self.viewY = viewY
        self.sequence = sequence
    }

    func release() {
        os_unfair_lock_lock(&releaseLock)
        guard !released else {
            os_unfair_lock_unlock(&releaseLock)
            return
        }
        released = true
        os_unfair_lock_unlock(&releaseLock)
        coordinator.releaseFrame(slotIndex: slotIndex, generation: generation, sequence: sequence)
    }

    deinit {
        release()
    }
}

private final class MatrixSimulationLifetimeCounter {
    static let shared = MatrixSimulationLifetimeCounter()

    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func decrement() {
        lock.lock()
        count = max(0, count - 1)
        lock.unlock()
    }

    func snapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

struct MatrixSimulationSession {
    let coordinator: MatrixSimulationCoordinator
    let consumerToken: UInt64
}

final class MatrixSimulationCoordinatorRegistry {
    static let shared = MatrixSimulationCoordinatorRegistry()

    private final class WeakCoordinator {
        weak var value: MatrixSimulationCoordinator?

        init(_ value: MatrixSimulationCoordinator) {
            self.value = value
        }
    }

    private var coordinators: [MatrixSimulationConfiguration: WeakCoordinator] = [:]
    private let lock = NSLock()

    func session(device: MTLDevice,
                 settings: MatrixSettings,
                 isPreview: Bool,
                 active: Bool) throws -> MatrixSimulationSession {
        let configuration = MatrixSimulationConfiguration(device: device,
                                                           settings: settings,
                                                           isPreview: isPreview)
        lock.lock()
        defer { lock.unlock() }

        coordinators = coordinators.filter { $0.value.value != nil }
        if let existing = coordinators[configuration]?.value,
           let token = existing.registerConsumerIfAccepting(active: active) {
            return MatrixSimulationSession(coordinator: existing, consumerToken: token)
        }

        let coordinator = try MatrixSimulationCoordinator(device: device,
                                                           settings: settings,
                                                           configuration: configuration)
        guard let token = coordinator.registerConsumerIfAccepting(active: active) else {
            throw MatrixSimulationError.registrationFailed
        }
        coordinators[configuration] = WeakCoordinator(coordinator)
        return MatrixSimulationSession(coordinator: coordinator, consumerToken: token)
    }
}

final class MatrixSimulationCoordinator {
    private struct Slot {
        let instanceBuffer: MTLBuffer
        var generation: UInt64 = 0
        var sequence: UInt64 = 0
        var targetTime: CFTimeInterval = 0
        var instanceCount = 0
        var viewX: Float = 0
        var viewY: Float = 0
        var gpuReaders = 0
        var preparing = false
        var ready = false
    }

    private struct ProductionTask {
        let slotIndex: Int
        let instanceBuffer: MTLBuffer
        let generation: UInt64
        let sequence: UInt64
        let targetTime: CFTimeInterval
        let rebased: Bool
        let simulationFrames: Int
    }

    let configuration: MatrixSimulationConfiguration

    private let device: MTLDevice
    private let settings: MatrixSettings
    private let producerQueue = DispatchQueue(label: "com.hxsf.MetalMatrix.simulation",
                                              qos: .utility,
                                              autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private var slots: [Slot]
    private var registeredConsumers: UInt64 = 0
    private var enabledConsumers: UInt64 = 0
    private var activeConsumers: UInt64 = 0
    private var lastConsumerRequest = Array(repeating: CFTimeInterval(0), count: UInt64.bitWidth)
    private var lastConsumerSequence = Array<UInt64?>(repeating: nil, count: UInt64.bitWidth)
    private var readyCallbacks: [() -> Void] = []
    private var producerScheduled = false
    private var retired = false
    private var timelineRebaseRequested = true
    private var nextTargetTime = CACurrentMediaTime()
    private var nextSequence: UInt64 = 0
    private var generation: UInt64 = 1

    private var producedFrames: UInt64 = 0
    private var consumedFrames: UInt64 = 0
    private var staleFrames: UInt64 = 0
    private var starvedFrames: UInt64 = 0
    private var preparationMillisecondsTotal: Double = 0
    private var lastPreparationMilliseconds: Double = 0

    private var strips: [MatrixStrip] = []
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
    private var simulationAccumulator: Double = 0
    private var hasProducedSimulationFrame = false

    private let instanceCapacity: Int
    private let stripCount: Int
    private let frameInterval: CFTimeInterval
    private let readyLowWatermark = 4
    private let readyHighWatermark = 12
    private let gridSize = 70
    private let gridDepth: Float = 35
    private let waveSize = 22
    private let splashRatio: Float = 0.7
    private let niceViews: [(x: Float, y: Float)] = [
        (0, 0), (0, -20), (0, 20), (25, 0), (-25, 0), (25, 20), (-25, 20), (25, -20), (-25, -20),
        (10, 0), (-10, 0), (0, 0), (0, 0), (0, 0), (0, 0), (0, 0)
    ]

    init(device: MTLDevice,
         settings: MatrixSettings,
         configuration: MatrixSimulationConfiguration) throws {
        self.device = device
        self.settings = settings
        self.configuration = configuration
        frameInterval = 1.0 / Double(max(1, settings.frameRate))
        stripCount = min(2_000, max(1, Int(settings.density * 2.2)))
        instanceCapacity = stripCount * (gridSize + 1)

        let displayCount = max(1, NSScreen.screens.count)
        let requiredCapacity = readyHighWatermark + 1 + 3 * displayCount
        let ringCapacity = max(16, ((requiredCapacity + 7) / 8) * 8)
        var slots: [Slot] = []
        slots.reserveCapacity(ringCapacity)
        for _ in 0..<ringCapacity {
            guard let buffer = device.makeBuffer(
                length: instanceCapacity * MemoryLayout<GlyphInstance>.stride,
                options: .storageModeShared
            ) else {
                throw MatrixSimulationError.noFrameBuffer
            }
            slots.append(Slot(instanceBuffer: buffer))
        }
        self.slots = slots
        buildBrightnessRamp()
        resetSimulation()
        MatrixSimulationLifetimeCounter.shared.increment()
    }

    deinit {
        MatrixSimulationLifetimeCounter.shared.decrement()
    }

    func registerConsumerIfAccepting(active: Bool) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !retired else { return nil }
        let freeBits = ~registeredConsumers
        let bitIndex = freeBits.trailingZeroBitCount
        guard bitIndex < UInt64.bitWidth else { return nil }
        let token = UInt64(1) << UInt64(bitIndex)
        registeredConsumers |= token
        if active {
            let now = CACurrentMediaTime()
            enabledConsumers |= token
            lastConsumerRequest[bitIndex] = now
            activateConsumerLocked(token, now: now)
        }
        return token
    }

    func unregisterConsumer(_ token: UInt64) {
        lock.lock()
        guard registeredConsumers & token != 0 else {
            lock.unlock()
            return
        }
        registeredConsumers &= ~token
        enabledConsumers &= ~token
        activeConsumers &= ~token
        lastConsumerSequence[token.trailingZeroBitCount] = nil
        if activeConsumers == 0 {
            discardReadyFramesLocked()
        }
        if registeredConsumers == 0 {
            retired = true
            readyCallbacks.removeAll()
        }
        scheduleProducerIfNeededLocked()
        lock.unlock()
    }

    func setConsumer(_ token: UInt64, active: Bool) {
        lock.lock()
        guard registeredConsumers & token != 0 else {
            lock.unlock()
            return
        }
        if active {
            let now = CACurrentMediaTime()
            enabledConsumers |= token
            lastConsumerRequest[token.trailingZeroBitCount] = now
            activateConsumerLocked(token, now: now)
        } else {
            enabledConsumers &= ~token
            activeConsumers &= ~token
            lastConsumerSequence[token.trailingZeroBitCount] = nil
            if activeConsumers == 0 {
                discardReadyFramesLocked()
            }
        }
        scheduleProducerIfNeededLocked()
        lock.unlock()
    }

    func acquireFrame(consumer token: UInt64, at time: CFTimeInterval) -> MatrixSharedFrame? {
        lock.lock()
        guard registeredConsumers & token != 0,
              enabledConsumers & token != 0 else {
            lock.unlock()
            return nil
        }
        lastConsumerRequest[token.trailingZeroBitCount] = time
        expireLaggingConsumersLocked(now: time, excluding: token)
        if activeConsumers & token == 0 {
            activateConsumerLocked(token, now: time)
        }

        let bitIndex = token.trailingZeroBitCount
        let lastSequence = lastConsumerSequence[bitIndex]
        let latestAllowedTime = time + frameInterval * 0.5
        var selectedIndex: Int?
        var dueFrameCount = 0
        for index in slots.indices {
            let slot = slots[index]
            guard slot.ready,
                  lastSequence == nil || slot.sequence > lastSequence!,
                  slot.targetTime <= latestAllowedTime else { continue }
            dueFrameCount += 1
            if selectedIndex == nil || slot.sequence > slots[selectedIndex!].sequence {
                selectedIndex = index
            }
        }

        guard let selectedIndex else {
            let hasNewerFrame = slots.contains {
                $0.ready && (lastSequence == nil || $0.sequence > lastSequence!)
            }
            if !hasNewerFrame {
                starvedFrames &+= 1
            }
            scheduleProducerIfNeededLocked()
            lock.unlock()
            return nil
        }

        let selectedSequence = slots[selectedIndex].sequence
        lastConsumerSequence[bitIndex] = selectedSequence
        if dueFrameCount > 1 {
            staleFrames &+= UInt64(dueFrameCount - 1)
        }
        for index in slots.indices where slots[index].ready && slots[index].sequence < selectedSequence {
            retireSlotLocked(index)
        }

        slots[selectedIndex].gpuReaders += 1
        consumedFrames &+= 1
        let slot = slots[selectedIndex]
        let frame = MatrixSharedFrame(
            coordinator: self,
            generation: slot.generation,
            slotIndex: selectedIndex,
            instanceBuffer: slot.instanceBuffer,
            instanceCount: slot.instanceCount,
            instanceCapacity: instanceCapacity,
            stripCount: stripCount,
            viewX: slot.viewX,
            viewY: slot.viewY,
            sequence: slot.sequence
        )
        scheduleProducerIfNeededLocked()
        lock.unlock()
        return frame
    }

    func diagnosticsSnapshot() -> MatrixSimulationDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        let average = producedFrames > 0
            ? preparationMillisecondsTotal / Double(producedFrames)
            : 0
        return MatrixSimulationDiagnostics(
            ringCapacity: slots.count,
            readyFrames: readyFrameCountLocked(),
            preparingFrames: slots.count { $0.preparing },
            gpuReaders: slots.reduce(0) { $0 + $1.gpuReaders },
            activeConsumers: activeConsumers.nonzeroBitCount,
            liveCoordinators: MatrixSimulationLifetimeCounter.shared.snapshot(),
            producedFrames: producedFrames,
            consumedFrames: consumedFrames,
            staleFrames: staleFrames,
            starvedFrames: starvedFrames,
            lastSequence: nextSequence > 0 ? nextSequence - 1 : 0,
            lastPreparationMilliseconds: lastPreparationMilliseconds,
            averagePreparationMilliseconds: average
        )
    }

    fileprivate func releaseFrame(slotIndex: Int, generation: UInt64, sequence: UInt64) {
        lock.lock()
        guard slots.indices.contains(slotIndex),
              slots[slotIndex].generation == generation,
              slots[slotIndex].sequence == sequence,
              slots[slotIndex].gpuReaders > 0 else {
            lock.unlock()
            return
        }
        slots[slotIndex].gpuReaders -= 1
        if !slots[slotIndex].ready && slots[slotIndex].gpuReaders == 0 {
            slots[slotIndex].instanceCount = 0
        }
        scheduleProducerIfNeededLocked()
        lock.unlock()
    }

    func whenReady(_ callback: @escaping () -> Void) {
        lock.lock()
        if readyFrameCountLocked() > 0 {
            lock.unlock()
            callback()
        } else if retired {
            lock.unlock()
        } else {
            readyCallbacks.append(callback)
            lock.unlock()
        }
    }

    private func activateConsumerLocked(_ token: UInt64, now: CFTimeInterval) {
        let hadNoActiveConsumers = activeConsumers == 0
        activeConsumers |= token
        if hadNoActiveConsumers {
            timelineRebaseRequested = true
        }
        lastConsumerSequence[token.trailingZeroBitCount] = nil
        scheduleProducerIfNeededLocked()
    }

    private func expireLaggingConsumersLocked(now: CFTimeInterval, excluding current: UInt64) {
        let timeout = max(1.0, frameInterval * Double(readyHighWatermark * 2))
        var candidates = activeConsumers & ~current
        while candidates != 0 {
            let bitIndex = candidates.trailingZeroBitCount
            let token = UInt64(1) << UInt64(bitIndex)
            candidates &= ~token
            guard now - lastConsumerRequest[bitIndex] > timeout else { continue }
            activeConsumers &= ~token
            lastConsumerSequence[bitIndex] = nil
        }
        if activeConsumers == 0 {
            discardReadyFramesLocked()
        }
    }

    private func retireSlotLocked(_ index: Int) {
        guard slots[index].ready else { return }
        slots[index].ready = false
        if slots[index].gpuReaders == 0 {
            slots[index].instanceCount = 0
        }
    }

    private func discardReadyFramesLocked() {
        for index in slots.indices where slots[index].ready {
            retireSlotLocked(index)
        }
    }

    private func readyFrameCountLocked() -> Int {
        slots.count { $0.ready }
    }

    private func scheduleProducerIfNeededLocked() {
        guard !retired,
              activeConsumers != 0,
              readyFrameCountLocked() <= readyLowWatermark,
              !producerScheduled else { return }
        producerScheduled = true
        producerQueue.async { [weak self] in
            self?.produceUntilHighWatermark()
        }
    }

    private func produceUntilHighWatermark() {
        while let task = nextProductionTask() {
            let start = CACurrentMediaTime()
            let steps: Int
            if task.rebased || !hasProducedSimulationFrame {
                simulationAccumulator = 0
                steps = 1
                hasProducedSimulationFrame = true
            } else {
                var accumulatedSteps = 0
                for _ in 0..<task.simulationFrames {
                    simulationAccumulator += frameInterval * 60
                    let frameSteps = max(1, Int(simulationAccumulator))
                    simulationAccumulator -= Double(frameSteps)
                    accumulatedSteps += frameSteps
                }
                steps = accumulatedSteps
            }
            advanceSimulation(steps: steps)
            let count = updateInstances(buffer: task.instanceBuffer)
            let milliseconds = (CACurrentMediaTime() - start) * 1_000
            publish(task: task, instanceCount: count, preparationMilliseconds: milliseconds)
        }
    }

    private func nextProductionTask() -> ProductionTask? {
        lock.lock()
        guard !retired,
              activeConsumers != 0,
              readyFrameCountLocked() < readyHighWatermark,
              let slotIndex = slots.firstIndex(where: {
                  !$0.preparing && !$0.ready && $0.gpuReaders == 0
              }) else {
            producerScheduled = false
            lock.unlock()
            return nil
        }

        let now = CACurrentMediaTime()
        let rebased = timelineRebaseRequested
        var simulationFrames = 1
        if rebased {
            timelineRebaseRequested = false
            nextTargetTime = now
        } else {
            let maximumLag = frameInterval * Double(readyHighWatermark)
            if now - nextTargetTime > maximumLag {
                let missedFrames = max(1, Int((now - nextTargetTime) / frameInterval))
                nextSequence &+= UInt64(missedFrames)
                simulationFrames = min(8, missedFrames + 1)
                nextTargetTime = now
            }
        }
        let sequence = nextSequence
        nextSequence &+= 1
        let targetTime = nextTargetTime
        nextTargetTime += frameInterval
        let currentGeneration = generation
        slots[slotIndex].preparing = true
        slots[slotIndex].generation = currentGeneration
        slots[slotIndex].sequence = sequence
        let instanceBuffer = slots[slotIndex].instanceBuffer
        lock.unlock()
        return ProductionTask(slotIndex: slotIndex,
                              instanceBuffer: instanceBuffer,
                              generation: currentGeneration,
                              sequence: sequence,
                              targetTime: targetTime,
                              rebased: rebased,
                              simulationFrames: simulationFrames)
    }

    private func publish(task: ProductionTask,
                         instanceCount: Int,
                         preparationMilliseconds: Double) {
        lock.lock()
        guard slots.indices.contains(task.slotIndex),
              slots[task.slotIndex].preparing,
              slots[task.slotIndex].generation == task.generation,
              slots[task.slotIndex].sequence == task.sequence else {
            lock.unlock()
            return
        }

        slots[task.slotIndex].preparing = false
        guard activeConsumers != 0, !retired else {
            slots[task.slotIndex].ready = false
            lock.unlock()
            return
        }
        slots[task.slotIndex].targetTime = task.targetTime
        slots[task.slotIndex].instanceCount = instanceCount
        slots[task.slotIndex].viewX = viewX
        slots[task.slotIndex].viewY = viewY
        slots[task.slotIndex].ready = true
        producedFrames &+= 1
        lastPreparationMilliseconds = preparationMilliseconds
        preparationMillisecondsTotal += preparationMilliseconds
        let callbacks = readyCallbacks
        readyCallbacks.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }

    private func resetSimulation() {
        rng = 0x4d6574616c4d6174
        simulationAccumulator = 0
        hasProducedSimulationFrame = false
        resetTracking()
        strips = (0..<stripCount).map { _ in
            var strip = makeStrip()
            strip.erasing = true
            strip.spinnerY = randomFloat(Float(gridSize))
            strip.glyphs = Array(repeating: 0, count: gridSize)
            return strip
        }
    }

    private func advanceSimulation(steps: Int) {
        for _ in 0..<max(1, min(8, steps)) {
            for index in strips.indices {
                tickStrip(index: index)
            }
            autoTrack()
        }
    }

    private func updateInstances(buffer: MTLBuffer) -> Int {
        let pointer = buffer.contents().bindMemory(to: GlyphInstance.self, capacity: instanceCapacity)
        var count = 0
        let glyphSize = SIMD2<Float>(1, 1)

        for strip in strips {
            for glyphIndex in 0..<gridSize {
                let glyph = strip.glyphs[glyphIndex]
                var below = strip.spinnerY >= Float(glyphIndex)
                if strip.erasing { below.toggle() }
                guard glyph != 0 && below && count < instanceCapacity else { continue }

                pointer[count] = GlyphInstance(
                    position: SIMD3(strip.x, strip.y - Float(glyphIndex), strip.z),
                    size: glyphSize,
                    glyph: UInt32(abs(glyph) - 1),
                    brightness: stripBrightness(strip, glyphIndex: glyphIndex, glyph: glyph),
                    highlight: strip.highlights[glyphIndex] ? 1 : 0
                )
                count += 1
            }

            if !strip.erasing && count < instanceCapacity {
                pointer[count] = GlyphInstance(
                    position: SIMD3(strip.x, strip.y - strip.spinnerY, strip.z),
                    size: glyphSize,
                    glyph: UInt32(abs(strip.spinnerGlyph) - 1),
                    brightness: glyphBrightness(glyph: strip.spinnerGlyph,
                                                highlight: false,
                                                z: strip.z,
                                                baseBrightness: 1),
                    highlight: 0
                )
                count += 1
            }
        }
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
            }
            strips[index].erasing = true
            strips[index].spinnerY = 0
            strips[index].spinnerSpeed /= 2
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
        return glyphBrightness(glyph: glyph,
                               highlight: strip.highlights[glyphIndex],
                               z: strip.z,
                               baseBrightness: base)
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

private enum MatrixSimulationError: Error {
    case noFrameBuffer
    case registrationFailed
}
