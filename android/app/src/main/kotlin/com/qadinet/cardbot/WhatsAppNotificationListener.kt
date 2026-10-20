package com.qadinet.cardbot

import android.app.Notification
import android.app.Person
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * WhatsApp auto-replies are deliberately limited to visible, one-to-one WhatsApp
 * notifications that expose an Android RemoteInput reply action. This service
 * never launches WhatsApp UI or scrapes its database.
 */
class WhatsAppNotificationListener : NotificationListenerService() {
    private val worker = Executors.newSingleThreadScheduledExecutor()
    private val queuedNotifications = ConcurrentHashMap.newKeySet<String>()

    override fun onListenerConnected() {
        super.onListenerConnected()
        runCatching {
            activeNotifications.orEmpty()
                .filter { it.packageName in WHATSAPP_PACKAGES }
                .forEach(::enqueueNotification)
        }.onFailure {
            Log.w(TAG, "Could not inspect active WhatsApp notifications (${it.javaClass.simpleName})")
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName !in WHATSAPP_PACKAGES) return
        enqueueNotification(sbn)
    }

    private fun enqueueNotification(sbn: StatusBarNotification) {
        val postedAt = sbn.postTime.takeIf { it > 0L } ?: sbn.notification.`when`
        val queueKey = "${sbn.key}|$postedAt"
        if (!queuedNotifications.add(queueKey)) return
        worker.execute { processOrRetry(sbn, queueKey, 0) }
    }

    /** Keeps transient failures queued with bounded exponential backoff. */
    private fun processOrRetry(
        sbn: StatusBarNotification,
        queueKey: String,
        attempt: Int
    ) {
        val completed = try {
            processNotification(sbn)
        } catch (error: Exception) {
            Log.e(TAG, "Could not process a WhatsApp notification (${error.javaClass.simpleName})")
            false
        }
        if (completed) {
            queuedNotifications.remove(queueKey)
            return
        }

        // إبقاء الإشعار في الطابور حتى ينجح الرد أو يعيد Android ربط الخدمة.
        val delaySeconds = (5L * (1L shl attempt.coerceAtMost(6))).coerceAtMost(300L)
        worker.schedule(
            { processOrRetry(sbn, queueKey, attempt + 1) },
            delaySeconds,
            TimeUnit.SECONDS
        )
    }

    /** Returns false only when a safely retryable action is still pending. */
    private fun processNotification(sbn: StatusBarNotification): Boolean {
        if (!NativeStore.isWhatsAppAutoReplyEnabled(applicationContext)) return true
        val notification = sbn.notification ?: return true
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return true
        val extras = notification.extras ?: return true
        if (isGroupConversation(extras)) return true

        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        if (title.isBlank() || isAggregateTitle(title)) return true
        val message = extractNotificationMessage(extras)
        if (message.isBlank() || message.length > 2000 || looksLikeOwnMessage(message)) return true

        val action = firstTextReplyAction(notification) ?: return true
        val remoteInputs = textReplyInputs(action).takeIf { it.isNotEmpty() } ?: return true
        val replyIntent = action.actionIntent ?: return true

        val phone = resolveSenderPhone(sbn, title) ?: return true
        val eventTime = sbn.postTime.takeIf { it > 0L } ?: notification.`when`
        val eventId = notificationDedupeDigest(sbn.key, eventTime, phone, message)
        if (!markPendingOnce(eventId)) return true

        val completed = NativeStore.processIncoming(
            applicationContext,
            phone,
            message,
            channel = "whatsapp",
            whatsappReply = { replyText ->
                sendDirectReply(replyIntent, remoteInputs, replyText)
            },
            eventId = eventId
        )
        if (completed) markDone(eventId)
        return completed
    }

    private fun resolveSenderPhone(sbn: StatusBarNotification, title: String): String? {
        val personPhone = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            runCatching {
                @Suppress("DEPRECATION")
                val people = sbn.notification.extras
                    .getParcelableArrayList<Person>(Notification.EXTRA_PEOPLE_LIST)
                people?.firstNotNullOfOrNull { person ->
                    val uri = person.uri?.let(Uri::parse)
                    uri?.takeIf { it.scheme.equals("tel", ignoreCase = true) }
                        ?.schemeSpecificPart
                }
            }.getOrNull()
        } else null
        val fromPerson = personPhone?.let(::normalizeYemeniPhone)
        if (fromPerson != null) return fromPerson

        normalizeYemeniPhone(title)?.let { return it }
        // لا يُقبل الاسم إلا إذا طابق عميلاً موثقاً واحداً فقط.
        return NativeStore.trustedPhoneForWhatsAppLabel(applicationContext, title)
    }

    private fun normalizeYemeniPhone(raw: String): String? {
        val digits = buildString {
            raw.forEach { char ->
                when (char) {
                    in '٠'..'٩' -> append('0' + (char - '٠'))
                    in '۰'..'۹' -> append('0' + (char - '۰'))
                    in '0'..'9' -> append(char)
                }
            }
        }
        val local = when {
            digits.startsWith("00967") -> digits.drop(5)
            digits.startsWith("967") -> digits.drop(3)
            digits.length == 10 && digits.startsWith("07") -> digits.drop(1)
            else -> digits
        }
        return local.takeIf { it.length == 9 && it.startsWith('7') }
    }

    private fun sendDirectReply(
        pendingIntent: android.app.PendingIntent,
        remoteInputs: Array<RemoteInput>,
        message: String
    ): Boolean {
        if (message.isBlank()) return false
        return try {
            val results = Bundle()
            remoteInputs.forEach { results.putCharSequence(it.resultKey, message) }
            val replyIntent = Intent()
            RemoteInput.addResultsToIntent(remoteInputs, replyIntent, results)
            pendingIntent.send(this, 0, replyIntent)
            true
        } catch (error: Exception) {
            Log.w(TAG, "WhatsApp direct reply action failed (${error.javaClass.simpleName})")
            false
        }
    }

    private fun markPendingOnce(eventId: String): Boolean {
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val key = "seen_$eventId"
        val current = prefs.all[key]
        if (current is Long) return false // أحداث الإصدار السابق عوملت كمنجزة.
        if (current is String && current.startsWith("done:")) return false

        val now = System.currentTimeMillis()
        val editor = prefs.edit().putString(key, "pending:$now")
        val old = prefs.all.entries
            .filter { it.key.startsWith("seen_") }
            .filter { now - storedTimestamp(it.value) > DEDUPE_TTL_MS }
        old.forEach { editor.remove(it.key) }
        val recent = prefs.all.entries
            .filter { it.key.startsWith("seen_") && it.key != key }
            .sortedByDescending { storedTimestamp(it.value) }
        if (recent.size >= MAX_DEDUPE_KEYS) {
            recent.drop(MAX_DEDUPE_KEYS - 1).forEach { editor.remove(it.key) }
        }
        editor.commit()
        return true
    }

    private fun markDone(eventId: String) {
        getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString("seen_$eventId", "done:${System.currentTimeMillis()}")
            .commit()
    }

    private fun storedTimestamp(value: Any?): Long = when (value) {
        is Long -> value
        is String -> value.substringAfter(':', "0").toLongOrNull() ?: 0L
        else -> 0L
    }

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }

    private fun isAggregateTitle(title: String): Boolean {
        val normalized = title.trim().lowercase(Locale.ROOT)
        return normalized.contains("messages from") || normalized.contains("رسائل من") ||
            normalized.matches(Regex("\\d+ (messages|رسائل).*"))
    }

    private fun looksLikeOwnMessage(message: String): Boolean {
        val normalized = message.trim().lowercase(Locale.ROOT)
        return normalized.startsWith("you:") || normalized.startsWith("you replied") ||
            normalized.startsWith("أنت:") || normalized.startsWith("قمت بالرد")
    }

    companion object {
        private const val TAG = "CardBotWhatsApp"
        private const val PREFS = "whatsapp_notification_dedupe"
        private const val DEDUPE_TTL_MS = 48L * 60 * 60 * 1000
        private const val MAX_DEDUPE_KEYS = 512
        private val WHATSAPP_PACKAGES = setOf("com.whatsapp", "com.whatsapp.w4b")

        internal fun extractNotificationMessage(extras: Bundle): String {
            fun nonBlank(key: String): String? = extras.getCharSequence(key)
                ?.toString()?.trim()?.takeIf { it.isNotEmpty() }
            return nonBlank(Notification.EXTRA_TEXT)
                ?: nonBlank(Notification.EXTRA_BIG_TEXT)
                ?: nonBlank(Notification.EXTRA_TITLE)
                ?: ""
        }

        internal fun firstTextReplyAction(notification: Notification): Notification.Action? =
            notification.actions?.firstOrNull { action ->
                action.actionIntent != null && textReplyInputs(action).isNotEmpty()
            }

        internal fun textReplyInputs(action: Notification.Action): Array<RemoteInput> =
            action.remoteInputs
                ?.filter { it.allowFreeFormInput && it.resultKey.isNotBlank() }
                ?.toTypedArray()
                ?: emptyArray()

        internal fun isGroupConversation(extras: Bundle, sdkInt: Int = Build.VERSION.SDK_INT): Boolean {
            // قيمة false الصريحة تعني محادثة فردية ولا يجوز نقضها بتخمين العنوان.
            if (extras.containsKey(Notification.EXTRA_IS_GROUP_CONVERSATION)) {
                return extras.getBoolean(Notification.EXTRA_IS_GROUP_CONVERSATION, false)
            }
            if (sdkInt < Build.VERSION_CODES.P) return false
            val conversationTitle = extras
                .getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()?.trim().orEmpty()
            if (conversationTitle.isBlank()) return false
            val sender = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
            return sender.isBlank() || !conversationTitle.equals(sender, ignoreCase = true)
        }

        internal fun notificationDedupeDigest(
            notificationKey: String,
            postedAt: Long,
            phone: String,
            message: String
        ): String {
            val raw = "$notificationKey|$postedAt|$phone|$message"
            return MessageDigest.getInstance("SHA-256")
                .digest(raw.toByteArray(Charsets.UTF_8))
                .take(16).joinToString("") { "%02x".format(it) }
        }

        fun hasNotificationAccess(context: Context): Boolean {
            val enabled = Settings.Secure.getString(
                context.contentResolver,
                "enabled_notification_listeners"
            ).orEmpty()
            val ourPackage = context.packageName
            return enabled.split(':').mapNotNull(ComponentName::unflattenFromString)
                .any { it.packageName == ourPackage && it.className == WhatsAppNotificationListener::class.java.name }
        }

        fun openNotificationAccessSettings(context: Context) {
            val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            if (context !is android.app.Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        }
    }
}
