import Accelerate
import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

final class SystemAudioSpectrumCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onSpectrum: (([Float]) -> Void)?
    var onPermissionRequired: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private let sampleQueue = DispatchQueue(
        label: "com.xiyue.VideoWallpaper.system-audio",
        qos: .utility
    )
    private var stream: SCStream?
    private var isStarting = false
    private var shouldBeRunning = false
    private var didReportMissingPermission = false
    private var smoothedSpectrum = Array(repeating: Float(0), count: 32)
    private var analysisSamples = Array(repeating: Float(0), count: 2_048)
    private var analysisSampleCount = 0
    private var analysisWriteIndex = 0
    private var lastDeliveryTime: TimeInterval = 0
    private var didLogAudioFormat = false
    private var didLogNonSilentSpectrum = false
    private let fftSize = 2_048
    private lazy var hannWindow: [Float] = (0..<fftSize).map { index in
        let phase = Float(index) / Float(fftSize - 1)
        return 0.5 - 0.5 * cos(2 * Float.pi * phase)
    }
    private let dftSetup = vDSP_DFT_zrop_CreateSetup(nil, 2_048, .FORWARD)
    private var dftInputEven = Array(repeating: Float(0), count: 1_024)
    private var dftInputOdd = Array(repeating: Float(0), count: 1_024)
    private var dftOutputReal = Array(repeating: Float(0), count: 1_024)
    private var dftOutputImaginary = Array(repeating: Float(0), count: 1_024)
    private var dftMagnitudes = Array(repeating: Float(0), count: 1_024)

    deinit {
        if let dftSetup {
            vDSP_DFT_DestroySetup(dftSetup)
        }
    }

    func start() {
        shouldBeRunning = true
        guard stream == nil, !isStarting else { return }
        guard CGPreflightScreenCaptureAccess() else {
            reportMissingPermissionIfNeeded()
            return
        }

        isStarting = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
                guard let display = content.displays.first else {
                    throw NSError(
                        domain: "VideoWallpaper.SystemAudio",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "没有可用于系统音频采集的显示器。"]
                    )
                }

                let filter = SCContentFilter(
                    display: display,
                    excludingApplications: [],
                    exceptingWindows: []
                )
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true
                configuration.sampleRate = 48_000
                configuration.channelCount = 1
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                configuration.queueDepth = 1
                configuration.showsCursor = false
                configuration.sourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)

                let candidate = SCStream(filter: filter, configuration: configuration, delegate: self)
                // Some macOS releases continue producing video frames for audio-only streams.
                // Accept a throttled 2x2 screen output so ScreenCaptureKit does not flood
                // WindowServer and the unified log with undeliverable frame callbacks.
                try candidate.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
                try candidate.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
                try await candidate.startCapture()

                await MainActor.run {
                    self.stream = candidate
                    self.isStarting = false
                    self.didReportMissingPermission = false
                    NSLog("System audio spectrum capture started")
                }
            } catch {
                await MainActor.run {
                    self.isStarting = false
                    if !CGPreflightScreenCaptureAccess() {
                        self.reportMissingPermissionIfNeeded()
                    } else {
                        self.onFailure?(error.localizedDescription)
                    }
                }
            }
        }
    }

    func stop() {
        shouldBeRunning = false
        isStarting = false
        let activeStream = stream
        stream = nil
        let silence = Array(repeating: Float(0), count: 32)
        sampleQueue.async { [weak self] in
            self?.smoothedSpectrum = silence
            self?.analysisSamples = Array(repeating: 0, count: 2_048)
            self?.analysisSampleCount = 0
            self?.analysisWriteIndex = 0
            self?.lastDeliveryTime = 0
        }
        onSpectrum?(silence)
        guard let activeStream else { return }
        Task {
            try? await activeStream.stopCapture()
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid else { return }
        process(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stream = nil
            self.isStarting = false
            if !CGPreflightScreenCaptureAccess() {
                self.reportMissingPermissionIfNeeded()
            } else {
                self.onFailure?(error.localizedDescription)
            }
        }
    }

    func authorizationMayHaveChanged() {
        guard shouldBeRunning, stream == nil, !isStarting else { return }
        guard CGPreflightScreenCaptureAccess() else { return }
        didReportMissingPermission = false
        start()
    }

    private func process(_ sampleBuffer: CMSampleBuffer) {
        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                      let samples = pcmSamples(
                        from: audioBufferList,
                        description: description
                      ),
                      !samples.isEmpty else {
                    return
                }
                if !didLogAudioFormat {
                    didLogAudioFormat = true
                    NSLog(
                        "System audio format: id=%u flags=%u bits=%u channels=%u buffers=%ld",
                        description.mFormatID,
                        description.mFormatFlags,
                        description.mBitsPerChannel,
                        description.mChannelsPerFrame,
                        audioBufferList.count
                    )
                }

                var writeIndex = analysisWriteIndex
                analysisSamples.withUnsafeMutableBufferPointer { buffer in
                    for sample in samples {
                        buffer[writeIndex] = sample
                        writeIndex = (writeIndex + 1) % buffer.count
                    }
                }
                analysisWriteIndex = writeIndex
                analysisSampleCount = min(analysisSamples.count, analysisSampleCount + samples.count)

                let now = ProcessInfo.processInfo.systemUptime
                guard analysisSampleCount >= 1_024,
                      now - lastDeliveryTime >= 1.0 / 20.0 else { return }
                lastDeliveryTime = now
                let orderedSamples = orderedAnalysisSamples()
                let spectrum = orderedSamples.withUnsafeBufferPointer { bufferedSamples in
                    calculateSpectrum(samples: bufferedSamples, sampleRate: description.mSampleRate)
                }
                if !didLogNonSilentSpectrum, let peak = spectrum.max(), peak > 0.01 {
                    didLogNonSilentSpectrum = true
                    NSLog("System audio spectrum received, peak=%.3f", peak)
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onSpectrum?(spectrum)
                }
            }
        } catch {
            return
        }
    }

    private func reportMissingPermissionIfNeeded() {
        guard !didReportMissingPermission else { return }
        didReportMissingPermission = true
        onPermissionRequired?()
    }

    private func orderedAnalysisSamples() -> [Float] {
        guard analysisSampleCount == analysisSamples.count else {
            return Array(analysisSamples.prefix(analysisSampleCount))
        }
        return Array(analysisSamples[analysisWriteIndex...])
            + Array(analysisSamples[..<analysisWriteIndex])
    }

    private func pcmSamples(
        from audioBufferList: UnsafeMutableAudioBufferListPointer,
        description: AudioStreamBasicDescription
    ) -> [Float]? {
        guard description.mFormatID == kAudioFormatLinearPCM,
              let buffer = audioBufferList.first,
              let data = buffer.mData else {
            return nil
        }

        let flags = description.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0
        let isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let channelStride = isNonInterleaved ? 1 : max(1, Int(description.mChannelsPerFrame))
        let bits = Int(description.mBitsPerChannel)
        let bytesPerSample = max(1, bits / 8)
        let valueCount = Int(buffer.mDataByteSize) / bytesPerSample
        guard valueCount > 0 else { return nil }

        var result: [Float] = []
        result.reserveCapacity(max(1, valueCount / channelStride))
        if isFloat, bits == 32 {
            let values = data.assumingMemoryBound(to: Float.self)
            for index in stride(from: 0, to: valueCount, by: channelStride) {
                let value = values[index]
                result.append(value.isFinite ? max(-1, min(1, value)) : 0)
            }
        } else if isFloat, bits == 64 {
            let values = data.assumingMemoryBound(to: Double.self)
            for index in stride(from: 0, to: valueCount, by: channelStride) {
                let value = values[index]
                result.append(value.isFinite ? Float(max(-1, min(1, value))) : 0)
            }
        } else if isSignedInteger, bits == 16 {
            let values = data.assumingMemoryBound(to: Int16.self)
            for index in stride(from: 0, to: valueCount, by: channelStride) {
                result.append(Float(values[index]) / Float(Int16.max))
            }
        } else if isSignedInteger, bits == 32 {
            let values = data.assumingMemoryBound(to: Int32.self)
            for index in stride(from: 0, to: valueCount, by: channelStride) {
                result.append(Float(values[index]) / Float(Int32.max))
            }
        } else {
            return nil
        }
        return result
    }

    private func calculateSpectrum(
        samples: UnsafeBufferPointer<Float>,
        sampleRate: Double
    ) -> [Float] {
        let windowSize = min(fftSize, samples.count)
        guard windowSize == fftSize, sampleRate > 0, let dftSetup else {
            return smoothedSpectrum
        }

        let start = samples.count - windowSize
        var mean = Float(0)
        for index in 0..<windowSize {
            mean += samples[start + index]
        }
        mean /= Float(windowSize)

        let window = hannWindow
        for index in 0..<(windowSize / 2) {
            let evenIndex = index * 2
            dftInputEven[index] = (samples[start + evenIndex] - mean) * window[evenIndex]
            dftInputOdd[index] = (samples[start + evenIndex + 1] - mean) * window[evenIndex + 1]
        }
        dftInputEven.withUnsafeBufferPointer { inputEven in
            dftInputOdd.withUnsafeBufferPointer { inputOdd in
                dftOutputReal.withUnsafeMutableBufferPointer { outputReal in
                    dftOutputImaginary.withUnsafeMutableBufferPointer { outputImaginary in
                        vDSP_DFT_Execute(
                            dftSetup,
                            inputEven.baseAddress!,
                            inputOdd.baseAddress!,
                            outputReal.baseAddress!,
                            outputImaginary.baseAddress!
                        )
                        var splitOutput = DSPSplitComplex(
                            realp: outputReal.baseAddress!,
                            imagp: outputImaginary.baseAddress!
                        )
                        dftMagnitudes.withUnsafeMutableBufferPointer { magnitudes in
                            vDSP_zvabs(
                                &splitOutput,
                                1,
                                magnitudes.baseAddress!,
                                1,
                                vDSP_Length(magnitudes.count)
                            )
                        }
                    }
                }
            }
        }

        let minimumFrequency = 45.0
        let maximumFrequency = min(18_000.0, sampleRate * 0.46)
        let ratio = maximumFrequency / minimumFrequency
        var result = Array(repeating: Float(0), count: 32)

        for band in 0..<32 {
            let lower = minimumFrequency * pow(ratio, Double(band) / 32.0)
            let upper = minimumFrequency * pow(ratio, Double(band + 1) / 32.0)
            let lowerBin = max(1, Int(floor(lower * Double(windowSize) / sampleRate)))
            let upperBin = min(
                windowSize / 2 - 1,
                max(lowerBin, Int(ceil(upper * Double(windowSize) / sampleRate)))
            )
            var power = Double(0)
            for bin in lowerBin...upperBin {
                let magnitude = Double(dftMagnitudes[bin])
                power += magnitude * magnitude
            }

            // vDSP's real-to-complex forward transform has an additional 2x scale.
            let binCount = Double(upperBin - lowerBin + 1)
            let amplitude = sqrt(power / binCount) * 2 / Double(windowSize)
            let decibels = 20 * log10(max(amplitude, 0.000_000_1))
            let normalized = Float(max(0, min(1, (decibels + 54) / 42)))
            let shaped = pow(normalized, 1.08)
            let previous = smoothedSpectrum[band]
            result[band] = shaped > previous
                ? previous * 0.12 + shaped * 0.88
                : previous * 0.68 + shaped * 0.32
        }

        smoothedSpectrum = result
        return result
    }
}
