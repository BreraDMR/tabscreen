// Screen capture: ScreenCaptureKit straight into VideoToolbox.
//
// The one setting that matters here is EnableLowLatencyRateControl - without it the
// tablet's decoder buffers about nine frames and the whole thing feels laggy.

import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    /// Called with one complete NAL unit, ready to be framed and sent.
    var onNAL: ((Data, Bool) -> Void)?
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private var session: VTCompressionSession?
    private var wroteParams = false
    private let lock = NSLock()

    private var width = 1280
    private var height = 800
    private var fps = 60
    private var bitrate = 5_000_000

    private var lastFrame: CVImageBuffer?
    private var lastFrameAt = CFAbsoluteTimeGetCurrent()
    private var pts = CMTime.zero
    private var ticking = false

    var isRunning: Bool { stream != nil }

    // MARK: - lifecycle

    func start(displayID: CGDirectDisplayID, width: Int, height: Int,
               fps: Int, bitrate: Int, done: @escaping (String?) -> Void) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            guard let content, let display = content.displays.first(where: { $0.displayID == displayID })
                    ?? content.displays.last else {
                done("\(L.noScreenAccess): \(error?.localizedDescription ?? L.displayNotFound)")
                return
            }
            do {
                try self.makeEncoder()
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = width
                config.height = height
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
                config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                config.showsCursor = true
                config.queueDepth = 3
                config.scalesToFit = true

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen,
                                           sampleHandlerQueue: DispatchQueue(label: "capture"))
                self.stream = stream          // must be retained or the stream dies silently
                stream.startCapture { err in
                    if let err {
                        self.stream = nil
                        done("\(L.captureFailed): \(err.localizedDescription)")
                    } else {
                        self.startTicker()
                        done(nil)
                    }
                }
            } catch {
                done("\(L.captureSetupFailed): \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        ticking = false
        stream?.stopCapture { _ in }
        stream = nil
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
        wroteParams = false
        lastFrame = nil
        pts = .zero
    }

    // MARK: - encoder

    private func makeEncoder() throws {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [
                // The whole reason this project feels responsive.
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!
            ] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let session = s else {
            throw NSError(domain: "TabScreen", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "\(L.encoderFailed) (\(status))"])
        }
        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps / 2))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 0.5))
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    /// ScreenCaptureKit only sends a frame when the picture changes, but a decoder's
    /// pipeline is measured in frames - so a still screen would leave the last frame
    /// stuck inside it. Repeat the last frame to keep a steady beat.
    private func startTicker() {
        ticking = true
        let interval = 1.0 / Double(fps)
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            while let self, self.ticking {
                Thread.sleep(forTimeInterval: interval)
                self.lock.lock()
                let idle = CFAbsoluteTimeGetCurrent() - self.lastFrameAt
                let frame = self.lastFrame
                self.lock.unlock()
                if let frame, idle >= interval {
                    self.push(frame, fresh: false)
                }
            }
        }
    }

    private func push(_ frame: CVImageBuffer, fresh: Bool) {
        guard let session else { return }
        lock.lock()
        if fresh { lastFrame = frame }
        lastFrameAt = CFAbsoluteTimeGetCurrent()
        pts = CMTimeAdd(pts, CMTime(value: 1, timescale: CMTimeScale(fps)))
        let stamp = pts
        lock.unlock()

        VTCompressionSessionEncodeFrame(
            session, imageBuffer: frame, presentationTimeStamp: stamp,
            duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, sample in
                guard status == noErr, let sample, CMSampleBufferDataIsReady(sample) else { return }
                self?.emit(sample)
            }
    }

    private func emit(_ sample: CMSampleBuffer) {
        var keyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
            if let notSync = CFDictionaryGetValue(
                dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()) {
                keyframe = !CFBooleanGetValue(unsafeBitCast(notSync, to: CFBoolean.self))
            }
        }

        // Re-send SPS/PPS on every keyframe so a client can join at any moment.
        if keyframe || !wroteParams, let format = CMSampleBufferGetFormatDescription(sample) {
            for i in 0..<2 {
                var ptr: UnsafePointer<UInt8>?
                var size = 0, count = 0
                var headerLen: Int32 = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: &headerLen) == noErr, let ptr {
                    onNAL?(Data(bytes: ptr, count: size), false)
                }
            }
            wroteParams = true
        }

        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let base = pointer else { return }

        // AVCC layout: [4-byte length][NAL]...
        var offset = 0
        while offset + 4 <= length {
            var raw: UInt32 = 0
            memcpy(&raw, base + offset, 4)
            let size = Int(UInt32(bigEndian: raw))
            offset += 4
            if size <= 0 || offset + size > length { break }
            let data = Data(bytes: base + offset, count: size)
            onNAL?(data, (data[0] & 0x1f) == 5)
            offset += size
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferDataIsReady(sample),
              let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        push(pixels, fresh: true)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("\(L.captureStopped): \(error.localizedDescription)")
        self.stream = nil
    }
}
