import CoreServices
import Foundation

/// File-level FSEvents stream that delivers (path, flags) batches on a given queue.
final class Watcher {
    private var stream: FSEventStreamRef?
    private let handler: ([(String, UInt32)]) -> Void

    init?(paths: [String], queue: DispatchQueue, handler: @escaping ([(String, UInt32)]) -> Void) {
        self.handler = handler
        guard !paths.isEmpty else { return nil }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let me = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
            guard let list = cfPaths as? [String] else { return }
            var batch: [(String, UInt32)] = []
            batch.reserveCapacity(count)
            for i in 0..<min(count, list.count) { batch.append((list[i], eventFlags[i])) }
            me.handler(batch)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                           | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags)
        else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}
