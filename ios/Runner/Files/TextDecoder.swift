import Foundation
import CoreFoundation

enum TextDecoder {
    static func decode(_ bytes: Data) throws -> String {
        let body: Data
        let encoding: String.Encoding
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { body = bytes.dropFirst(3); encoding = .utf8 }
        else if bytes.starts(with: [0xff, 0xfe]) { body = bytes.dropFirst(2); encoding = .utf16LittleEndian }
        else if bytes.starts(with: [0xfe, 0xff]) { body = bytes.dropFirst(2); encoding = .utf16BigEndian }
        else {
            if let text = String(data: bytes, encoding: .utf8) { return text }
            let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)); body = bytes
        }
        if (encoding == .utf16LittleEndian || encoding == .utf16BigEndian) && body.count % 2 != 0 { throw DocumentError.invalid }
        guard let text = String(data: body, encoding: encoding) else { throw DocumentError.invalid }
        if encoding == .utf16LittleEndian || encoding == .utf16BigEndian {
            guard text.data(using: encoding) == body else { throw DocumentError.invalid }
        }
        return text
    }
}
