extension TranslationCatalog {
    /// Words this fork adds to `nativeSources`, kept out of
    /// NativeTranslations.swift so upstream merges don't conflict there:
    /// the browser's (`browserSources`) and the rest below. Joined into
    /// `nativeSources` by the one `forkSources` entry in its list.
    static let forkSources: [String: [String: String]] = [browserSources].reduce(forkOwnSources) { all, area in
        all.merging(area) { kept, added in kept.merging(added) { first, _ in first } }
    }

    /// The voice service picker's words, the resume row's note for an
    /// offline computer, and the chat's load-earlier-history button. The
    /// voice services' names, Happy Server and ElevenLabs, are products
    /// that no language translates.
    static let forkOwnSources: [String: [String: String]] = [
        "en": [
            "native.voice.service": "Voice service",
            "native.voice.needsOwnAgent": "Needs your own agent ID",
            "native.voice.savedNotOffered": "${saved} isn’t offered by this server, so voice uses the server’s default, ${current}.",
            "native.voice.noService": "This server offers no voice service. ElevenLabs works with your own agent ID.",
            "native.sessionResume.machineOffline": "This session's computer is offline. Resume appears here once the computer is on and Happy CLI is running on it.",
            "native.chat.loadPreviousHistory": "Load previous history",
        ],
        "ru": [
            "native.voice.service": "Голосовой сервис",
            "native.voice.needsOwnAgent": "Нужен ваш собственный ID агента",
            "native.voice.savedNotOffered": "Этот сервер не предлагает ${saved}, поэтому голос использует сервис по умолчанию: ${current}.",
            "native.voice.noService": "Этот сервер не предлагает голосовой сервис. ElevenLabs работает с вашим собственным ID агента.",
            "native.sessionResume.machineOffline": "Компьютер этой сессии не в сети. Кнопка возобновления появится здесь, когда компьютер будет включён и на нём будет запущен Happy CLI.",
            "native.chat.loadPreviousHistory": "Загрузить предыдущую историю",
        ],
        "pl": [
            "native.voice.service": "Usługa głosowa",
            "native.voice.needsOwnAgent": "Wymaga własnego ID agenta",
            "native.voice.savedNotOffered": "Ten serwer nie oferuje ${saved}, więc głos korzysta z usługi domyślnej: ${current}.",
            "native.voice.noService": "Ten serwer nie oferuje usługi głosowej. ElevenLabs działa z własnym ID agenta.",
            "native.sessionResume.machineOffline": "Komputer tej sesji jest offline. Wznowienie pojawi się tutaj, gdy komputer będzie włączony i będzie na nim działać Happy CLI.",
            "native.chat.loadPreviousHistory": "Wczytaj wcześniejszą historię",
        ],
        "es": [
            "native.voice.service": "Servicio de voz",
            "native.voice.needsOwnAgent": "Necesita tu propio ID de agente",
            "native.voice.savedNotOffered": "Este servidor no ofrece ${saved}, así que la voz usa su servicio predeterminado: ${current}.",
            "native.voice.noService": "Este servidor no ofrece ningún servicio de voz. ElevenLabs funciona con tu propio ID de agente.",
            "native.sessionResume.machineOffline": "El ordenador de esta sesión está sin conexión. Reanudar aparecerá aquí cuando el ordenador esté encendido y Happy CLI se esté ejecutando en él.",
            "native.chat.loadPreviousHistory": "Cargar historial anterior",
        ],
        "it": [
            "native.voice.service": "Servizio vocale",
            "native.voice.needsOwnAgent": "Richiede il tuo ID agente",
            "native.voice.savedNotOffered": "Questo server non offre ${saved}, quindi la voce usa il servizio predefinito: ${current}.",
            "native.voice.noService": "Questo server non offre alcun servizio vocale. ElevenLabs funziona con il tuo ID agente.",
            "native.sessionResume.machineOffline": "Il computer di questa sessione è offline. Riprendi comparirà qui quando il computer sarà acceso e Happy CLI sarà in esecuzione.",
            "native.chat.loadPreviousHistory": "Carica la cronologia precedente",
        ],
        "pt": [
            "native.voice.service": "Serviço de voz",
            "native.voice.needsOwnAgent": "Precisa do seu próprio ID de agente",
            "native.voice.savedNotOffered": "Este servidor não oferece ${saved}, por isso a voz usa o serviço padrão: ${current}.",
            "native.voice.noService": "Este servidor não oferece nenhum serviço de voz. O ElevenLabs funciona com o seu próprio ID de agente.",
            "native.sessionResume.machineOffline": "O computador desta sessão está offline. Retomar aparecerá aqui quando o computador estiver ligado e o Happy CLI estiver em execução nele.",
            "native.chat.loadPreviousHistory": "Carregar histórico anterior",
        ],
        "ca": [
            "native.voice.service": "Servei de veu",
            "native.voice.needsOwnAgent": "Necessita el teu propi ID d'agent",
            "native.voice.savedNotOffered": "Aquest servidor no ofereix ${saved}, així que la veu fa servir el servei predeterminat: ${current}.",
            "native.voice.noService": "Aquest servidor no ofereix cap servei de veu. ElevenLabs funciona amb el teu propi ID d'agent.",
            "native.sessionResume.machineOffline": "L'ordinador d'aquesta sessió està fora de línia. Reprèn apareixerà aquí quan l'ordinador estigui engegat i Happy CLI s'hi estigui executant.",
            "native.chat.loadPreviousHistory": "Carrega l'historial anterior",
        ],
        "zh-Hans": [
            "native.voice.service": "语音服务",
            "native.voice.needsOwnAgent": "需要您自己的代理 ID",
            "native.voice.savedNotOffered": "此服务器不提供 ${saved}，因此语音使用服务器默认服务：${current}。",
            "native.voice.noService": "此服务器不提供语音服务。ElevenLabs 可使用您自己的代理 ID。",
            "native.sessionResume.machineOffline": "此会话所在的电脑已离线。电脑开机并运行 Happy CLI 后，恢复选项会显示在这里。",
            "native.chat.loadPreviousHistory": "加载更早的历史记录",
        ],
        "zh-Hant": [
            "native.voice.service": "語音服務",
            "native.voice.needsOwnAgent": "需要您自己的代理 ID",
            "native.voice.savedNotOffered": "此伺服器不提供 ${saved}，因此語音使用伺服器預設服務：${current}。",
            "native.voice.noService": "此伺服器不提供語音服務。ElevenLabs 可使用您自己的代理 ID。",
            "native.sessionResume.machineOffline": "此工作階段所在的電腦已離線。電腦開機並執行 Happy CLI 後，繼續選項會顯示在這裡。",
            "native.chat.loadPreviousHistory": "載入更早的歷史記錄",
        ],
        "ja": [
            "native.voice.service": "音声サービス",
            "native.voice.needsOwnAgent": "自分のエージェント ID が必要です",
            "native.voice.savedNotOffered": "このサーバーは ${saved} を提供していないため、音声にはサーバーのデフォルトの ${current} を使用します。",
            "native.voice.noService": "このサーバーは音声サービスを提供していません。ElevenLabs は自分のエージェント ID で使えます。",
            "native.sessionResume.machineOffline": "このセッションのコンピューターはオフラインです。コンピューターの電源が入り Happy CLI が実行されると、ここに再開が表示されます。",
            "native.chat.loadPreviousHistory": "以前の履歴を読み込む",
        ],
    ]
}
