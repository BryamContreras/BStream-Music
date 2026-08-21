package com.bstream.bstream_music

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.annotation.RequiresApi
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

private class PoTokenException(message: String) : Exception(message)

/**
 * Android Web BotGuard provider.
 *
 * The WebView executes only the bundled BotGuard harness. Network requests to
 * YouTube are performed by the application-side HTTP executor, which keeps the
 * same timeout and avoids letting the WebView load arbitrary remote content.
 */
class AndroidPoTokenProvider(private val context: Context) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val requestExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val networkExecutor: ExecutorService = Executors.newCachedThreadPool()
    private val stateLock = Object()
    private val visitorDataLock = Object()
    private var visitorData: String? = null
    private var visitorDataFetchedAt = 0L
    private var generator: Generator? = null
    private var generatorFuture: CompletableFuture<Generator>? = null
    @Volatile
    private var disposed = false

    fun getTokens(videoId: String): CompletableFuture<Map<String, Any?>> {
        val result = CompletableFuture<Map<String, Any?>>()
        requestExecutor.execute {
            try {
                if (disposed || videoId.isBlank()) {
                    result.complete(unavailable())
                    return@execute
                }
                val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(PO_TOKEN_TIMEOUT_MS)
                val sessionId = getVisitorData(remainingMillis(deadline))
                    ?: throw IllegalStateException("YouTube visitorData unavailable")
                val tokens = mintWithRetry(videoId, sessionId, deadline)
                result.complete(tokens)
            } catch (error: Throwable) {
                resetGenerator()
                result.completeExceptionally(error)
            }
        }
        return result
    }

    fun dispose() {
        if (disposed) {
            return
        }
        disposed = true
        synchronized(stateLock) {
            generator?.close()
            generator = null
            generatorFuture = null
        }
        requestExecutor.shutdownNow()
        networkExecutor.shutdownNow()
    }

    private fun mintWithRetry(
        videoId: String,
        sessionId: String,
        deadlineNanos: Long,
    ): Map<String, Any?> {
        var state = ensureGenerator(sessionId).get(remainingMillis(deadlineNanos), TimeUnit.MILLISECONDS)
        return try {
            val streamingToken = state.streamingToken ?: state.mint(sessionId)
                .get(remainingMillis(deadlineNanos), TimeUnit.MILLISECONDS)
                .also { state.streamingToken = it }
            val playerToken = state.mint(videoId).get(remainingMillis(deadlineNanos), TimeUnit.MILLISECONDS)
            tokenMap(sessionId, playerToken, streamingToken, state.expiresAtEpochMs)
        } catch (_: Throwable) {
            invalidate(state)
            state = ensureGenerator(sessionId).get(remainingMillis(deadlineNanos), TimeUnit.MILLISECONDS)
            val streamingToken = state.mint(sessionId)
                .get(remainingMillis(deadlineNanos), TimeUnit.MILLISECONDS)
                .also { state.streamingToken = it }
            val playerToken = state.mint(videoId).get(remainingMillis(deadlineNanos), TimeUnit.MILLISECONDS)
            tokenMap(sessionId, playerToken, streamingToken, state.expiresAtEpochMs)
        }
    }

    private fun remainingMillis(deadlineNanos: Long): Long {
        val remaining = TimeUnit.NANOSECONDS.toMillis(deadlineNanos - System.nanoTime())
        if (remaining <= 0L) {
            throw java.util.concurrent.TimeoutException("PO token generation timed out")
        }
        return remaining
    }

    private fun tokenMap(
        visitorData: String,
        playerToken: String,
        streamingToken: String,
        expiresAtEpochMs: Long,
    ): Map<String, Any?> = mapOf(
        "available" to true,
        "visitorData" to visitorData,
        "playerRequestPoToken" to playerToken,
        "streamingDataPoToken" to streamingToken,
        "expiresAtEpochMs" to expiresAtEpochMs,
    )

    private fun unavailable(): Map<String, Any?> = mapOf("available" to false)

    private fun ensureGenerator(sessionId: String): CompletableFuture<Generator> {
        synchronized(stateLock) {
            val current = generator
            val currentFuture = generatorFuture
            if (current != null &&
                currentFuture != null &&
                !current.isDead &&
                !current.isExpired &&
                current.sessionId == sessionId &&
                !currentFuture.isCompletedExceptionally
            ) {
                return currentFuture
            }

            current?.close()
            val nextFuture = CompletableFuture<Generator>()
            val next = Generator(context.applicationContext, sessionId, nextFuture)
            generator = next
            generatorFuture = nextFuture
            mainHandler.post { next.start() }
            return nextFuture
        }
    }

    private fun invalidate(state: Generator) {
        synchronized(stateLock) {
            if (generator === state) {
                generator = null
                generatorFuture = null
            }
        }
        state.close()
    }

    private fun resetGenerator() {
        synchronized(stateLock) {
            generator?.close()
            generator = null
            generatorFuture = null
        }
    }

    private fun getVisitorData(timeoutMs: Long): String? {
        synchronized(visitorDataLock) {
            if (visitorData != null &&
                System.currentTimeMillis() - visitorDataFetchedAt < VISITOR_DATA_TTL_MS
            ) {
                return visitorData
            }
        }

        val body = httpGet("https://music.youtube.com/sw.js_data", timeoutMs)
        val parsed = runCatching { JSONArray(stripAntiXssi(body)) }.getOrNull()
        val extracted = findVisitorData(parsed) ?: fixedVisitorData(parsed)
            ?: throw IllegalStateException("sw.js_data did not contain visitorData")
        synchronized(visitorDataLock) {
            visitorData = extracted
            visitorDataFetchedAt = System.currentTimeMillis()
        }
        return extracted
    }

    private fun fixedVisitorData(root: JSONArray?): String? {
        return runCatching {
            root
                ?.getJSONArray(0)
                ?.getJSONArray(2)
                ?.getJSONArray(0)
                ?.getJSONArray(0)
                ?.getString(13)
                ?.takeIf { it.isNotBlank() }
        }.getOrNull()
    }

    private fun findVisitorData(value: Any?): String? {
        when (value) {
            is JSONObject -> {
                val direct = value.optString("visitorData", "")
                    .ifBlank { value.optString("visitor_data", "") }
                if (direct.isNotBlank()) {
                    return direct
                }
                val keys = value.keys()
                while (keys.hasNext()) {
                    val found = findVisitorData(value.opt(keys.next()))
                    if (!found.isNullOrBlank()) {
                        return found
                    }
                }
            }
            is JSONArray -> {
                for (index in 0 until value.length()) {
                    val found = findVisitorData(value.opt(index))
                    if (!found.isNullOrBlank()) {
                        return found
                    }
                }
            }
        }
        return null
    }

    private fun stripAntiXssi(value: String): String {
        return if (value.startsWith(")]}'")) value.substring(4) else value
    }

    private fun httpGet(url: String, timeoutMs: Long): String {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            val timeout = minOf(timeoutMs, NETWORK_TIMEOUT_MS).toInt()
            connection.connectTimeout = timeout
            connection.readTimeout = timeout
            connection.requestMethod = "GET"
            connection.setRequestProperty("User-Agent", WEB_USER_AGENT)
            connection.setRequestProperty("Accept", "application/json")
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val body = stream?.let { BufferedInputStream(it).use { input -> input.readBytes() } }
                ?.toString(StandardCharsets.UTF_8)
                .orEmpty()
            if (code !in 200..299) {
                throw IllegalStateException("YouTube visitorData returned HTTP $code")
            }
            return body
        } finally {
            connection.disconnect()
        }
    }

    private fun httpPost(url: String, body: String): String {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = NETWORK_TIMEOUT_MS.toInt()
            connection.readTimeout = NETWORK_TIMEOUT_MS.toInt()
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("User-Agent", WEB_USER_AGENT)
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("Content-Type", "application/json+protobuf")
            connection.setRequestProperty("x-goog-api-key", GOOGLE_API_KEY)
            connection.setRequestProperty("x-user-agent", "grpc-web-javascript/0.1")
            connection.outputStream.use { it.write(body.toByteArray(StandardCharsets.UTF_8)) }
            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val response = stream?.let { BufferedInputStream(it).use { input -> input.readBytes() } }
                ?.toString(StandardCharsets.UTF_8)
                .orEmpty()
            if (code !in 200..299 || response.isBlank()) {
                throw IllegalStateException("BotGuard endpoint returned HTTP $code")
            }
            return response
        } finally {
            connection.disconnect()
        }
    }

    private inner class Generator(
        private val appContext: Context,
        val sessionId: String,
        val ready: CompletableFuture<Generator>,
    ) {
        private val requestCounter = AtomicLong()
        private val pending = ConcurrentHashMap<String, CompletableFuture<String>>()
        private var webView: WebView? = null
        private var closed = false
        @Volatile
        var isDead = false
            private set
        @Volatile
        var expiresAtEpochMs: Long = 0L
            private set
        @Volatile
        var streamingToken: String? = null

        val isExpired: Boolean
            get() = expiresAtEpochMs != 0L &&
                System.currentTimeMillis() >= expiresAtEpochMs

        fun start() {
            if (closed) return
            try {
                val view = WebView(appContext)
                webView = view
                view.settings.javaScriptEnabled = true
                view.settings.userAgentString = WEB_USER_AGENT
                view.settings.blockNetworkLoads = true
                view.addJavascriptInterface(Bridge(), JS_BRIDGE)
                view.webChromeClient = WebChromeClient()
                view.webViewClient = object : WebViewClient() {
                    @RequiresApi(26)
                    override fun onRenderProcessGone(
                        view: WebView,
                        detail: android.webkit.RenderProcessGoneDetail,
                    ): Boolean {
                        fail(PoTokenException("BotGuard WebView renderer stopped"))
                        return true
                    }
                }
                val html = appContext.assets.open(PO_TOKEN_ASSET).bufferedReader().use { it.readText() }
                val injected = html.replaceFirst(
                    "</script>",
                    "window.$JS_BRIDGE.downloadAndRunBotguard();</script>",
                )
                view.loadDataWithBaseURL(
                    "https://www.youtube.com",
                    injected,
                    "text/html",
                    "UTF-8",
                    null,
                )
                mainHandler.postDelayed({
                    if (!ready.isDone) {
                        fail(PoTokenException("BotGuard WebView initialization timed out"))
                    }
                }, GENERATOR_TIMEOUT_MS)
            } catch (error: Throwable) {
                fail(error)
            }
        }

        fun mint(identifier: String): CompletableFuture<String> {
            val result = CompletableFuture<String>()
            if (closed || isDead || !ready.isDone || ready.isCompletedExceptionally) {
                result.completeExceptionally(PoTokenException("BotGuard WebView unavailable"))
                return result
            }
            val key = "$identifier#${requestCounter.incrementAndGet()}"
            pending[key] = result
            val bytes = identifier.toByteArray(StandardCharsets.UTF_8)
                .joinToString(",") { (it.toInt() and 0xff).toString() }
            val escapedKey = JSONObject.quote(key)
            mainHandler.post {
                val view = webView
                if (view == null || closed) {
                    completeError(key, PoTokenException("BotGuard WebView unavailable"))
                    return@post
                }
                view.evaluateJavascript(
                    """(function(){
                        var requestKey=$escapedKey;
                        try {
                          obtainPoToken(new Uint8Array([$bytes])).then(function(value){
                            $JS_BRIDGE.onObtainPoTokenResult(requestKey, value.join(','));
                          }).catch(function(error){
                            $JS_BRIDGE.onObtainPoTokenError(requestKey, String(error));
                          });
                        } catch(error) {
                          $JS_BRIDGE.onObtainPoTokenError(requestKey, String(error));
                        }
                    })();""",
                    null,
                )
                mainHandler.postDelayed({
                    if (pending.remove(key)?.completeExceptionally(
                            PoTokenException("BotGuard token generation timed out"),
                        ) != null
                    ) {
                        isDead = true
                    }
                }, MINT_TIMEOUT_MS)
            }
            return result
        }

        fun close() {
            if (closed) return
            closed = true
            isDead = true
            pending.values.forEach { it.completeExceptionally(PoTokenException("BotGuard WebView closed")) }
            pending.clear()
            mainHandler.post {
                webView?.let { view ->
                    runCatching {
                        view.loadUrl("about:blank")
                        view.stopLoading()
                        view.removeJavascriptInterface(JS_BRIDGE)
                        view.destroy()
                    }
                }
                webView = null
            }
        }

        private fun completeError(key: String, error: Throwable) {
            pending.remove(key)?.completeExceptionally(error)
        }

        private fun fail(error: Throwable) {
            isDead = true
            if (!ready.isDone) ready.completeExceptionally(error)
            pending.values.forEach { it.completeExceptionally(error) }
            pending.clear()
            close()
        }

        private fun onBotGuardResult(botguardResponse: String) {
            networkExecutor.execute {
                try {
                    val body = JSONArray()
                        .put(REQUEST_KEY)
                        .put(botguardResponse)
                        .toString()
                    val response = httpPost(GENERATE_IT_URL, body)
                    val parsed = parseIntegrityTokenData(response)
                    expiresAtEpochMs = parsed.second
                    val integrity = base64ToUint8(parsed.first)
                    mainHandler.post {
                        webView?.evaluateJavascript(
                            """try {
                              window.integrityToken=$integrity;
                              createPoTokenMinter(window.webPoSignalOutput, window.integrityToken)
                                .then(function(){ $JS_BRIDGE.onMinterCreated(); })
                                .catch(function(error){ $JS_BRIDGE.onJsInitializationError(String(error)); });
                            } catch(error) {
                              $JS_BRIDGE.onJsInitializationError(String(error));
                            }""",
                            null,
                        )
                    }
                } catch (error: Throwable) {
                    mainHandler.post { fail(error) }
                }
            }
        }

        private fun onBotGuardCreate() {
            networkExecutor.execute {
                try {
                    val response = httpPost(CREATE_URL, JSONArray().put(REQUEST_KEY).toString())
                    val challenge = parseChallengeData(response)
                    mainHandler.post {
                        webView?.evaluateJavascript(
                            """try {
                              window.data=$challenge;
                              runBotGuard(window.data).then(function(result){
                                window.webPoSignalOutput=result.webPoSignalOutput;
                                $JS_BRIDGE.onRunBotguardResult(JSON.stringify(result.botguardResponse));
                              }).catch(function(error){ $JS_BRIDGE.onJsInitializationError(String(error)); });
                            } catch(error) {
                              $JS_BRIDGE.onJsInitializationError(String(error));
                            }""",
                            null,
                        )
                    }
                } catch (error: Throwable) {
                    mainHandler.post { fail(error) }
                }
            }
        }

        private fun onTokenResult(key: String, value: String) {
            try {
                val bytes = if (value.isBlank()) byteArrayOf() else value.split(',')
                    .map { it.trim().toInt().toByte() }
                    .toByteArray()
                val token = Base64.encodeToString(
                    bytes,
                    Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP,
                )
                pending.remove(key)?.complete(token)
            } catch (error: Throwable) {
                completeError(key, error)
            }
        }

        private inner class Bridge {
            @JavascriptInterface
            fun downloadAndRunBotguard() = onBotGuardCreate()

            @JavascriptInterface
            fun onRunBotguardResult(response: String) = onBotGuardResult(response)

            @JavascriptInterface
            fun onMinterCreated() {
                if (!ready.isDone) ready.complete(this@Generator)
            }

            @JavascriptInterface
            fun onJsInitializationError(error: String) =
                fail(PoTokenException(error))

            @JavascriptInterface
            fun onObtainPoTokenResult(key: String, value: String) =
                onTokenResult(key, value)

            @JavascriptInterface
            fun onObtainPoTokenError(key: String, error: String) =
                completeError(key, PoTokenException(error))
        }
    }

    private fun parseChallengeData(raw: String): String {
        val scrambled = JSONArray(raw)
        val challenge = if (scrambled.length() > 1 && scrambled.opt(1) is String) {
            JSONArray(descramble(scrambled.getString(1)))
        } else {
            scrambled.getJSONArray(0)
        }
        val interpreter = firstString(challenge.opt(1))
        val trusted = firstString(challenge.opt(2))
        return JSONObject()
            .put("messageId", challenge.getString(0))
            .put(
                "interpreterJavascript",
                JSONObject()
                    .put("privateDoNotAccessOrElseSafeScriptWrappedValue", interpreter ?: JSONObject.NULL)
                    .put("privateDoNotAccessOrElseTrustedResourceUrlWrappedValue", trusted ?: JSONObject.NULL),
            )
            .put("interpreterHash", challenge.getString(3))
            .put("program", challenge.getString(4))
            .put("globalName", challenge.getString(5))
            .put("clientExperimentsStateBlob", challenge.getString(7))
            .toString()
    }

    private fun firstString(value: Any?): String? {
        if (value !is JSONArray) return null
        for (index in 0 until value.length()) {
            val item = value.opt(index)
            if (item is String) return item
        }
        return null
    }

    private fun descramble(value: String): String {
        return decodeYouTubeBase64(value)
            .map { (it.toInt() + 97).toByte() }
            .toByteArray()
            .toString(StandardCharsets.UTF_8)
    }

    private fun parseIntegrityTokenData(raw: String): Pair<String, Long> {
        val data = JSONArray(raw)
        val token = data.getString(0)
        val ttlSeconds = data.optLong(1, 3600L)
        val expires = System.currentTimeMillis() +
            maxOf(60_000L, ttlSeconds * 1000L - TOKEN_EXPIRY_MARGIN_MS)
        return token to expires
    }

    private fun base64ToUint8(value: String): String {
        val bytes = decodeYouTubeBase64(value)
        return "new Uint8Array([${bytes.joinToString(",") { (it.toInt() and 0xff).toString() }}])"
    }

    private fun decodeYouTubeBase64(value: String): ByteArray {
        var normalized = value.replace('-', '+').replace('_', '/')
        normalized = normalized.replace('.', '=')
        normalized += "=".repeat((4 - normalized.length % 4) % 4)
        return Base64.decode(normalized, Base64.DEFAULT)
    }

    companion object {
        private const val CREATE_URL = "https://www.youtube.com/api/jnn/v1/Create"
        private const val GENERATE_IT_URL = "https://www.youtube.com/api/jnn/v1/GenerateIT"
        private const val GOOGLE_API_KEY = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
        private const val REQUEST_KEY = "O43z0dpjhgX20SCx4KAo"
        private const val JS_BRIDGE = "BStreamPoToken"
        private const val PO_TOKEN_ASSET = "po_token.html"
        private const val WEB_USER_AGENT =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " +
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.3"
        private const val NETWORK_TIMEOUT_MS = 15_000L
        private const val GENERATOR_TIMEOUT_MS = 45_000L
        private const val MINT_TIMEOUT_MS = 15_000L
        private const val PO_TOKEN_TIMEOUT_MS = 8_000L
        private const val VISITOR_DATA_TTL_MS = 6 * 60 * 60 * 1000L
        private const val TOKEN_EXPIRY_MARGIN_MS = 10 * 60 * 1000L
    }
}
