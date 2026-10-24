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
