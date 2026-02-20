// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CurveFitterPro",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "CurveFitterPro", targets: ["CurveFitterPro"])
    ],
    targets: [
        .target(
            name: "CurveFitterPro",
            path: "Sources"
        )
    ]
)
