import Foundation

/// Mach-O sections (LIEF/class-dump job) + Capstone ARM64 (`cs_disasm`).
enum MachOExtractor {
    static let stp: UInt32 = 0xA9BF7BFD
    static let nameRe = try! NSRegularExpression(pattern: "^[a-z][a-z0-9]*(_[a-z0-9]+)+$")

    struct Result {
        var byCode: [String: String]
        var named: Int
        var stubCodes: Int
        var engine: String
    }

    struct CsLine {
        var addr: UInt64
        var mnem: String
        var op: String
    }

    static func extract(_ data: Data, progress: ((Double, String) -> Void)? = nil) throws -> Result {
        if ab_cs_init() != 0 {
            throw EditorError.message("Capstone falhou a abrir (CS_ARCH_ARM64).")
        }
        guard data.count > 16 else {
            throw EditorError.message("Ficheiro demasiado pequeno.")
        }
        let thin = try thinSlice(data)
        let textEnd = min(thin.count, 0x3600000)
        progress?(4, "Capstone: a varrer stubs…")
        var pairCount: [String: Int] = [:]
        var samples: [(off: Int, t2: Int, t3: Int, t4: Int)] = []
        var off = 0x4000
        var lastPct = 4.0
        while off + 24 < textEnd {
            let pct = 4.0 + 70.0 * Double(off) / Double(max(textEnd, 1))
            if pct - lastPct >= 3 {
                lastPct = pct
                progress?(pct, String(format: "Capstone · stubs %.0f%%", pct))
            }
            if u32(thin, off) != stp {
                off += 4
                continue
            }
            let lines = disasm(thin, at: off, n: 24, addr: UInt64(off))
            guard lines.count >= 5,
                  lines[0].mnem == "stp",
                  lines[1].mnem == "bl",
                  lines[2].mnem == "bl",
                  lines[3].mnem == "bl",
                  lines[4].mnem == "bl",
                  let t2 = blImm(lines[2]),
                  let t3 = blImm(lines[3]),
                  let t4 = blImm(lines[4])
            else {
                off += 4
                continue
            }
            let k = "\(t2):\(t4)"
            pairCount[k, default: 0] += 1
            samples.append((off, t2, t3, t4))
            off += 24
        }
        let top = pairCount.sorted { $0.value > $1.value }.prefix(8)
        progress?(78, "Capstone: a ler códigos…")
        var bestMap: [Int: String] = [:]
        for (k, _) in top {
            let parts = k.split(separator: ":")
            guard parts.count == 2, let t2 = Int(parts[0]), let t4 = Int(parts[1]) else { continue }
            var local: [Int: String] = [:]
            for s in samples where s.t2 == t2 && s.t4 == t4 {
                if let code = extractCode(thin, s.t3) {
                    local[s.off] = code
                }
            }
            if local.count > bestMap.count { bestMap = local }
        }
        var byCode: [String: String] = [:]
        let tags: Set<Int> = [0x100000, 0x200000, 0x300000, 0x400000]
        let dataLo = 0x3A00000
        let dataHi = min(thin.count - 8, 0x4400000)
        progress?(88, "Capstone: a ligar nomes…")
        off = dataLo & ~7
        while off < dataHi {
            let q = u64(thin, off)
            let tag = Int(q >> 32)
            let imp = Int(q & 0xFFFF_FFFF)
            if tags.contains(tag), let code = bestMap[imp] {
                let nq = u64(thin, off + 8)
                let va = Int(nq & 0xF_FFFF_FFFF)
                if let nm = cstr(thin, va), isName(nm) {
                    byCode[code] = nm
                }
            }
            off += 8
        }
        return Result(
            byCode: byCode,
            named: byCode.count,
            stubCodes: Set(bestMap.values).count,
            engine: "capstone-arm64"
        )
    }

    private static func extractCode(_ data: Data, _ u: Int) -> String? {
        guard u + 4 < data.count else { return nil }
        let helper = disasm(data, at: u, n: 48, addr: UInt64(u))
        var x0: UInt64 = 0
        var helpers: [Int] = []
        for line in helper {
            applyMov(&x0, line)
            if line.mnem == "bl", let t = blImm(line) { helpers.append(t) }
        }
        if asciiDigits(x0) == nil {
            for t in helpers {
                let extra = disasm(data, at: t, n: 16, addr: UInt64(t))
                for line in extra { applyMov(&x0, line) }
                if asciiDigits(x0) != nil { break }
            }
        }
        return asciiDigits(x0)
    }

    private static func applyMov(_ x0: inout UInt64, _ line: CsLine) {
        guard line.mnem == "mov" || line.mnem == "movz" || line.mnem == "movk" else { return }
        guard line.op.hasPrefix("x0") || line.op.hasPrefix("w0") else { return }
        guard let imm = immOf(line.op) else { return }
        var shift = 0
        if let r = line.op.range(of: "lsl #") {
            shift = Int(line.op[r.upperBound...].prefix(2).filter(\.isNumber)) ?? 0
        }
        let mask: UInt64 = ~(UInt64(0xFFFF) << UInt64(shift))
        x0 = (x0 & mask) | (UInt64(imm & 0xFFFF) << UInt64(shift))
    }

    private static func disasm(_ data: Data, at: Int, n: Int, addr: UInt64) -> [CsLine] {
        let end = min(at + n, data.count)
        guard at >= 0, end > at else { return [] }
        let slice = data.subdata(in: at..<end)
        var buf = [CChar](repeating: 0, count: 8192)
        let count = slice.withUnsafeBytes { raw -> Int32 in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return ab_cs_disasm(p, slice.count, addr, &buf, buf.count)
        }
        if count <= 0 { return [] }
        let text = String(cString: buf)
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            let addr = UInt64(parts[0], radix: 16) ?? 0
            let op = parts.count > 2 ? String(parts[2]) : ""
            return CsLine(addr: addr, mnem: String(parts[1]), op: op)
        }
    }

    private static func blImm(_ line: CsLine) -> Int? {
        guard line.mnem == "bl" || line.mnem == "b" else { return nil }
        let hex = line.op.replacingOccurrences(of: "#", with: "")
        if hex.hasPrefix("0x") { return Int(hex.dropFirst(2), radix: 16) }
        return Int(hex)
    }

    private static func immOf(_ op: String) -> Int? {
        guard let hash = op.firstIndex(of: "#") else { return nil }
        var s = String(op[op.index(after: hash)...])
        if let comma = s.firstIndex(of: ",") { s = String(s[..<comma]) }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("0x") { return Int(s.dropFirst(2), radix: 16) }
        return Int(s)
    }

    private static func thinSlice(_ data: Data) throws -> Data {
        if data[0] == 0xCF, data[1] == 0xFA, data[2] == 0xED, data[3] == 0xFE { return data }
        throw EditorError.message("Não é Mach-O arm64. Se for fat, extrai a slice arm64.")
    }

    private static func asciiDigits(_ x0: UInt64) -> String? {
        var s = ""
        for i in 0..<8 {
            let c = UInt8((x0 >> (i * 8)) & 0xFF)
            if (48...57).contains(c), let u = UnicodeScalar(UInt32(c)) { s.append(Character(u)) }
            else { break }
        }
        return (s.count >= 4 && s.count <= 6) ? s : nil
    }

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
