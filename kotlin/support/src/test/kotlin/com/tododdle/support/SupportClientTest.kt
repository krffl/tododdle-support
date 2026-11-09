package com.tododdle.support

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class SupportClientTest {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var server: MockWebServer
    private val configBody: String by lazy {
        val cases = Json.parseToJsonElement(File(System.getProperty("tododdle.casesFile")!!).readText()).jsonObject
        cases.getValue("config").toString()
    }

    @Before
    fun start() {
        server = MockWebServer()
        server.start()
    }

    @After
    fun stop() {
        server.shutdown()
    }

    private val baseUrl get() = server.url("/api/support/sdk/v1").toString()

    private fun received(id: String = "rpt_AAAAAAAAAAAAAAAA0001") =
        MockResponse().setResponseCode(201).setBody("""{"reportId":"$id","status":"received","unknownField":1}""")

    private suspend fun expectError(block: suspend () -> Unit): TododdleSupportException {
        try {
            block()
        } catch (e: TododdleSupportException) {
            return e
        }
        fail("Expected TododdleSupportException")
        error("unreachable")
    }

    @Test
    fun sendsIdentityHeadersAndAutomaticContext() = runBlocking {
        server.enqueue(received())
        newSupport(baseUrl).report(Report(type = ReportType.FEEDBACK, description = "Nice", formVersion = 3))

        val request = server.takeRequest()
        assertEquals("/api/support/sdk/v1/reports", request.path)
        assertEquals("kotlin/${TododdleSupport.VERSION}", request.getHeader("X-Tododdle-Sdk"))
        assertEquals("com.example.app", request.getHeader("X-Tododdle-App-Id"))
        val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
        val context = body.getValue("context").jsonObject
        assertEquals("android", context.getValue("platform").jsonPrimitive.content)
        assertEquals("9.9.9", context.getValue("appVersion").jsonPrimitive.content)
        assertEquals("Pixel Test", context.getValue("deviceModel").jsonPrimitive.content)
        assertFalse("empty values are left out", body.containsKey("title"))
        assertFalse(body.containsKey("attachments"))
    }

    @Test
    fun appContextWinsOverAutomaticContext() = runBlocking {
        server.enqueue(received())
        newSupport(baseUrl).report(
            Report(type = ReportType.PROBLEM, description = "x", formVersion = 3, context = ReportContext(appVersion = "2.4.0", screen = "Home")),
        )
        val context = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject.getValue("context").jsonObject
        assertEquals("2.4.0", context.getValue("appVersion").jsonPrimitive.content)
        assertEquals("Home", context.getValue("screen").jsonPrimitive.content)
        assertEquals("999", context.getValue("build").jsonPrimitive.content)
    }

    @Test
    fun noContextWhenCollectionIsOff() = runBlocking {
        server.enqueue(received())
        val support = TododdleSupport(
            Configuration(key = "tdsk_pub_x", baseUrl = baseUrl, collectContext = false),
            FakeEnvironment(),
        ) { }
        support.report(Report(type = ReportType.PROBLEM, description = "x", formVersion = 3))
        val body = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject
        assertFalse(body.containsKey("context"))
    }

    @Test
    fun fetchesConfigForFormVersionAndValidatesAgainstIt() = runBlocking {
        server.enqueue(MockResponse().setBody(configBody).setHeader("ETag", "\"cfg-3\""))
        val error = expectError {
            // "area" is a required SELECT and the description is required.
            newSupport(baseUrl).report(Report(type = ReportType.PROBLEM))
        }
        assertEquals(ErrorCode.INVALID_FIELDS, error.code)
        assertNull(error.httpStatus)
        assertEquals(setOf("description", "area"), error.fields.keys)
        assertEquals("Only the config request is sent", 1, server.requestCount)
    }

    @Test
    fun retriesAtMostThreeTimesWithBackoff() = runBlocking {
        repeat(3) { server.enqueue(MockResponse().setResponseCode(502)) }
        val sleeper = RecordingSleeper()
        val error = expectError {
            newSupport(baseUrl, sleeper).report(Report(type = ReportType.PROBLEM, description = "x", formVersion = 3))
        }
        assertEquals(ErrorCode.SERVER_ERROR, error.code)
        assertEquals(502, error.httpStatus)
        assertTrue(error.isRetryable)
        assertEquals(3, server.requestCount)
        assertEquals(listOf(1000L, 2000L), sleeper.delays)
    }

    @Test
    fun networkErrorsAreRetriedThenReported() = runBlocking {
        repeat(3) { server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START)) }
        val error = expectError {
            newSupport(baseUrl).report(Report(type = ReportType.PROBLEM, description = "x", formVersion = 3))
        }
        assertEquals(ErrorCode.NETWORK_ERROR, error.code)
        assertTrue(error.isRetryable)
        assertEquals(3, server.requestCount)
    }

    @Test
    fun retryAfterLongerThanTheLimitFailsWithoutWaiting() = runBlocking {
        server.enqueue(
            MockResponse().setResponseCode(429).setHeader("Retry-After", "600")
                .setBody("""{"error":{"code":"RATE_LIMITED","message":"Slow down."}}"""),
        )
        val sleeper = RecordingSleeper()
        val error = expectError {
            newSupport(baseUrl, sleeper).report(Report(type = ReportType.PROBLEM, description = "x", formVersion = 3))
        }
        assertEquals(ErrorCode.RATE_LIMITED, error.code)
        assertEquals(600L, error.retryAfterSeconds)
        assertEquals(emptyList<Long>(), sleeper.delays)
        assertEquals(1, server.requestCount)
    }

    @Test
    fun uploadSendsOnlyTheReturnedHeaders() = runBlocking {
        val uploadUrl = server.url("/upload/1").toString()
        server.enqueue(
            MockResponse().setResponseCode(201).setBody(
                """{"reportId":"rpt_AAAAAAAAAAAAAAAA0009","status":"awaiting_uploads","submitToken":"st_0123456789abcdef0123456789abcdef",
                   "uploads":[{"uploadUrl":"$uploadUrl","headers":{"Content-Type":"text/plain","x-amz-meta":"a"},"expiresAt":"2099-01-01T00:00:00Z"}]}""",
            ),
        )
        server.enqueue(MockResponse().setResponseCode(200))
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"reportId":"rpt_AAAAAAAAAAAAAAAA0009","status":"received"}"""))

        val receipt = newSupport(baseUrl).report(
            Report(
                type = ReportType.PROBLEM, description = "x", formVersion = 3,
                attachments = listOf(Attachment("note.txt", "text/plain", "hello".toByteArray())),
            ),
        )
        assertEquals("received", receipt.status)
        server.takeRequest()
        val upload = server.takeRequest()
        assertEquals("PUT", upload.method)
        assertNull("The SDK key never goes to the storage host", upload.getHeader("X-Tododdle-Key"))
        assertNull(upload.getHeader("X-Tododdle-App-Id"))
        assertEquals("text/plain", upload.getHeader("Content-Type"))
        assertEquals("a", upload.getHeader("x-amz-meta"))
    }

    @Test
    fun failedUploadIsReported() = runBlocking {
        val uploadUrl = server.url("/upload/1").toString()
        server.enqueue(
            MockResponse().setResponseCode(201).setBody(
                """{"reportId":"rpt_AAAAAAAAAAAAAAAA0009","status":"awaiting_uploads","submitToken":"st_0123456789abcdef0123456789abcdef",
                   "uploads":[{"uploadUrl":"$uploadUrl","headers":{},"expiresAt":"2099-01-01T00:00:00Z"}]}""",
            ),
        )
        server.enqueue(MockResponse().setResponseCode(403))
        val error = expectError {
            newSupport(baseUrl).report(
                Report(
                    type = ReportType.PROBLEM, description = "x", formVersion = 3,
                    attachments = listOf(Attachment("note.txt", "text/plain", "hello".toByteArray())),
                ),
            )
        }
        assertEquals(ErrorCode.UPLOAD_FAILED, error.code)
        assertEquals(403, error.httpStatus)
        assertEquals(2, server.requestCount)
    }

    @Test
    fun configIsCachedOnDiskAndUsedOffline() = runBlocking {
        val environment = FakeEnvironment(cacheDir = temp.root)
        server.enqueue(MockResponse().setBody(configBody).setHeader("ETag", "\"cfg-3\""))
        newSupport(baseUrl, environment = environment).config()

        // A new instance (new app launch) reads the file and revalidates with the ETag.
        server.enqueue(MockResponse().setResponseCode(304))
        val second = newSupport(baseUrl, environment = environment)
        assertEquals(3, second.cachedConfig()?.form?.version)
        assertEquals(3, second.config().form.version)
        server.takeRequest()
        assertEquals("\"cfg-3\"", server.takeRequest().getHeader("If-None-Match"))

        // Offline: the last good config still opens the form.
        server.shutdown()
        assertEquals(3, newSupport(baseUrl, environment = environment).config().form.version)
    }

    @Test
    fun revokedKeyIsNotHiddenByTheCache() = runBlocking {
        val environment = FakeEnvironment(cacheDir = temp.root)
        server.enqueue(MockResponse().setBody(configBody).setHeader("ETag", "\"cfg-3\""))
        val support = newSupport(baseUrl, environment = environment)
        support.config()
        server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":{"code":"KEY_REVOKED","message":"Revoked."}}"""))
        assertEquals(ErrorCode.KEY_REVOKED, expectError { support.config() }.code)
    }

    @Test
    fun malformedResponseIsATypedError() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(201).setBody("not json"))
        val error = expectError {
            newSupport(baseUrl).report(Report(type = ReportType.PROBLEM, description = "x", formVersion = 3))
        }
        assertEquals(ErrorCode.INVALID_RESPONSE, error.code)
    }

    @Test
    fun unknownConfigValuesAreTolerated() = runBlocking {
        val future = configBody
            .replace("\"SELECT\"", "\"DATE\"")
            .replace("\"question\"", "\"idea\"")
            .replace("\"theme\":{", "\"newThing\":{\"a\":1},\"theme\":{")
        server.enqueue(MockResponse().setBody(future))
        val config = newSupport(baseUrl).config()
        assertEquals(FieldType("DATE"), config.form.fields.first().type)
        assertEquals(ReportType("idea"), config.form.types.last().value)
    }
}
