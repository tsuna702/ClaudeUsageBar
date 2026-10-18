import Foundation

// 언어: 설정에서 고른 값 (system / ko / en). system이면 macOS 첫 번째 선호 언어를 따름

enum Lang {
    static let key = "language"

    static var isKorean: Bool {
        switch UserDefaults.standard.string(forKey: key) ?? "system" {
        case "ko": return true
        case "en": return false
        default: return Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
        }
    }

    static var locale: Locale { Locale(identifier: isKorean ? "ko_KR" : "en_US") }
}

// 한국어/영어 문구 중 현재 언어에 맞는 것을 고름
func L(_ ko: String, _ en: String) -> String { Lang.isKorean ? ko : en }
