import Foundation

/// 从 .ico 里掏出最大的那张 PNG。
///
/// 为什么需要它：`UIImage(data:)` 在 iOS 上**不认 .ico**，直接给 nil。
/// 而现代网站的 favicon.ico 里装的基本都是 PNG 子图，把它拆出来就能用。
/// 里面装的是老式 BMP（DIB）子图的话这里放弃，交给上层继续往下一个来源退。
enum ICOUnpacker {
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func extractLargestPNG(from data: Data) -> Data? {
        // 本来就是 PNG 就直接还回去（有些站点的 /favicon.ico 其实是张 PNG）
        if data.starts(with: pngSignature) { return data }

        let bytes = [UInt8](data)
        // ICONDIR: reserved(2) type(2) count(2)
        guard bytes.count > 6,
              bytes[0] == 0, bytes[1] == 0,
              bytes[2] == 1, bytes[3] == 0
        else { return nil }

        let count = Int(bytes[4]) | (Int(bytes[5]) << 8)
        guard count > 0, bytes.count >= 6 + count * 16 else { return nil }

        var best: (pixels: Int, range: Range<Int>)?
        for index in 0..<count {
            let entry = 6 + index * 16
            // ICONDIRENTRY: width(1) height(1) colors(1) reserved(1) planes(2) bits(2) size(4) offset(4)
            // width/height 为 0 表示 256
            let width = bytes[entry] == 0 ? 256 : Int(bytes[entry])
            let height = bytes[entry + 1] == 0 ? 256 : Int(bytes[entry + 1])
            let size = readUInt32(bytes, at: entry + 8)
            let offset = readUInt32(bytes, at: entry + 12)
            guard size > 0, offset >= 0, offset + size <= bytes.count else { continue }

            let range = offset..<(offset + size)
            guard range.count > 8,
                  Array(bytes[range.lowerBound..<(range.lowerBound + 8)]) == pngSignature
            else { continue }

            let pixels = width * height
            if best == nil || pixels > best!.pixels {
                best = (pixels, range)
            }
        }

        guard let best else { return nil }
        return data.subdata(in: best.range)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> Int {
        guard offset + 4 <= bytes.count else { return 0 }
        let value = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        return value > UInt32(Int32.max) ? 0 : Int(value)
    }
}
