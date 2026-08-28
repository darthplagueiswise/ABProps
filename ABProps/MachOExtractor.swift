import Foundation

/// Focused WAABProperties getter scan. ARM64 encodings only — no LIEF, no Capstone.
enum MachOExtractor {
    static let stp: UInt32 = 0xA9BF7BFD
    static let nameRe = try! NSRegularExpression(pattern: "^[a-z][a-z0-9]*(_[a-z0-9]+)+$")

    struct Result {
        var byCode: [String: String]
        var named: Int
        var stubCodes: Int
    }

    static func extract(_ data: Data) throws -> Result {
        guard data.count > 16, data[0] == 0xCF, data[1] == 0xFA, data[2] == 0xED, data[3] == 0xFE else {
            throw EditorError.message("Não é Mach-O arm64. Se for fat, extrai a slice arm64.")
        }
        let textEnd = min(data.count, 0x3600000)
        var pairCount: [String: Int] = [:]
        var samples: [(off: Int, t2: Int, t3: Int, t4: Int)] = []
        var off = 0x4000
        while off + 24 < textEnd {
            if u32(data, off) != stp {
                off += 4
                continue
            }
            let t1 = decBl(off + 4, u32(data, off + 4))
            let t2 = decBl(off + 8, u32(data, off + 8))
            let t3 = decBl(off + 12, u32(data, off + 12))
            let t4 = decBl(off + 16, u32(data, off + 16))
            if let t1, let t2, let t3, let t4, t1 != 0 {
                let k = "\(t2):\(t4)"
                pairCount[k, default: 0] += 1
                samples.append((off, t2, t3, t4))
                off += 24
                continue
            }
            off += 4
        }
        let top = pairCount.sorted { $0.value > $1.value }.prefix(8)
        var bestMap: [Int: String] = [:]
        for (k, _) in top {
            let parts = k.split(separator: ":")
            guard parts.count == 2, let t2 = Int(parts[0]), let t4 = Int(parts[1]) else { continue }
            var local: [Int: String] = [:]
            for s in samples where s.t2 == t2 && s.t4 == t4 {
                if let code = extractCode(data, s.t3) {
                    local[s.off] = code
                }
            }
            if local.count > bestMap.count { bestMap = local }
        }
        var byCode: [String: String] = [:]
        let tags: Set<Int> = [0x100000, 0x200000, 0x300000]
        let dataLo = 0x3A00000
        let dataHi = min(data.count - 8, 0x4400000)
        off = dataLo & ~7
        while off < dataHi {
            let q = u64(data, off)
            let tag = Int(q >> 32)
            let imp = Int(q & 0xFFFF_FFFF)
            if tags.contains(tag), let code = bestMap[imp] {
                let nq = u64(data, off + 8)
                let va = Int(nq & 0xF_FFFF_FFFF)
                if let nm = cstr(data, va), isName(nm) {
                    byCode[code] = nm
                }
            }
            off += 8
        }
        return Result(byCode: byCode, named: byCode.count, stubCodes: Set(bestMap.values).count)
    }

    private static func extractCode(_ data: Data, _ u: Int) -> String? {
        var x0: UInt64 = 0
        var helpers: [Int] = []
        for i in 0..<16 {
            let pc = u + i * 4
            guard pc + 4 <= data.count else { break }
            let w = u32(data, pc)
            if let mw = decMovWide(w) {
                let mask: UInt64 = ~(UInt64(0xFFFF) << mw.shift)
                x0 = (x0 & mask) | (UInt64(mw.imm) << mw.shift)
            } else if let t = decBl(pc, w) {
                helpers.append(t)
            }
        }
        for t in helpers {
            guard t + 4 <= data.count else { continue }
            if let mw = decMovWide(u32(data, t)), mw.kind == .movk {
                let mask: UInt64 = ~(UInt64(0xFFFF) << mw.shift)
                x0 = (x0 & mask) | (UInt64(mw.imm) << mw.shift)
                break
            }
        }
        var s = ""
        for i in 0..<8 {
            let c = UInt8((x0 >> (i * 8)) & 0xFF)
            if (48...57).contains(c) { s.append(Character(UnicodeScalar(c))) }
            else { break }
        }
        return (s.count >= 4 && s.count <= 6) ? s : nil
    }

    private static func decBl(_ pc: Int, _ w: UInt32) -> Int? {
        guard w >> 26 == 0b100101 else { return nil }
        var imm = Int(w & 0x3FFFFFF)
        if imm & 0x2000000 != 0 { imm -= 0x4000000 }
        return pc + imm * 4
    }

    private static func decMovWide(_ w: UInt32) -> (kind: Kind, shift: UInt64, imm: UInt64)? {
        let opc = (w >> 29) & 3
        let id = (w >> 23) & 0x3F
        let hw = (w >> 21) & 3
        let imm16 = (w >> 5) & 0xFFFF
        let rd = w & 0x1F
        guard id == 0b100101, rd == 0, opc == 2 || opc == 3 else { return nil }
        return (opc == 3 ? .movk : .movz, UInt64(hw * 16), UInt64(imm16))
    }

    private enum Kind { case movz, movk }

    private static func u32(_ data: Data, _ off: Int) -> UInt32 {
        guard off + 4 <= data.count else { return 0 }
        return UInt32(data[off]) |
            UInt32(data[off + 1]) << 8 |
            UInt32(data[off + 2]) << 16 |
            UInt32(data[off + 3]) << 24
    }

    private static func u64(_ data: Data, _ off: Int) -> UInt64 {
        UInt64(u32(data, off)) | (UInt64(u32(data, off + 4)) << 32)
    }

    private static func cstr(_ data: Data, _ va: Int) -> String? {
        guard va >= 0, va < data.count else { return nil }
        var e = va
        while e < data.count, e < va + 200, data[e] != 0 { e += 1 }
        return String(bytes: data[va..<e], encoding: .utf8)
    }

    private static func isName(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        return nameRe.firstMatch(in: s, range: r) != nil
    }
}
