import CryptoKit
import Foundation
import Security

/// 证书指纹：叶子证书 SPKI 的 SHA-256（用来比对），外加整张证书的 SHA-256（只展示）。
///
/// 为什么比对 SPKI 而不是整张证书，见 README「代理证书的三种验证」：
/// 续签时只要密钥不变，SPKI 指纹就不变；整张证书的指纹每次续签都变。
/// 这也是 RFC 7469（HPKP）和 curl `--pinnedpubkey` 选的写法，格式 `sha256//<base64>` 大家都认得。
enum CertificateFingerprint {
    /// 叶子证书的 SubjectPublicKeyInfo 做 SHA-256
    static func spkiSHA256(of certificate: SecCertificate) -> Data? {
        let der = [UInt8](SecCertificateCopyData(certificate) as Data)
        guard let spki = subjectPublicKeyInfo(inCertificate: der) else { return nil }
        return Data(SHA256.hash(data: spki))
    }

    static func certificateSHA256(of certificate: SecCertificate) -> Data {
        Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
    }

    // MARK: - 指纹文本

    /// 用户填的指纹 → 32 字节。认这几种写法：
    /// - base64，可带 `sha256/` 或 `sha256//` 前缀（curl / HPKP 的写法）
    /// - 十六进制，可带冒号或空格分隔（`openssl x509 -fingerprint` 的写法）
    static func parsePin(_ raw: String) -> Data? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("sha256/") {
            text = String(text.dropFirst("sha256/".count))
            while text.hasPrefix("/") { text.removeFirst() }
        }
        let hexCandidate = text.filter { $0 != ":" && $0 != " " }
        if hexCandidate.count == 64, let data = Data(hex: hexCandidate) { return data }
        guard let data = Data(base64Encoded: text), data.count == 32 else { return nil }
        return data
    }

    /// 多行文本拆成指纹。返回 (认得的，规范化成 base64；认不出的原文)
    static func parsePinList(_ text: String) -> (pins: [String], invalid: [String]) {
        var pins: [String] = []
        var invalid: [String] = []
        let tokens = text
            .split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for token in tokens {
            if let data = parsePin(token) {
                let normalized = data.base64EncodedString()
                if !pins.contains(normalized) { pins.append(normalized) }
            } else {
                invalid.append(token)
            }
        }
        return (pins, invalid)
    }

    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: - DER

    /// 从证书 DER 里把 SubjectPublicKeyInfo 那一整段 TLV 原样切出来。
    ///
    /// 不用 `SecCertificateCopyKey` + `SecKeyCopyExternalRepresentation`：后者给的是
    /// **裸公钥**（RSA 是 PKCS#1、EC 是 X9.63 点），不是 SPKI，要自己按密钥类型补 ASN.1 头，
    /// 漏一种类型就算错一种。直接从证书里切 SPKI 对所有密钥类型都一样。
    ///
    /// Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
    /// TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber, signature,
    ///                               issuer, validity, subject, subjectPublicKeyInfo, ... }
    static func subjectPublicKeyInfo(inCertificate der: [UInt8]) -> [UInt8]? {
        guard let certificate = DERReader.element(in: der, at: 0), certificate.tag == 0x30,
              let tbs = DERReader.element(in: der, at: certificate.contentStart), tbs.tag == 0x30
        else { return nil }

        var cursor = tbs.contentStart
        var element = DERReader.element(in: der, at: cursor)
        // 可选的 [0] version
        if element?.tag == 0xA0, let version = element {
            cursor = version.end
            element = DERReader.element(in: der, at: cursor)
        }
        // serialNumber, signature, issuer, validity, subject —— 跳过五个
        for _ in 0..<5 {
            guard let current = element, current.end <= tbs.end else { return nil }
            cursor = current.end
            element = DERReader.element(in: der, at: cursor)
        }
        guard let spki = element, spki.tag == 0x30, spki.end <= tbs.end else { return nil }
        return Array(der[spki.start..<spki.end])
    }
}

/// 最小的 DER TLV 读取器，只够切证书用。所有越界都返回 nil，不信任输入。
enum DERReader {
    struct Element {
        let tag: UInt8
        let start: Int
        let contentStart: Int
        let end: Int
    }

    static func element(in bytes: [UInt8], at offset: Int) -> Element? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        let tag = bytes[offset]
        // 证书里用不到多字节 tag（低 5 位全 1），遇到就当坏数据
        guard tag & 0x1F != 0x1F else { return nil }
        let first = bytes[offset + 1]
        var length = 0
        var header = 2
        if first & 0x80 == 0 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            // 0 是不定长（DER 里不允许），超过 4 字节的长度对证书没有意义
            guard (1...4).contains(count), offset + 2 + count <= bytes.count else { return nil }
            for index in 0..<count {
                length = (length << 8) | Int(bytes[offset + 2 + index])
            }
            header += count
        }
        let contentStart = offset + header
        let end = contentStart + length
        guard end <= bytes.count else { return nil }
        return Element(tag: tag, start: offset, contentStart: contentStart, end: end)
    }
}

extension Data {
    /// 纯十六进制串（不带分隔符）→ Data。长度为奇数或有非法字符返回 nil。
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
