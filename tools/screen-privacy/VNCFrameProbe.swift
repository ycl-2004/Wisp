// Pulls one framebuffer update from macOS Screen Sharing over RFB and counts marker
// pixels. Screen Sharing captures as a system service, on a different path from
// ScreenCaptureKit and the legacy CoreGraphics calls, so it has to be measured
// separately rather than assumed to behave the same.
//
// The password is read from stdin, never from argv: process arguments are visible to
// any process running as the same user.
//
// Usage: echo -n PASSWORD | vnc-frame-probe [host] [port]
import Foundation
import CommonCrypto
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ProbeFailure: Error, CustomStringConvertible {
    case connect(String), handshake(String), auth(String), protocolError(String)
    var description: String {
        switch self {
        case .connect(let m): return "connect failed: \(m)"
        case .handshake(let m): return "handshake failed: \(m)"
        case .auth(let m): return "authentication failed: \(m)"
        case .protocolError(let m): return "protocol error: \(m)"
        }
    }
}

final class RFBConnection {
    private let fd: Int32

    init(host: String, port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProbeFailure.connect("socket() failed") }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            throw ProbeFailure.connect("bad host \(host)")
        }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            throw ProbeFailure.connect("connect() to \(host):\(port) failed (errno \(errno)) — is Screen Sharing on?")
        }
    }

    deinit { close(fd) }

    func read(_ count: Int) throws -> Data {
        var buffer = Data(count: count)
        var filled = 0
        while filled < count {
            let got: Int = buffer.withUnsafeMutableBytes { raw in
                recv(fd, raw.baseAddress!.advanced(by: filled), count - filled, 0)
            }
            guard got > 0 else { throw ProbeFailure.protocolError("connection closed after \(filled)/\(count) bytes") }
            filled += got
        }
        return buffer
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < data.count {
                let wrote = send(fd, raw.baseAddress!.advanced(by: sent), data.count - sent, 0)
                guard wrote > 0 else { throw ProbeFailure.protocolError("send failed") }
                sent += wrote
            }
        }
    }
}

/// VNC authentication uses each password byte with its bits reversed as the DES key.
/// Source: RFC 6143 §7.2.2.
func vncKey(from password: String) -> Data {
    var key = Data(count: 8)
    for (index, byte) in Array(password.utf8).prefix(8).enumerated() {
        var reversed: UInt8 = 0
        for bit in 0..<8 where byte & (1 << bit) != 0 { reversed |= 1 << (7 - bit) }
        key[index] = reversed
    }
    return key
}

func desEncrypt(_ block: Data, key: Data) throws -> Data {
    var output = Data(count: block.count)
    var moved = 0
    let status = output.withUnsafeMutableBytes { out in
        block.withUnsafeBytes { input in
            key.withUnsafeBytes { keyBytes in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES),
                        CCOptions(kCCOptionECBMode), keyBytes.baseAddress, 8, nil,
                        input.baseAddress, block.count, out.baseAddress, block.count, &moved)
            }
        }
    }
    guard status == kCCSuccess else { throw ProbeFailure.auth("DES failed (\(status))") }
    return output
}

func u16(_ data: Data, _ offset: Int) -> Int { Int(data[data.startIndex + offset]) << 8 | Int(data[data.startIndex + offset + 1]) }
func u32(_ data: Data, _ offset: Int) -> Int {
    (0..<4).reduce(0) { $0 << 8 | Int(data[data.startIndex + offset + $1]) }
}
func be16(_ value: Int) -> Data { Data([UInt8(value >> 8 & 255), UInt8(value & 255)]) }

let host = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "127.0.0.1"
let port = UInt16(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "5900") ?? 5900
guard let password = readLine(strippingNewline: true), !password.isEmpty else {
    FileHandle.standardError.write(Data("no password on stdin\n".utf8))
    exit(2)
}

do {
    let connection = try RFBConnection(host: host, port: port)

    // 1. Version handshake.
    let version = try connection.read(12)
    guard String(decoding: version, as: UTF8.self).hasPrefix("RFB ") else {
        throw ProbeFailure.handshake("unexpected banner")
    }
    try connection.write(Data("RFB 003.008\n".utf8))

    // 2. Security types; pick VNC authentication (2).
    let count = Int(try connection.read(1)[0])
    guard count > 0 else {
        let length = u32(try connection.read(4), 0)
        let reason = String(decoding: try connection.read(length), as: UTF8.self)
        throw ProbeFailure.handshake("server refused: \(reason)")
    }
    let types = try connection.read(count)
    print("securityTypes=\(Array(types))")

    // Type 1 (None) is what the "anyone may request permission" flow uses: the Mac
    // asks its local user to approve, and the approved session is the live one.
    // Type 2 (VNC password) authenticates without asking, and on this Mac it lands
    // in a separate login session instead of the console session.
    if types.contains(1) {
        print("using security type 1 (None) — the Mac may now ask you to approve the connection")
        try connection.write(Data([1]))
    } else if types.contains(2) {
        print("using security type 2 (VNC password)")
        try connection.write(Data([2]))
        let challenge = try connection.read(16)
        try connection.write(try desEncrypt(challenge, key: vncKey(from: password)))
    } else {
        throw ProbeFailure.auth("server offers only \(Array(types)); this probe supports 1 and 2")
    }
    let result = u32(try connection.read(4), 0)
    guard result == 0 else {
        let length = u32(try connection.read(4), 0)
        let reason = length > 0 && length < 4096
            ? String(decoding: try connection.read(length), as: UTF8.self) : "no reason given"
        throw ProbeFailure.auth("rejected: \(reason)")
    }

    // 4. ClientInit (shared) and ServerInit.
    try connection.write(Data([1]))
    let serverInit = try connection.read(24)
    let width = u16(serverInit, 0), height = u16(serverInit, 2)
    let nameLength = u32(serverInit, 20)
    let name = String(decoding: try connection.read(nameLength), as: UTF8.self)

    // 5. Use the server's own pixel format rather than requesting one. A display can
    // report depth 30, in which case fixed 8-bit assumptions decode to nothing.
    let bitsPerPixel = Int(serverInit[serverInit.startIndex + 4])
    let depth = Int(serverInit[serverInit.startIndex + 5])
    let bigEndian = serverInit[serverInit.startIndex + 6] != 0
    let trueColour = serverInit[serverInit.startIndex + 7] != 0
    let redMax = u16(serverInit, 8), greenMax = u16(serverInit, 10), blueMax = u16(serverInit, 12)
    let redShift = Int(serverInit[serverInit.startIndex + 14])
    let greenShift = Int(serverInit[serverInit.startIndex + 15])
    let blueShift = Int(serverInit[serverInit.startIndex + 16])
    print("pixelFormat bpp=\(bitsPerPixel) depth=\(depth) bigEndian=\(bigEndian) trueColour=\(trueColour) "
        + "max=(\(redMax),\(greenMax),\(blueMax)) shift=(\(redShift),\(greenShift),\(blueShift))")
    guard trueColour, bitsPerPixel == 32 else {
        throw ProbeFailure.protocolError("unsupported pixel format for this probe")
    }
    try connection.write(Data([2, 0]) + be16(1) + Data([0, 0, 0, 0]))  // SetEncodings: Raw

    // 6. Ask for the whole screen, non-incremental.
    try connection.write(Data([3, 0]) + be16(0) + be16(0) + be16(width) + be16(height))

    let header = try connection.read(4)
    guard header[header.startIndex] == 0 else { throw ProbeFailure.protocolError("expected FramebufferUpdate") }
    let rectangles = u16(header, 2)

    var magenta = 0, cyan = 0, total = 0, nonBlack = 0
    var sumR = 0, sumG = 0, sumB = 0
    // Optional frame dump, for telling a mirrored screen apart from a virtual desktop.
    let dumpPath = ProcessInfo.processInfo.environment["WISP_VNC_DUMP"]
    var rgba = Data()
    for _ in 0..<rectangles {
        let rect = try connection.read(12)
        let w = u16(rect, 4), h = u16(rect, 6)
        let encoding = u32(rect, 8)
        guard encoding == 0 else { throw ProbeFailure.protocolError("unsupported encoding \(encoding)") }
        let pixels = try connection.read(w * h * 4)
        if dumpPath != nil { rgba.append(pixels) }
        pixels.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let value: UInt32 = bigEndian
                    ? (UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
                       | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3]))
                    : (UInt32(bytes[index + 3]) << 24 | UInt32(bytes[index + 2]) << 16
                       | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index]))
                let r = Int(value >> UInt32(redShift)) & redMax
                let g = Int(value >> UInt32(greenShift)) & greenMax
                let b = Int(value >> UInt32(blueShift)) & blueMax
                // Normalise each channel to 0-255 so one threshold works for any depth.
                let r8 = r * 255 / max(redMax, 1), g8 = g * 255 / max(greenMax, 1), b8 = b * 255 / max(blueMax, 1)
                if r8 > 200 && g8 < 70 && b8 > 200 { magenta += 1 }
                if r8 < 70 && g8 > 200 && b8 > 200 { cyan += 1 }
                if r8 > 16 || g8 > 16 || b8 > 16 { nonBlack += 1 }
                sumR += r8; sumG += g8; sumB += b8
                total += 1
            }
        }
    }
    print("server=\"\(name)\" framebuffer=\(width)x\(height) rectangles=\(rectangles) pixels=\(total)")
    print("magenta=\(magenta) cyan=\(cyan)")
    if let dumpPath, rectangles == 1, !rgba.isEmpty {
        let provider = CGDataProvider(data: rgba as CFData)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        if let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: info, provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent),
           let destination = CGImageDestinationCreateWithURL(
               URL(fileURLWithPath: dumpPath) as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            print("dumped frame to \(dumpPath)")
        }
    }
    let denominator = max(total, 1)
    print("frameStats nonBlack=\(nonBlack) (\(nonBlack * 100 / denominator)%) "
        + "averageRGB=(\(sumR / denominator),\(sumG / denominator),\(sumB / denominator))")
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
