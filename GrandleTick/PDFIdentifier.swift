import Foundation
import CryptoKit

enum PDFIdentifier {
    static func contentHash(_ data: Data) -> String {
        // 对前 12 个摘要字节编码，得到 96 位内容指纹，避免依赖调试说明文本的格式。
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func legacyIdentifier(for identifier: String) -> String? {
        // 1. 仅对修复后的内容指纹提供兼容，文件系统标识和未知格式不按大小兜底。
        let parts = identifier.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "pdf", UInt64(parts[1]) != nil,
              parts[2].count == 24, parts[3].count == 24,
              (parts[2] + parts[3]).allSatisfy({ "0123456789abcdef".contains($0) }) else {
            return nil
        }

        // 2. 还原旧版本实际存储的标识，仅用于查询既有记录，不作为新记录的身份。
        return "pdf_\(parts[1])_SHA256 diges_SHA256 diges"
    }
}
