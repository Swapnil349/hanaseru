package com.swapnil.hanaseru.coach

import android.content.Context
import androidx.compose.runtime.mutableStateOf
import com.swapnil.hanaseru.content.MyScenes
import com.swapnil.hanaseru.content.SceneResult
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.IOException
import java.net.HttpURLConnection
import java.net.MalformedURLException
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException

/**
 * How to reach the AI coach, and your name for the lines. Kept in this app's private storage (and left out of
 * Android's backups): the passphrase never leaves the phone except to the coach server set here, and is never logged.
 */
class CoachSettings(context: Context) {
    private val store = context.getSharedPreferences("coach", Context.MODE_PRIVATE)
    private val url = mutableStateOf(store.getString("serverURL", DEFAULT_URL) ?: DEFAULT_URL)
    private val secret = mutableStateOf(store.getString("passphrase", "") ?: "")
    private val name = mutableStateOf(store.getString("learnerName", "") ?: "")

    var serverURL: String
        get() = url.value
        set(value) {
            url.value = value
            store.edit().putString("serverURL", value).apply()
        }

    var passphrase: String
        get() = secret.value
        set(value) {
            secret.value = value
            store.edit().putString("passphrase", value).apply()
        }

    /** Your name as it should appear in Japanese lines ({name}). */
    var learnerName: String
        get() = name.value
        set(value) {
            name.value = value
            store.edit().putString("learnerName", value).apply()
        }

    val isSetUp: Boolean get() = serverURL.isNotBlank() && passphrase.isNotBlank()

    companion object {
        const val DEFAULT_URL = "https://hanaseru-coach.onrender.com"
    }
}

/** The AI coach server, over plain HTTPS. Every failure is a [Failure] with a message to show as it is. */
class CoachClient(private val settings: CoachSettings) {
    class Failure(message: String) : Exception(message)

    private val json = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
        isLenient = true
    }

    /** "Connected", with the coach's model when it says. */
    suspend fun health(): String {
        val body = request("GET", "/health", null, HEALTH_TIMEOUT_MILLIS)
        val model = runCatching {
            (json.parseToJsonElement(body) as JsonObject)["model"]?.jsonPrimitive?.contentOrNull
        }.getOrNull()
        return if (model.isNullOrBlank()) "Connected to the coach." else "Connected to the coach ($model)."
    }

    /**
     * Writes a scene from your description (POST /v1/scene), or changes `previous` as described. Takes up to a
     * minute and a half, more while the free server wakes up.
     */
    suspend fun scene(
        description: String,
        kind: String,
        politeness: String,
        length: Int,
        learnerName: String,
        previous: SceneResult? = null,
    ): SceneResult {
        val payload = buildJsonObject {
            put("description", description.trim())
            put("kind", kind)
            put("learnerName", learnerName.trim())
            put("learnerLevel", 3)
            put("politeness", politeness)
            put("length", length.coerceIn(2, 12))
            if (previous != null) put("previous", MyScenes.encode(previous))
        }
        val body = request("POST", "/v1/scene", payload.toString(), SCENE_TIMEOUT_MILLIS)
        val result = try {
            json.decodeFromString(SceneResult.serializer(), body)
        } catch (failed: Exception) {
            throw Failure("The coach's answer couldn't be read. Try again.")
        }
        if (result.beats.none { it.learner.japanese.isNotBlank() }) {
            throw Failure("The coach sent back an empty scene. Try again, perhaps with a little more detail.")
        }
        return result
    }

    private suspend fun request(method: String, path: String, body: String?, readTimeout: Int): String {
        val token = settings.passphrase.trim()
        var base = settings.serverURL.trim().trimEnd('/')
        if (base.isEmpty()) throw Failure("Add the coach's server address in Settings.")
        if (token.isEmpty()) throw Failure("Add the coach's passphrase in Settings.")
        if (!base.contains("://")) base = "https://$base"
        val opened: HttpURLConnection? = try {
            URL(base + path).openConnection() as? HttpURLConnection
        } catch (failed: MalformedURLException) {
            null
        } catch (failed: IOException) {
            null
        }
        val connection = opened ?: throw Failure("The server address in Settings isn't a web address.")
        // Leaving the screen disconnects, which ends the blocked read at once.
        return coroutineScope {
            val work = async(Dispatchers.IO) { exchange(connection, method, body, token, readTimeout) }
            try {
                work.await()
            } catch (cancelled: CancellationException) {
                connection.disconnect()
                throw cancelled
            }
        }
    }

    private fun exchange(connection: HttpURLConnection, method: String, body: String?, token: String, readTimeout: Int): String {
        try {
            connection.requestMethod = method
            connection.connectTimeout = CONNECT_TIMEOUT_MILLIS
            connection.readTimeout = readTimeout
            connection.useCaches = false
            connection.setRequestProperty("Authorization", "Bearer $token")
            connection.setRequestProperty("Accept", "application/json")
            if (body != null) {
                val bytes = body.toByteArray(Charsets.UTF_8)
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                connection.setFixedLengthStreamingMode(bytes.size)
                connection.outputStream.use { it.write(bytes) }
            }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() } ?: ""
            if (status !in 200..299) throw Failure(message(status, text))
            return text
        } catch (failure: Failure) {
            throw failure
        } catch (failed: SocketTimeoutException) {
            throw Failure("The coach took too long to answer. Try again: the free server may still have been waking up.")
        } catch (failed: UnknownHostException) {
            throw Failure("Couldn't find the coach server. Check the internet connection and the server address.")
        } catch (failed: IOException) {
            throw Failure("Couldn't reach the coach. Check the internet connection and the server address.")
        } finally {
            connection.disconnect()
        }
    }

    private fun message(status: Int, body: String): String {
        val error = runCatching {
            (json.parseToJsonElement(body) as JsonObject)["error"]?.jsonPrimitive?.contentOrNull
        }.getOrNull()
        return when (status) {
            401, 403 -> "The coach didn't accept the passphrase. Check it in Settings."
            404 -> "That server has no such coach feature. Check the server address in Settings."
            429 -> "The coach has had too many requests. Wait a minute and try again."
            400, 413 -> "The coach couldn't use that" + (if (error.isNullOrBlank()) "." else ": $error")
            502, 503, 504 -> "The coach server is starting up or busy. Try again in a minute."
            else -> "The coach had a problem (error $status). Try again."
        }
    }

    private companion object {
        const val CONNECT_TIMEOUT_MILLIS = 30_000
        /** The free server may need a minute to wake. */
        const val HEALTH_TIMEOUT_MILLIS = 90_000
        /** Waking up plus writing a scene (up to ~90 s). */
        const val SCENE_TIMEOUT_MILLIS = 180_000
    }
}
