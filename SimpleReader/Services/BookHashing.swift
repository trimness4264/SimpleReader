import Foundation
import CryptoKit

enum BookHashing {
    static func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func identity(file: URL, filename: String) throws -> BookIdentity {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var full = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { full.update(data: bytes) }
        var partial = Insecure.MD5()
        // KOReader util.partialMD5: 1024-byte windows at 0, 1 KiB, 4 KiB ... 1 GiB.
        for offset in [UInt64(0)] + (0...10).map({ UInt64(1024) << (2 * $0) }) {
            try handle.seek(toOffset: offset)
            guard let bytes = try handle.read(upToCount: 1024), !bytes.isEmpty else { break }
            partial.update(data: bytes)
        }
        return BookIdentity(sha256: full.finalize().map { String(format: "%02x", $0) }.joined(), partialMD5: partial.finalize().map { String(format: "%02x", $0) }.joined(), filenameMD5: md5(Data(filename.utf8)))
    }
}
