// MPPKit: Microsoft Project (.mpp) files in Swift
// SPDX-License-Identifier: GPL-3.0-only
//
// swift-corelibs-foundation lacks String(localized:); on Linux the key is the text.

#if !canImport(Darwin)
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

extension String {
    init(localized key: String) { self = key }
}
#endif

#if os(WASI)
// The WebAssembly build has FoundationEssentials only: the two NSString
// helpers MPPKit uses, written out.
public enum WhitespaceSet { case whitespaces, whitespacesAndNewlines }

extension StringProtocol {
    public func trimmingCharacters(in set: WhitespaceSet) -> String {
        let drop: (Character) -> Bool = set == .whitespaces
            ? { $0 == " " || $0 == "\t" || $0 == "\u{A0}" }
            : { $0.isWhitespace }
        guard let first = firstIndex(where: { !drop($0) }) else { return "" }
        let last = lastIndex(where: { !drop($0) })!
        return String(self[first...last])
    }
}

extension String {
    /// `String(format:)` for the integer patterns MPPKit uses: %d, %0Nd, %02x.
    public init(format: String, _ args: CVarArg...) {
        var out = "", i = format.startIndex, n = 0
        while i < format.endIndex {
            let c = format[i]
            guard c == "%" else { out.append(c); i = format.index(after: i); continue }
            i = format.index(after: i)
            var spec = ""
            while i < format.endIndex, "0123456789".contains(format[i]) { spec.append(format[i]); i = format.index(after: i) }
            guard i < format.endIndex else { break }
            let kind = format[i]; i = format.index(after: i)
            if kind == "%" { out.append("%"); continue }
            let value: Int = n < args.count ? (args[n] as? Int) ?? Int(args[n] as? Int32 ?? 0) : 0
            n += 1
            var text = kind == "x" ? String(value, radix: 16) : String(abs(value))
            let width = Int(spec) ?? 0
            let pad: Character = spec.hasPrefix("0") ? "0" : " "
            if text.count < width - (value < 0 && kind != "x" ? 1 : 0) {
                text = String(repeating: pad, count: width - text.count - (value < 0 && kind != "x" ? 1 : 0)) + text
            }
            out += (value < 0 && kind != "x" ? "-" : "") + text
        }
        self = out
    }
}
#endif
