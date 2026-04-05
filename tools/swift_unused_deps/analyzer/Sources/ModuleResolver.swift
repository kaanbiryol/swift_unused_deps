import Foundation

public enum ResolutionStatus: Equatable {
    case resolved(label: String)
    case system
    case unresolved
}

public struct ResolvedModule {
    public let moduleName: String
    public let status: ResolutionStatus
}

public struct ModuleResolver {

    private let moduleMap: [String: String]
    private let systemModules: Set<String>

    public init(transitiveModuleMap: [String: String], extraSystemModules: Set<String> = []) {
        self.moduleMap = transitiveModuleMap
        self.systemModules = Self.defaultSystemModules.union(extraSystemModules)
    }

    public func resolve(_ moduleName: String) -> ResolvedModule {
        if systemModules.contains(moduleName) {
            return ResolvedModule(moduleName: moduleName, status: .system)
        }
        if let label = moduleMap[moduleName] {
            return ResolvedModule(moduleName: moduleName, status: .resolved(label: label))
        }
        return ResolvedModule(moduleName: moduleName, status: .unresolved)
    }

    public func isSystemModule(_ name: String) -> Bool {
        systemModules.contains(name)
    }

    public static let defaultSystemModules: Set<String> = {
        let stdlib = [
            "Swift", "SwiftOnoneSupport", "SwiftShims",
            "_Concurrency", "_StringProcessing", "_RegexParser",
            "_SwiftConcurrencyShims", "_Differentiation",
            "_Backtracing", "_MatchingEngine",
            "_Builtin_float", "_FoundationCShims",
            "_DarwinFoundation1", "_DarwinFoundation2", "_DarwinFoundation3",
            "Observation", "System", "XPC",
        ]

        let sdk = [
            "Accelerate", "Accessibility", "AVFoundation", "AVKit",
            "AuthenticationServices", "BackgroundTasks",
            "CFNetwork", "Combine", "Contacts", "ContactsUI",
            "CoreAnimation", "CoreBluetooth", "CoreData",
            "CoreFoundation", "CoreGraphics", "CoreHaptics",
            "CoreImage", "CoreLocation", "CoreMedia", "CoreMIDI",
            "CoreML", "CoreMotion", "CoreServices", "CoreSpotlight",
            "CoreTelephony", "CoreText", "CoreVideo",
            "CryptoKit", "CryptoTokenKit",
            "Darwin", "Dispatch",
            "EventKit", "EventKitUI",
            "Foundation",
            "GameKit", "GameplayKit",
            "HealthKit", "HomeKit",
            "ImageIO", "Intents", "IntentsUI", "IOKit",
            "LocalAuthentication",
            "MapKit", "MediaPlayer", "MessageUI",
            "Metal", "MetalKit", "MetricKit",
            "MobileCoreServices", "MultipeerConnectivity",
            "NaturalLanguage", "Network", "NetworkExtension",
            "NotificationCenter",
            "ObjectiveC", "os", "OSLog",
            "PassKit", "PDFKit", "Photos", "PhotosUI", "PushKit",
            "QuartzCore", "QuickLook",
            "RealityKit",
            "SafariServices", "SceneKit", "Security",
            "Social", "SpriteKit", "StoreKit", "SwiftUI",
            "SystemConfiguration",
            "UIKit", "UniformTypeIdentifiers",
            "UserNotifications", "UserNotificationsUI",
            "VideoToolbox", "Vision", "VisionKit",
            "WatchConnectivity", "WebKit", "WidgetKit",
        ]

        return Set(stdlib + sdk)
    }()
}
