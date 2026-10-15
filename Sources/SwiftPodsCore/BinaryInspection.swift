import Foundation

struct BinarySlice: Hashable {
    let architecture: String
    let platform: String
    let variant: String
    let minimumOS: String
    let kind: String
    var json: [String: String] {
        ["architecture": architecture, "platform": platform, "variant": variant, "minimum_os": minimumOS, "kind": kind]
    }
}

enum BinaryInspection {
    static func inspect(_ url: URL) throws -> [BinarySlice] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func bytes(_ offset: Int, _ count: Int, _ limit: Int) -> Bool {
            offset >= 0 && count >= 0 && offset <= limit && count <= limit - offset
        }
        func integer(_ offset: Int, _ count: Int, little: Bool) -> UInt64 {
            let values = data[offset..<(offset + count)]
            return (little ? Array(values.reversed()) : Array(values)).reduce(0) { ($0 << 8) | UInt64($1) }
        }
        func parse(_ start: Int, _ size: Int, depth: Int = 0) throws -> [BinarySlice] {
            guard depth < 6, bytes(start, size, data.count), size >= 4 else { return [] }
            let end = start + size
            let magic = integer(start, 4, little: false)
            if magic == 0xcafe_babe || magic == 0xcafe_babf || magic == 0xbeba_feca || magic == 0xbfba_feca {
                let little = magic == 0xbeba_feca || magic == 0xbfba_feca
                guard bytes(start, 8, end) else { return [] }
                let count = Int(integer(start + 4, 4, little: little))
                let wide = magic == 0xcafe_babf || magic == 0xbfba_feca
                guard count <= 64, bytes(start + 8, count * (wide ? 32 : 20), end) else { return [] }
                var result: [BinarySlice] = []
                for index in 0..<count {
                    let row = start + 8 + index * (wide ? 32 : 20)
                    let offset = integer(row + 8, wide ? 8 : 4, little: little)
                    let length = integer(row + (wide ? 16 : 12), wide ? 8 : 4, little: little)
                    guard offset <= UInt64(size), length <= UInt64(size) - offset else { continue }
                    result += try parse(start + Int(offset), Int(length), depth: depth + 1)
                }
                return result
            }
            if size >= 8 && data[start..<(start + 8)] == Data("!<arch>\n".utf8) {
                var cursor = start + 8
                var slices: [BinarySlice] = []
                while bytes(cursor, 60, end) {
                    let header = String(decoding: data[cursor..<(cursor + 60)], as: UTF8.self)
                    let name = String(header.prefix(16)).trimmingCharacters(in: .whitespaces)
                    let sizeText = String(decoding: data[(cursor + 48)..<(cursor + 58)], as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                    guard let memberSize = Int(sizeText), memberSize >= 0, bytes(cursor + 60, memberSize, end) else {
                        break
                    }
                    let filenameSize = name.hasPrefix("#1/") ? Int(name.dropFirst(3)) ?? memberSize : 0
                    if filenameSize >= 0 && filenameSize <= memberSize {
                        let member = try parse(cursor + 60 + filenameSize, memberSize - filenameSize, depth: depth + 1)
                        slices += member.map {
                            BinarySlice(
                                architecture: $0.architecture, platform: $0.platform, variant: $0.variant,
                                minimumOS: $0.minimumOS, kind: "static")
                        }
                    }
                    cursor += 60 + memberSize + memberSize % 2
                }
                return slices
            }
            guard [UInt64(0xfeed_face), 0xcefa_edfe, 0xfeed_facf, 0xcffa_edfe].contains(magic) else { return [] }
            let little = magic == 0xcefa_edfe || magic == 0xcffa_edfe
            let wide = magic == 0xfeed_facf || magic == 0xcffa_edfe
            guard bytes(start, wide ? 32 : 28, end) else { return [] }
            let cpu = integer(start + 4, 4, little: little)
            let type = integer(start + 12, 4, little: little)
            let subtype = integer(start + 8, 4, little: little) & 0x00ff_ffff
            var architecture =
                [UInt64(0x0100_000c): "arm64", 0x0100_0007: "x86_64", 0x0200_000c: "arm64_32", 12: "arm", 7: "i386"][
                    cpu] ?? "unknown"
            if cpu == 12 {
                architecture = [UInt64(6): "armv6", 9: "armv7", 11: "armv7s", 12: "armv7k"][subtype] ?? architecture
            }
            if cpu == 0x0100_000c && subtype == 2 { architecture = "arm64e" }
            if cpu == 0x0100_0007 && subtype == 8 { architecture = "x86_64h" }
            let kind = [UInt64(6): "dynamic", 2: "executable", 8: "bundle", 1: "object"][type] ?? "unknown"
            let count = Int(integer(start + 16, 4, little: little))
            guard count <= 4096 else { return [] }
            var cursor = start + (wide ? 32 : 28)
            var platform = "unknown"
            var variant = "unknown"
            var minimum = "unknown"
            for _ in 0..<count {
                guard bytes(cursor, 8, end) else { break }
                let command = integer(cursor, 4, little: little)
                let length = Int(integer(cursor + 4, 4, little: little))
                guard length >= 8, bytes(cursor, length, end) else { break }
                var version: UInt64?
                if command == 0x32 && length >= 24 {
                    let id = integer(cursor + 8, 4, little: little)
                    let platforms: [UInt64: (String, String)] = [
                        1: ("osx", "device"), 2: ("ios", "device"), 3: ("tvos", "device"), 4: ("watchos", "device"),
                        6: ("ios", "maccatalyst"), 7: ("ios", "simulator"), 8: ("tvos", "simulator"),
                        9: ("watchos", "simulator"), 11: ("visionos", "device"), 12: ("visionos", "simulator"),
                    ]
                    (platform, variant) = platforms[id] ?? ("unknown", "unknown")
                    version = integer(cursor + 12, 4, little: little)
                } else if [UInt64(0x24), 0x25, 0x2f, 0x30].contains(command) && length >= 16 {
                    platform = [UInt64(0x24): "osx", 0x25: "ios", 0x2f: "tvos", 0x30: "watchos"][command] ?? "unknown"
                    variant = platform != "osx" && ["i386", "x86_64"].contains(architecture) ? "simulator" : "device"
                    version = integer(cursor + 8, 4, little: little)
                }
                if let version { minimum = "\(version >> 16).\((version >> 8) & 255).\(version & 255)" }
                cursor += length
            }
            return [
                BinarySlice(
                    architecture: architecture, platform: platform, variant: variant, minimumOS: minimum, kind: kind)
            ]
        }
        return Array(Set(try parse(0, data.count))).sorted {
            ($0.architecture, $0.platform, $0.variant, $0.kind) < ($1.architecture, $1.platform, $1.variant, $1.kind)
        }
    }
}
