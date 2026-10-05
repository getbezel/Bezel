import Accelerate
import Foundation
import Synchronization

/// Preallocated stereo FFT workspace. Only the serial HAL callback touches the
/// sample buffers; atomic band values are the sole cross-thread interface.
final class AudioSpectrum: @unchecked Sendable {
    private let count = 512
    private let setup: FFTSetup?
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    private let window = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    private let windowed = UnsafeMutablePointer<Float>.allocate(capacity: 512)
    private let real = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let imaginary = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let leftPower = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let rightPower = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    private let edges: [Int]
    private let interval: Int
    private var position = 0
    private let band0 = Atomic<UInt32>(0)
    private let band1 = Atomic<UInt32>(0)
    private let band2 = Atomic<UInt32>(0)
    private let band3 = Atomic<UInt32>(0)
    private let band4 = Atomic<UInt32>(0)
    private let band5 = Atomic<UInt32>(0)
    private let band6 = Atomic<UInt32>(0)

    init(sampleRate: Double) {
        let rate = sampleRate.isFinite ? min(384_000, max(8_000, sampleRate)) : 48_000
        interval = max(512, Int(rate / 20))
        edges = [1] + [150.0, 300, 600, 1200, 2400, 4800].map { min(255, max(1, Int(($0 * 512 / rate).rounded()))) } + [256]
        setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))
        left.initialize(repeating: 0, count: 512)
        right.initialize(repeating: 0, count: 512)
        window.initialize(repeating: 0, count: 512)
        windowed.initialize(repeating: 0, count: 512)
        real.initialize(repeating: 0, count: 256)
        imaginary.initialize(repeating: 0, count: 256)
        leftPower.initialize(repeating: 0, count: 256)
        rightPower.initialize(repeating: 0, count: 256)
        vDSP_hann_window(window, 512, Int32(vDSP_HANN_NORM))
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
        left.deallocate(); right.deallocate(); window.deallocate(); windowed.deallocate()
        real.deallocate(); imaginary.deallocate(); leftPower.deallocate(); rightPower.deallocate()
    }

    /// At most twenty FFT pairs per second; no allocations, locks or dispatch.
    func offer(left l: Float, right r: Float) {
        guard setup != nil else { return }
        if position < count { left[position] = l.isFinite ? l : 0; right[position] = r.isFinite ? r : 0 }
        position += 1
        if position == count { analyze() }
        if position >= interval { position = 0 }
    }

    func clear() {
        position = 0
        for index in 0..<7 { store(0, at: index) }
    }

    var bands: [Double] {
        [band0.load(ordering: .relaxed), band1.load(ordering: .relaxed), band2.load(ordering: .relaxed),
         band3.load(ordering: .relaxed), band4.load(ordering: .relaxed), band5.load(ordering: .relaxed),
         band6.load(ordering: .relaxed)].map { Double(Float(bitPattern: $0)) }
    }

    private func transform(_ source: UnsafeMutablePointer<Float>, power: UnsafeMutablePointer<Float>) {
        guard let setup else { return }
        vDSP_vmul(source, 1, window, 1, windowed, 1, 512)
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: 256) {
            vDSP_ctoz($0, 2, &split, 1, 256)
        }
        vDSP_fft_zrip(setup, &split, 1, 9, FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, power, 1, 256)
        power[0] = 0 // Packed DC and Nyquist are not display bands.
    }

    private func analyze() {
        transform(left, power: leftPower)
        transform(right, power: rightPower)
        for band in 0..<7 {
            var power: Float = 0
            for bin in edges[band]..<edges[band + 1] { power += (leftPower[bin] + rightPower[bin]) * 0.5 }
            let amplitude = sqrtf(max(0, power)) * (2 / Float(count))
            let normalized = amplitude > 0 ? min(1, max(0, (20 * log10f(amplitude) + 70) / 64)) : 0
            store(normalized.isFinite ? normalized : 0, at: band)
        }
    }

    private func store(_ value: Float, at index: Int) {
        switch index {
        case 0: band0.store(value.bitPattern, ordering: .relaxed)
        case 1: band1.store(value.bitPattern, ordering: .relaxed)
        case 2: band2.store(value.bitPattern, ordering: .relaxed)
        case 3: band3.store(value.bitPattern, ordering: .relaxed)
        case 4: band4.store(value.bitPattern, ordering: .relaxed)
        case 5: band5.store(value.bitPattern, ordering: .relaxed)
        default: band6.store(value.bitPattern, ordering: .relaxed)
        }
    }
}
