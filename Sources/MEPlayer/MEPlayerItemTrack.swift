//
//  Decoder.swift
//  KSPlayer
//
//  Created by kintan on 2018/3/9.
//
import AVFoundation
import CoreMedia
import ffmpeg
protocol TrackProtocol: AnyObject, CustomStringConvertible {
    var stream: UnsafeMutablePointer<AVStream> { get }
    var mediaType: AVFoundation.AVMediaType { get }
    var timebase: Timebase { get }
    var fps: Int { get }
    var rotation: Double { get }
    var bitRate: Int64 { get }
    var naturalSize: CGSize { get }
}

extension TrackProtocol {
    var streamIndex: Int32 { stream.pointee.index }
}

func == (lhs: TrackProtocol, rhs: TrackProtocol) -> Bool {
    lhs.streamIndex == rhs.streamIndex
}

class AssetTrack: TrackProtocol, CustomStringConvertible {
    var description: String {
        if let entry = av_dict_get(stream.pointee.metadata, "title", nil, 0), let title = entry.pointee.value {
            return String(cString: title)
        } else {
            if mediaType == .subtitle {
                return NSLocalizedString("内置字幕", comment: "")
            } else {
                return mediaType.rawValue
            }
        }
    }

    let stream: UnsafeMutablePointer<AVStream>
    let mediaType: AVFoundation.AVMediaType
    let timebase: Timebase
    let fps: Int
    let bitRate: Int64
    let rotation: Double
    let naturalSize: CGSize
    init?(stream: UnsafeMutablePointer<AVStream>) {
        self.stream = stream
        bitRate = stream.pointee.codecpar.pointee.bit_rate
        if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
            mediaType = .audio
        } else if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
            mediaType = .video
        } else if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE {
            mediaType = .subtitle
        } else {
            return nil
        }
        var timebase = Timebase(stream.pointee.time_base)
        if timebase.num <= 0 || timebase.den <= 0 {
            timebase = Timebase(num: 1, den: mediaType == .audio ? KSPlayerManager.audioPlayerSampleRate : 25000)
        }
        self.timebase = timebase
        rotation = stream.rotation
        naturalSize = CGSize(width: Int(stream.pointee.codecpar.pointee.width), height: Int(stream.pointee.codecpar.pointee.height))
        let frameRate = av_guess_frame_rate(nil, stream, nil)
        if stream.pointee.duration > 0, stream.pointee.nb_frames > 0, stream.pointee.nb_frames != stream.pointee.duration {
            fps = Int(stream.pointee.nb_frames * Int64(timebase.den) / (stream.pointee.duration * Int64(timebase.num)))
        } else if frameRate.den > 0, frameRate.num > 0 {
            fps = Int(frameRate.num / frameRate.den)
        } else {
            fps = mediaType == .audio ? 44 : 24
        }
    }
}

protocol PlayerItemTrackProtocol: Capacity {
    init(assetTrack: TrackProtocol, options: KSOptions)
    var mediaType: AVFoundation.AVMediaType { get }
    // 是否无缝循环
    var isLoopModel: Bool { get set }
    var delegate: CodecCapacityDelegate? { get set }
    func decode()
    func seek(time: TimeInterval)
    func endOfFile()
    func putPacket(packet: Packet)
    func getOutputRender(where predicate: ((MEFrame) -> Bool)?) -> MEFrame?
    func shutdown()
}

class FFPlayerItemTrack<Frame: MEFrame>: PlayerItemTrackProtocol, CustomStringConvertible {
    let description: String
    fileprivate var state = MECodecState.idle
    weak var delegate: CodecCapacityDelegate?
//    var track: TrackProtocol
    fileprivate let fps: Int
    let options: KSOptions
    let mediaType: AVFoundation.AVMediaType
    let outputRenderQueue: CircularBuffer<Frame>
    var isLoopModel = false

    var isFinished: Bool { state.contains(.finished) }

    //   CMTime((packetQueue.duration + outputRenderQueue.duration) * Int64(timebase.num), timebase.den).seconds
    var loadedTime: TimeInterval { TimeInterval(loadedCount) / TimeInterval(fps) }

    var loadedCount: Int { outputRenderQueue.count }

    var bufferingProgress: Int { min(100, Int(loadedTime * 100) / Int(options.preferredForwardBufferDuration)) }

    var isPlayable: Bool { true }

    required init(assetTrack: TrackProtocol, options: KSOptions) {
        mediaType = assetTrack.mediaType
        description = mediaType.rawValue
        fps = assetTrack.fps
        self.options = options
        // 默认缓存队列大小跟帧率挂钩,经测试除以4，最优
        if mediaType == .audio {
            outputRenderQueue = CircularBuffer(initialCapacity: fps / 4, expanding: false)
        } else if mediaType == .video {
            outputRenderQueue = CircularBuffer(initialCapacity: fps / 4, sorted: true, expanding: false)
        } else {
            outputRenderQueue = CircularBuffer()
        }
    }

    func decode() {
        state = .decoding
    }

    func seek(time _: TimeInterval) {
        state.remove(.finished)
        state.insert(.flush)
        outputRenderQueue.flush()
    }

    func putPacket(packet _: Packet) {
        fatalError("Abstract method")
    }

    func getOutputRender(where predicate: ((MEFrame) -> Bool)?) -> MEFrame? {
        return outputRenderQueue.pop(where: predicate)
    }

    func endOfFile() {
        state.insert(.finished)
    }

    func shutdown() {
        if state == .idle {
            return
        }
        state = .closed
        outputRenderQueue.shutdown()
    }

    deinit {
        shutdown()
    }
}

final class AsyncPlayerItemTrack: FFPlayerItemTrack<Frame> {
    private let operationQueue = OperationQueue()
    private var decoderMap = [Int32: DecodeProtocol]()
    private var decodeOperation: BlockOperation!
    private var seekTime = 0.0
    private var isFirst = true
    private var isSeek = false
    // 无缝播放使用的PacketQueue
    private var loopPacketQueue: CircularBuffer<Packet>?
    private var packetQueue = CircularBuffer<Packet>()
    override var loadedCount: Int { packetQueue.count + outputRenderQueue.count }
    override var isLoopModel: Bool {
        didSet {
            if isLoopModel {
                loopPacketQueue = CircularBuffer<Packet>()
                endOfFile()
            } else {
                if let loopPacketQueue = loopPacketQueue {
                    packetQueue = loopPacketQueue
                    decode()
                }
            }
        }
    }

    override var isPlayable: Bool {
        guard !state.contains(.finished) else {
            return true
        }
        let status = LoadingStatus(fps: fps, packetCount: packetQueue.count,
                                   frameCount: outputRenderQueue.count,
                                   frameMaxCount: outputRenderQueue.maxCount,
                                   isFirst: isFirst, isSeek: isSeek, mediaType: mediaType)
        if options.playable(status: status) {
            isFirst = false
            isSeek = false
            return true
        } else {
            return false
        }
    }

    required init(assetTrack: TrackProtocol, options: KSOptions) {
        decoderMap[assetTrack.streamIndex] = assetTrack.makeDecode(options: options)
        super.init(assetTrack: assetTrack, options: options)
        operationQueue.name = "KSPlayer_" + description
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .userInteractive
    }

    override func putPacket(packet: Packet) {
        if isLoopModel {
            loopPacketQueue?.push(packet)
        } else {
            packetQueue.push(packet)
            delegate?.codecDidChangeCapacity(track: self)
        }
    }

    override func decode() {
        guard operationQueue.operationCount == 0 else { return }
        decodeOperation = BlockOperation { [weak self] in
            guard let self = self else { return }
            Thread.current.name = self.operationQueue.name
            Thread.current.stackSize = KSPlayerManager.stackSize
            self.decodeThread()
        }
        decodeOperation.queuePriority = .veryHigh
        decodeOperation.qualityOfService = .userInteractive
        operationQueue.addOperation(decodeOperation)
        decoderMap.values.forEach { $0.decode() }
    }

    private func decodeThread() {
        state = .decoding
        while !decodeOperation.isCancelled {
            if state.contains(.closed) || state.contains(.failed) || (state.contains(.finished) && packetQueue.count == 0) {
                break
            } else if state.contains(.flush) {
                decoderMap.values.forEach { $0.doFlushCodec() }
                state.remove(.flush)
            } else if state.contains(.decoding) {
                guard let packet = packetQueue.pop(wait: true), !state.contains(.flush), !state.contains(.closed) else {
                    continue
                }
                doDecode(packet: packet)
            }
        }
    }

    override func getOutputRender(where predicate: ((MEFrame) -> Bool)?) -> MEFrame? {
        let outputFecthRender = outputRenderQueue.pop(where: predicate)
        if outputFecthRender == nil {
            if state.contains(.finished), loadedCount == 0 {
                delegate?.codecDidFinished(track: self)
            }
        } else {
            delegate?.codecDidChangeCapacity(track: self)
        }
        return outputFecthRender
    }

    override func seek(time: TimeInterval) {
        seekTime = time
        packetQueue.flush()
        super.seek(time: time)
        loopPacketQueue = nil
        isLoopModel = false
        delegate?.codecDidChangeCapacity(track: self)
        isSeek = true
        decoderMap.values.forEach { $0.seek(time: time) }
    }

    override func endOfFile() {
        super.endOfFile()
        if loadedCount == 0 {
            delegate?.codecDidFinished(track: self)
        }
        delegate?.codecDidChangeCapacity(track: self)
    }

    override func shutdown() {
        if state == .idle {
            return
        }
        super.shutdown()
        packetQueue.shutdown()
        operationQueue.cancelAllOperations()
        if Thread.current.name != operationQueue.name {
            operationQueue.waitUntilAllOperationsAreFinished()
        }
        decoderMap.values.forEach { $0.shutdown() }
        decoderMap.removeAll()
    }

    private func doDecode(packet: Packet) {
        let decoder = decoderMap.value(for: packet.assetTrack.streamIndex, default: packet.assetTrack.makeDecode(options: options))
        do {
            let array = try decoder.doDecode(packet: packet.corePacket)
            guard packet.corePacket.pointee.flags & AV_PKT_FLAG_DISCARD == 0 else {
                return
            }
            array.forEach { frame in
                guard !state.contains(.flush), !state.contains(.closed) else {
                    return
                }
                if seekTime > 0, options.isAccurateSeek {
                    if frame.seconds < seekTime {
                        return
                    } else {
                        seekTime = 0.0
                    }
                }
                outputRenderQueue.push(frame)
                delegate?.codecDidChangeCapacity(track: self)
            }
        } catch {
            KSLog("Decoder did Failed : \(error)")
            if decoder is HardwareDecode {
                decoderMap[packet.assetTrack.streamIndex] = SoftwareDecode(assetTrack: packet.assetTrack, options: options)
                KSLog("VideoCodec switch to software decompression")
            } else {
                state = .failed
            }
        }
    }
}

extension Dictionary {
    public mutating func value(for key: Key, default defaultValue: @autoclosure () -> Value) -> Value {
        if let value = self[key] {
            return value
        } else {
            let value = defaultValue()
            self[key] = value
            return value
        }
    }
}
