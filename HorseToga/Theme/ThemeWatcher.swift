//
//  Copyright © 2026 Jason Chan.
//  Licensed under the MIT License. See LICENSE at the repository root.
//

import CoreServices
import Foundation

/// Recursive FSEvents watch over the user themes directory with a debounce:
/// editors write-then-rename, producing bursts; we want ONE reload per burst.
@MainActor
final class ThemeWatcher {
    // nonisolated(unsafe): a C handle we must release in deinit (which is
    // nonisolated in Swift 6). Only written once in init, read in deinit.
    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?

    init?(directory: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            themeWatcherCallback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    fileprivate func fileChanged() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

private nonisolated func themeWatcherCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<ThemeWatcher>.fromOpaque(info).takeUnretainedValue()
    // Stream is scheduled on the main queue, so this is an assertion, not a hop.
    MainActor.assumeIsolated {
        watcher.fileChanged()
    }
}
