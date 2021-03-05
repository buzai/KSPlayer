//
//  SWScale.swift
//  KSPlayer-iOS
//
//  Created by wangjinbian on 2020/1/27.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import Libavcodec
import Libswscale
import Libswresample
import VideoToolbox

protocol Swresample {
    func transfer(avframe: UnsafeMutablePointer<AVFrame>, timebase: Timebase) -> MEFrame
    func shutdown()
}

class VideoSwresample: Swresample {
    private var dstFormat: AVPixelFormat
    private var imgConvertCtx: OpaquePointer?
    private var format: AVPixelFormat = AV_PIX_FMT_NONE
    private var height: Int32 = 0
    private var width: Int32 = 0
    private var forceTransfer: Bool
    var dstFrame: UnsafeMutablePointer<AVFrame>?
    init(dstFormat: AVPixelFormat = AV_PIX_FMT_NV12, forceTransfer: Bool = false) {
        self.dstFormat = dstFormat
        self.forceTransfer = forceTransfer
    }

    private func setup(frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        setup(format: AVPixelFormat(rawValue: frame.pointee.format), width: frame.pointee.width, height: frame.pointee.height)
    }

    func setup(format: AVPixelFormat, width: Int32, height: Int32) -> Bool {
        if self.format == format, self.width == width, self.height == height {
            return true
        }
        shutdown()
        self.format = format
        self.height = height
        self.width = width
        if !forceTransfer {
            if PixelBuffer.isSupported(format: self.format) {
                return true
            } else {
                dstFormat = self.format.bestPixelFormat()
            }
        }
        imgConvertCtx = sws_getCachedContext(imgConvertCtx, width, height, self.format, width, height, dstFormat, SWS_BICUBIC, nil, nil, nil)
        guard imgConvertCtx != nil else {
            return false
        }
        dstFrame = av_frame_alloc()
        guard let dstFrame = dstFrame else {
            sws_freeContext(imgConvertCtx)
            imgConvertCtx = nil
            return false
        }
        dstFrame.pointee.width = width
        dstFrame.pointee.height = height
        dstFrame.pointee.format = dstFormat.rawValue
        av_image_alloc(&dstFrame.pointee.data.0, &dstFrame.pointee.linesize.0, width, height, AVPixelFormat(rawValue: dstFrame.pointee.format), 64)
        return true
    }

    func transfer(avframe: UnsafeMutablePointer<AVFrame>, timebase: Timebase) -> MEFrame {
        let frame = VideoVTBFrame()
        frame.timebase = timebase
        if avframe.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            // swiftlint:disable force_cast
            frame.corePixelBuffer = avframe.pointee.data.3 as! CVPixelBuffer
            // swiftlint:enable force_cast
        } else {
            if setup(frame: avframe), let dstFrame = dstFrame, swsConvert(data: Array(tuple: avframe.pointee.data), linesize: Array(tuple: avframe.pointee.linesize)) {
                avframe.pointee.format = dstFrame.pointee.format
                avframe.pointee.data = dstFrame.pointee.data
                avframe.pointee.linesize = dstFrame.pointee.linesize
            }
            frame.corePixelBuffer = PixelBuffer(frame: avframe)
        }
        frame.duration = avframe.pointee.pkt_duration
        frame.size = Int64(avframe.pointee.pkt_size)
        return frame
    }

    func transfer(format: AVPixelFormat, width: Int32, height: Int32, data: [UnsafeMutablePointer<UInt8>?], linesize: [Int]) -> CGImage? {
        if setup(format: format, width: width, height: height), swsConvert(data: data, linesize: linesize.compactMap({Int32($0)})), let frame = dstFrame?.pointee {
            return CGImage.make(rgbData: frame.data.0!, linesize: Int(frame.linesize.0), width: Int(width), height: Int(height), isAlpha: dstFormat == AV_PIX_FMT_RGBA)
        }
        return nil
    }

    private func swsConvert(data: [UnsafeMutablePointer<UInt8>?], linesize: [Int32]) -> Bool {
        guard let dstFrame = dstFrame else {
            return false
        }
        let result = sws_scale(imgConvertCtx, data.map { UnsafePointer($0) }, linesize, 0, height, &dstFrame.pointee.data.0, &dstFrame.pointee.linesize.0)
        return result > 0
    }

    func shutdown() {
        av_frame_free(&dstFrame)
        sws_freeContext(imgConvertCtx)
        imgConvertCtx = nil
    }

    static func == (lhs: VideoSwresample, rhs: AVFrame) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.format.rawValue == rhs.format
    }
}

class PixelBuffer: BufferProtocol {
    var attachmentsDic: CFDictionary?
    let bitDepth: Int32
    let format: AVPixelFormat
    let width: Int
    let height: Int
    let planeCount: Int
    let isFullRangeVideo: Bool
    let colorPrimaries: CFString?
    let transferFunction: CFString?
    let yCbCrMatrix: CFString?

    let sar: CGSize
    private let formats: [MTLPixelFormat]
    private let widths: [Int]
    private let heights: [Int]
    private let dataWrap: MTLBufferWrap
    private var lineSize = [Int]()
    public var colorspace: CGColorSpace? {
       attachmentsDic.flatMap { CVImageBufferCreateColorSpaceFromAttachments($0)?.takeUnretainedValue() }
    }

    init(frame: UnsafeMutablePointer<AVFrame>) {
        format = AVPixelFormat(rawValue: frame.pointee.format)
        yCbCrMatrix = frame.pointee.colorspace.ycbcrMatrix
        colorPrimaries = frame.pointee.color_primaries.colorPrimaries
        transferFunction = frame.pointee.color_trc.transferFunction
        var attachments = [CFString: CFString]()
        attachments[kCVImageBufferColorPrimariesKey] = colorPrimaries
        attachments[kCVImageBufferTransferFunctionKey] = transferFunction
        attachments[kCVImageBufferYCbCrMatrixKey] = yCbCrMatrix
        attachmentsDic = attachments as CFDictionary
        width = Int(frame.pointee.width)
        height = Int(frame.pointee.height)
        isFullRangeVideo = frame.pointee.color_range == AVCOL_RANGE_JPEG
        let bytesPerRow = Array(tuple: frame.pointee.linesize).compactMap { Int($0) }
        bitDepth = format.bitDepth()
        sar = frame.pointee.sample_aspect_ratio.size
        planeCount = Int(format.planeCount())
        switch planeCount {
        case 3:
            formats = bitDepth > 8 ? [.r16Unorm, .r16Unorm, .r16Unorm] : [.r8Unorm, .r8Unorm, .r8Unorm]
            widths = [width, width / 2, width / 2]
            heights = [height, height / 2, height / 2]
        case 2:
            formats =  bitDepth > 8 ? [.r16Unorm, .rg16Unorm] : [.r8Unorm, .rg8Unorm]
            widths = [width, width / 2]
            heights = [height, height / 2]
        default:
            formats = [.bgra8Unorm]
            widths = [width]
            heights = [height]
        }
        var size = [Int]()
        for i in 0 ..< planeCount {
            if #available(iOS 11.0, tvOS 11.0, *) {
                let alignment = MetalRender.device.minimumLinearTextureAlignment(for: formats[i])
                let remainder = bytesPerRow[i] % alignment
                lineSize.append(remainder == 0 ? bytesPerRow[i] : bytesPerRow[i] + alignment - remainder)
            } else {
                lineSize.append(bytesPerRow[i])
            }
            size.append(lineSize[i] * heights[i])

        }
        dataWrap = ObjectPool.share.object(class: MTLBufferWrap.self, key: "VideoData") { MTLBufferWrap(size: size) }
        dataWrap.size = size
        let bytes = Array(tuple: frame.pointee.data)
        for i in 0 ..< planeCount {
            if bytesPerRow[i] == lineSize[i] {
                dataWrap.data[i]?.contents().copyMemory(from: bytes[i]!, byteCount: heights[i]*lineSize[i])
            } else {
                let contents = dataWrap.data[i]?.contents()
                let source = bytes[i]!
                for j in 0 ..< heights[i] {
                    contents?.advanced(by: j*lineSize[i]).copyMemory(from: source.advanced(by: j*bytesPerRow[i]), byteCount: bytesPerRow[i])
                }
            }
        }
    }

    deinit {
        ObjectPool.share.comeback(item: dataWrap, key: "VideoData")
    }

    func textures(frome cache: MetalTextureCache) -> [MTLTexture] {
        cache.textures(formats: formats, widths: widths, heights: heights, buffers: dataWrap.data, lineSizes: lineSize)
    }

    func widthOfPlane(at planeIndex: Int) -> Int {
        widths[planeIndex]
    }

    func heightOfPlane(at planeIndex: Int) -> Int {
        heights[planeIndex]
    }

    public static func isSupported(format: AVPixelFormat) -> Bool {
        [AV_PIX_FMT_BGRA, AV_PIX_FMT_NV12, AV_PIX_FMT_P010BE, AV_PIX_FMT_YUV420P].contains(format)
    }

    func image() -> CGImage? {
        let image: CGImage?
        if format == AV_PIX_FMT_RGB24 {
            image =  CGImage.make(rgbData: dataWrap.data[0]!.contents().assumingMemoryBound(to: UInt8.self), linesize: Int(lineSize[0]), width: width, height: height)
        } else {
            let scale = VideoSwresample(dstFormat: AV_PIX_FMT_RGB24, forceTransfer: true)
            image = scale.transfer(format: format, width: Int32(width), height: Int32(height), data: dataWrap.data.map({ $0?.contents().assumingMemoryBound(to: UInt8.self) }), linesize: lineSize)
            scale.shutdown()
        }
        return image
    }
}

extension AVCodecParameters {

    var sar: NSDictionary? {
        let sar = sample_aspect_ratio.size
        if sar.width != sar.height {
            return [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: sar.width,
                    kCVImageBufferPixelAspectRatioVerticalSpacingKey: sar.height] as NSDictionary
        } else {
            return nil
        }
    }
}

extension AVPixelFormat {
    func bitDepth() -> Int32 {
        let descriptor = av_pix_fmt_desc_get(self)
        return descriptor?.pointee.comp.0.depth ?? 8
    }

    func planeCount() -> UInt8 {
        if let desc = av_pix_fmt_desc_get(self) {
            switch desc.pointee.nb_components {
            case 3:
                return UInt8(desc.pointee.comp.2.plane + 1)
            case 2:
                return UInt8(desc.pointee.comp.1.plane + 1)
            default:
                return UInt8(desc.pointee.comp.0.plane + 1)
            }
        } else {
            return 1
        }
    }

    func bestPixelFormat() -> AVPixelFormat {
        return bitDepth() > 8 ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12
    }
}

extension CVPixelBufferPool {
    func getPixelBuffer(fromFrame frame: AVFrame) -> CVPixelBuffer? {
        var pbuf: CVPixelBuffer?
        let ret = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self, &pbuf)
        //        let dic = [kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        //                       kCVPixelBufferBytesPerRowAlignmentKey: frame.linesize.0] as NSDictionary
        //        let ret = CVPixelBufferCreate(kCFAllocatorDefault, Int(frame.width), Int(frame.height), AVPixelFormat(rawValue: frame.format).format, dic, &pbuf)
        if let pbuf = pbuf, ret == kCVReturnSuccess {
            CVPixelBufferLockBaseAddress(pbuf, CVPixelBufferLockFlags(rawValue: 0))
            let data = Array(tuple: frame.data)
            let linesize = Array(tuple: frame.linesize)
            let heights = [frame.height, frame.height / 2, frame.height / 2]
            for i in 0 ..< pbuf.planeCount {
                let perRow = Int(linesize[i])
                pbuf.baseAddressOfPlane(at: i)?.copyMemory(from: data[i]!, byteCount: Int(heights[i]) * perRow)
            }
            CVPixelBufferUnlockBaseAddress(pbuf, CVPixelBufferLockFlags(rawValue: 0))
        }
        return pbuf
    }
}

extension CGImage {
    static func make(rgbData: UnsafePointer<UInt8>, linesize: Int, width: Int, height: Int, isAlpha: Bool = false) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = isAlpha ? CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue) : CGBitmapInfo.byteOrderMask
        guard let data = CFDataCreate(kCFAllocatorDefault, rgbData, linesize * height), let provider = CGDataProvider(data: data) else {
            return nil
        }
        // swiftlint:disable line_length
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: isAlpha ? 32 : 24, bytesPerRow: linesize, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        // swiftlint:enable line_length
    }
}

typealias SwrContext = OpaquePointer

class AudioSwresample: Swresample {
    private var swrContext: SwrContext?
    private var descriptor: AudioDescriptor?
    private func setup(frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        let newDescriptor = AudioDescriptor(frame: frame)
        if let descriptor = descriptor, descriptor == newDescriptor {
            return true
        }
        let outChannel = av_get_default_channel_layout(Int32(KSPlayerManager.audioPlayerMaximumChannels))
        let inChannel = av_get_default_channel_layout(Int32(newDescriptor.inputNumberOfChannels))
        swrContext = swr_alloc_set_opts(nil, outChannel, AV_SAMPLE_FMT_FLTP, KSPlayerManager.audioPlayerSampleRate, inChannel, newDescriptor.inputFormat, newDescriptor.inputSampleRate, 0, nil)
        let result = swr_init(swrContext)
        if result < 0 {
            shutdown()
            return false
        } else {
            descriptor = newDescriptor
            return true
        }
    }

    func transfer(avframe: UnsafeMutablePointer<AVFrame>, timebase: Timebase) -> MEFrame {
        _ = setup(frame: avframe)
        var numberOfSamples = avframe.pointee.nb_samples
        let nbSamples = swr_get_out_samples(swrContext, numberOfSamples)
        var frameBuffer = Array(tuple: avframe.pointee.data).map { UnsafePointer<UInt8>($0) }
        var bufferSize = Int32(0)
        _ = av_samples_get_buffer_size(&bufferSize, Int32(KSPlayerManager.audioPlayerMaximumChannels), nbSamples, AV_SAMPLE_FMT_FLTP, 1)
        let frame = AudioFrame(bufferSize: bufferSize)
        numberOfSamples = swr_convert(swrContext, &frame.dataWrap.data, nbSamples, &frameBuffer, numberOfSamples)
        frame.timebase = timebase
        frame.numberOfSamples = Int(numberOfSamples)
        frame.duration = avframe.pointee.pkt_duration
        frame.size = Int64(avframe.pointee.pkt_size)
        if frame.duration == 0 {
            frame.duration = Int64(avframe.pointee.nb_samples) * Int64(frame.timebase.den) / (Int64(avframe.pointee.sample_rate) * Int64(frame.timebase.num))
        }
        return frame
    }

    func shutdown() {
        swr_free(&swrContext)
    }
}

class AudioDescriptor: Equatable {
    fileprivate let inputNumberOfChannels: AVAudioChannelCount
    fileprivate let inputSampleRate: Int32
    fileprivate let inputFormat: AVSampleFormat
    init(codecpar: UnsafeMutablePointer<AVCodecParameters>) {
        let channels = UInt32(codecpar.pointee.channels)
        inputNumberOfChannels = channels == 0 ? KSPlayerManager.audioPlayerMaximumChannels : channels
        let sampleRate = codecpar.pointee.sample_rate
        inputSampleRate = sampleRate == 0 ? KSPlayerManager.audioPlayerSampleRate : sampleRate
        inputFormat = AVSampleFormat(rawValue: codecpar.pointee.format)
    }

    init(frame: UnsafeMutablePointer<AVFrame>) {
        let channels = UInt32(frame.pointee.channels)
        inputNumberOfChannels = channels == 0 ? KSPlayerManager.audioPlayerMaximumChannels : channels
        let sampleRate = frame.pointee.sample_rate
        inputSampleRate = sampleRate == 0 ? KSPlayerManager.audioPlayerSampleRate : sampleRate
        inputFormat = AVSampleFormat(rawValue: frame.pointee.format)
    }

    static func == (lhs: AudioDescriptor, rhs: AudioDescriptor) -> Bool {
        lhs.inputFormat == rhs.inputFormat && lhs.inputSampleRate == rhs.inputSampleRate && lhs.inputNumberOfChannels == rhs.inputNumberOfChannels
    }

    static func == (lhs: AudioDescriptor, rhs: AVFrame) -> Bool {
        lhs.inputFormat.rawValue == rhs.format && lhs.inputSampleRate == rhs.sample_rate && lhs.inputNumberOfChannels == rhs.channels
    }
}
