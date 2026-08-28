import Foundation

enum PlistCodec {
    static let magic = "bplist00"

    static func isBplist(_ data: Data) -> Bool {
        data.count >= 8 && String(bytes: data.prefix(8), encoding: .ascii) == magic
    }

    static func parse(_ data: Data) throws -> PlistValue {
        guard isBplist(data) else { throw EditorError.message("Não é bplist00.") }
        let n = data.count
        let t = n - 32
        let oS = Int(data[t + 6])
        let rS = Int(data[t + 7])
        let nObj = intBE(data, t + 8, 8)
        let top = intBE(data, t + 16, 8)
        let ot = intBE(data, t + 24, 8)
        var offs = [Int]()
        offs.reserveCapacity(nObj)
        for i in 0..<nObj {
            offs.append(intBE(data, ot + i * oS, oS))
        }
        var cache: [Int: PlistValue] = [:]
        func pref(_ p: Int) -> Int { intBE(data, p, rS) }
        func obj(_ i: Int) throws -> PlistValue {
            if let c = cache[i] { return c }
            let off = offs[i]
            let m = Int(data[off])
            let typ = m >> 4
            let info = m & 0xf
            let val: PlistValue
            if m == 0 { val = .null }
            else if m == 8 { val = .bool(false) }
            else if m == 9 { val = .bool(true) }
            else if typ == 1 {
                let sz = 1 << info
                val = .int(intSigned(data, off + 1, sz))
            } else if typ == 2 {
                let sz = 1 << info
                if sz == 4 {
                    val = .real(Double(Float(bitPattern: UInt32(intBE(data, off + 1, 4)))))
                } else {
                    var bits: UInt64 = 0
                    for i in 0..<8 { bits = (bits << 8) | UInt64(data[off + 1 + i]) }
                    val = .real(Double(bitPattern: bits))
                }
            } else if typ == 3 {
                var bits: UInt64 = 0
                for i in 0..<8 { bits = (bits << 8) | UInt64(data[off + 1 + i]) }
                val = .date(Double(bitPattern: bits))
            } else if typ == 4 {
                let L = readLen(data, off, info)
                val = .data(data.subdata(in: (off + L.h)..<(off + L.h + L.n)))
            } else if typ == 5 {
                let L = readLen(data, off, info)
                let s = String(bytes: data[off+L.h..<off+L.h+L.n], encoding: .ascii) ?? ""
                val = .str(s)
            } else if typ == 6 {
                let L = readLen(data, off, info)
                var s = ""
                let start = off + L.h
                for k in 0..<L.n {
                    let c = Int(data[start + k * 2]) << 8 | Int(data[start + k * 2 + 1])
                    if let u = UnicodeScalar(c) { s.append(Character(u)) }
                }
                val = .str(s)
            } else if typ == 0xa {
                let L = readLen(data, off, info)
                var a: [PlistValue] = []
                for k in 0..<L.n { a.append(try obj(pref(off + L.h + k * rS))) }
                val = .arr(a)
            } else if typ == 0xd {
                let L = readLen(data, off, info)
                var e: [(String, PlistValue)] = []
                for k in 0..<L.n {
                    let key = try obj(pref(off + L.h + k * rS))
                    let vv = try obj(pref(off + L.h + L.n * rS + k * rS))
                    let ks: String
                    if case .str(let s) = key { ks = s } else { ks = "\(key)" }
                    e.append((ks, vv))
                }
                val = .dict(e)
            } else {
                throw EditorError.message("tipo 0x\(String(m, radix: 16))")
            }
            cache[i] = val
            return val
        }
        return try obj(top)
    }

    static func serialize(_ value: PlistValue) throws -> Data {
        struct Obj {
            enum Kind {
                case null, bool(Bool), int(Int64), real(Double), date(Double)
                case data(Data), str(String), arr([Int]), dict(keys: [Int], vals: [Int])
            }
            var kind: Kind
        }
        var objects: [Obj] = []
        var intern: [String: Int] = [:]
        func add(_ obj: Obj, key: String?) -> Int {
            if let key, let i = intern[key] { return i }
            let i = objects.count
            objects.append(obj)
            if let key { intern[key] = i }
            return i
        }
        func write(_ v: PlistValue) -> Int {
            switch v {
            case .null: return add(Obj(kind: .null), key: "n")
            case .bool(let b): return add(Obj(kind: .bool(b)), key: b ? "t" : "f")
            case .int(let n): return add(Obj(kind: .int(n)), key: "i:\(n)")
            case .real(let n): return add(Obj(kind: .real(n)), key: "r:\(n)")
            case .date(let n): return add(Obj(kind: .date(n)), key: "d:\(n)")
            case .data(let d): return add(Obj(kind: .data(d)), key: nil)
            case .str(let s): return add(Obj(kind: .str(s)), key: "s:\(s)")
            case .arr(let a): return add(Obj(kind: .arr(a.map(write))), key: nil)
            case .dict(let p):
                return add(Obj(kind: .dict(keys: p.map { write(.str($0.0)) }, vals: p.map { write($0.1) })), key: nil)
            case .nested(let inner):
                let bytes = (try? serialize(inner.wrapped())) ?? Data()
                return add(Obj(kind: .data(bytes)), key: nil)
            }
        }
        let top = write(value)
        let n = objects.count
        let ref = sizeFor(n)
        func encInt(_ n: Int64) -> Data {
            if n >= 0 && n <= 255 { return Data([0x10, UInt8(n)]) }
            if n >= Int16.min && n <= Int16.max {
                var d = Data([0x11, 0, 0])
                let v = Int16(n).bigEndian
                Swift.withUnsafeBytes(of: v) { d.replaceSubrange(1..<3, with: $0) }
                return d
            }
            if n >= Int32.min && n <= Int32.max {
                var d = Data([0x12, 0, 0, 0, 0])
                let v = Int32(n).bigEndian
                Swift.withUnsafeBytes(of: v) { d.replaceSubrange(1..<5, with: $0) }
                return d
            }
            var d = Data([0x13])
            var v = UInt64(bitPattern: n).bigEndian
            Swift.withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
            return d
        }
        func encMarker(_ base: UInt8, _ len: Int) -> Data {
            if len < 15 { return Data([base | UInt8(len)]) }
            var o = Data([base | 0x0f])
            o.append(encInt(Int64(len)))
            return o
        }
        func refs(_ arr: [Int]) -> Data {
            var d = Data(count: arr.count * ref)
            for (i, v) in arr.enumerated() {
                writeInt(&d, i * ref, ref, v)
            }
            return d
        }
        func enc(_ obj: Obj) -> Data {
            switch obj.kind {
            case .null: return Data([0])
            case .bool(let b): return Data([b ? 9 : 8])
            case .int(let n): return encInt(n)
            case .real(let n):
                var d = Data([0x23])
                var v = n.bitPattern.bigEndian
                Swift.withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
                return d
            case .date(let n):
                var d = Data([0x33])
                var v = n.bitPattern.bigEndian
                Swift.withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
                return d
            case .data(let raw):
                var d = encMarker(0x40, raw.count)
                d.append(raw)
                return d
            case .str(let s):
                if s.utf8.allSatisfy({ $0 < 128 }) {
                    let raw = Data(s.utf8)
                    var d = encMarker(0x50, raw.count)
                    d.append(raw)
                    return d
                }
                var raw = Data()
                for ch in s.utf16 {
                    raw.append(UInt8(ch >> 8))
                    raw.append(UInt8(ch & 0xff))
                }
                var d = encMarker(0x60, s.utf16.count)
                d.append(raw)
                return d
            case .arr(let r):
                var d = encMarker(0xa0, r.count)
                d.append(refs(r))
                return d
            case .dict(let keys, let vals):
                var d = encMarker(0xd0, keys.count)
                d.append(refs(keys))
                d.append(refs(vals))
                return d
            }
        }
        let chunks = objects.map(enc)
        var cur = 8
        var offs: [Int] = []
        for c in chunks { offs.append(cur); cur += c.count }
        let otOff = cur
        let oSize = sizeFor(otOff + n * 4 + 32)
        var ot = Data(count: n * oSize)
        for i in 0..<n { writeInt(&ot, i * oSize, oSize, offs[i]) }
        var out = Data(magic.utf8)
        for c in chunks { out.append(c) }
        out.append(ot)
        var trailer = Data(count: 32)
        trailer[6] = UInt8(oSize)
        trailer[7] = UInt8(ref)
        writeInt(&trailer, 8, 8, n)
        writeInt(&trailer, 16, 8, top)
        writeInt(&trailer, 24, 8, otOff)
        out.append(trailer)
        return out
    }

    private static func sizeFor(_ n: Int) -> Int {
        n < 256 ? 1 : n < 65536 ? 2 : 4
    }

    private static func writeInt(_ d: inout Data, _ off: Int, _ size: Int, _ n: Int) {
        switch size {
        case 1: d[off] = UInt8(n & 0xff)
        case 2:
            d[off] = UInt8((n >> 8) & 0xff)
            d[off + 1] = UInt8(n & 0xff)
        case 4:
            d[off] = UInt8((n >> 24) & 0xff)
            d[off + 1] = UInt8((n >> 16) & 0xff)
            d[off + 2] = UInt8((n >> 8) & 0xff)
            d[off + 3] = UInt8(n & 0xff)
        default:
            for i in 0..<8 {
                d[off + i] = UInt8((n >> ((7 - i) * 8)) & 0xff)
            }
        }
    }

    private static func intBE(_ data: Data, _ off: Int, _ size: Int) -> Int {
        var n = 0
        for i in 0..<size { n = (n << 8) | Int(data[off + i]) }
        return n
    }

    private static func intSigned(_ data: Data, _ off: Int, _ size: Int) -> Int64 {
        var n: Int64 = 0
        for i in 0..<size { n = (n << 8) | Int64(data[off + i]) }
        let bits = size * 8
        if bits < 64, (n & (1 << (bits - 1))) != 0 {
            n -= 1 << bits
        }
        return n
    }

    private static func readLen(_ data: Data, _ off: Int, _ info: Int) -> (n: Int, h: Int) {
        if info < 15 { return (info, 1) }
        let m = Int(data[off + 1])
        let nb = 1 << (m & 0xf)
        return (intBE(data, off + 2, nb), 2 + nb)
    }
}

