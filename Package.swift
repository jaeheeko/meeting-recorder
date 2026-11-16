// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS("26.0")],
    dependencies: [
        // 화자 분리(pyannote 계열, Core ML). 버전을 고정한다. Diarizer trait 만 켜서 TTS 등은 빌드에서 뺀다.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: ["Diarizer"]),
    ],
    targets: [
        .executableTarget(
            name: "MeetingRecorder",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/MeetingRecorder",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        ),
    ]
)
