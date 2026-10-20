package com.qadinet.cardbot

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/** OS-backed wake-up for scheduled sales; inexact-on-idle avoids Android 12 exact-alarm special access. */
object ScheduledSaleAlarm {
    private const val ACTION_DUE = "com.qadinet.cardbot.SCHEDULED_SALE_DUE"

    fun schedule(context: Context, scheduleId: String, atMillis: Long) {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pending = pendingIntent(context, scheduleId, PendingIntent.FLAG_UPDATE_CURRENT) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pending)
        } else {
            manager.set(AlarmManager.RTC_WAKEUP, atMillis, pending)
        }
    }

    fun cancel(context: Context, scheduleId: String) {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pending = pendingIntent(context, scheduleId, PendingIntent.FLAG_NO_CREATE) ?: return
        manager.cancel(pending)
        pending.cancel()
    }

    fun rescheduleAll(context: Context) {
        NativeStore.pendingScheduledSales(context).forEach { (id, at) -> schedule(context, id, at) }
    }

    private fun pendingIntent(context: Context, id: String, flag: Int): PendingIntent? {
        val intent = Intent(context, ScheduledSaleReceiver::class.java)
            .setAction(ACTION_DUE)
            .putExtra("scheduleId", id)
        val flags = flag or if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        return PendingIntent.getBroadcast(context, id.hashCode(), intent, flags)
    }

    internal fun isDueAction(action: String?): Boolean = action == ACTION_DUE
}

class ScheduledSaleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!ScheduledSaleAlarm.isDueAction(intent.action)) return
        CardBotService.start(context.applicationContext)
    }
}
