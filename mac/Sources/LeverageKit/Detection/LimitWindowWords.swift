import Foundation

public enum LimitWindowWords {
    public static func words(for window: LimitWindow) -> [String] { [] }
    public static func window(named field: String) -> LimitWindow? { nil }
    public static func windows(in text: String) -> [LimitWindow] { [] }
    public static func window(in text: String) -> LimitWindow? { nil }
}
