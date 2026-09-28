import Foundation

@MainActor final class ApplicationDirectoryMonitor {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounceTask: Task<Void, Never>?
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }

    deinit {
        debounceTask?.cancel()
        sources.forEach { $0.cancel() }
    }

    func start() {
        guard sources.isEmpty else { return }
        let urls = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]

        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke], queue: .main)
            source.setEventHandler { [weak self] in self?.scheduleChange() }
            source.setCancelHandler { close(descriptor) }
            sources.append(source)
            source.resume()
        }
    }

    private func scheduleChange() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }
}
