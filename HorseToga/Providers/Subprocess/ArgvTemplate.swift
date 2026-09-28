//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import Foundation

/// Tiny slot renderer for config-driven argv: replaces {{name}} with values;
/// any argument left with an unresolved slot is DROPPED (so templates degrade
/// gracefully when a slot has no value).
nonisolated enum ArgvTemplate {
    static func render(_ args: [String], slots: [String: String]) -> [String] {
        args.compactMap { arg in
            var rendered = arg
            for (key, value) in slots {
                rendered = rendered.replacingOccurrences(of: "{{\(key)}}", with: value)
            }
            return rendered.contains("{{") ? nil : rendered
        }
    }
}
