// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "NessoHub",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "nesso-hub",
      path: "Sources/NessoHub",
      linkerSettings: [
        // A command-line tool has no bundle, so its Info.plist goes into the
        // binary itself. macOS reads the Bluetooth and Apple Events usage
        // strings from there, and kills a process that asks without them.
        .unsafeFlags([
          "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
          "-Xlinker", "Info.plist",
        ])
      ]
    )
  ]
)
