import Foundation

/// Minimal H.264 Annex-B inspection: split a byte stream at 00 00 01 / 00 00 00 01 start
/// codes and classify NAL units. Used to log what `video_process` receives and to validate
/// stream dumps and fixtures. Not a decoder.
enum AnnexB {
    struct NAL: Equatable {
        /// Offset of the start code.
        let offset: Int
        let startCodeLength: Int
        /// NAL header + payload length (excludes the start code).
        let length: Int
        let header: UInt8

        var type: UInt8 { header & 0x1F }
        var forbiddenBitSet: Bool { header & 0x80 != 0 }
        var payloadOffset: Int { offset + startCodeLength }
    }

    static func typeName(_ t: UInt8) -> String {
        switch t {
        case 1: return "slice"
        case 5: return "IDR"
        case 6: return "SEI"
        case 7: return "SPS"
        case 8: return "PPS"
        case 9: return "AUD"
        case 14: return "prefix"
        default: return "t\(t)"
        }
    }

    /// Splits `data` at start codes. Bytes before the first start code (garbage) are
    /// reported through `leadingBytes`. Trailing zero bytes of a NAL that precede a 4-byte
    /// start code belong to that start code, as the H.264 byte-stream format defines.
    static func split(_ data: UnsafeRawBufferPointer) -> (nals: [NAL], leadingBytes: Int) {
        let n = data.count
        var starts: [(offset: Int, scLen: Int)] = []
        var i = 0
        while i + 2 < n {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                if i > 0, data[i - 1] == 0 {
                    starts.append((i - 1, 4))
                } else {
                    starts.append((i, 3))
                }
                i += 3
            } else {
                i += 1
            }
        }
        var nals: [NAL] = []
        for (k, s) in starts.enumerated() {
            let payload = s.offset + s.scLen
            let end = k + 1 < starts.count ? starts[k + 1].offset : n
            guard payload < end else { continue }   // empty unit (e.g. 00 00 01 00 00 01)
            nals.append(NAL(offset: s.offset, startCodeLength: s.scLen, length: end - payload, header: data[payload]))
        }
        return (nals, starts.first?.offset ?? n)
    }

    static func split(_ data: Data) -> (nals: [NAL], leadingBytes: Int) {
        data.withUnsafeBytes { split($0) }
    }

    /// A short "SPS(4) PPS(4) IDR(4)+..." summary: type name and start code length.
    static func summary(_ nals: [NAL], limit: Int = 6) -> String {
        var parts = nals.prefix(limit).map { "\(typeName($0.type))(sc\($0.startCodeLength),\($0.length)B)" }
        if nals.count > limit { parts.append("+\(nals.count - limit)") }
        return parts.joined(separator: " ")
    }

    /// True when the buffer starts with a 4-byte start code, as UxPlay's mirror path writes it
    /// after a successful decrypt. UxPlay overwrites byte 0 with 0x01 when decryption or NAL
    /// length parsing failed, so a buffer starting `01` is a failed decrypt.
    static func looksDecrypted(_ p: UnsafePointer<UInt8>, _ len: Int) -> Bool {
        len >= 5 && p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 1 && p[4] & 0x80 == 0
    }
}
