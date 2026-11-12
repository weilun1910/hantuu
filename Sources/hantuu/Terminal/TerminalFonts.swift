import AppKit
import CoreText

/// Terminal.app owns these fonts. Register them for this process without copying them.
enum TerminalFonts {
    static let directory = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts", isDirectory: true)

    struct Registration {
        let registered: Int
        let found: Int
        let available: Bool
    }

    static let registration: Registration = {
        let result = register(in: directory)
        Log.write("SF Mono process registration: \(result.available ? "available" : "unavailable; using JetBrains Mono"), \(result.registered)/\(result.found) font files registered")
        return result
    }()

    static func register(in directory: URL) -> Registration {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("SF-Mono-") && $0.pathExtension.lowercased() == "otf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var count = 0
        for file in files {
            var error: Unmanaged<CFError>?
            let success = CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error)
            let registrationError = error?.takeRetainedValue()
            if success || registrationError.map({
                CFErrorGetDomain($0) as String == kCTFontManagerErrorDomain as String
                    && CFErrorGetCode($0) == CTFontManagerError.alreadyRegistered.rawValue
            }) == true {
                count += 1
            }
        }
        let font = CTFontCreateWithName("SFMono-Regular" as CFString, 13, nil)
        let resolved = CTFontCopyFamilyName(font) as String == "SF Mono"
        return Registration(registered: count, found: files.count, available: count > 0 && resolved)
    }

    static func installedFamilies() -> [String] {
        _ = registration
        let manager = NSFontManager.shared
        let fontNames: [String] = manager.availableFonts
        let families: [String] = fontNames.compactMap { name -> String? in
            guard let font = NSFont(name: name, size: 13),
                  manager.traits(of: font).contains(.fixedPitchFontMask) else { return nil }
            return font.familyName
        }
        let defaults = ["SF Mono", "JetBrains Mono"]
        return defaults + Set(families).subtracting(defaults).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
