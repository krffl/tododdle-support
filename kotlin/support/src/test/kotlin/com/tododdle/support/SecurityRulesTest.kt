package com.tododdle.support

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/** Key, base URL, redirect, upload URL and screen rules. */
class SecurityRulesTest {
    private lateinit var server: MockWebServer

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

    private suspend fun expectError(block: suspend () -> Unit): TododdleSupportException {
        try {
            block()
        } catch (e: TododdleSupportException) {
            return e
        }
        fail("Expected TododdleSupportException")
        error("unreachable")
    }

    private fun awaitingUpload(uploadUrl: String, headers: String = """{"Content-Type":"text/plain"}""") =
        MockResponse().setResponseCode(201).setBody(
            """{"reportId":"rpt_AAAAAAAAAAAAAAAA0009","status":"awaiting_uploads","submitToken":"st_0123456789abcdef0123456789abcdef",
               "uploads":[{"uploadUrl":"$uploadUrl","headers":$headers,"expiresAt":"2099-01-01T00:00:00Z"}]}""",
        )

    private fun reportWithAttachment() = Report(
        type = ReportType.PROBLEM, description = "x", formVersion = 3,
        attachments = listOf(Attachment("note.txt", "text/plain", "hello".toByteArray())),
    )

    @Test
    fun keyMustHaveAPublicOrTestPrefix() {
        Configuration(key = "tdsk_pub_abc")
        Configuration(key = "tdsk_test_abc")
        for (key in listOf("sk_live_abc", "tdsk_secret_abc", "TDSK_PUB_abc", " tdsk_pub_abc")) {
            assertThrows(key, IllegalArgumentException::class.java) { Configuration(key = key) }
        }
    }

    @Test
    fun baseUrlMustBeHttpsUnlessLoopback() {
        Configuration(key = "tdsk_pub_x", baseUrl = "https://app.tododdle.com/api/support/sdk/v1")
        Configuration(key = "tdsk_pub_x", baseUrl = "http://127.0.0.1:8080/v1")
        Configuration(key = "tdsk_pub_x", baseUrl = "http://localhost:8080/v1")
        Configuration(key = "tdsk_pub_x", baseUrl = "http://[::1]:8080/v1")
        for (url in listOf("http://app.tododdle.com/v1", "http://10.0.2.2:3000/v1", "ftp://example.com", "not a url")) {
            assertThrows(url, IllegalArgumentException::class.java) { Configuration(key = "tdsk_pub_x", baseUrl = url) }
        }
    }

    @Test
    fun redirectsAreNotFollowed() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", server.url("/elsewhere").toString()))
        val error = expectError {
            newSupport(baseUrl).report(Report(type = ReportType.PROBLEM, description = "x", formVersion = 3))
        }
        assertEquals(ErrorCode.INVALID_RESPONSE, error.code)
        assertEquals(302, error.httpStatus)
        assertEquals("The redirect target is never requested", 1, server.requestCount)
    }

    @Test
    fun redirectsAreNotFollowedWithTheAppsOwnClient() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(307).setHeader("Location", server.url("/elsewhere").toString()))
        val support = TododdleSupport(
            Configuration(key = "tdsk_pub_x", baseUrl = baseUrl, httpClient = OkHttpClient.Builder().followRedirects(true).build()),
            FakeEnvironment(),
        ) { }
        val error = expectError { support.report(Report(type = ReportType.PROBLEM, description = "x", formVersion = 3)) }
        assertEquals(ErrorCode.INVALID_RESPONSE, error.code)
        assertEquals(1, server.requestCount)
    }

    @Test
    fun plainHttpUploadUrlIsRefused() = runBlocking {
        server.enqueue(awaitingUpload("http://uploads.example.com/upload/1"))
        val error = expectError { newSupport(baseUrl).report(reportWithAttachment()) }
        assertEquals(ErrorCode.INVALID_RESPONSE, error.code)
        assertEquals("Nothing is uploaded", 1, server.requestCount)
    }

    @Test
    fun nonHttpUploadUrlIsRefused() = runBlocking {
        server.enqueue(awaitingUpload("file:///etc/passwd"))
        val error = expectError { newSupport(baseUrl).report(reportWithAttachment()) }
        assertEquals(ErrorCode.INVALID_RESPONSE, error.code)
        assertEquals(1, server.requestCount)
    }

    @Test
    fun loopbackHttpUploadUrlIsAllowedAndForbiddenHeadersAreDropped() = runBlocking {
        val uploadUrl = server.url("/upload/1").toString().replace("://localhost:", "://127.0.0.1:")
        server.enqueue(
            awaitingUpload(
                uploadUrl,
                """{"Content-Type":"text/plain","x-amz-meta":"a","Authorization":"Bearer leak","Cookie":"s=1",
                    "Host":"evil.example","Proxy-Authorization":"Basic x","Connection":"close",
                    "Transfer-Encoding":"chunked","Content-Length":"999"}""",
            ),
        )
        server.enqueue(MockResponse().setResponseCode(200))
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"reportId":"rpt_AAAAAAAAAAAAAAAA0009","status":"received"}"""))

        val receipt = newSupport(baseUrl).report(reportWithAttachment())
        assertEquals("received", receipt.status)
        server.takeRequest()
        val upload = server.takeRequest()
        assertEquals("PUT", upload.method)
        assertEquals("a", upload.getHeader("x-amz-meta"))
        assertEquals("text/plain", upload.getHeader("Content-Type"))
        assertNull(upload.getHeader("Authorization"))
        assertNull(upload.getHeader("Cookie"))
        assertNull(upload.getHeader("Proxy-Authorization"))
        assertNull(upload.getHeader("Transfer-Encoding"))
        assertEquals("5", upload.getHeader("Content-Length"))
        assertEquals("127.0.0.1:${server.port}", upload.getHeader("Host"))
    }

    @Test
    fun screenDropsQueryStringAndFragment() = runBlocking {
        for ((screen, expected) in listOf(
            "Favourites?tab=recent" to "Favourites",
            "Favourites#token=abc" to "Favourites",
            "Favourites#a?b" to "Favourites",
            "Settings/Profile" to "Settings/Profile",
        )) {
            server.enqueue(MockResponse().setResponseCode(201).setBody("""{"reportId":"rpt_AAAAAAAAAAAAAAAA0001","status":"received"}"""))
            newSupport(baseUrl).report(
                Report(type = ReportType.PROBLEM, description = "x", formVersion = 3, context = ReportContext(screen = screen)),
            )
            val context = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject.getValue("context").jsonObject
            assertEquals(expected, context.getValue("screen").jsonPrimitive.content)
        }
    }
}
