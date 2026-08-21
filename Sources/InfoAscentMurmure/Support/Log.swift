import OSLog

enum Log {
    static let audio = Logger(subsystem: "com.infoascent.murmure", category: "audio")
    static let speech = Logger(subsystem: "com.infoascent.murmure", category: "speech")
    static let hotkey = Logger(subsystem: "com.infoascent.murmure", category: "hotkey")
    static let inject = Logger(subsystem: "com.infoascent.murmure", category: "inject")
    static let app = Logger(subsystem: "com.infoascent.murmure", category: "app")
}
