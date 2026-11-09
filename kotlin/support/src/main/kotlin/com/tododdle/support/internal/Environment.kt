package com.tododdle.support.internal

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.tododdle.support.ReportContext
import java.io.File
import java.util.Locale

/** What the SDK reads from the host app. Swapped for a fake in JVM tests. */
internal interface Environment {
    /** The Android package name, sent as `X-Tododdle-App-Id`. */
    val appId: String?

    /** Folder for the optional config file cache, or null for memory only. */
    val cacheDir: File?

    /** App version, build, Android version, device model and locale. Nothing else. */
    fun automaticContext(): ReportContext
}

internal class AndroidEnvironment(context: Context) : Environment {
    private val appContext = context.applicationContext ?: context

    override val appId: String? = appContext.packageName

    override val cacheDir: File? get() = appContext.cacheDir

    override fun automaticContext(): ReportContext {
        val (versionName, versionCode) = packageVersion()
        return ReportContext(
            platform = "android",
            appVersion = versionName?.take(50),
            build = versionCode?.toString()?.take(50),
            osName = "Android",
            osVersion = Build.VERSION.RELEASE?.take(50),
            deviceModel = deviceModel().take(100),
            locale = Locale.getDefault().toLanguageTag().take(35),
        )
    }

    private fun packageVersion(): Pair<String?, Long?> = try {
        val info = if (Build.VERSION.SDK_INT >= 33) {
            appContext.packageManager.getPackageInfo(appContext.packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            appContext.packageManager.getPackageInfo(appContext.packageName, 0)
        }
        val code = if (Build.VERSION.SDK_INT >= 28) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        info.versionName to code
    } catch (_: PackageManager.NameNotFoundException) {
        null to null
    }

    private fun deviceModel(): String {
        val manufacturer = Build.MANUFACTURER.orEmpty()
        val model = Build.MODEL.orEmpty()
        return if (model.startsWith(manufacturer, ignoreCase = true)) model else "$manufacturer $model".trim()
    }
}
