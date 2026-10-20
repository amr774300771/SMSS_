package com.qadinet.cardbot

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat

class CardBotService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var lastFingerprint = ""

    private val update = object : Runnable {
        override fun run() {
            try {
                NativeStore.processDueSales(this@CardBotService)
                val (notification, fingerprint) = buildNotification()
                if (fingerprint != lastFingerprint) {
                    getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
                    lastFingerprint = fingerprint
                }
            } catch (_: Exception) {
                // Keep the foreground service alive even if a status refresh fails.
            } finally {
                handler.postDelayed(this, 30_000)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        running = true
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_TOGGLE -> NativeStore.toggleTrigger(this)
            ACTION_SETTINGS, ACTION_REPORTS -> Unit
        }
        val (notification, fingerprint) = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } catch (_: Exception) {
                startForeground(NOTIFICATION_ID, notification)
            }
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        runCatching { NativeStore.processDueSales(this) }
        lastFingerprint = fingerprint
        handler.removeCallbacks(update)
        handler.postDelayed(update, 30_000)
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(update)
        running = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "حالة القاضي نت", NotificationManager.IMPORTANCE_LOW).apply {
                description = "حالة خدمة رسائل القاضي نت دون تنبيهات منبثقة أو صوتية"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Pair<Notification, String> {
        val status = NativeStore.statusSnapshot(this)
        val active = status["triggerEnabled"] == true
        val processed = status["processedCount"] ?: 0
        val sales = status["totalSalesCount"] ?: 0
        val lowStock = status["lowStockCount"] ?: 0
        val title = if (active) "🟢 القاضي نت — نشط" else "⏸️ القاضي نت — متوقف"
        val body = "${if (active) "✅ المحرك يعمل" else "المحرك متوقف"} | 📨 $processed طلب | 💰 $sales بيعة | ⚠️ $lowStock باقة منخفضة"
        val fingerprint = "$title|$body"

        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val toggle = PendingIntent.getService(
            this, 1, Intent(this, CardBotService::class.java).setAction(ACTION_TOGGLE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val settings = PendingIntent.getActivity(
            this, 2, Intent(this, MainActivity::class.java).putExtra("screen", "settings"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val reports = PendingIntent.getActivity(
            this, 3, Intent(this, MainActivity::class.java).putExtra("screen", "reports"),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText("حالة المحرك: ${if (active) "يعمل" else "متوقف"}\nعدد العمليات: $processed\nعدد المبيعات: $sales\nباقات منخفضة المخزون: $lowStock\nاضغط لفتح التطبيق."))
            .setContentIntent(open)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(0, if (active) "⏸ إيقاف" else "▶ تشغيل", toggle)
            .addAction(0, "⚙ الإعدادات", settings)
            .addAction(0, "📊 التقارير", reports)
            .build()
        return notification to fingerprint
    }

    companion object {
        @Volatile var running: Boolean = false
            private set
        const val NOTIFICATION_ID = 1001
        // A new channel ID is required because Android channel importance is immutable after creation.
        private const val CHANNEL_ID = "cardbot_status_v2"
        const val ACTION_TOGGLE = "com.qadinet.cardbot.TOGGLE"
        const val ACTION_SETTINGS = "com.qadinet.cardbot.SETTINGS"
        const val ACTION_REPORTS = "com.qadinet.cardbot.REPORTS"

        fun start(context: Context) {
            val intent = Intent(context, CardBotService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent) else context.startService(intent)
        }

        fun refresh(context: Context) {
            try { start(context) } catch (_: Exception) { }
        }
    }
}
