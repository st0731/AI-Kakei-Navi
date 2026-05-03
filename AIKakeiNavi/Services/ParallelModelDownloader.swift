import Foundation

actor ParallelModelDownloader {

    private struct ModelMeta: Decodable {
        let sha: String
        let siblings: [FileInfo]

        struct FileInfo: Decodable {
            let rfilename: String
            let size: Int64?
            let lfs: LFSInfo?

            struct LFSInfo: Decodable {
                let sha256: String
                let size: Int64
            }

            var expectedBytes: Int64 { lfs?.size ?? size ?? 0 }
        }
    }

    private let maxConcurrent = 6
    private let userAgent = "AIKakeiNavi/1.0 (iOS; on-device-llm)"
    private var totalExpectedBytes: Int64 = 0
    private var downloadedBytes: Int64 = 0
    private var completedFiles = 0
    private var totalFiles = 0
    private var lastReportedProgress: Double = -1

    func download(modelID: String, onProgress: @Sendable @escaping (Double, String) -> Void) async throws {
        onProgress(0, "モデル情報を取得中...")

        let meta = try await fetchMeta(modelID: modelID)
        let root = repoRoot(modelID: modelID)
        let metaRoot = root.appending(path: ".cache/huggingface/download")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var rootForExclusion = root
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? rootForExclusion.setResourceValues(resourceValues)

        let files = meta.siblings
        totalFiles = files.count
        totalExpectedBytes = files.reduce(0) { $0 + $1.expectedBytes }
        downloadedBytes = 0
        completedFiles = 0
        lastReportedProgress = -1

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iter = files.makeIterator()
            var active = 0

            while active < maxConcurrent, let file = iter.next() {
                group.addTask { [self] in
                    try await self.fetchFile(file, commitHash: meta.sha,
                                            modelID: modelID, root: root, metaRoot: metaRoot,
                                            onProgress: onProgress)
                }
                active += 1
            }

            for try await _ in group {
                if let file = iter.next() {
                    group.addTask { [self] in
                        try await self.fetchFile(file, commitHash: meta.sha,
                                                modelID: modelID, root: root, metaRoot: metaRoot,
                                                onProgress: onProgress)
                    }
                }
            }
        }
    }

    private func fetchMeta(modelID: String) async throws -> ModelMeta {
        // ?blobs=true guarantees each sibling includes `size` and `lfs` for progress tracking
        guard let url = URL(string: "https://huggingface.co/api/models/\(modelID)?blobs=true") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ModelMeta.self, from: data)
    }

    private func fetchFile(
        _ file: ModelMeta.FileInfo,
        commitHash: String,
        modelID: String,
        root: URL,
        metaRoot: URL,
        onProgress: @Sendable @escaping (Double, String) -> Void
    ) async throws {
        let filename = file.rfilename
        let dest = root.appending(path: filename)
        let metaPath = metaRoot.appending(path: filename + ".metadata")

        if FileManager.default.fileExists(atPath: dest.path),
           FileManager.default.fileExists(atPath: metaPath.path) {
            recordCompletion(bytes: file.expectedBytes, onProgress: onProgress)
            return
        }

        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://huggingface.co/\(modelID)/resolve/\(commitHash)/\(encoded)")
        else { throw URLError(.badURL) }

        if let lfs = file.lfs {
            // Large LFS file: parallel 20MB chunks via HTTP Range requests → 3-5x faster
            try await downloadChunked(from: url, to: dest, fileSize: lfs.size) { [self] delta in
                Task { await self.addBytes(delta, onProgress: onProgress) }
            }
        } else {
            var fileRequest = URLRequest(url: url)
            fileRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (tmp, response) = try await URLSession.shared.download(for: fileRequest)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: tmp)
                throw URLError(.badServerResponse)
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: dest)
            }
        }

        let metaContent: String
        if let lfs = file.lfs {
            metaContent = "\(commitHash)\n\(lfs.sha256)\n\(Date().timeIntervalSince1970)\n"
        } else {
            metaContent = "\(commitHash)\n\(Date().timeIntervalSince1970)\n"
        }
        try FileManager.default.createDirectory(
            at: metaPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try metaContent.write(to: metaPath, atomically: true, encoding: .utf8)

        // LFS bytes counted in real-time via addBytes; only add non-LFS bytes here
        recordCompletion(bytes: file.lfs == nil ? file.expectedBytes : 0, onProgress: onProgress)
    }

    private func recordCompletion(bytes: Int64, onProgress: @Sendable @escaping (Double, String) -> Void) {
        completedFiles += 1
        downloadedBytes += bytes
        reportProgress(force: true, onProgress: onProgress)
    }

    private func addBytes(_ delta: Int64, onProgress: @Sendable @escaping (Double, String) -> Void) {
        downloadedBytes += delta
        reportProgress(force: false, onProgress: onProgress)
    }

    private func reportProgress(force: Bool, onProgress: @Sendable @escaping (Double, String) -> Void) {
        let progress: Double
        let text: String
        if totalExpectedBytes > 0 {
            progress = min(1.0, Double(downloadedBytes) / Double(totalExpectedBytes))
            let mb = Double(downloadedBytes) / 1_048_576
            let totalMB = Double(totalExpectedBytes) / 1_048_576
            text = String(format: "ダウンロード中... %.0f/%.0f MB", mb, totalMB)
        } else {
            progress = Double(completedFiles) / Double(max(totalFiles, 1))
            text = "ダウンロード中... (\(completedFiles)/\(totalFiles))"
        }
        guard force || progress - lastReportedProgress > 0.005 else { return }
        lastReportedProgress = progress
        onProgress(progress, text)
    }

    // Downloads a file in parallel 20MB chunks using HTTP Range requests.
    // pwrite() enables concurrent writes at different file offsets without serialization.
    private nonisolated func downloadChunked(
        from url: URL,
        to dest: URL,
        fileSize: Int64,
        onBytes: @Sendable @escaping (Int64) -> Void
    ) async throws {
        guard fileSize > 0 else { return }

        let chunkSize: Int64 = 20 * 1024 * 1024  // 20MB
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        guard FileManager.default.createFile(atPath: tmpURL.path, contents: nil) else {
            throw URLError(.cannotCreateFile)
        }
        let fd = open(tmpURL.path, O_WRONLY)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw URLError(.cannotOpenFile)
        }
        guard ftruncate(fd, fileSize) == 0 else {
            close(fd)
            try? FileManager.default.removeItem(at: tmpURL)
            throw URLError(.cannotCreateFile)
        }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var active = 0
                var nextStart: Int64 = 0

                while active < 6, nextStart < fileSize {
                    let start = nextStart
                    let end = min(start + chunkSize - 1, fileSize - 1)
                    group.addTask {
                        try await Self.downloadChunk(url: url, fd: fd, start: start, end: end, onBytes: onBytes)
                    }
                    active += 1
                    nextStart += chunkSize
                }

                for try await _ in group {
                    if nextStart < fileSize {
                        let start = nextStart
                        let end = min(start + chunkSize - 1, fileSize - 1)
                        group.addTask {
                            try await Self.downloadChunk(url: url, fd: fd, start: start, end: end, onBytes: onBytes)
                        }
                        nextStart += chunkSize
                    }
                }
            }
        } catch {
            close(fd)
            try? FileManager.default.removeItem(at: tmpURL)
            throw error
        }

        close(fd)
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.moveItem(at: tmpURL, to: dest)
        }
    }

    private static func downloadChunk(
        url: URL,
        fd: Int32,
        start: Int64,
        end: Int64,
        onBytes: @Sendable (Int64) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue("AIKakeiNavi/1.0 (iOS; on-device-llm)", forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 206 else {
            throw URLError(.badServerResponse)
        }
        let written = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
            guard let base = ptr.baseAddress, !ptr.isEmpty else { return 0 }
            return pwrite(fd, base, ptr.count, off_t(start))
        }
        guard written == data.count else { throw URLError(.cannotWriteToFile) }
        onBytes(Int64(data.count))
    }

    // Mirrors HubApi.localRepoLocation: <Documents>/huggingface/models/<modelID>/
    private func repoRoot(modelID: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "huggingface/models/\(modelID)")
    }
}
