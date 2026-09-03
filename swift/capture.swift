// Screen capture straight from the compositor (ScreenCaptureKit) into the hardware
// encoder (VideoToolbox), with no ffmpeg in between.
//
// Writes H.264 to stdout as [4-byte length][NAL], which is exactly the shape the
// encoder already produces (AVCC), so nothing has to be re-parsed downstream.
//
//   capture [displayID] [width] [height] [fps] [bitrate]

import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

let args = CommandLine.arguments
let wantedDisplayID: CGDirectDisplayID? = args.count > 1 ? CGDirectDisplayID(args[1]) : nil
let outWidth = args.count > 2 ? Int(args[2])! : 1280
let outHeight = args.count > 3 ? Int(args[3])! : 800
let fps = args.count > 4 ? Int(args[4])! : 60
let bitrate = args.count > 5 ? Int(args[5])! : 5_000_000

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

/// Writes length-prefixed NALs to stdout. One place, so writes stay ordered.
final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private let fd = FileHandle.standardOutput.fileDescriptor

    func write(_ bytes: UnsafeRawPointer, _ count: Int) {
        lock.lock()
        var off = 0
        while off < count {
            let n = Darwin.write(fd, bytes.advanced(by: off), count - off)
            if n <= 0 { break }
            off += n
        }
        lock.unlock()
    }

    func writeNAL(_ data: UnsafeRawPointer, _ len: Int) {
        var header = UInt32(len).bigEndian
        withUnsafeBytes(of: &header) { self.write($0.baseAddress!, 4) }
        write(data, len)
    }
}

let output = Output()

/// VideoToolbox H.264 encoder tuned for the lowest latency we can ask for.
final class Encoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private var wroteParams = false
    var encoded = 0

    init() {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(outWidth), height: Int32(outHeight),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [
                kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!
            ] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &s)
        guard status == noErr, let session = s else {
            log("не удалось создать кодировщик: \(status)")
            exit(1)
        }
        self.session = session

        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)  // no B-frames
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps / 2))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 0.5))
        if #available(macOS 11.0, *) {
            set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ pixels: CVImageBuffer, _ pts: CMTime) {
        guard let session else { return }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixels, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: nil,
            infoFlagsOut: nil) { [weak self] status, _, sample in
                if status != noErr { log("кодировщик вернул ошибку \(status)") ; return }
                guard let sample, CMSampleBufferDataIsReady(sample) else { return }
                self?.encoded += 1
                self?.emit(sample)
            }
    }

    /// Pull the encoded NALs out and hand them to stdout, re-sending SPS/PPS on keyframes
    /// so a client that joins mid-stream can start decoding straight away.
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

        if keyframe || !wroteParams, let format = CMSampleBufferGetFormatDescription(sample) {
            for i in 0..<2 {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                var count = 0
                var headerLen: Int32 = 0
                let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: &headerLen)
                if st == noErr, let ptr { output.writeNAL(ptr, size) }
            }
            wroteParams = true
        }

        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let base = pointer else { return }

        // AVCC: [4-byte length][NAL][4-byte length][NAL]... - already our format,
        // just pass each unit through.
        var offset = 0
        while offset + 4 <= length {
            var nalLen: UInt32 = 0
            memcpy(&nalLen, base + offset, 4)
            let size = Int(UInt32(bigEndian: nalLen))
            offset += 4
            if size <= 0 || offset + size > length { break }
            output.writeNAL(base + offset, size)
            offset += size
        }
    }
}

let encoder = Encoder()

/// Keeps the stream running at a steady rate by repeating the last frame when the
/// screen is idle - a decoder pipeline measured in frames stalls without this.
final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var last: CVImageBuffer?
    private var lastAt = CFAbsoluteTimeGetCurrent()
    private var pts = CMTime.zero
    private let step: CMTime

    init() {
        step = CMTime(value: 1, timescale: CMTimeScale(fps))
        let interval = 1.0 / Double(fps)
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            while true {
                Thread.sleep(forTimeInterval: interval)
                lock.lock()
                let idleFor = CFAbsoluteTimeGetCurrent() - lastAt
                let frame = last
                lock.unlock()
                if let frame, idleFor >= interval {
                    push(frame, fresh: false)
                }
            }
        }
    }

    func push(_ frame: CVImageBuffer, fresh: Bool) {
        lock.lock()
        if fresh {
            last = frame
            lastAt = CFAbsoluteTimeGetCurrent()
        } else {
            lastAt = CFAbsoluteTimeGetCurrent()
        }
        pts = CMTimeAdd(pts, step)
        let stamp = pts
        lock.unlock()
        encoder.encode(frame, stamp)
    }
}

let ticker = Ticker()

final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var arrived = 0, usable = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
                of type: SCStreamOutputType) {
        arrived += 1
        guard type == .screen, CMSampleBufferDataIsReady(sample),
              let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        usable += 1
        if arrived % 300 == 0 {
            log("кадров с экрана: \(arrived), пригодных: \(usable), закодировано: \(encoder.encoded)")
        }
        ticker.push(pixels, fresh: true)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("поток остановлен: \(error)")
        exit(1)
    }
}

let handler = StreamOutput()
let ready = DispatchSemaphore(value: 0)
// must outlive the callback below, otherwise the stream is released and dies silently
nonisolated(unsafe) var liveStream: SCStream?

SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
    guard let content else {
        log("нет доступа к экрану: \(String(describing: error))")
        exit(1)
    }
    // the virtual screen is the one we were told about, otherwise take the last
    let display = content.displays.first { $0.displayID == wantedDisplayID } ?? content.displays.last
    guard let display else {
        log("дисплей не найден")
        exit(1)
    }
    log("захватываю дисплей \(display.displayID) \(display.width)x\(display.height)")

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.width = outWidth
    config.height = outHeight
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    config.showsCursor = true
    config.queueDepth = 3            // shallow: we want the newest frame, not a backlog
    config.scalesToFit = true

    let stream = SCStream(filter: filter, configuration: config, delegate: handler)
    liveStream = stream
    do {
        try stream.addStreamOutput(handler, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "capture"))
        stream.startCapture { err in
            if let err { log("старт не удался: \(err)"); exit(1) }
            log("захват пошёл")
        }
    } catch {
        log("не смог настроить поток: \(error)")
        exit(1)
    }
    ready.signal()
}

ready.wait()
RunLoop.main.run()
