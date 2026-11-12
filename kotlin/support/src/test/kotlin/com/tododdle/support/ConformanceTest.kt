package com.tododdle.support

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import java.io.File
import java.util.Base64

/**
 * Replays every case in contract/cases/cases.json against a MockWebServer and checks each
 * `request.must` rule and the `expect` block.
 */
@RunWith(Parameterized::class)
class ConformanceTest(private val name: String, private val case: JsonObject) {

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        val root: JsonObject by lazy {
            val path = System.getProperty("tododdle.casesFile")
                ?: error("Run through Gradle: the tododdle.casesFile system property is not set.")
            json.parseToJsonElement(File(path).readText()).jsonObject
        }

        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun cases(): List<Array<Any>> = root.getValue("cases").jsonArray.also {
            check(it.size == 14) { "Expected 14 conformance cases, found ${it.size}. Update this runner." }
        }.map {
            val case = it.jsonObject
            arrayOf(case.getValue("name").jsonPrimitive.content, case)
        }
    }

    private lateinit var server: MockWebServer
    private val recorded = mutableListOf<RecordedRequest>()
    private val mismatches = mutableListOf<String>()

    @Before
    fun start() {
        server = MockWebServer()
        val exchanges = case.getValue("exchanges").jsonArray.map { it.jsonObject }
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = synchronized(recorded) {
                val index = recorded.size
                recorded += request
                val exchange = exchanges.getOrNull(index)
                    ?: return MockResponse().setResponseCode(599).also {
                        mismatches += "Unexpected extra request ${request.method} ${request.path}"
                    }
                val expected = exchange.getValue("request").jsonObject
                val method = expected.getValue("method").jsonPrimitive.content
                val path = expected.getValue("path").jsonPrimitive.content
                if (request.method != method || request.requestUrl?.encodedPath != path) {
                    mismatches += "Request ${index + 1}: expected $method $path, got ${request.method} ${request.requestUrl?.encodedPath}"
                }
                toMockResponse(exchange.getValue("response").jsonObject)
            }
        }
        server.start()
    }

    @After
    fun stop() {
        server.shutdown()
    }

    @Test
    fun conformance() = runBlocking {
        val sleeper = RecordingSleeper()
        val support = newSupport(baseUrl = server.url("/").toString().trimEnd('/'), sleeper = sleeper)
        val operation = case.getValue("operation").jsonPrimitive.content

        var config: SupportConfig? = null
        var receipt: ReportReceipt? = null
        var error: TododdleSupportException? = null
        try {
            when (operation) {
                "getConfig" -> config = support.config()
                "getConfigTwice" -> {
                    support.config()
                    config = support.config()
                }
                "report" -> receipt = support.report(caseReport(attachment = null))
                "reportWithAttachment" -> receipt = support.report(caseReport(attachment = caseAttachment()))
                else -> fail("Unknown operation $operation")
            }
        } catch (e: TododdleSupportException) {
            error = e
        }

        assertTrue(mismatches.joinToString("\n"), mismatches.isEmpty())
        checkRequests()
        checkExpect(case.getValue("expect").jsonObject, config, receipt, error, sleeper)
    }

    private fun checkRequests() {
        val exchanges = case.getValue("exchanges").jsonArray.map { it.jsonObject }
        assertEquals("Every exchange is used, in order", exchanges.size, recorded.size)
        exchanges.forEachIndexed { index, exchange ->
            val must = exchange.getValue("request").jsonObject["must"]?.jsonObject ?: return@forEachIndexed
            val request = recorded[index]
            val label = "Request ${index + 1} (${request.method} ${request.path})"
            for ((rule, value) in must) {
                when (rule) {
                    "headers" -> checkHeaders(label, request, value)
                    "body" -> checkBody(label, request, value)
                    "rawBodyBase64" -> {
                        val expected = resolveAttachmentBytes(value.jsonPrimitive.content)
                        assertArrayEquals("$label raw body", expected, request.body.readByteArray())
                    }
                    "sameIdempotencyKeyAsPrevious" -> {
                        if (value.jsonPrimitive.booleanOrNull == true) {
                            val previous = recorded.subList(0, index).last { it.method == "POST" && it.requestUrl?.encodedPath == "/reports" }
                            assertEquals("$label idempotency key", idempotencyKey(previous), idempotencyKey(request))
                        }
                    }
                    else -> fail("$label: unknown must rule '$rule'. Teach the conformance runner about it.")
                }
            }
        }
    }

    private fun checkHeaders(label: String, request: RecordedRequest, value: JsonElement) {
        when (value) {
            is JsonArray -> value.forEach {
                val name = it.jsonPrimitive.content
                assertNotNull("$label must send header $name", request.getHeader(name))
            }
            is JsonObject -> value.forEach { (name, expected) ->
                assertEquals("$label header $name", expected.jsonPrimitive.content, request.getHeader(name))
            }
            else -> fail("$label: unexpected headers rule $value")
        }
    }

    private fun checkBody(label: String, request: RecordedRequest, value: JsonElement) {
        val body = json.parseToJsonElement(request.body.clone().readUtf8())
        when (value) {
            is JsonArray -> value.forEach {
                val path = it.jsonPrimitive.content
                val found = lookup(body, path)
                assertTrue("$label body must contain $path", found != null && found != JsonNull)
            }
            is JsonObject -> value.forEach { (path, expected) ->
                assertEquals("$label body $path", expected, lookup(body, path))
            }
            else -> fail("$label: unexpected body rule $value")
        }
    }

    private fun checkExpect(
        expect: JsonObject,
        config: SupportConfig?,
        receipt: ReportReceipt?,
        error: TododdleSupportException?,
        sleeper: RecordingSleeper,
    ) {
        for ((key, value) in expect) {
            when (key) {
                "ok" -> assertEquals("ok (error was $error)", value.jsonPrimitive.booleanOrNull, error == null)
                "formVersion" -> assertEquals(value.jsonPrimitive.int, config?.form?.version)
                "fieldKeys" -> assertEquals(value.jsonArray.map { it.jsonPrimitive.content }, config?.form?.fields?.map { it.key })
                "reportId" -> assertEquals(value.jsonPrimitive.content, receipt?.reportId)
                "errorCode" -> assertEquals(value.jsonPrimitive.content, error?.code)
                "httpStatus" -> assertEquals(value.jsonPrimitive.int, error?.httpStatus)
                "fieldErrors" -> assertEquals(
                    value.jsonObject.mapValues { it.value.jsonPrimitive.content },
                    error?.fields,
                )
                "requests" -> assertEquals("request count", value.jsonPrimitive.int, recorded.size)
                "minDelayMs" -> assertTrue(
                    "waited ${sleeper.total} ms, expected at least $value",
                    sleeper.total >= value.jsonPrimitive.long,
                )
                else -> fail("Unknown expect key '$key'. Teach the conformance runner about it.")
            }
        }
    }

    private fun toMockResponse(response: JsonObject): MockResponse {
        val mock = MockResponse().setResponseCode(response.getValue("status").jsonPrimitive.int)
        response["headers"]?.jsonObject?.forEach { (name, value) -> mock.setHeader(name, value.jsonPrimitive.content) }
        val body = response["body"] ?: return mock
        val text = when {
            body is JsonPrimitive && body.content == "\$config" -> root.getValue("config").toString()
            else -> body.toString()
        }
        mock.setHeader("Content-Type", "application/json")
        return mock.setBody(text.replace("{{baseUrl}}", server.url("/").toString().trimEnd('/')))
    }

    private fun caseReport(attachment: Attachment?): Report {
        val template = root.getValue("report").jsonObject
        return Report(
            type = ReportType(template.getValue("type").jsonPrimitive.content),
            description = template["description"]?.jsonPrimitive?.content,
            title = template["title"]?.jsonPrimitive?.content,
            fields = template["fields"]?.jsonObject?.mapValues { it.value.jsonPrimitive.content }.orEmpty(),
            context = template["context"]?.let { json.decodeFromJsonElement(ReportContext.serializer(), it) }
                ?.let { context -> case["screen"]?.let { context.copy(screen = it.jsonPrimitive.content) } ?: context },
            reporter = template["reporter"]?.let { json.decodeFromJsonElement(Reporter.serializer(), it) },
            attachments = listOfNotNull(attachment),
            formVersion = root.getValue("config").jsonObject.getValue("form").jsonObject.getValue("version").jsonPrimitive.int,
        )
    }

    private fun caseAttachment(): Attachment {
        val spec = case.getValue("attachment").jsonObject
        return Attachment(
            fileName = spec.getValue("fileName").jsonPrimitive.content,
            contentType = spec.getValue("contentType").jsonPrimitive.content,
            bytes = Base64.getDecoder().decode(spec.getValue("bytesBase64").jsonPrimitive.content),
        )
    }

    private fun resolveAttachmentBytes(value: String): ByteArray =
        if (value == "\$attachment") {
            Base64.getDecoder().decode(case.getValue("attachment").jsonObject.getValue("bytesBase64").jsonPrimitive.content)
        } else {
            Base64.getDecoder().decode(value)
        }

    private fun idempotencyKey(request: RecordedRequest): String? =
        lookup(json.parseToJsonElement(request.body.clone().readUtf8()), "idempotencyKey")?.jsonPrimitive?.content

    /** Follows a dotted path such as `fields.area` or `attachments.0.fileName`. */
    private fun lookup(element: JsonElement, path: String): JsonElement? =
        path.split('.').fold(element as JsonElement?) { current, part ->
            when (current) {
                is JsonObject -> current[part]
                is JsonArray -> part.toIntOrNull()?.let { current.getOrNull(it) }
                else -> null
            }
        }
}
