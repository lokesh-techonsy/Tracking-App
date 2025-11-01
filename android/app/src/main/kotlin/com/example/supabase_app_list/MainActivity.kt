package com.example.supabase_app_list

import android.app.AppOpsManager
import android.app.usage.NetworkStats
import android.app.usage.NetworkStatsManager
import android.app.usage.UsageStats
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.BitmapDrawable
import android.net.ConnectivityManager
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.RemoteException
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.*
import java.net.NetworkInterface

class MainActivity : FlutterActivity() {
    private val CHANNEL = "installed_apps"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Do not auto-open Usage Access settings; we'll prompt only on explicit user interaction from Flutter.
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstalledApps" -> {
                    val systemApps = call.argument<Boolean>("system") ?: false
                    val installedApps = getInstalledAppsList(systemApps)
                    result.success(installedApps)
                }
                "getBatteryUsage" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName != null) {
                        try {
                            if (!hasUsageAccessPermission()) {
                                result.error("PERMISSION_DENIED", "Usage access not granted", null)
                            } else {
                                val batteryUsage = getAppBatteryUsage(packageName)
                                result.success(mapOf("packageName" to packageName, "batteryUsage" to batteryUsage))
                            }
                        } catch (e: Exception) {
                            result.error("NATIVE_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_PACKAGE", "Package name is missing", null)
                    }
                }
                "getDataUsage" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName != null) {
                        try {
                            val dataUsage = getDataUsage(packageName)
                            result.success(mapOf("packageName" to packageName, "dataUsage" to formatDataUsage(dataUsage)))
                        } catch (e: Exception) {
                            result.error("NATIVE_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_PACKAGE", "Package name is missing", null)
                    }
                }
                "getAppUsageDetails" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName != null) {
                        try {
                            if (!hasUsageAccessPermission()) {
                                result.error("PERMISSION_DENIED", "Usage access not granted", null)
                            } else {
                                val usageDetails = getAppUsageDetails(packageName)
                                result.success(usageDetails)
                            }
                        } catch (e: Exception) {
                            result.error("NATIVE_ERROR", e.message, null)
                        }
                    } else {
                        result.error("INVALID_PACKAGE", "Package name is missing", null)
                    }
                }
                "requestUsageAccess" -> {
                    requestUsageAccess()
                    result.success(null)
                }
                "getDeviceIdentifier" -> {
                    try {
                        val id = getDeviceIdentifier()
                        result.success(id)
                    } catch (e: Exception) {
                        result.error("NATIVE_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun getInstalledAppsList(systemApps: Boolean): List<Map<String, Any>> {
        val pm = packageManager
        val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)
        val installedApps = mutableListOf<Map<String, Any>>()

        for (app in apps) {
            val isSystemApp = (app.flags and ApplicationInfo.FLAG_SYSTEM) != 0 ||
                    (app.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
            val isUserApp = !isSystemApp

            if ((systemApps && isSystemApp) || (!systemApps && isUserApp)) {
                val appName = app.loadLabel(pm).toString()
                val icon = pm.getApplicationIcon(app.packageName)

                val iconBitmap = when (icon) {
                    is BitmapDrawable -> icon.bitmap
                    is AdaptiveIconDrawable -> {
                        val bitmap = Bitmap.createBitmap(100, 100, Bitmap.Config.ARGB_8888)
                        val canvas = Canvas(bitmap)
                        icon.setBounds(0, 0, canvas.width, canvas.height)
                        icon.draw(canvas)
                        bitmap
                    }
                    else -> null
                }

                if (iconBitmap != null) {
                    val stream = ByteArrayOutputStream()
                    iconBitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                    val byteArray = stream.toByteArray()

                    installedApps.add(
                        mapOf(
                            "name" to appName,
                            "packageName" to app.packageName,
                            "icon" to byteArray
                        )
                    )
                }
            }
        }
        return installedApps
    }

    private fun getAppBatteryUsage(packageName: String): Double {
        val usageStatsManager = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val endTime = System.currentTimeMillis()
        val startTime = endTime - (24 * 60 * 60 * 1000) // Last 24 hours

        val stats = usageStatsManager.queryAndAggregateUsageStats(startTime, endTime)
        val usageStats = stats[packageName]

        return if (usageStats != null) {
            val totalTimeForeground = usageStats.totalTimeInForeground / 1000 // Convert to seconds
            val estimatedBatteryUsage = (totalTimeForeground / 3600.0) * 5.0 // Estimate usage in %
            estimatedBatteryUsage
        } else {
            -1.0 // App not found in usage stats
        }
    }

    private fun getDataUsage(packageName: String): Long {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return -1

        return try {
            val networkStatsManager = getSystemService(Context.NETWORK_STATS_SERVICE) as NetworkStatsManager
            val calendar = Calendar.getInstance()
            calendar.add(Calendar.DAY_OF_MONTH, -1) // Get last 24 hours usage
            val startTime = calendar.timeInMillis
            val endTime = System.currentTimeMillis()

            // Safely obtain UID; may throw NameNotFoundException
            val uid = packageManager.getApplicationInfo(packageName, 0).uid

            // Query device summary as a fallback (may not be per-app without READ_NETWORK_USAGE_HISTORY privilege)
            val bucket: NetworkStats.Bucket = networkStatsManager.querySummaryForDevice(
                ConnectivityManager.TYPE_WIFI,
                null,
                startTime,
                endTime
            )
            bucket.txBytes + bucket.rxBytes
        } catch (e: Exception) {
            // Catch RemoteException, SecurityException, NameNotFoundException, etc.
            Log.w("MainActivity", "getDataUsage failed: ${e.message}")
            -1
        }
    }

    private fun getAppUsageDetails(packageName: String): Map<String, Any> {
        val usageStatsManager = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val endTime = System.currentTimeMillis()
        // Look back further (7 days) to ensure we catch lastTimeUsed and foreground time
        val startTime = endTime - (7L * 24 * 60 * 60 * 1000)

        val stats = usageStatsManager.queryAndAggregateUsageStats(startTime, endTime)
        val usageStats = stats[packageName]

        return try {
            val packageInfo = packageManager.getPackageInfo(packageName, 0)
            val firstInstallTime = packageInfo.firstInstallTime

            val lastTimeUsed = usageStats?.lastTimeUsed ?: 0L
            val totalTimeInForeground = usageStats?.totalTimeInForeground ?: 0L

            mapOf(
                "lastTimeUsed" to lastTimeUsed,
                "totalTimeInForeground" to totalTimeInForeground,
                "firstInstallTime" to firstInstallTime
            )
        } catch (e: PackageManager.NameNotFoundException) {
            mapOf("error" to "Package not found")
        }
    }


    private fun formatDataUsage(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val kb = bytes / 1024.0
        if (kb < 1024) return "%.2f KB".format(kb)
        val mb = kb / 1024.0
        if (mb < 1024) return "%.2f MB".format(mb)
        val gb = mb / 1024.0
        return "%.2f GB".format(gb)
    }

    private fun hasUsageAccessPermission(): Boolean {
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = appOps.unsafeCheckOpNoThrow(
            AppOpsManager.OPSTR_GET_USAGE_STATS,
            android.os.Process.myUid(),
            packageName
        )
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun requestUsageAccess() {
        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
        startActivity(intent)
    }

    // Best-effort device identifier: prefer ANDROID_ID; fall back to Wi-Fi MAC if available
    private fun getDeviceIdentifier(): String {
        return try {
            val androidId = Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID)
            if (!androidId.isNullOrEmpty()) return androidId

            // Fallback: Try reading wlan0 MAC (may be restricted on newer Android versions)
            val ni = NetworkInterface.getByName("wlan0")
            val mac = ni?.hardwareAddress?.joinToString(":") { String.format("%02X", it) }
            mac ?: "UNKNOWN"
        } catch (e: Exception) {
            "UNKNOWN"
        }
    }
}
