extension TranslationCatalog {
    /// Settings › Appearance › Input's Enter to send row, which on iOS is
    /// a hardware keyboard's (`SendShortcut`): happy-app's own strings name
    /// only Shift+Enter, and say nothing of ⌘+Enter, so these are under
    /// `native.hardwareKeyboard.` keys, in happy-app's words for each part.
    static let hardwareKeyboardSources: [String: [String: String]] = [
        "en": [
            "native.hardwareKeyboard.enterToSend": "Hardware Keyboard: Enter to Send",
            "native.hardwareKeyboard.enterToSendEnabled": "Enter sends; Shift, ⌘ or Control + Enter for a new line",
            "native.hardwareKeyboard.enterToSendDisabled": "Enter inserts a new line; ⌘ + Enter sends",
        ],
        "ru": [
            "native.hardwareKeyboard.enterToSend": "Аппаратная клавиатура: Enter для отправки",
            "native.hardwareKeyboard.enterToSendEnabled": "Enter отправляет; Shift, ⌘ или Control + Enter — новая строка",
            "native.hardwareKeyboard.enterToSendDisabled": "Enter вставляет новую строку; ⌘ + Enter отправляет",
        ],
        "pl": [
            "native.hardwareKeyboard.enterToSend": "Klawiatura sprzętowa: Enter aby wysłać",
            "native.hardwareKeyboard.enterToSendEnabled": "Enter wysyła; Shift, ⌘ lub Control + Enter dla nowej linii",
            "native.hardwareKeyboard.enterToSendDisabled": "Enter wstawia nową linię; ⌘ + Enter wysyła",
        ],
        "es": [
            "native.hardwareKeyboard.enterToSend": "Teclado físico: Enter para enviar",
            "native.hardwareKeyboard.enterToSendEnabled": "Enter envía; Shift, ⌘ o Control + Enter para una nueva línea",
            "native.hardwareKeyboard.enterToSendDisabled": "Enter inserta una nueva línea; ⌘ + Enter envía",
        ],
        "it": [
            "native.hardwareKeyboard.enterToSend": "Tastiera fisica: Invio con Enter",
            "native.hardwareKeyboard.enterToSendEnabled": "Invio invia; Maiusc, ⌘ o Control + Invio per una nuova riga",
            "native.hardwareKeyboard.enterToSendDisabled": "Invio inserisce una nuova riga; ⌘ + Invio invia",
        ],
        "pt": [
            "native.hardwareKeyboard.enterToSend": "Teclado físico: Enter para enviar",
            "native.hardwareKeyboard.enterToSendEnabled": "Enter envia; Shift, ⌘ ou Control + Enter para nova linha",
            "native.hardwareKeyboard.enterToSendDisabled": "Enter insere uma nova linha; ⌘ + Enter envia",
        ],
        "ca": [
            "native.hardwareKeyboard.enterToSend": "Teclat físic: Enter per enviar",
            "native.hardwareKeyboard.enterToSendEnabled": "Enter envia; Maj, ⌘ o Control + Enter per a una nova línia",
            "native.hardwareKeyboard.enterToSendDisabled": "Enter insereix una nova línia; ⌘ + Enter envia",
        ],
        "zh-Hans": [
            "native.hardwareKeyboard.enterToSend": "硬件键盘：回车发送",
            "native.hardwareKeyboard.enterToSendEnabled": "回车发送；Shift、⌘ 或 Control + 回车换行",
            "native.hardwareKeyboard.enterToSendDisabled": "回车换行；⌘ + 回车发送",
        ],
        "zh-Hant": [
            "native.hardwareKeyboard.enterToSend": "實體鍵盤：Enter 鍵傳送",
            "native.hardwareKeyboard.enterToSendEnabled": "Enter 傳送；Shift、⌘ 或 Control + Enter 換行",
            "native.hardwareKeyboard.enterToSendDisabled": "Enter 鍵插入換行；⌘ + Enter 傳送",
        ],
        "ja": [
            "native.hardwareKeyboard.enterToSend": "ハードウェアキーボード：Enterで送信",
            "native.hardwareKeyboard.enterToSendEnabled": "Enterで送信（Shift、⌘、Control + Enterで改行）",
            "native.hardwareKeyboard.enterToSendDisabled": "Enterで改行（⌘ + Enterで送信）",
        ],
    ]
}
