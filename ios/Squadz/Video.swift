import AVFoundation
import CoreImage
import CoreMedia
import SquadKit
import UIKit
import VideoToolbox

// Squad video, first cut (docs/VIDEO.md). A phone's camera is encoded as H.264 at a low bit rate
// and sent, frame by frame, on the phone's own link to the leader's device, which decodes and
// shows it. A frame is shown and dropped, unless the leader is recording or snaps a still, which
// the whole squad is shown (StreamRecorder and H264Display.still, below).

/// Where pictures come from: the camera, or a made-up pattern where there is no camera.
@MainActor
protocol FrameSource: AnyObject {
    /// Calls `deliver` on the main actor with each picture. False if it can't start.
    func start(deliver: @escaping @MainActor (CVPixelBuffer) -> Void) async -> Bool
    func stop()
}

/// The back camera.
@MainActor
final class CameraSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "squadz.camera")
    private var deliver: (@MainActor (CVPixelBuffer) -> Void)?

    func start(deliver: @escaping @MainActor (CVPixelBuffer) -> Void) async -> Bool {
        guard await AVCaptureDevice.requestAccess(for: .video),
              let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera) else { return false }
        self.deliver = deliver
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard session.canAddInput(input) else { session.commitConfiguration(); return false }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return false }
        session.addOutput(output)
        // Upright, as the phone is usually held.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        session.commitConfiguration()
        let session = session
        queue.async { session.startRunning() }
        return true
    }

    func stop() {
        deliver = nil
        let session = session
        queue.async { session.stopRunning() }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let picture = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        nonisolated(unsafe) let sent = picture
        Task { @MainActor in self.deliver?(sent) }
    }
}

/// A moving pattern, for the simulator (which has no camera) and for tests.
@MainActor
final class PatternSource: FrameSource {
    private var timer: Timer?
    private var count = 0
    let width = 320, height = 240

    func start(deliver: @escaping @MainActor (CVPixelBuffer) -> Void) async -> Bool {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let picture = self.picture() else { return }
                deliver(picture)
            }
        }
        return true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Coloured bars with a white stripe that moves across, so a viewer can see it is live.
    func picture() -> CVPixelBuffer? {
        count += 1
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &made)
        guard let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bars: [(UInt8, UInt8, UInt8)] = [(40, 40, 200), (40, 160, 220), (60, 180, 60), (200, 120, 40), (160, 60, 160)]
        let stripe = (count * 6) % width
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let (b, g, r) = abs(x - stripe) < 6 ? (255, 255, 255) : bars[x * bars.count / width]
                row[x * 4] = b
                row[x * 4 + 1] = g
                row[x * 4 + 2] = r
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }
}

/// Pictures in, H.264 out, in Annex B form: each unit after a 00 00 00 01 start code. A key frame
/// carries the parameter sets in front, so a viewer can start from any key frame.
final class H264Encoder {
    private var session: VTCompressionSession?
    private var count: Int64 = 0
    private let fps: Int32
    /// Called on VideoToolbox's own queue.
    private let onFrame: @Sendable (_ isKey: Bool, _ data: Data) -> Void

    init?(width: Int, height: Int, kbps: Int, fps: Int = 10, onFrame: @escaping @Sendable (Bool, Data) -> Void) {
        self.fps = Int32(fps)
        self.onFrame = onFrame
        var made: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &made) == noErr,
              let session = made else { return nil }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: kbps * 1000))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        // A key frame every two seconds: a viewer who joins or drops a frame waits at most that long.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2))
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    func encode(_ picture: CVPixelBuffer) {
        guard let session else { return }
        let time = CMTime(value: count, timescale: fps)
        count += 1
        let onFrame = onFrame
        VTCompressionSessionEncodeFrame(session, imageBuffer: picture, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample, let (isKey, data) = Self.annexB(sample) else { return }
            onFrame(isKey, data)
        }
    }

    func stop() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    deinit { stop() }

    static let startCode = Data([0, 0, 0, 1])

    /// The encoder's own form (each unit after its length) turned into Annex B.
    static func annexB(_ sample: CMSampleBuffer) -> (isKey: Bool, data: Data)? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        var out = Data()
        if isKey {
            var sets = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &sets, nalUnitHeaderLengthOut: nil)
            for i in 0..<sets {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer,
                                                                         parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                         nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
                out += startCode
                out.append(pointer, count: size)
            }
        }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: length)
        let copied = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var at = 0
        while at + 4 <= length {
            let size = bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
            at += 4
            guard size > 0, at + size <= length else { return nil }
            out += startCode
            out += bytes[at..<at + size]
            at += size
        }
        return (isKey, out)
    }
}

/// Annex B H.264 in, pictures on a layer. It keeps nothing but the parameter sets.
@MainActor
final class H264Display {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?
    private var sets: (sps: Data, pps: Data)?
    /// Pictures shown since this was made.
    private(set) var shown = 0

    init() {
        layer.videoGravity = .resizeAspect
    }

    /// The pictures since the last key frame, that one first: what a still is made from.
    private var sinceKey: [CMSampleBuffer] = []

    /// Shows what a frame holds, and hands back what was shown so it can be kept. A frame that
    /// arrives before any key frame shows nothing.
    @discardableResult
    func show(_ annexB: Data, isKey: Bool = false) -> CMSampleBuffer? {
        guard let sample = samples(annexB).first else { return nil }
        if isKey { sinceKey = [] }
        if isKey || !sinceKey.isEmpty { sinceKey.append(sample) }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)
        shown += 1
        return sample
    }

    func clear() {
        layer.flushAndRemoveImage()
        format = nil
        sets = nil
        sinceKey = []
    }

    /// The picture on screen now, as a JPEG. It is decoded again from the last key frame on,
    /// since the layer that draws the stream doesn't give its pictures back.
    func still() -> Data? {
        guard let format, !sinceKey.isEmpty else { return nil }
        var made: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &made) == noErr,
              let session = made else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }
        var picture: CVImageBuffer?
        for sample in sinceKey {
            VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status == noErr, let image { picture = image }
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard let picture else { return nil }
        let image = CIImage(cvImageBuffer: picture)
        return CIContext().jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
    }

    /// The picture a frame holds, ready to show at once: none if no key frame has come yet. An
    /// encoder may cut one picture into several slices; they go to the decoder together.
    func samples(_ annexB: Data) -> [CMSampleBuffer] {
        var sps: Data?, pps: Data?
        var slices: [Data] = []
        for unit in Self.units(annexB) {
            guard let first = unit.first else { continue }
            switch first & 0x1F {
            case 7: sps = unit
            case 8: pps = unit
            case 1, 5: slices.append(unit)
            default: break
            }
        }
        if let sps, let pps, sets?.sps != sps || sets?.pps != pps {
            sets = (sps, pps)
            format = Self.format(sps: sps, pps: pps)
        }
        guard !slices.isEmpty, let format, let sample = Self.sample(slices, format: format) else { return [] }
        return [sample]
    }

    /// The units between start codes (00 00 01, with or without a zero in front).
    static func units(_ annexB: Data) -> [Data] {
        let bytes = [UInt8](annexB)
        var starts: [(code: Int, unit: Int)] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append((i > 0 && bytes[i - 1] == 0 ? i - 1 : i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        return starts.enumerated().compactMap { n, start in
            let end = n + 1 < starts.count ? starts[n + 1].code : bytes.count
            return end > start.unit ? Data(bytes[start.unit..<end]) : nil
        }
    }

    static func format(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var made: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                                                                           parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, formatDescriptionOut: &made)
            }
        }
        return status == noErr ? made : nil
    }

    static func sample(_ units: [Data], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        // The decoder wants each unit after its length, not after a start code.
        var data = Data()
        for unit in units {
            var bytes = UInt32(unit.count).bigEndian
            data += Data(bytes: &bytes, count: 4)
            data += unit
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: data.count, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return nil }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        // No clock: show each picture as it arrives.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

/// A phone streaming: pictures from a source, through the encoder, out as frames.
@MainActor
final class VideoStreamer {
    let stream: UUID
    private let source: FrameSource
    private let kbps: Int
    private var encoder: H264Encoder?
    private var count: UInt32 = 0
    private var last = Date.distantPast
    private let send: @MainActor (VideoMission.Frame) -> Void
    /// Frames sent since the start.
    private(set) var sent = 0

    /// Ten pictures a second is plenty for seeing what someone sees, and all a mesh can carry.
    static let fps = 10

    init(stream: UUID, source: FrameSource, kbps: Int, send: @escaping @MainActor (VideoMission.Frame) -> Void) {
        self.stream = stream
        self.source = source
        self.kbps = kbps
        self.send = send
    }

    func start() async -> Bool {
        await source.start { [weak self] picture in self?.take(picture) }
    }

    func stop() {
        source.stop()
        encoder?.stop()
        encoder = nil
    }

    private func take(_ picture: CVPixelBuffer) {
        // Cameras give thirty a second; pass on ten.
        let now = Date()
        guard now.timeIntervalSince(last) >= 1 / Double(Self.fps) - 0.01 else { return }
        last = now
        if encoder == nil {
            let stream = stream
            encoder = H264Encoder(width: CVPixelBufferGetWidth(picture), height: CVPixelBufferGetHeight(picture), kbps: kbps, fps: Self.fps) { [weak self] isKey, data in
                Task { @MainActor in
                    guard let self, self.encoder != nil else { return }
                    self.count &+= 1
                    self.sent += 1
                    self.send(VideoMission.Frame(stream: stream, count: self.count, isKey: isKey, data: data))
                }
            }
        }
        encoder?.encode(picture)
    }
}

/// Saves a stream to a video file as it arrives, without encoding it again: the frames the phone
/// sent go into the file as they are.
@MainActor
final class StreamRecorder {
    let url: URL
    let began: Date
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstAt: Date?
    private var last = CMTime.invalid
    /// Pictures written so far.
    private(set) var frames = 0

    init(url: URL, now: Date = .now) {
        self.url = url
        began = now
    }

    /// Adds a picture. The file starts at the first key frame, since nothing before one can be shown.
    func append(_ sample: CMSampleBuffer, isKey: Bool, now: Date = .now) {
        if writer == nil {
            guard isKey, let format = CMSampleBufferGetFormatDescription(sample),
                  let made = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
            let track = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            track.expectsMediaDataInRealTime = true
            guard made.canAdd(track) else { return }
            made.add(track)
            guard made.startWriting() else { return }
            made.startSession(atSourceTime: .zero)
            writer = made
            input = track
            firstAt = now
        }
        guard let input, let firstAt, input.isReadyForMoreMediaData else { return }
        // Pictures are timed by when they arrived, each strictly after the one before.
        var time = CMTime(seconds: now.timeIntervalSince(firstAt), preferredTimescale: 600)
        if last.isValid, time <= last { time = last + CMTime(value: 1, timescale: 600) }
        last = time
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var timed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing, sampleBufferOut: &timed) == noErr, let timed else { return }
        if !isKey, let attachments = CMSampleBufferGetSampleAttachmentsArray(timed, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if input.append(timed) { frames += 1 }
    }

    /// Closes the file. Returns how long it runs, or nil if nothing was written (the file is removed).
    func finish() async -> Double? {
        guard let writer, let input, frames > 0 else {
            self.writer?.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return max(0.1, last.seconds)
    }
}
