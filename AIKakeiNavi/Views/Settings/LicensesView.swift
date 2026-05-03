import SwiftUI

private struct LicenseEntry: Identifiable {
    let id = UUID()
    let name: String
    let copyright: String
    let licenseType: String
    let url: String
}

private let libraries: [LicenseEntry] = [
    LicenseEntry(
        name: "Qwen3-1.7B",
        copyright: "© 2025 Alibaba Cloud",
        licenseType: "Apache License 2.0",
        url: "https://huggingface.co/Qwen/Qwen3-1.7B"
    ),
    LicenseEntry(
        name: "mlx-swift",
        copyright: "© 2023 Apple Inc.",
        licenseType: "MIT License",
        url: "https://github.com/ml-explore/mlx-swift"
    ),
    LicenseEntry(
        name: "mlx-swift-examples",
        copyright: "© 2023 Apple Inc.",
        licenseType: "MIT License",
        url: "https://github.com/ml-explore/mlx-swift-examples"
    ),
    LicenseEntry(
        name: "swift-transformers",
        copyright: "© 2023 HuggingFace Inc.",
        licenseType: "Apache License 2.0",
        url: "https://github.com/huggingface/swift-transformers"
    ),
    LicenseEntry(
        name: "swift-jinja",
        copyright: "© 2024 HuggingFace Inc.",
        licenseType: "Apache License 2.0",
        url: "https://github.com/huggingface/swift-jinja"
    ),
    LicenseEntry(
        name: "swift-collections",
        copyright: "© 2021 Apple Inc.",
        licenseType: "Apache License 2.0",
        url: "https://github.com/apple/swift-collections"
    ),
    LicenseEntry(
        name: "swift-numerics",
        copyright: "© 2019 Apple Inc.",
        licenseType: "Apache License 2.0",
        url: "https://github.com/apple/swift-numerics"
    ),
    LicenseEntry(
        name: "GzipSwift",
        copyright: "© 2015 1024jp",
        licenseType: "MIT License",
        url: "https://github.com/1024jp/GzipSwift"
    ),
]

struct LicensesView: View {
    var body: some View {
        List(libraries) { lib in
            if let url = URL(string: lib.url) {
                Link(destination: url) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(lib.name)
                            .foregroundStyle(.primary)
                            .fontWeight(.medium)
                        Text(lib.licenseType)
                            .font(.caption)
                            .foregroundStyle(.blue)
                        Text(lib.copyright)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("オープンソースライセンス")
    }
}
