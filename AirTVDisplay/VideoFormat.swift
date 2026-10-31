// SPDX-License-Identifier: MIT
import CoreMedia
import Foundation

/// Annex-B -> AVCC conversion and H.264 format descriptions for VideoToolbox.
///
/// UxPlay hands `video_process` one access unit per call in Annex-B form (4-byte start codes),
/// with the SPS + PPS of a codec packet prepended to the next frame (raop_rtp_mirror.c). The
/// parameter sets are pulled out here (they go into the `CMVideoFormatDescription`, not the
/// sample) and the remaining NAL units are rewritten with 4-byte big-endian lengths.
enum VideoFormat {
    struct AccessUnit {
        var sps: Data?
        var pps: Data?
        /// Length-prefixed (4-byte BE) NAL units, parameter sets and AUDs removed.
        var avcc: Data
        /// NAL lengths written into `avcc`, in order.
        var nalLengths: [Int]
        var hasIDR: Bool
        /// Number of slice NALs (types 1 and 5).
        var sliceCount: Int
    }

    static func accessUnit(_ buf: UnsafeRawBufferPointer) -> AccessUnit {
        let nals = AnnexB.split(buf).nals
        var au = AccessUnit(sps: nil, pps: nil, avcc: Data(), nalLengths: [], hasIDR: false, sliceCount: 0)
        au.avcc.reserveCapacity(buf.count)
        for n in nals {
            let body = UnsafeRawBufferPointer(rebasing: buf[n.payloadOffset..<(n.payloadOffset + n.length)])
            switch n.type {
            case 7: au.sps = Data(body)
            case 8: au.pps = Data(body)
            case 9: continue   // access unit delimiter: meaningless in AVCC
            default:
                var be = UInt32(n.length).bigEndian
                withUnsafeBytes(of: &be) { au.avcc.append(contentsOf: $0) }
                au.avcc.append(contentsOf: body)
                au.nalLengths.append(n.length)
                if n.type == 5 { au.hasIDR = true }
                if n.type == 1 || n.type == 5 { au.sliceCount += 1 }
            }
        }
        return au
    }

    static func accessUnit(_ data: Data) -> AccessUnit { data.withUnsafeBytes { accessUnit($0) } }

    enum FormatError: Error { case status(OSStatus) }

    static func formatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        var fd: CMFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        }
        guard status == noErr, let fd else { throw FormatError.status(status) }
        return fd
    }

    /// Wraps AVCC bytes in a ready `CMSampleBuffer` (the bytes are copied).
    static func sampleBuffer(avcc: Data, format: CMVideoFormatDescription, pts: CMTime) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard st == noErr, let block else { throw FormatError.status(st) }
        st = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                  offsetIntoDestination: 0, dataLength: avcc.count) }
        guard st == noErr else { throw FormatError.status(st) }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = avcc.count
        st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                       sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                       sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard st == noErr, let sample else { throw FormatError.status(st) }
        return sample
    }

    static func dimensions(_ fd: CMVideoFormatDescription) -> (width: Int, height: Int) {
        let d = CMVideoFormatDescriptionGetDimensions(fd)
        return (Int(d.width), Int(d.height))
    }

    /// Groups a raw Annex-B file into UxPlay-shaped buffers: one per coded picture (all of its
    /// slices), with any preceding SPS/PPS/SEI/AUD prepended, every NAL behind a 4-byte start
    /// code. A picture starts at a non-VCL NAL or at a slice with first_mb_in_slice == 0.
    static func accessUnits(fromAnnexB data: Data) -> [Data] {
        let nals = AnnexB.split(data).nals
        var units: [Data] = []
        var cur = Data()
        var curHasSlice = false
        for n in nals {
            let isSlice = n.type == 1 || n.type == 5
            // first_mb_in_slice is ue(v); its first bit is 1 exactly when the value is 0.
            let firstSlice = isSlice && n.length > 1 && data[n.payloadOffset + 1] & 0x80 != 0
            if curHasSlice && (!isSlice || firstSlice) {
                units.append(cur); cur = Data(); curHasSlice = false
            }
            cur.append(contentsOf: [0, 0, 0, 1])
            cur.append(data[n.payloadOffset..<(n.payloadOffset + n.length)])
            if isSlice { curHasSlice = true }
        }
        if curHasSlice { units.append(cur) }
        return units
    }
}
