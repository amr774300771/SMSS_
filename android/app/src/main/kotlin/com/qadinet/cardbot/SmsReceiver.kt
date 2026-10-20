package com.qadinet.cardbot

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log

class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val pending = goAsync()
        Thread {
            try {
                Telephony.Sms.Intents.getMessagesFromIntent(intent).forEach { sms ->
                    val sender = sms.originatingAddress.orEmpty()
                    val body = sms.messageBody.orEmpty()
                    if (sender.isNotBlank() && body.isNotBlank()) NativeStore.processIncoming(context.applicationContext, sender, body)
                }
            } catch (e: Exception) { Log.e("CardBot", "SMS processing failed", e) }
            finally { pending.finish() }
        }.start()
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            ScheduledSaleAlarm.rescheduleAll(context)
            CardBotService.start(context)
        }
    }
}
