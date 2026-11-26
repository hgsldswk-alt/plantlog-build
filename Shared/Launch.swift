import Foundation

enum Launch {
    static let freePeriod = false
    static let arguments = ProcessInfo.processInfo.arguments
    static func isFree(arguments: [String]) -> Bool {
        #if DEBUG
        freePeriod && !arguments.contains(where: { ["-paid-mode", "-paywall", "-expired"].contains($0) })
        #else
        freePeriod
        #endif
    }
    static var isFree: Bool { isFree(arguments: arguments) }
    static var testing: Bool {
        #if DEBUG
        arguments.contains("-ui-testing")
        #else
        false
        #endif
    }
    static func value(_ flag: String, in args: [String] = arguments) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
