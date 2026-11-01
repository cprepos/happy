package com.slopus.happy.model.settings

import android.content.res.Resources
import androidx.annotation.StringRes
import com.slopus.happy.R
import com.slopus.happy.net.HappyHttp
import com.slopus.happy.net.HappyJson
import kotlinx.serialization.Serializable
import java.net.URLEncoder
import java.text.DateFormat
import java.util.Date

/** pushRegistration.ts `PushPermissionStatus`. */
enum class PushPermissionStatus { Unsupported, Granted, Denied, Undetermined }

/** pushRegistration.ts `PushPermissionInfo`. */
data class PushPermission(val status: PushPermissionStatus, val granted: Boolean, val canAskAgain: Boolean) {
    companion object {
        /** What happy-app reports when the notifications module can't say: undetermined, can't ask. */
        val Undetermined = PushPermission(PushPermissionStatus.Undetermined, granted = false, canAskAgain = false)
    }
}

data class PushPermissionRequest(val granted: Boolean, val openedSettings: Boolean, val permission: PushPermission)

data class PushTokenSync(val registered: Boolean, val token: String?, val permission: PushPermission)

/**
 * This device's push registration (sync/pushRegistration.ts): permission,
 * the current Expo push token, and registering it with the server.
 * Implemented over FCM by `push/AppPushRegistration`.
 */
interface PushRegistration {
    suspend fun permission(): PushPermission
    suspend fun requestPermissionOrOpenSettings(): PushPermissionRequest
    suspend fun currentToken(): String?
    suspend fun syncCurrentToken(): PushTokenSync
    suspend fun removeToken(token: String)
}

/** apiPush.ts `PushTokenSchema`. */
@Serializable
data class PushToken(val id: String, val token: String, val createdAt: Long, val updatedAt: Long)

@Serializable private data class PushTokenList(val tokens: List<PushToken>)

/** apiPush.ts: the account's registered push tokens. */
class PushTokensApi(private val http: HappyHttp, private val token: () -> String?) {
    private fun bearer() = token() ?: throw ConnectException("Not signed in")

    suspend fun list(): List<PushToken> =
        HappyJson.decodeFromString(PushTokenList.serializer(), http.send("GET", "/v1/push-tokens", bearer())).tokens

    suspend fun unregister(pushToken: String) {
        // encodeURIComponent
        val encoded = URLEncoder.encode(pushToken, "UTF-8").replace("+", "%20")
        http.send("DELETE", "/v1/push-tokens/$encoded", bearer())
    }
}

/** account.tsx's formatting of push state, in the person's language (`strings_push.xml`). */
object PushText {
    /** formatPushTokenFingerprint: the Expo token's value, first and last 6 when longer than 12. */
    fun fingerprint(token: String): String {
        val raw = token.removePrefix("ExponentPushToken[").removeSuffix("]")
        return if (raw.length <= 12) raw else "${raw.take(6)}…${raw.takeLast(6)}"
    }

    /** formatPushPermissionLabel. */
    @StringRes
    fun label(permission: PushPermission?): Int = when {
        permission == null -> R.string.push_label_loading
        permission.status == PushPermissionStatus.Unsupported -> R.string.push_label_unavailable
        permission.granted -> R.string.push_label_allowed
        permission.status == PushPermissionStatus.Denied -> R.string.push_label_denied
        else -> R.string.push_label_not_requested
    }

    /** formatPushPermissionSubtitle. */
    @StringRes
    fun subtitle(permission: PushPermission?): Int = when {
        permission == null -> R.string.push_subtitle_checking
        permission.status == PushPermissionStatus.Unsupported -> R.string.push_subtitle_unsupported
        permission.granted -> R.string.push_subtitle_granted
        permission.canAskAgain -> R.string.push_subtitle_can_ask
        else -> R.string.push_subtitle_stopped
    }

    /** The "Request Permission Again" row's subtitle. */
    @StringRes
    fun requestSubtitle(permission: PushPermission?): Int = when {
        permission?.status == PushPermissionStatus.Unsupported -> R.string.push_request_unsupported
        permission?.canAskAgain == true -> R.string.push_request_can_ask
        else -> R.string.push_request_settings
    }

    /** buildPushTokenSubtitle, with `toLocaleString` as the default locale's medium date and time. */
    fun tokenSubtitle(
        resources: Resources,
        token: PushToken,
        isCurrentDevice: Boolean,
        deviceLabel: String,
        appLabel: String?,
        format: DateFormat = defaultFormat(),
    ): String {
        val lines = mutableListOf<String>()
        if (isCurrentDevice) {
            lines += deviceLabel
            if (appLabel != null) lines += appLabel
        } else {
            lines += resources.getString(R.string.push_other_device)
        }
        lines += resources.getString(R.string.push_registered, format.format(Date(token.createdAt)))
        lines += resources.getString(R.string.push_last_seen, format.format(Date(token.updatedAt)))
        lines += resources.getString(R.string.push_server_id, token.id)
        lines += resources.getString(R.string.push_token, fingerprint(token.token))
        return lines.joinToString("\n")
    }

    private fun defaultFormat() = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.MEDIUM)

    /**
     * getCurrentPushDeviceMetadata: device name, model when it differs,
     * OS and version; app version, build, and "simulator" on an emulator.
     */
    fun deviceLabels(
        resources: Resources,
        deviceName: String?,
        modelName: String?,
        osVersion: String?,
        appVersion: String?,
        buildVersion: String?,
        emulator: Boolean,
    ): Pair<String, String?> {
        val device = listOfNotNull(
            deviceName,
            modelName?.takeIf { it != deviceName },
            listOfNotNull("Android", osVersion).filter { it.isNotEmpty() }.joinToString(" "),
        ).filter { it.isNotBlank() }
        val app = listOfNotNull(
            appVersion?.takeIf { it.isNotEmpty() }?.let { "Happy $it" },
            buildVersion?.takeIf { it.isNotEmpty() }?.let { resources.getString(R.string.push_build, it) },
            resources.getString(R.string.push_simulator).takeIf { emulator },
        )
        return (device.joinToString(" • ").ifEmpty { resources.getString(R.string.push_android_device) }) to app.joinToString(" • ").ifEmpty { null }
    }
}
