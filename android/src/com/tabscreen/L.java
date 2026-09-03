package com.tabscreen;

import java.util.Locale;

/** Russian on a Russian device, English everywhere else. */
final class L {
    private static final boolean RU = Locale.getDefault().getLanguage().equals("ru");

    static String t(String en, String ru) { return RU ? ru : en; }

    static final String LOOKING = t("Looking for a Mac on the network…\nStart TabScreen on it and press \"Turn on\".",
                                    "Ищу Mac в сети…\nЗапусти на нём TabScreen и нажми «Включить».");
    static final String MANUAL_HINT = t("or type the address: 192.168.0.30",
                                        "или введи адрес вручную: 192.168.0.30");
    static final String CONNECT = t("Connect", "Подключиться");
    static final String CONNECTING = t("connecting to ", "подключаюсь к ");
    static final String FOUND = t("Found: ", "Нашёл: ");
    static final String NO_LINK = t("no link: ", "нет связи: ");
    static final String RETRY = t(" (retrying)", " (повтор)");
    static final String WAITING_KEY = t("waiting for a keyframe…", "жду ключевой кадр…");
    static final String DECODER_UP = t("decoder started", "декодер запущен");
    static final String RUNNING = t("running", "идёт");
    static final String PAUSED = t("paused", "пауза");
    static final String BAD_LENGTH = t("bad frame length: ", "битая длина кадра: ");
    static final String STREAM_ENDED = t("stream ended", "поток закончился");
    static final String SERVER_CLOSED = t("server closed the connection", "сервер закрыл соединение");
}
