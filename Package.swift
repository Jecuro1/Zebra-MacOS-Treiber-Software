// swift-tools-version: 6.0
//
// LabelWerk — moderner macOS-Treiber & Studio für Zebra®-Etikettendrucker.
//
// Paketaufbau (siehe ARCHITECTURE.md):
//   CZlib               – System-zlib (Z64-Kompression, PNG)
//   LabelWerkCore       – Gemeinsame Typen, Modellkatalog, ZPL/EPL/CPCL/SGD-Befehle
//   LabelWerkImaging    – Bitmaps, Dithering, Grafik-Encoder (Hex/ACS/Z64), PNG, Job-Encoder
//   LabelWerkBarcode    – Barcode-Encoder (Code128, EAN, QR, DataMatrix, PDF417 …)
//   LabelWerkRender     – ZPL-Parser/Interpreter → Display-Liste, Software-Rasterizer
//   LabelWerkStatus     – Statusparser (~HS, ~HQES, ~HI, SGD, ^HH), Alarme
//   LabelWerkTransport  – Verbindungen (TCP, USB, Bluetooth, BLE, CUPS) & Discovery
//   LabelWerkKit        – High-Level PrinterClient, Umbrella-Modul
//   lwctl               – Kommandozeilen-Werkzeug (macOS & Linux)
//   LabelWerkApp        – SwiftUI-App (nur macOS)

import PackageDescription

let strictLibrary: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
]

var products: [Product] = [
    .library(name: "LabelWerkKit", targets: ["LabelWerkKit"]),
    .executable(name: "lwctl", targets: ["lwctl"]),
]

var targets: [Target] = [
    .systemLibrary(
        name: "CZlib",
        path: "Sources/CZlib"
    ),
    .target(
        name: "LabelWerkCore",
        dependencies: [],
        swiftSettings: strictLibrary
    ),
    .target(
        name: "LabelWerkImaging",
        dependencies: ["LabelWerkCore", "CZlib"],
        swiftSettings: strictLibrary
    ),
    .target(
        name: "LabelWerkBarcode",
        dependencies: [],
        swiftSettings: strictLibrary
    ),
    .target(
        name: "LabelWerkRender",
        dependencies: ["LabelWerkCore", "LabelWerkImaging", "LabelWerkBarcode"],
        swiftSettings: strictLibrary
    ),
    .target(
        name: "LabelWerkStatus",
        dependencies: ["LabelWerkCore"],
        swiftSettings: strictLibrary
    ),
    .target(
        name: "LabelWerkTransport",
        dependencies: ["LabelWerkCore"],
        swiftSettings: strictLibrary
    ),
    .target(
        name: "LabelWerkKit",
        dependencies: [
            "LabelWerkCore", "LabelWerkImaging", "LabelWerkBarcode",
            "LabelWerkRender", "LabelWerkStatus", "LabelWerkTransport",
        ],
        swiftSettings: strictLibrary
    ),
    .executableTarget(
        name: "lwctl",
        dependencies: ["LabelWerkKit"],
        swiftSettings: strictLibrary
    ),

    // MARK: Tests
    .testTarget(name: "LabelWerkCoreTests", dependencies: ["LabelWerkCore"]),
    .testTarget(name: "LabelWerkImagingTests", dependencies: ["LabelWerkImaging"]),
    .testTarget(name: "LabelWerkBarcodeTests", dependencies: ["LabelWerkBarcode"]),
    .testTarget(name: "LabelWerkRenderTests", dependencies: ["LabelWerkRender"]),
    .testTarget(name: "LabelWerkStatusTests", dependencies: ["LabelWerkStatus"]),
    .testTarget(name: "LabelWerkTransportTests", dependencies: ["LabelWerkTransport"]),
    .testTarget(name: "LabelWerkKitTests", dependencies: ["LabelWerkKit"]),
]

#if os(macOS)
// Die SwiftUI-App wird nur auf macOS gebaut. Auf Linux (CI) werden Kern, Treiber-Logik
// und CLI gebaut und getestet.
products.append(.executable(name: "LabelWerk", targets: ["LabelWerkApp"]))
targets.append(
    .executableTarget(
        name: "LabelWerkApp",
        dependencies: ["LabelWerkKit"],
        path: "Sources/LabelWerkApp",
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
)
#endif

let package = Package(
    name: "LabelWerk",
    defaultLocalization: "de",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
