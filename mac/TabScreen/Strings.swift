// Russian for a Russian system, English everywhere else. Two languages is enough -
// a full localisation setup would be more machinery than this app deserves.

import Foundation

enum L {
    private static let ru = Locale.preferredLanguages.first?.hasPrefix("ru") ?? false

    static func t(_ en: String, _ rus: String) -> String { ru ? rus : en }

    static var appReady: String { t("Ready", "Готов") }
    static var appRunning: String { t("Running", "Работает") }
    static var starting: String { t("Starting…", "Запускаю…") }
    static var turnOn: String { t("Turn on", "Включить") }
    static var turnOff: String { t("Stop", "Остановить") }
    static var screen: String { t("Screen", "Экран") }
    static var virtual: String { t("Virtual", "Виртуальный") }
    static var builtIn: String { t("Built-in display", "Встроенный экран") }
    static var display: String { t("Display", "Дисплей") }
    static var createScreen: String { t("Create virtual screen", "Создать виртуальный экран") }
    static var createScreenHelp: String {
        t("Needs BetterDisplay - it creates a screen that isn't physically there",
          "Нужен BetterDisplay — он создаёт экран, которого нет физически")
    }
    static var creating: String { t("Creating a virtual screen…", "Создаю виртуальный экран…") }
    static var created: String { t("Virtual screen ready", "Виртуальный экран готов") }
    static var startOnLaunch: String { t("Turn on at launch", "Включать сразу при запуске") }
    static var refresh: String { t("Refresh the list", "Обновить список") }
    static var connectFrom: String { t("Connect from the tablet:", "Подключись с планшета:") }
    static var orFind: String {
        t("or just tap \"Find Mac\" in the app on the tablet",
          "или просто нажми «Найти Mac» в приложении на планшете")
    }
    static var tablets: String { t("Tablets", "Планшетов") }
    static var latency: String { t("Latency", "Задержка") }
    static var fps: String { t("Frames/s", "Кадров/с") }
    static var ms: String { t("ms", "мс") }

    static var noBetterDisplay: String {
        t("Install BetterDisplay first - a virtual screen can't be created without it",
          "Сначала установи BetterDisplay — без него виртуальный экран не создать")
    }
    static var betterDisplaySilent: String {
        t("BetterDisplay isn't responding - start it by hand",
          "BetterDisplay не отвечает — запусти его вручную")
    }
    static var notCreated: String {
        t("BetterDisplay didn't create the screen", "BetterDisplay не создал экран")
    }
    static var notConnected: String {
        t("Screen created but not connected - switch it on in BetterDisplay",
          "Экран создан, но не подключился — включи его в BetterDisplay")
    }
    static var noScreenChosen: String { t("No screen selected", "Не выбран экран") }
    static var portBusy: String { t("Port 8090 is busy", "Порт 8090 занят") }
    static var noScreenAccess: String { t("no screen access", "нет доступа к экрану") }
    static var displayNotFound: String { t("display not found", "дисплей не найден") }
    static var captureFailed: String { t("couldn't start capture", "не удалось начать захват") }
    static var captureSetupFailed: String { t("couldn't set up capture", "не удалось настроить захват") }
    static var captureStopped: String { t("capture stopped", "захват остановлен") }
    static var encoderFailed: String { t("encoder failed to start", "кодировщик не создался") }
}
