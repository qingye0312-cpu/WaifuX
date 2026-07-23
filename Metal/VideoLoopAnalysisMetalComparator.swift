import Foundation
import Metal

struct VideoLoopAnalysisDifferenceMetrics: Sendable {
    let absoluteDifferenceTotal: Int
    let squaredDifferenceTotal: Int
    let strongDifferenceCount: Int
    let sampleCount: Int
}

/// Computes the low-resolution signature matrix used by loop-point refinement.
/// The caller retains candidate selection and thresholds; this service only
/// replaces the dense per-pixel difference work with one Metal dispatch.
final class VideoLoopAnalysisMetalComparator: @unchecked Sendable {
    static let shared = VideoLoopAnalysisMetalComparator()

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLComputePipelineState?

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return
        }

        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void loopSignatureDifference(
            const device uchar *referenceLuma [[buffer(0)]],
            const device uchar *candidateLuma [[buffer(1)]],
            device atomic_uint *absoluteTotals [[buffer(2)]],
            device atomic_uint *squaredTotals [[buffer(3)]],
            device atomic_uint *strongTotals [[buffer(4)]],
            constant uint &candidateCount [[buffer(5)]],
            constant uint &sampleCount [[buffer(6)]],
            uint3 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= sampleCount || gid.z >= candidateCount) {
                return;
            }

            const uint pairIndex = gid.y * candidateCount + gid.z;
            const uint referenceIndex = gid.y * sampleCount + gid.x;
            const uint candidateIndex = gid.z * sampleCount + gid.x;
            const uint difference = uint(abs(int(referenceLuma[referenceIndex]) - int(candidateLuma[candidateIndex])));

            atomic_fetch_add_explicit(&absoluteTotals[pairIndex], difference, memory_order_relaxed);
            atomic_fetch_add_explicit(&squaredTotals[pairIndex], difference * difference, memory_order_relaxed);
            if (difference > 36) {
                atomic_fetch_add_explicit(&strongTotals[pairIndex], 1, memory_order_relaxed);
            }
        }
        """

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let function = library.makeFunction(name: "loopSignatureDifference") else {
                return
            }
            self.device = device
            self.commandQueue = commandQueue
            self.pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            self.device = nil
            self.commandQueue = nil
            self.pipelineState = nil
        }
    }

    /// Returns one metric for every reference/candidate pair in row-major order.
    /// `nil` leaves the caller on its existing CPU implementation.
    func pairwiseDifferences(
        referenceSignatures: [[UInt8]],
        candidateSignatures: [[UInt8]]
    ) -> [VideoLoopAnalysisDifferenceMetrics]? {
        guard let device,
              let commandQueue,
              let pipelineState,
              let firstReference = referenceSignatures.first,
              !firstReference.isEmpty,
              !candidateSignatures.isEmpty else {
            return nil
        }

        let sampleCount = firstReference.count
        guard referenceSignatures.allSatisfy({ $0.count == sampleCount }),
              candidateSignatures.allSatisfy({ $0.count == sampleCount }),
              sampleCount <= Int(UInt32.max),
              referenceSignatures.count <= Int(UInt32.max),
              candidateSignatures.count <= Int(UInt32.max) else {
            return nil
        }

        let referenceBytes = referenceSignatures.flatMap { $0 }
        let candidateBytes = candidateSignatures.flatMap { $0 }
        let pairCount = referenceSignatures.count * candidateSignatures.count
        guard pairCount > 0,
              pairCount <= Int(UInt32.max) / MemoryLayout<UInt32>.size,
              let referenceBuffer = makeBuffer(bytes: referenceBytes, device: device),
              let candidateBuffer = makeBuffer(bytes: candidateBytes, device: device) else {
            return nil
        }

        let outputLength = pairCount * MemoryLayout<UInt32>.size
        guard let absoluteBuffer = device.makeBuffer(length: outputLength, options: .storageModeShared),
              let squaredBuffer = device.makeBuffer(length: outputLength, options: .storageModeShared),
              let strongBuffer = device.makeBuffer(length: outputLength, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }

        blitEncoder.fill(buffer: absoluteBuffer, range: 0..<outputLength, value: 0)
        blitEncoder.fill(buffer: squaredBuffer, range: 0..<outputLength, value: 0)
        blitEncoder.fill(buffer: strongBuffer, range: 0..<outputLength, value: 0)
        blitEncoder.endEncoding()

        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        var candidateCount = UInt32(candidateSignatures.count)
        var sampleCount32 = UInt32(sampleCount)
        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setBuffer(referenceBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(candidateBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(absoluteBuffer, offset: 0, index: 2)
        computeEncoder.setBuffer(squaredBuffer, offset: 0, index: 3)
        computeEncoder.setBuffer(strongBuffer, offset: 0, index: 4)
        computeEncoder.setBytes(&candidateCount, length: MemoryLayout<UInt32>.size, index: 5)
        computeEncoder.setBytes(&sampleCount32, length: MemoryLayout<UInt32>.size, index: 6)

        let threadsPerThreadgroup = MTLSize(
            width: min(sampleCount, max(1, pipelineState.threadExecutionWidth)),
            height: 1,
            depth: 1
        )
        computeEncoder.dispatchThreads(
            MTLSize(
                width: sampleCount,
                height: referenceSignatures.count,
                depth: candidateSignatures.count
            ),
            threadsPerThreadgroup: threadsPerThreadgroup
        )
        computeEncoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed, commandBuffer.error == nil else {
            return nil
        }

        let absoluteValues = absoluteBuffer.contents().bindMemory(to: UInt32.self, capacity: pairCount)
        let squaredValues = squaredBuffer.contents().bindMemory(to: UInt32.self, capacity: pairCount)
        let strongValues = strongBuffer.contents().bindMemory(to: UInt32.self, capacity: pairCount)
        return (0..<pairCount).map { index in
            VideoLoopAnalysisDifferenceMetrics(
                absoluteDifferenceTotal: Int(absoluteValues[index]),
                squaredDifferenceTotal: Int(squaredValues[index]),
                strongDifferenceCount: Int(strongValues[index]),
                sampleCount: sampleCount
            )
        }
    }

    private func makeBuffer(bytes: [UInt8], device: MTLDevice) -> MTLBuffer? {
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: rawBuffer.count,
                options: .storageModeShared
            )
        }
    }
}
