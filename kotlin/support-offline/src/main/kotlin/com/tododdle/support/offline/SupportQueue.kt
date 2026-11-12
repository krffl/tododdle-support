package com.tododdle.support.offline

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.tododdle.support.Configuration
import com.tododdle.support.Report
import com.tododdle.support.ReportValidator
import com.tododdle.support.TododdleSupport
import com.tododdle.support.TododdleSupportException
import okhttp3.OkHttpClient
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * An opt-in offline queue. Saves a report in the app's no-backup folder and sends it with
 * WorkManager when the device is online, reusing the report's idempotency key on every attempt.
 *
 * Add the `support-offline` artifact only if you want this; the core library has no WorkManager
 * dependency.
 *
 * The queue holds at most [MAX_QUEUED_REPORTS] reports, drops reports older than
 * [MAX_QUEUED_AGE_MILLIS], and keeps report files under [MAX_QUEUED_BYTES] in total. When a new
 * report would break a cap, the oldest reports are dropped first.
 */
public object SupportQueue {
    /** Output key of a finished work item: the report ID. */
    public const val OUTPUT_REPORT_ID: String = "reportId"

    /** Output key of a failed work item: the error code. */
    public const val OUTPUT_ERROR_CODE: String = "errorCode"

    /** WorkManager tag on every queued report. */
    public const val WORK_TAG: String = "tododdle-support-report"

    /** The most reports the queue holds. Saving one more drops the oldest. */
    public const val MAX_QUEUED_REPORTS: Int = 10

    /** Queued reports older than this (7 days) are dropped. */
    public const val MAX_QUEUED_AGE_MILLIS: Long = 7L * 24 * 60 * 60 * 1000

    /** The most bytes of queued report files (20 MB). Saving more drops the oldest reports. */
    public const val MAX_QUEUED_BYTES: Long = 20L * 1024 * 1024

    /**
     * Supplies the OkHttp client the background worker uses to send queued reports. The worker
     * runs without your app's [Configuration], so set this in `Application.onCreate` when you
     * pass your own [Configuration.httpClient] (for example for certificate pinning or a proxy).
     * When null, the SDK's default client is used.
     */
    @JvmStatic
    @Volatile
    public var httpClientFactory: (() -> OkHttpClient)? = null

    internal const val INPUT_ID: String = "id"
    internal const val MAX_ATTEMPTS: Int = 10

    /**
     * Saves [report] and schedules it. Returns the unique WorkManager work name, which you can
     * observe with `WorkManager.getWorkInfosForUniqueWorkFlow`. Enqueuing the same report again
     * keeps the first work item.
     *
     * @throws TododdleSupportException with code `INVALID_FIELDS` when the report breaks the
     *   contract limits (checked against the cached config too, when there is one).
     */
    @JvmStatic
    public fun enqueue(context: Context, configuration: Configuration, report: Report): String {
        val appContext = context.applicationContext ?: context
        val config = TododdleSupport(appContext, configuration).cachedConfig()
            ?.takeIf { report.formVersion == null || it.form.version == report.formVersion }
        ReportValidator.requireValid(report, config)
        val id = store(appContext).save(configuration, report)
        val name = workName(id)
        val request = OneTimeWorkRequestBuilder<SendReportWorker>()
            .setInputData(workDataOf(INPUT_ID to id))
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(WORK_TAG)
            .build()
        WorkManager.getInstance(appContext).enqueueUniqueWork(name, ExistingWorkPolicy.KEEP, request)
        return name
    }

    /** Idempotency keys of reports still waiting to be sent. */
    @JvmStatic
    public fun pending(context: Context): List<String> = store(context.applicationContext ?: context).ids()

    /** The unique work name for a report's idempotency key. */
    @JvmStatic
    public fun workName(idempotencyKey: String): String = "tododdle-support-$idempotencyKey"

    /** The configuration the worker sends with: the stored one plus the app's HTTP client, if any. */
    internal fun workerConfiguration(stored: Configuration): Configuration =
        httpClientFactory?.invoke()?.let { stored.copy(httpClient = it) } ?: stored

    internal fun store(context: Context): QueueStore =
        QueueStore(File(context.noBackupFilesDir, "tododdle-support-queue"))
}

/** Sends one queued report. Retries network, rate-limit and server errors; drops refused reports. */
public class SendReportWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val id = inputData.getString(SupportQueue.INPUT_ID) ?: return Result.failure()
        val store = SupportQueue.store(applicationContext)
        val (configuration, report) = store.load(id) ?: run {
            store.delete(id)
            return Result.failure()
        }
        return try {
            val receipt = TododdleSupport(applicationContext, SupportQueue.workerConfiguration(configuration)).report(report)
            store.delete(id)
            Result.success(workDataOf(SupportQueue.OUTPUT_REPORT_ID to receipt.reportId))
        } catch (e: TododdleSupportException) {
            if (e.isRetryable && runAttemptCount + 1 < SupportQueue.MAX_ATTEMPTS) {
                Result.retry()
            } else {
                store.delete(id)
                Result.failure(workDataOf(SupportQueue.OUTPUT_ERROR_CODE to e.code))
            }
        }
    }
}
