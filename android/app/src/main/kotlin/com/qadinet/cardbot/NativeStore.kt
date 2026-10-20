package com.qadinet.cardbot

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.PowerManager
import android.os.Build
import android.telephony.TelephonyManager
import android.telephony.SmsManager
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.regex.Pattern
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/** Local serialized source of truth shared by the SMS receiver and Flutter UI. */
object NativeStore {
    private val lock = Any()
    private data class PackageMatch(
        val item: JSONObject? = null,
        val excluded: Boolean = false,
        val ambiguous: Boolean = false
    )
    private val fallbackPackageIds = setOf("500", "300", "3000", "200")
    private val packageIdPattern = Regex("^[A-Za-z0-9_-]{1,24}$")
    private val allowedConfigs = setOf("packages.json", "permissions.json", "trigger_config.json", "trusted_clients.json")
    private const val LEDGER_NAME = "transactions.json"
    private const val JOURNAL_NAME = ".pending_transaction.json"
    private const val WHATSAPP_REPLY_LIMIT = 20
    private const val WHATSAPP_REPLY_WINDOW_MS = 60L * 60 * 1000

    fun directory(context: Context): File = File(context.filesDir, "CardBot").apply { mkdirs() }
    private fun file(context: Context, name: String) = File(directory(context), name)
    private fun text(context: Context, name: String): String = file(context, name).takeIf { it.exists() }?.readText(Charsets.UTF_8) ?: ""
    private fun isoNow(): String = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US).format(Date())
    private fun stampNow(): String = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())

    fun initialize(context: Context, defaults: Map<String, String>) = synchronized(lock) {
        directory(context)
        recoverPendingTransaction(context)
        val hadLedger = file(context, LEDGER_NAME).exists()
        defaults.forEach { (name, content) -> if (!file(context, name).exists()) atomicWrite(file(context, name), content) }
        sanitizeDiagnosticHistory(context)
        repairPackageConfig(context, defaults["packages.json"])
        packageIds(context).forEach { id -> if (!file(context, "cards_$id.txt").exists()) atomicWrite(file(context, "cards_$id.txt"), "") }
        listOf("debts.txt", "sales.log").forEach { name -> if (!file(context, name).exists()) atomicWrite(file(context, name), "") }
        if (!hadLedger) migrateLegacyLedger(context)
        ensureCounters(context)
    }

    private fun repairPackageConfig(context: Context, defaultContent: String?) {
        val target = file(context, "packages.json")
        try {
            packageIdsFromConfig(
                JSONObject(target.readText(Charsets.UTF_8)),
                enforcePriceId = false,
                enforceKeywordUniqueness = false
            )
        } catch (_: Exception) {
            val previous = target.takeIf { it.exists() }?.readText(Charsets.UTF_8).orEmpty()
            if (previous.isNotEmpty()) {
                val backup = file(context, "packages.json.recovery-${System.currentTimeMillis()}.bak")
                atomicWrite(backup, previous)
            }
            val fallback = defaultContent?.takeIf { it.isNotBlank() }
                ?: "{\"schemaVersion\":1,\"packages\":[{\"id\":\"500\",\"price\":500,\"label\":\"500\",\"keywords\":[\"500\",\"خمس\"]},{\"id\":\"300\",\"price\":300,\"label\":\"300\",\"keywords\":[\"300\",\"ثلاثمائة\"]},{\"id\":\"3000\",\"price\":3000,\"label\":\"3000\",\"keywords\":[\"3000\",\"ثلاثة آلاف\"]},{\"id\":\"200\",\"price\":200,\"label\":\"200\",\"keywords\":[\"200\",\"مئتان\"]}]}"
            atomicWrite(target, fallback)
        }
    }

    private fun atomicWrite(target: File, content: String) {
        target.parentFile?.mkdirs()
        val temp = File(target.parentFile, target.name + ".tmp")
        FileOutputStream(temp).use { stream ->
            stream.write(content.toByteArray(Charsets.UTF_8))
            stream.fd.sync()
        }
        if (!temp.renameTo(target)) {
            try {
                FileOutputStream(target).use { stream ->
                    stream.write(content.toByteArray(Charsets.UTF_8))
                    stream.fd.sync()
                }
                temp.delete()
            } catch (error: Exception) {
                temp.delete()
                throw error
            }
        }
    }

    /** Write-ahead journal rolls back multi-file updates after an exception or process restart. */
    private fun writeBatch(
        context: Context,
        replacements: Map<String, String>,
        appends: Map<String, String> = emptyMap(),
        verify: (() -> Unit)? = null
    ) {
        val writes = replacements.toMutableMap()
        if (replacements.keys.any { it.matches(Regex("cards_[A-Za-z0-9_-]{1,24}\\.txt")) } &&
            !replacements.containsKey("inventory_undo.json")) {
            writes["inventory_undo.json"] = "{}"
        }
        val oldFiles = JSONObject()
        writes.keys.forEach { name ->
            val target = file(context, name)
            oldFiles.put(name, JSONObject().put("exists", target.exists()).put("content", if (target.exists()) target.readText(Charsets.UTF_8) else ""))
        }
        val appendLengths = JSONObject()
        appends.keys.forEach { name ->
            val target = file(context, name)
            appendLengths.put(name, JSONObject().put("exists", target.exists()).put("length", if (target.exists()) target.length() else 0L))
        }
        val journal = JSONObject().put("oldFiles", oldFiles).put("appendLengths", appendLengths)
        val journalFile = file(context, JOURNAL_NAME)
        atomicWrite(journalFile, journal.toString())
        try {
            writes.forEach { (name, content) -> atomicWrite(file(context, name), content) }
            appends.forEach { (name, content) -> file(context, name).appendText(content, Charsets.UTF_8) }
            verify?.invoke()
            journalFile.delete()
        } catch (e: Exception) {
            rollback(journal, context)
            journalFile.delete()
            throw e
        }
    }

    private fun rollback(journal: JSONObject, context: Context) {
        val oldFiles = journal.optJSONObject("oldFiles") ?: JSONObject()
        val keys = oldFiles.keys()
        while (keys.hasNext()) {
            val name = keys.next()
            val state = oldFiles.optJSONObject(name) ?: continue
            val target = file(context, name)
            if (state.optBoolean("exists")) atomicWrite(target, state.optString("content")) else target.delete()
        }
        val appendLengths = journal.optJSONObject("appendLengths") ?: JSONObject()
        val appendKeys = appendLengths.keys()
        while (appendKeys.hasNext()) {
            val name = appendKeys.next()
            val state = appendLengths.optJSONObject(name) ?: continue
            val target = file(context, name)
            if (state.optBoolean("exists")) {
                if (target.exists()) RandomAccessFile(target, "rw").use { it.setLength(state.optLong("length")) }
            } else target.delete()
        }
    }

    private fun recoverPendingTransaction(context: Context) {
        val pending = file(context, JOURNAL_NAME)
        if (!pending.exists()) return
        val journal = try { JSONObject(pending.readText(Charsets.UTF_8)) } catch (e: Exception) {
            throw IllegalStateException("تعذر قراءة سجل استعادة العملية؛ لم تُحذف البيانات: ${e.message}")
        }
        rollback(journal, context)
        pending.delete()
    }

    private fun json(context: Context, name: String, fallback: String): JSONObject = try {
        JSONObject(text(context, name).ifBlank { fallback })
    } catch (_: Exception) {
        JSONObject(fallback)
    }

    private fun ledger(context: Context): JSONObject = json(context, LEDGER_NAME, "{\"schemaVersion\":1,\"transactions\":[]}")
    private fun transactions(context: Context): JSONArray = ledger(context).optJSONArray("transactions") ?: JSONArray()
    private fun ledgerContent(entries: JSONArray): String = JSONObject().put("schemaVersion", 1).put("transactions", entries).toString()

    private fun newEntry(
        type: String,
        phone: String,
        amount: Long,
        delta: Long,
        paymentMethod: String = "",
        packageId: String = "",
        clientName: String = "",
        reference: String = "",
        note: String = "",
        createdAt: String = isoNow(),
        affectsBalance: Boolean = true
    ): JSONObject = JSONObject()
        .put("id", UUID.randomUUID().toString())
        .put("type", type)
        .put("phone", phone.trim())
        .put("clientName", clientName.trim())
        .put("amount", amount)
        .put("delta", delta)
        .put("affectsBalance", affectsBalance)
        .put("paymentMethod", paymentMethod)
        .put("packageId", packageId)
        .put("reference", reference.trim())
        .put("note", note.trim())
        .put("createdAt", createdAt)

    private fun legacyTimestamp(value: String): String = try {
        val parsed = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).parse(value.trim()) ?: Date()
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US).format(parsed)
    } catch (_: Exception) { isoNow() }

    /** Preserve known old sales as informational history and the current debt as one opening entry. */
    private fun migrateLegacyLedger(context: Context) {
        val entries = JSONArray()
        val openingTime = isoNow()
        text(context, "debts.txt").lineSequence().filter { it.contains('|') }.forEach { line ->
            val parts = line.split('|', limit = 2)
            val phone = parts[0].trim()
            val balance = parts.getOrNull(1)?.toLongOrNull() ?: 0L
            if (phone.isNotEmpty() && balance != 0L) {
                entries.put(newEntry("opening_balance", phone, kotlin.math.abs(balance), balance, note = "الرصيد المرحّل عند تفعيل دفتر الحركات", createdAt = openingTime))
            }
        }
        text(context, "sales.log").lineSequence().filter { it.isNotBlank() }.forEach { line ->
            val parts = line.split(" | ")
            if (parts.size >= 4 && parts[2].isNotBlank()) {
                val price = parts.getOrNull(1)?.toLongOrNull() ?: 0L
                val method = parts.getOrNull(5) ?: "credit"
                val packageId = packageIds(context).firstOrNull { it == price.toString() } ?: ""
                entries.put(newEntry("legacy_sale", parts[2], price, 0L, paymentMethod = method, packageId = packageId,
                    note = "عملية تاريخية مستوردة؛ لا تؤثر على الرصيد الافتتاحي", createdAt = legacyTimestamp(parts[0]), affectsBalance = false))
            }
        }
        atomicWrite(file(context, LEDGER_NAME), ledgerContent(entries))
        val balances = balancesFrom(entries)
        atomicWrite(file(context, "debts.txt"), debtText(balances, entries))
    }

    private fun ensureCounters(context: Context) {
        val trigger = json(context, "trigger_config.json", "{\"triggerEnabled\":true,\"processedCount\":0,\"errorCount\":0}")
        if (!trigger.has("totalSalesCount")) {
            trigger.put("totalSalesCount", text(context, "sales.log").lineSequence().count { it.isNotBlank() })
            atomicWrite(file(context, "trigger_config.json"), trigger.toString())
        }
    }

    private fun phoneKey(phone: String): String {
        var digits = buildString {
            phone.forEach { char ->
                when (char) {
                    in '٠'..'٩' -> append('0' + (char - '٠'))
                    in '۰'..'۹' -> append('0' + (char - '۰'))
                    in '0'..'9' -> append(char)
                }
            }
        }
        if (digits.startsWith("00967")) digits = digits.drop(5)
        else if (digits.startsWith("967")) digits = digits.drop(3)
        digits = digits.trimStart('0')
        return digits.takeLast(10)
    }

    private fun balancesFrom(entries: JSONArray): MutableMap<String, Long> {
        val balances = linkedMapOf<String, Long>()
        for (i in 0 until entries.length()) {
            val entry = entries.optJSONObject(i) ?: continue
            if (!entry.optBoolean("affectsBalance", true)) continue
            val key = phoneKey(entry.optString("phone"))
            if (key.isNotEmpty()) balances[key] = (balances[key] ?: 0L) + entry.optLong("delta", 0L)
        }
        return balances
    }

    private fun latestPhones(entries: JSONArray): Map<String, String> {
        val result = linkedMapOf<String, String>()
        for (i in 0 until entries.length()) {
            val raw = entries.optJSONObject(i)?.optString("phone").orEmpty()
            val key = phoneKey(raw)
            if (key.isNotEmpty()) result[key] = raw
        }
        return result
    }

    private fun debtText(balances: Map<String, Long>, entries: JSONArray): String {
        val phones = latestPhones(entries)
        return balances.entries.filter { it.value != 0L }.joinToString("\n") { (key, amount) -> "${phones[key] ?: key}|$amount" }.let { if (it.isEmpty()) "" else "$it\n" }
    }

    private fun debtMap(context: Context): MutableMap<String, Long> = balancesFrom(transactions(context))
    private fun currentBalance(context: Context, phone: String): Long = debtMap(context)[phoneKey(phone)] ?: 0L

    private fun clientConfig(context: Context, phone: String): JSONObject? {
        val clients = json(context, "permissions.json", "{\"clients\":[]}").optJSONArray("clients") ?: return null
        return (0 until clients.length()).mapNotNull { clients.optJSONObject(it) }
            .firstOrNull { phoneKey(it.optString("phone")) == phoneKey(phone) }
    }

    fun trustedPhoneForWhatsAppLabel(context: Context, label: String): String? = synchronized(lock) {
        val wanted = label.trim().lowercase(Locale.ROOT).replace(Regex("\\s+"), " ")
        if (wanted.length < 2) return@synchronized null
        val clients = json(context, "trusted_clients.json", "{\"clients\":[]}").optJSONArray("clients") ?: return@synchronized null
        val matches = (0 until clients.length()).mapNotNull { clients.optJSONObject(it) }
            .filter { it.optString("name").trim().lowercase(Locale.ROOT).replace(Regex("\\s+"), " ") == wanted }
            .map { it.optString("phone").trim() }
            .filter { phoneKey(it).length >= 7 }
            .distinctBy { phoneKey(it) }
        matches.singleOrNull()
    }

    fun isWhatsAppAutoReplyEnabled(context: Context): Boolean = synchronized(lock) {
        val trigger = json(context, "trigger_config.json", "{\"triggerEnabled\":true}")
        trigger.optBoolean("triggerEnabled", true) && trigger.optBoolean("whatsappAutoReplyEnabled", false)
    }

    private fun customerName(context: Context, phone: String): String {
        val configured = clientConfig(context, phone)?.optString("name")?.trim().orEmpty()
        if (configured.isNotEmpty()) return configured
        val clients = json(context, "trusted_clients.json", "{\"clients\":[]}").optJSONArray("clients") ?: return ""
        return (0 until clients.length()).mapNotNull { clients.optJSONObject(it) }
            .firstOrNull { phoneKey(it.optString("phone")) == phoneKey(phone) }
            ?.optString("name")?.trim().orEmpty()
    }

    private fun effectivePrice(context: Context, phone: String, item: JSONObject): Int {
        val id = item.optString("id")
        val basePrice = item.optInt("price", id.toIntOrNull() ?: 0)
        val permissions = json(context, "permissions.json", "{\"global\":{},\"clients\":[]}")
        val client = clientConfig(context, phone)
        client?.optJSONObject("packagePrices")?.let { prices ->
            if (prices.has(id)) return prices.optInt(id, basePrice).coerceAtLeast(1)
        }
        val global = permissions.optJSONObject("global") ?: JSONObject()
        val groupId = client?.optString("priceGroup").orEmpty()
        val groups = global.optJSONArray("priceGroups") ?: JSONArray()
        val group = (0 until groups.length()).mapNotNull { groups.optJSONObject(it) }
            .firstOrNull { it.optString("id") == groupId }
        group?.optJSONObject("packagePrices")?.let { prices ->
            if (prices.has(id)) return prices.optInt(id, basePrice).coerceAtLeast(1)
        }
        val customerDiscount = client?.optDouble("discountPercent", Double.NaN)
            ?.takeIf { it.isFinite() && it in 0.0..100.0 }
        val groupDiscount = group?.optDouble("discountPercent", Double.NaN)
            ?.takeIf { it.isFinite() && it in 0.0..100.0 }
        val discount = customerDiscount ?: groupDiscount ?: return basePrice
        return kotlin.math.round(basePrice * (100.0 - discount) / 100.0).toInt().coerceAtLeast(1)
    }

    private fun renderTemplate(context: Context, key: String, defaultText: String, values: Map<String, String>): String {
        val trigger = json(context, "trigger_config.json", "{}")
        val template = trigger.optJSONObject("templates")?.optString(key)?.takeIf { it.isNotBlank() } ?: defaultText
        return values.entries.fold(template) { current, (name, value) -> current.replace("{$name}", value) }
    }

    private fun recordRequestEvent(context: Context, reason: String, phone: String, detail: String = "") {
        val trigger = json(context, "trigger_config.json", "{\"triggerEnabled\":true}")
        val events = trigger.optJSONArray("events") ?: JSONArray()
        for (index in 0 until events.length()) {
            events.optJSONObject(index)?.let { oldEvent ->
                oldEvent.remove("phone")
                if (oldEvent.has("detail")) {
                    oldEvent.put("detail", redactDiagnosticNumbers(oldEvent.optString("detail")))
                }
            }
        }
        events.put(JSONObject().put("time", isoNow()).put("reason", reason)
            .put("detail", redactDiagnosticNumbers(detail).take(180)))
        while (events.length() > 20) events.remove(0)
        trigger.put("events", events)
        trigger.put("lastEventAt", isoNow())
        trigger.put("lastEventReason", reason)
        atomicWrite(file(context, "trigger_config.json"), trigger.toString())
    }

    private fun recordSmsFailure(context: Context, phone: String, error: String) {
        val trigger = json(context, "trigger_config.json", "{\"errorCount\":0}")
        trigger.put("errorCount", trigger.optInt("errorCount", 0) + 1)
        trigger.put("lastSmsError", "تعذر إرسال الرسالة؛ تحقق من أذونات SMS والشريحة.")
        trigger.put("lastSmsErrorAt", isoNow())
        val events = trigger.optJSONArray("events") ?: JSONArray()
        for (index in 0 until events.length()) {
            events.optJSONObject(index)?.let { oldEvent ->
                oldEvent.remove("phone")
                if (oldEvent.has("detail")) {
                    oldEvent.put("detail", redactDiagnosticNumbers(oldEvent.optString("detail")))
                }
            }
        }
        events.put(JSONObject().put("time", isoNow()).put("reason", "sms_send_failed").put("detail", "تعذر إرسال الرسالة؛ تحقق من أذونات SMS والشريحة."))
        while (events.length() > 20) events.remove(0)
        trigger.put("events", events)
        atomicWrite(file(context, "trigger_config.json"), trigger.toString())
    }

    private fun redactDiagnosticNumbers(value: String): String = value.replace(
        Regex("(?<![0-9٠-٩۰-۹])(?:\\+|00)?[0-9٠-٩۰-۹][0-9٠-٩۰-۹\\s()\\-]{6,}[0-9٠-٩۰-۹](?![0-9٠-٩۰-۹])"),
        "[رقم مخفي]"
    )

    private fun sanitizeDiagnosticHistory(context: Context) {
        val triggerFile = file(context, "trigger_config.json")
        if (!triggerFile.exists()) return
        val trigger = json(context, "trigger_config.json", "{}")
        val events = trigger.optJSONArray("events") ?: JSONArray()
        for (index in 0 until events.length()) {
            events.optJSONObject(index)?.let { event ->
                event.remove("phone")
                if (event.has("detail")) {
                    event.put("detail", redactDiagnosticNumbers(event.optString("detail")))
                }
            }
        }
        while (events.length() > 20) events.remove(0)
        trigger.put("events", events)
        if (trigger.has("lastSmsError")) {
            trigger.put("lastSmsError", "تعذر إرسال الرسالة؛ تحقق من أذونات SMS والشريحة.")
        }
        atomicWrite(triggerFile, trigger.toString())
    }

    private fun sendWhatsAppReply(
        context: Context,
        phone: String,
        message: String,
        callback: (String) -> Boolean
    ): Boolean {
        val trigger = json(context, "trigger_config.json", "{}")
        val now = System.currentTimeMillis()
        val recent = JSONArray()
        val stored = trigger.optJSONArray("whatsappReplyTimes") ?: JSONArray()
        for (index in 0 until stored.length()) {
            val timestamp = stored.optLong(index, 0L)
            if (timestamp > 0L && now - timestamp in 0L..WHATSAPP_REPLY_WINDOW_MS) {
                recent.put(timestamp)
            }
        }
        if (recent.length() >= WHATSAPP_REPLY_LIMIT) {
            trigger.put("whatsappReplyTimes", recent)
            atomicWrite(file(context, "trigger_config.json"), trigger.toString())
            recordRequestEvent(context, "whatsapp_rate_limited", phone, "تم بلوغ حد الردود المؤقت؛ ستُعاد المحاولة لاحقًا")
            return false
        }
        recent.put(now)
        trigger.put("whatsappReplyTimes", recent)
        atomicWrite(file(context, "trigger_config.json"), trigger.toString())
        val sent = try { callback(message) } catch (_: Exception) { false }
        if (!sent) recordRequestEvent(context, "whatsapp_reply_failed", phone, "تعذر تنفيذ الرد من إشعار WhatsApp")
        return sent
    }

    fun snapshot(context: Context): Map<String, Any?> = synchronized(lock) {
        val entries = transactions(context)
        val inventory = JSONObject()
        packageIds(context).forEach { id -> inventory.put(id, JSONArray(text(context, "cards_$id.txt").lineSequence().map { it.trim() }.filter { it.isNotEmpty() }.toList())) }
        val lowStockWarnings = JSONArray()
        val packageList = packages(context)
        for (index in 0 until packageList.length()) {
            val item = packageList.optJSONObject(index) ?: continue
            val id = item.optString("id")
            val threshold = item.optInt("minStock", 0).coerceAtLeast(0)
            val count = inventory.optJSONArray(id)?.length() ?: 0
            if (threshold > 0 && count <= threshold) {
                lowStockWarnings.put(JSONObject().put("packageId", id).put("count", count).put("threshold", threshold))
            }
        }
        val debts = JSONArray()
        val balances = balancesFrom(entries)
        val phones = latestPhones(entries)
        balances.forEach { (key, amount) -> if (amount != 0L) debts.put(JSONObject().put("phone", phones[key] ?: key).put("amount", amount)) }
        val sales = JSONArray()
        val transactionsById = (0 until entries.length()).mapNotNull { entries.optJSONObject(it) }
            .associateBy { it.optString("id") }
        text(context, "sales.log").lineSequence().filter { it.isNotBlank() }.toList().takeLast(1000).forEach { line ->
            val parts = line.split(" | ")
            if (parts.size >= 5) {
                val transactionId = parts.getOrNull(7).orEmpty()
                val transaction = transactionsById[transactionId]
                sales.put(JSONObject()
                    .put("time", parts[0])
                    .put("packageId", parts.getOrNull(6) ?: parts[1])
                    .put("price", parts[1].toLongOrNull() ?: 0L)
                    .put("phone", parts[2])
                    .put("card", parts[3])
                    .put("debt", parts[4].toLongOrNull() ?: 0L)
                    .put("paymentMethod", parts.getOrNull(5) ?: "credit")
                    .put("transactionId", transactionId)
                    .put("receiptConfirmedAt", transaction?.optString("receiptConfirmedAt", "") ?: "")
                    .put("whatsappStatus", transaction?.optString("whatsappStatus", "") ?: "")
                    .put("returnedAt", transaction?.optString("returnedAt", "") ?: "")
                    .put("returnReason", transaction?.optString("returnReason", "") ?: ""))
            }
        }
        transactionsById.values.filter { it.optString("type").startsWith("manual_sale_") }.takeLast(1000).forEach { transaction ->
            sales.put(JSONObject()
                .put("time", transaction.optString("createdAt"))
                .put("saleSource", "manual")
                .put("description", transaction.optString("description", transaction.optString("note")))
                .put("quantity", transaction.optInt("quantity", 1))
                .put("unitPrice", transaction.optLong("unitPrice", transaction.optLong("amount")))
                .put("unitCost", transaction.optLong("unitCost", 0L))
                .put("profit", transaction.optLong("profit", 0L))
                .put("packageId", "بيع يدوي")
                .put("price", transaction.optLong("amount"))
                .put("phone", transaction.optString("phone"))
                .put("clientName", transaction.optString("clientName"))
                .put("card", "")
                .put("debt", transaction.optLong("balanceAfter", balances[phoneKey(transaction.optString("phone"))] ?: 0L))
                .put("balanceBefore", transaction.optLong("balanceBefore", 0L))
                .put("paymentMethod", transaction.optString("paymentMethod", "cash"))
                .put("transactionId", transaction.optString("id")))
        }
        mapOf(
            "inventory" to inventory.toMapSafe(),
            "debts" to debts.toListSafe(),
            "sales" to sales.toListSafe(),
            "transactions" to entries.toListSafe(),
            "lowStockWarnings" to lowStockWarnings.toListSafe(),
            "packages" to json(context, "packages.json", "{\"packages\":[]}").toMapSafe(),
            "permissions" to json(context, "permissions.json", "{\"global\":{},\"clients\":[]}").toMapSafe(),
            "trigger" to json(context, "trigger_config.json", "{\"triggerEnabled\":true}").toMapSafe(),
            "trusted" to json(context, "trusted_clients.json", "{\"filterEnabled\":false,\"clients\":[]}").toMapSafe(),
            "dataPath" to directory(context).absolutePath
        )
    }

    /** Small status read for the foreground service; deliberately does not load inventory or sales history. */
    fun statusSnapshot(context: Context): Map<String, Any?> = synchronized(lock) {
        val trigger = json(context, "trigger_config.json", "{\"triggerEnabled\":true}")
        val packageList = packages(context)
        val lowStockCount = (0 until packageList.length()).count { index ->
            val item = packageList.optJSONObject(index) ?: return@count false
            val threshold = item.optInt("minStock", 0)
            threshold > 0 && text(context, "cards_${item.optString("id")}.txt").lineSequence().count { it.isNotBlank() } <= threshold
        }
        mapOf(
            "triggerEnabled" to trigger.optBoolean("triggerEnabled", true),
            "processedCount" to trigger.optInt("processedCount", 0),
            "totalSalesCount" to trigger.optInt("totalSalesCount", 0),
            "errorCount" to trigger.optInt("errorCount", 0),
            "lastRun" to trigger.optString("lastRun", ""),
            "lastSmsError" to trigger.optString("lastSmsError", ""),
            "events" to (trigger.optJSONArray("events") ?: JSONArray()).toListSafe(),
            "lowStockCount" to lowStockCount
        )
    }

    fun serviceDiagnostics(context: Context, serviceRunning: Boolean): Map<String, Any?> {
        val telephony = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val notificationPermission = Build.VERSION.SDK_INT < 33 ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        val smsPermission = context.checkSelfPermission(Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED
        val receivePermission = context.checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED &&
            context.checkSelfPermission(Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED
        val simState = runCatching { telephony?.simState ?: TelephonyManager.SIM_STATE_UNKNOWN }
            .getOrDefault(TelephonyManager.SIM_STATE_UNKNOWN)
        return mapOf(
            "serviceRunning" to serviceRunning,
            "triggerEnabled" to json(context, "trigger_config.json", "{}").optBoolean("triggerEnabled", true),
            "whatsappAutoReplyEnabled" to json(context, "trigger_config.json", "{}").optBoolean("whatsappAutoReplyEnabled", false),
            "sendSmsPermission" to smsPermission,
            "receiveSmsPermission" to receivePermission,
            "notificationPermission" to notificationPermission,
            "simReady" to (simState == TelephonyManager.SIM_STATE_READY),
            "simState" to simState,
            "batteryOptimizationIgnored" to (power?.isIgnoringBatteryOptimizations(context.packageName) ?: false),
            "diagnosedAt" to isoNow()
        )
    }

    private fun Any?.toBackupJsonValue(): Any = when (this) {
        null -> JSONObject.NULL
        is Map<*, *> -> JSONObject().also { target ->
            this.entries.forEach { (key, value) -> target.put(key.toString(), value.toBackupJsonValue()) }
        }
        is Iterable<*> -> JSONArray().also { target -> this.forEach { target.put(it.toBackupJsonValue()) } }
        else -> this
    }

    private fun JSONObject.toMapSafe(): Map<String, Any?> = keys().asSequence().associateWith { key ->
        when (val value = opt(key)) {
            JSONObject.NULL -> null
            is JSONObject -> value.toMapSafe()
            is JSONArray -> value.toListSafe()
            else -> value
        }
    }

    private fun JSONArray.toListSafe(): List<Any?> = (0 until length()).map { index ->
        when (val value = opt(index)) {
            JSONObject.NULL -> null
            is JSONObject -> value.toMapSafe()
            is JSONArray -> value.toListSafe()
            else -> value
        }
    }

    fun saveConfig(context: Context, name: String, content: String) = synchronized(lock) {
        require(allowedConfigs.contains(name)) { "اسم ملف الإعدادات غير مسموح" }
        val parsed = JSONObject(content)
        if (name != "packages.json") {
            atomicWrite(file(context, name), content)
            return@synchronized
        }
        val savedConfig = JSONObject(text(context, "packages.json"))
        val requestedIds = packageIdsFromConfig(parsed, enforcePriceId = false)
        validatePackagePriceIds(parsed, savedConfig)
        val previousIds = packageIdsFromConfig(savedConfig, enforcePriceId = false, enforceKeywordUniqueness = false)
        require(previousIds.all { it in requestedIds }) {
            "لحذف أو تغيير معرّف باقة استخدم مسار التغيير الآمن؛ لم تُحذف أي بيانات"
        }
        val addedIds = requestedIds - previousIds
        Log.i("CardBotPackages", "save start old=${previousIds.size} new=${requestedIds.size} added=${addedIds.size}")
        val updates = linkedMapOf("packages.json" to parsed.toString())
        try {
            if (addedIds.isNotEmpty()) {
                val permissions = json(context, "permissions.json", "{\"global\":{},\"clients\":[]}")
                val global = permissions.optJSONObject("global") ?: JSONObject()
                val allowed = global.optJSONArray("allowedPackages") ?: JSONArray()
                val existing = (0 until allowed.length()).map { allowed.optString(it) }.toMutableSet()
                addedIds.forEach { id -> if (existing.add(id)) allowed.put(id) }
                global.put("allowedPackages", allowed)
                permissions.put("global", global)
                updates["permissions.json"] = permissions.toString()
                addedIds.forEach { id ->
                    require(!file(context, "cards_$id.txt").exists() || text(context, "cards_$id.txt").isBlank()) {
                        "يوجد ملف مخزون غير فارغ للمعرّف $id؛ أوقفنا الحفظ لمنع استبدال كروت موجودة"
                    }
                    updates["cards_$id.txt"] = ""
                }
            }
            writeBatch(context, updates, verify = {
                val persisted = JSONObject(text(context, "packages.json"))
                check(packageIdsFromConfig(persisted, enforcePriceId = false) == requestedIds) { "لم تتطابق قائمة الباقات بعد إعادة قراءتها من التخزين" }
                validatePackagePriceIds(persisted, savedConfig)
                addedIds.forEach { id -> check(file(context, "cards_$id.txt").exists()) { "لم يُنشأ ملف مخزون الباقة $id" } }
            })
            Log.i("CardBotPackages", "save success packages=${requestedIds.size} added=${addedIds.size}")
        } catch (error: Exception) {
            Log.e("CardBotPackages", "save failed stage=validate_or_commit old=${previousIds.size} new=${requestedIds.size} added=${addedIds.size} reason=${error.message}", error)
            throw error
        }
    }

    fun updatePackagePrice(context: Context, oldPackageId: String, content: String): Map<String, Any?> = synchronized(lock) {
        val parsed = JSONObject(content)
        val currentConfig = JSONObject(text(context, "packages.json"))
        val newIds = packageIdsFromConfig(parsed, enforcePriceId = false)
        validatePackagePriceIds(parsed, currentConfig)
        val oldIds = packageIdsFromConfig(currentConfig, enforcePriceId = false, enforceKeywordUniqueness = false)
        require(oldPackageId in oldIds) { "الباقة الأصلية $oldPackageId غير موجودة؛ لم يُجرَ أي تغيير" }
        val removed = oldIds - newIds
        val added = newIds - oldIds
        require(removed == setOf(oldPackageId) && added.size == 1) {
            "طلب تغيير السعر يجب أن يستبدل باقة واحدة فقط؛ لم يُجرَ أي تغيير"
        }
        val newId = added.single()
        require(oldPackageId != newId) { "لم يتغير معرّف الباقة" }
        val sourceStock = file(context, "cards_$oldPackageId.txt")
        val destinationStock = file(context, "cards_$newId.txt")
        val oldStockContent = if (sourceStock.exists()) sourceStock.readText(Charsets.UTF_8) else ""
        val destinationContent = if (destinationStock.exists()) destinationStock.readText(Charsets.UTF_8) else ""
        require(destinationContent.lineSequence().none { it.isNotBlank() }) {
            "مخزون الباقة $newId موجود وغير فارغ؛ لم نكتب فوقه ولم ننقل البيانات"
        }

        val permissions = json(context, "permissions.json", "{\"global\":{},\"clients\":[]}")
        val global = permissions.optJSONObject("global") ?: JSONObject()
        global.optJSONArray("allowedPackages")?.let { global.put("allowedPackages", replaceId(it, oldPackageId, newId)) }
        permissions.put("global", global)
        val clients = permissions.optJSONArray("clients") ?: JSONArray()
        for (index in 0 until clients.length()) {
            clients.optJSONObject(index)?.optJSONArray("allowedPackages")?.let { allowed ->
                clients.optJSONObject(index)?.put("allowedPackages", replaceId(allowed, oldPackageId, newId))
            }
        }
        val replacements = linkedMapOf(
            "packages.json" to parsed.toString(),
            "permissions.json" to permissions.toString(),
            "cards_$oldPackageId.txt" to "",
            "cards_$newId.txt" to oldStockContent
        )
        Log.i("CardBotPackages", "price change start old=$oldPackageId new=$newId stockLines=${oldStockContent.lineSequence().count { it.isNotBlank() }}")
        try {
            writeBatch(context, replacements, verify = {
                val persisted = JSONObject(text(context, "packages.json"))
                check(packageIdsFromConfig(persisted, enforcePriceId = false) == newIds) { "قائمة الباقات بعد النقل لم تجتز التحقق" }
                validatePackagePriceIds(persisted, currentConfig)
                check(file(context, "cards_$oldPackageId.txt").readText(Charsets.UTF_8).isBlank()) { "مخزون المعرّف القديم لم يُفرغ" }
                check(file(context, "cards_$newId.txt").readText(Charsets.UTF_8) == oldStockContent) { "لم يطابق المخزون المنقول الملف الجديد" }
            })
            Log.i("CardBotPackages", "price change success old=$oldPackageId new=$newId historical ledgers preserved")
        } catch (error: Exception) {
            Log.e("CardBotPackages", "price change failed old=$oldPackageId new=$newId reason=${error.message}", error)
            throw error
        }
        snapshot(context)
    }

    private fun replaceId(source: JSONArray, oldId: String, newId: String): JSONArray {
        val result = JSONArray()
        val seen = linkedSetOf<String>()
        for (index in 0 until source.length()) {
            val value = source.optString(index)
            val replaced = if (value == oldId) newId else value
            if (seen.add(replaced)) result.put(replaced)
        }
        return result
    }

    private fun validatePackagePriceIds(requested: JSONObject, previous: JSONObject) {
        val oldPackages = previous.optJSONArray("packages") ?: JSONArray()
        val oldById = (0 until oldPackages.length()).mapNotNull { oldPackages.optJSONObject(it) }
            .associateBy { it.optString("id").trim() }
        val requestedPackages = requested.optJSONArray("packages") ?: JSONArray()
        for (index in 0 until requestedPackages.length()) {
            val item = requestedPackages.optJSONObject(index) ?: continue
            val id = item.optString("id").trim()
            val price = item.optLong("price", 0L)
            if (id == price.toString()) continue
            val original = oldById[id]
            require(original != null && samePackageDefinition(original, item)) {
                "معرّف الباقة يجب أن يساوي سعرها ($id ≠ $price). عدّل الباقة من واجهتها لنقل المخزون والسماحات بأمان؛ لم تُحفظ أي تغييرات."
            }
        }
    }

    private fun samePackageDefinition(first: JSONObject, second: JSONObject): Boolean {
        val firstKeys = first.keys().asSequence().toSet()
        val secondKeys = second.keys().asSequence().toSet()
        if (firstKeys != secondKeys) return false
        return firstKeys.all { key ->
            (first.opt(key)?.toString() ?: "null") == (second.opt(key)?.toString() ?: "null")
        }
    }

    fun deletePackage(context: Context, packageId: String): Map<String, Any?> = synchronized(lock) {
        require(packageIdPattern.matches(packageId) && packageId in packageIds(context)) { "الباقة غير موجودة" }
        val config = json(context, "packages.json", "{\"packages\":[]}")
        val current = config.optJSONArray("packages") ?: JSONArray()
        val remaining = JSONArray()
        for (index in 0 until current.length()) {
            val item = current.optJSONObject(index) ?: continue
            if (item.optString("id") != packageId) remaining.put(item)
        }
        require(remaining.length() > 0) { "لا يمكن حذف آخر باقة؛ أضف باقة أخرى أولاً" }
        val permissions = json(context, "permissions.json", "{\"global\":{},\"clients\":[]}")
        val global = permissions.optJSONObject("global") ?: JSONObject()
        global.optJSONArray("allowedPackages")?.let { global.put("allowedPackages", filteredIds(it, packageId)) }
        permissions.put("global", global)
        val clients = permissions.optJSONArray("clients") ?: JSONArray()
        for (index in 0 until clients.length()) {
            val client = clients.optJSONObject(index) ?: continue
            client.optJSONArray("allowedPackages")?.let { client.put("allowedPackages", filteredIds(it, packageId)) }
        }
        config.put("packages", remaining)
        writeBatch(context, mapOf(
            "packages.json" to config.toString(),
            "permissions.json" to permissions.toString(),
            "cards_$packageId.txt" to ""
        ))
        snapshot(context)
    }

    /**
     * تراجع ذري قصير العمر: يستعيد تعريف الباقة والبطاقات والصلاحيات السابقة.
     * يرفض التنفيذ إذا أُعيد إنشاء الباقة أو أُضيف مخزون جديد بعد الحذف.
     */
    fun restoreDeletedPackage(
        context: Context,
        packageId: String,
        originalPackagesJson: String,
        originalPermissionsJson: String,
        cards: List<String>
    ): Map<String, Any?> = synchronized(lock) {
        require(packageIdPattern.matches(packageId)) { "معرّف الباقة غير صالح" }
        val originalPackages = JSONObject(originalPackagesJson)
        val originalItems = originalPackages.optJSONArray("packages") ?: JSONArray()
        val definition = (0 until originalItems.length())
            .mapNotNull { originalItems.optJSONObject(it) }
            .firstOrNull { it.optString("id") == packageId }
            ?: throw IllegalArgumentException("تعذر العثور على تعريف الباقة الأصلي")

        val currentPackages = json(context, "packages.json", "{\"packages\":[]}")
        val currentItems = currentPackages.optJSONArray("packages") ?: JSONArray()
        require((0 until currentItems.length()).none {
            currentItems.optJSONObject(it)?.optString("id") == packageId
        }) { "أُعيد إنشاء الباقة بالفعل؛ لم يُستبدل أي مخزون" }

        val cardFile = file(context, "cards_$packageId.txt")
        require(!cardFile.exists() || cardFile.readLines(Charsets.UTF_8).all { it.isBlank() }) {
            "يوجد مخزون جديد لهذه الباقة؛ لم تتم الكتابة فوقه"
        }
        val cleanCards = cards.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        require(cleanCards.size == cards.size && cleanCards.none {
            it.contains('\n') || it.contains('\r')
        }) { "قائمة البطاقات الأصلية غير صالحة للاستعادة" }

        val currentPermissions = json(context, "permissions.json", "{\"global\":{},\"clients\":[]}")
        val originalPermissions = JSONObject(originalPermissionsJson)
        val currentGlobal = currentPermissions.optJSONObject("global") ?: JSONObject()
        val originalGlobal = originalPermissions.optJSONObject("global") ?: JSONObject()
        mergeAllowedPackage(currentGlobal, originalGlobal, packageId)

        val currentClients = currentPermissions.optJSONArray("clients") ?: JSONArray()
        val originalClients = originalPermissions.optJSONArray("clients") ?: JSONArray()
        val originalByPhone = (0 until originalClients.length())
            .mapNotNull { originalClients.optJSONObject(it) }
            .associateBy { it.optString("phone") }
        for (index in 0 until currentClients.length()) {
            val client = currentClients.optJSONObject(index) ?: continue
            originalByPhone[client.optString("phone")]?.let { originalClient ->
                mergeAllowedPackage(client, originalClient, packageId)
            }
        }
        currentPackages.put("packages", currentItems.put(definition))
        currentPermissions.put("global", currentGlobal)

        val restoredCards = if (cleanCards.isEmpty()) "" else cleanCards.joinToString("\n", postfix = "\n")
        writeBatch(
            context,
            mapOf(
                "packages.json" to currentPackages.toString(),
                "permissions.json" to currentPermissions.toString(),
                "cards_$packageId.txt" to restoredCards
            )
        )
        snapshot(context)
    }

    /** يعيد سماح الباقة المحذوفة فقط، ويحافظ على أي تعديلات أحدث لبقية القوائم. */
    private fun mergeAllowedPackage(current: JSONObject, original: JSONObject, packageId: String) {
        val originalAllowed = original.optJSONArray("allowedPackages") ?: return
        if ((0 until originalAllowed.length()).none { originalAllowed.optString(it) == packageId }) return
        val currentAllowed = current.optJSONArray("allowedPackages") ?: return
        if ((0 until currentAllowed.length()).none { currentAllowed.optString(it) == packageId }) {
            currentAllowed.put(packageId)
        }
    }

    private fun filteredIds(values: JSONArray, removed: String): JSONArray {
        val output = JSONArray()
        for (index in 0 until values.length()) {
            val value = values.optString(index)
            if (value != removed) output.put(value)
        }
        return output
    }

    fun saveClientAndTrusted(context: Context, permissions: String, trusted: String) = synchronized(lock) {
        JSONObject(permissions)
        JSONObject(trusted)
        writeBatch(context, mapOf("permissions.json" to permissions, "trusted_clients.json" to trusted))
    }

    fun addCards(context: Context, packageId: String, cards: List<String>) = synchronized(lock) {
        require(packageIdPattern.matches(packageId) && packageId in packageIds(context)) { "الباقة غير معروفة" }
        val clean = cards.map { it.trim() }.filter { it.isNotEmpty() && !it.contains('\n') && !it.contains('\r') }.distinct()
        require(clean.isNotEmpty()) { "لا توجد أرقام بطاقات صالحة" }
        val target = file(context, "cards_$packageId.txt")
        val old = target.takeIf { it.exists() }?.readLines(Charsets.UTF_8)?.map { it.trim() }?.filter { it.isNotEmpty() }.orEmpty()
        val merged = (old + clean).distinct()
        writeBatch(
            context,
            mapOf("cards_$packageId.txt" to if (merged.isEmpty()) "" else merged.joinToString("\n", postfix = "\n"))
        )
    }

    fun updateInventory(context: Context, changesJson: String): Map<String, Any?> = synchronized(lock) {
        val changes = JSONArray(changesJson)
        require(changes.length() in 1..5000) { "حدد من بطاقة واحدة إلى 5000 بطاقة" }
        val ids = packageIds(context)
        val stock = ids.associateWith { id ->
            text(context, "cards_$id.txt").lineSequence().map { it.trim() }.filter { it.isNotEmpty() }.toMutableList()
        }.toMutableMap()
        val soldCards = text(context, "sales.log").lineSequence().mapNotNull { line ->
            line.split(" | ").getOrNull(3)?.takeIf { it.isNotBlank() }
        }.toSet()
        val changedIds = linkedSetOf<String>()
        val touched = mutableSetOf<String>()
        for (index in 0 until changes.length()) {
            val change = changes.optJSONObject(index) ?: throw IllegalArgumentException("بيانات إجراء المخزون غير صالحة")
            val action = change.optString("action")
            val sourceId = change.optString("packageId")
            val card = change.optString("card").trim()
            require(action in setOf("delete", "edit", "move")) { "إجراء مخزون غير معروف" }
            require(sourceId in ids && card.isNotEmpty() && !card.any { it.isWhitespace() }) { "الباقة أو رقم البطاقة غير صالح" }
            val source = stock.getValue(sourceId)
            require(source.count { it == card } == 1) { "البطاقة $card لم تعد ضمن المخزون المتاح؛ حدّث الشاشة وحاول مجدداً" }
            // نعدّل النسخة المتاحة في المخزون فقط؛ لا نغيّر أي سجل بيع تاريخي، بما في ذلك البطاقات المرتجعة.
            val uniqueKey = "$sourceId\u0000$card"
            require(touched.add(uniqueKey)) { "تم تحديد البطاقة نفسها أكثر من مرة" }
            when (action) {
                "delete" -> source.remove(card)
                "edit" -> {
                    val replacement = change.optString("newCard").trim()
                    require(replacement.isNotEmpty() && !replacement.any { it.isWhitespace() }) { "رقم البطاقة البديل غير صالح" }
                    require(stock.values.flatten().none { it == replacement }) { "رقم البطاقة البديل موجود في المخزون بالفعل" }
                    require(!soldCards.contains(replacement)) { "رقم البطاقة البديل موجود في سجل المبيعات" }
                    source[source.indexOf(card)] = replacement
                }
                "move" -> {
                    val targetId = change.optString("targetPackageId")
                    require(targetId in ids && targetId != sourceId) { "اختر باقة وجهة مختلفة وصالحة" }
                    require(stock.getValue(targetId).none { it == card }) { "البطاقة موجودة مسبقاً في باقة الوجهة" }
                    source.remove(card)
                    stock.getValue(targetId).add(card)
                    changedIds.add(targetId)
                }
            }
            changedIds.add(sourceId)
        }
        val before = JSONObject()
        val after = JSONObject()
        val replacements = linkedMapOf<String, String>()
        changedIds.forEach { id ->
            val name = "cards_$id.txt"
            val previous = text(context, name)
            val next = stock.getValue(id).let { if (it.isEmpty()) "" else it.joinToString("\n", postfix = "\n") }
            before.put(name, previous)
            after.put(name, next)
            replacements[name] = next
        }
        val undo = JSONObject().put("expiresAt", System.currentTimeMillis() + 60_000L).put("before", before).put("after", after)
        replacements["inventory_undo.json"] = undo.toString()
        writeBatch(context, replacements)
        snapshot(context)
    }

    fun undoInventoryChange(context: Context): Map<String, Any?> = synchronized(lock) {
        val undo = runCatching { JSONObject(text(context, "inventory_undo.json")) }.getOrNull()
            ?: throw IllegalArgumentException("لا توجد عملية مخزون قابلة للتراجع")
        require(System.currentTimeMillis() <= undo.optLong("expiresAt", 0L)) { "انتهت مهلة التراجع؛ لم يتغير المخزون" }
        val before = undo.optJSONObject("before") ?: throw IllegalArgumentException("بيانات التراجع غير صالحة")
        val after = undo.optJSONObject("after") ?: throw IllegalArgumentException("بيانات التراجع غير صالحة")
        val restore = linkedMapOf<String, String>()
        after.keys().forEach { name ->
            require(name.matches(Regex("cards_[A-Za-z0-9_-]{1,24}\\.txt"))) { "ملف التراجع غير مسموح" }
            require(text(context, name) == after.getString(name)) { "تغير المخزون بعد العملية؛ أُوقف التراجع منعاً لفقد بيانات أحدث" }
            restore[name] = before.optString(name, "")
        }
        restore["inventory_undo.json"] = "{}"
        writeBatch(context, restore)
        snapshot(context)
    }

    private fun salesToday(context: Context, phone: String): List<Pair<Int, String>> {
        val day = SimpleDateFormat("yyyyMMdd", Locale.US).format(Date())
        val key = phoneKey(phone)
        return text(context, "sales.log").lineSequence().mapNotNull { line ->
            val parts = line.split(" | ")
            if (parts.size < 5 || !parts[0].startsWith(day) || phoneKey(parts[2]) != key) null
            else (parts[1].toIntOrNull() ?: 0) to parts[2]
        }.toList()
    }

    private fun checkPermission(context: Context, phone: String, id: String, amount: Int, paymentMethod: String = "credit", additionalDebt: Long = 0L, additionalCount: Int = 0, additionalAmount: Long = 0L): String? {
        val perms = json(context, "permissions.json", "{\"global\":{\"allowAllClients\":true,\"onlyTrusted\":false,\"allowedPackages\":[\"500\",\"300\",\"3000\",\"200\"],\"maxDebt\":50000,\"maxDailyTransactions\":10,\"maxDailyAmount\":100000,\"blockedClients\":[],\"timeRestriction\":{\"enabled\":false}},\"clients\":[]}")
        val global = perms.optJSONObject("global") ?: JSONObject()
        val blocked = global.optJSONArray("blockedClients") ?: JSONArray()
        if ((0 until blocked.length()).any { phoneKey(blocked.optString(it)) == phoneKey(phone) }) return "عذراً، رقمك غير مسموح له بالشراء."
        val clients = perms.optJSONArray("clients") ?: JSONArray()
        var client: JSONObject? = null
        for (i in 0 until clients.length()) {
            val candidate = clients.optJSONObject(i) ?: continue
            if (phoneKey(candidate.optString("phone")) == phoneKey(phone)) { client = candidate; break }
        }
        val trusted = json(context, "trusted_clients.json", "{\"filterEnabled\":false,\"clients\":[]}")
        if (trusted.optBoolean("filterEnabled", false) || global.optBoolean("onlyTrusted", false)) {
            val array = trusted.optJSONArray("clients") ?: JSONArray()
            if ((0 until array.length()).none { index ->
                    val value = array.opt(index)
                    phoneKey(if (value is JSONObject) value.optString("phone") else value.toString()) == phoneKey(phone)
                }) return "عذراً، الشراء متاح للعملاء الموثقين فقط."
        }
        if (client?.optBoolean("blocked", false) == true || client?.optBoolean("enabled", true) == false) return "عذراً، صلاحية الشراء لهذا الرقم متوقفة."
        val blockedUntil = client?.optString("blockedUntil").orEmpty()
        if (blockedUntil.isNotBlank()) {
            val until = runCatching {
                SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US).parse(blockedUntil)
            }.getOrNull()
            if (until != null && until.time > System.currentTimeMillis()) {
                val reason = client?.optString("temporaryBlockReason").orEmpty().ifBlank { "إيقاف مؤقت" }
                return "عذراً، حسابك موقوف مؤقتاً حتى ${SimpleDateFormat("yyyy/MM/dd HH:mm", Locale("ar")).format(until)}. السبب: $reason"
            }
        }
        if (!global.optBoolean("allowAllClients", true) && client == null) return "عذراً، رقمك غير مسجل ضمن العملاء المسموح لهم."
        val allowed = client?.optJSONArray("allowedPackages") ?: global.optJSONArray("allowedPackages")
        if (allowed != null && (0 until allowed.length()).none { allowed.optString(it) == id }) return "عذراً، هذه الباقة غير متاحة لحسابك."
        val methods = client?.optJSONArray("paymentMethods") ?: global.optJSONArray("paymentMethods")
        if (methods != null && (0 until methods.length()).none { methods.optString(it) == paymentMethod }) return "طريقة الدفع غير مسموحة لهذا العميل."
        val currentDebt = currentBalance(context, phone)
        val maxDebt = client?.optLong("maxDebt", global.optLong("maxDebt", 50000)) ?: global.optLong("maxDebt", 50000)
        if (paymentMethod == "credit" && currentDebt + additionalDebt + amount > maxDebt) return "عذراً، تجاوزت حد الرصيد المسموح (${maxDebt} ر.ي)."
        val today = salesToday(context, phone)
        val maxTx = client?.optInt("maxDailyTransactions", global.optInt("maxDailyTransactions", 10)) ?: global.optInt("maxDailyTransactions", 10)
        val maxAmount = client?.optLong("maxDailyAmount", global.optLong("maxDailyAmount", 100000)) ?: global.optLong("maxDailyAmount", 100000)
        if (today.size + additionalCount + 1 > maxTx || today.sumOf { it.first } + additionalAmount + amount > maxAmount) return "عذراً، وصلت إلى حد الشراء اليومي."
        val restriction = client?.optJSONObject("timeRestriction") ?: global.optJSONObject("timeRestriction")
        if (restriction?.optBoolean("enabled", false) == true) {
            val now = SimpleDateFormat("HH:mm", Locale.US).format(Date())
            val from = restriction.optString("from", "08:00")
            val to = restriction.optString("to", "22:00")
            val inside = if (from <= to) now >= from && now <= to else now >= from || now <= to
            if (!inside) return "عذراً، الشراء متاح من $from إلى $to فقط."
        }
        return null
    }

    private fun packages(context: Context): JSONArray = json(context, "packages.json", "{\"packages\":[]}").optJSONArray("packages") ?: JSONArray()

    private fun packageById(context: Context, packageId: String): JSONObject? =
        (0 until packages(context).length()).mapNotNull { packages(context).optJSONObject(it) }
            .firstOrNull { it.optString("id") == packageId }

    private fun packageIdsFromConfig(
        config: JSONObject,
        enforcePriceId: Boolean = true,
        enforceKeywordUniqueness: Boolean = true
    ): Set<String> {
        val list = config.optJSONArray("packages") ?: throw IllegalArgumentException("قائمة الباقات غير صالحة")
        require(list.length() in 1..200) { "يجب أن تحتوي القائمة على باقة واحدة على الأقل ولا تتجاوز 200 باقة" }
        val ids = linkedSetOf<String>()
        val keywordOwners = linkedMapOf<String, String>()
        val priorKeywords = mutableListOf<Pair<String, String>>()
        for (index in 0 until list.length()) {
            val item = list.optJSONObject(index) ?: throw IllegalArgumentException("تعريف باقة غير صالح")
            val id = item.optString("id").trim()
            require(packageIdPattern.matches(id)) { "معرّف الباقة غير صالح" }
            require(ids.add(id)) { "معرّف الباقة مكرر: $id" }
            val price = item.optLong("price", 0L)
            require(price in 1..Int.MAX_VALUE.toLong()) { "سعر الباقة $id يجب أن يكون أكبر من صفر" }
            if (enforcePriceId) {
                require(id.all { it.isDigit() } && id == price.toString()) {
                    "معرّف الباقة يجب أن يساوي سعرها ($id ≠ $price)"
                }
            }
            require(item.optString("label", id).length <= 80) { "اسم الباقة $id طويل جداً" }
            val keywords = item.optJSONArray("keywords") ?: JSONArray()
            if (enforcePriceId) {
                require(keywords.length() in 1..50 && (0 until keywords.length()).all { keywords.optString(it).trim().length in 1..80 }) {
                    "أضف من كلمة إلى 50 كلمة طلب صالحة للباقة $id، وبحد أقصى 80 حرفاً لكل كلمة"
                }
            }
            for (wordIndex in 0 until keywords.length()) {
                val word = keywords.optString(wordIndex).trim()
                if (word.isEmpty()) {
                    if (enforcePriceId) throw IllegalArgumentException("كلمة طلب فارغة في الباقة $id")
                    continue
                }
                if (enforceKeywordUniqueness) {
                    val normalized = normalizeKeyword(word)
                    val previous = keywordOwners.putIfAbsent(normalized, id)
                    require(previous == null || previous == id) {
                        "كلمة الطلب «$word» مستخدمة في الباقة $previous أيضاً"
                    }
                    require(previous == null) { "كلمة الطلب «$word» مكررة داخل الباقة $id" }
                    for ((priorWord, priorId) in priorKeywords) {
                        if (priorId != id && (keywordMatches(normalized, priorWord) || keywordMatches(priorWord, normalized))) {
                            throw IllegalArgumentException("عبارة الطلب «$word» تتداخل مع كلمة «$priorWord» للباقة $priorId")
                        }
                    }
                    priorKeywords.add(normalized to id)
                }
            }
        }
        return ids
    }

    private fun normalizeKeyword(value: String): String = value.lowercase(Locale.ROOT)
        .replace("ـ", "")
        .replace(Regex("[\\u064B-\\u065F\\u0670]"), "")
        .replace(Regex("\\s+"), " ")

    private fun keywordMatches(message: String, alias: String): Boolean = try {
        val pattern = Pattern.compile(
            "(?<![\\p{L}\\p{N}])" + Pattern.quote(alias) + "(?![\\p{L}\\p{N}])",
            Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE
        )
        pattern.matcher(message).find()
    } catch (_: Exception) { false }

    private fun packageIds(context: Context): Set<String> {
        val config = json(context, "packages.json", "{\"packages\":[]}")
        return try {
            packageIdsFromConfig(config, enforcePriceId = false, enforceKeywordUniqueness = false)
        } catch (_: Exception) { fallbackPackageIds }
    }

    private fun findPackage(context: Context, message: String, phone: String): PackageMatch {
        val list = packages(context)
        val normalized = normalizeKeyword(message)
        val matches = mutableListOf<Pair<JSONObject, String>>()
        for (item in (0 until list.length()).mapNotNull { list.optJSONObject(it) }) {
            val words = item.optJSONArray("keywords") ?: JSONArray(item.optString("id"))
            for (i in 0 until words.length()) {
                val word = normalizeKeyword(words.optString(i))
                if (word.isEmpty()) continue
                if (keywordMatches(normalized, word)) matches.add(item to word)
            }
        }
        if (matches.isEmpty()) return PackageMatch()

        val mostSpecificLength = matches.maxOf { it.second.length }
        val strongest = matches.filter { it.second.length == mostSpecificLength }
            .distinctBy { it.first.optString("id") }
        if (strongest.size != 1) return PackageMatch(ambiguous = true)

        val item = strongest.single().first
        val excludedPhones = item.optJSONArray("excludedPhones") ?: JSONArray()
        if ((0 until excludedPhones.length()).any {
                phoneKey(excludedPhones.optString(it)) == phoneKey(phone)
            }) return PackageMatch(excluded = true)
        val excludedWords = item.optJSONArray("excludedKeywords") ?: JSONArray()
        if ((0 until excludedWords.length()).any { index ->
                val excluded = normalizeKeyword(excludedWords.optString(index))
                excluded.isNotEmpty() && keywordMatches(normalized, excluded)
            }) return PackageMatch(excluded = true)
        return PackageMatch(item = item)
    }

    private fun buildDebtCache(balances: Map<String, Long>, entries: JSONArray): String = debtText(balances, entries)

    private fun updateCounters(trigger: JSONObject, timestamp: String) {
        trigger.put("processedCount", trigger.optInt("processedCount", 0) + 1)
        trigger.put("totalSalesCount", trigger.optInt("totalSalesCount", 0) + 1)
        trigger.put("lastRun", timestamp)
    }

    private fun recordSale(context: Context, id: String, price: Int, phone: String, clientName: String, replyBySms: Boolean, paymentMethod: String, reference: String = "", replyViaWhatsApp: ((String) -> Boolean)? = null): Map<String, Any?> {
        val cardFile = file(context, "cards_$id.txt")
        val available = cardFile.takeIf { it.exists() }?.readLines(Charsets.UTF_8)?.map { it.trim() }?.filter { it.isNotEmpty() }.orEmpty()
        if (available.isEmpty()) return mapOf("ok" to false, "message" to "لا توجد بطاقات متبقية من فئة $id. الرجاء مراجعة الموزع.")

        val card = available.first()
        val entries = transactions(context)
        val currentBalances = balancesFrom(entries)
        val key = phoneKey(phone)
        val current = currentBalances[key] ?: 0L
        val delta = if (paymentMethod == "credit") price.toLong() else 0L
        val balanceAfter = current + delta
        val transaction = newEntry(
            type = if (paymentMethod == "credit") "sale_credit" else "sale_cash",
            phone = phone,
            amount = price.toLong(),
            delta = delta,
            paymentMethod = paymentMethod,
            packageId = id,
            clientName = clientName,
            reference = reference,
            note = "صرف كرت باقة $id"
        )
        if (replyViaWhatsApp != null) transaction.put("whatsappStatus", "pending")
        entries.put(transaction)
        val balances = balancesFrom(entries)
        val oldTrigger = json(context, "trigger_config.json", "{\"triggerEnabled\":true,\"processedCount\":0,\"totalSalesCount\":0}")
        val timestamp = stampNow()
        updateCounters(oldTrigger, timestamp)
        val oldSalesLine = "$timestamp | $price | $phone | $card | $balanceAfter | $paymentMethod | $id | ${transaction.optString("id")}\n"
        val replacement = mapOf(
            "cards_$id.txt" to if (available.size <= 1) "" else available.drop(1).joinToString("\n", postfix = "\n"),
            LEDGER_NAME to ledgerContent(entries),
            "debts.txt" to buildDebtCache(balances, entries),
            "trigger_config.json" to oldTrigger.toString()
        )
        writeBatch(context, replacement, mapOf("sales.log" to oldSalesLine))

        val reply = renderTemplate(
            context,
            "success",
            "أهلاً {name}،\nهذا رد تلقائي لشبكة القاضي نت\nكرتك: {card} | فئة: {price} | شبكة: القاضي نت\nالمتبقي عليك: {debt} ر.ي",
            mapOf("name" to clientName.ifBlank { "عميلنا" }, "card" to card, "price" to price.toString(), "package" to id, "debt" to balanceAfter.toString(), "phone" to phone, "reason" to "")
        )
        var smsSent: Boolean? = null
        var smsError = ""
        var whatsappSent: Boolean? = null
        if (replyBySms && phone.isNotBlank()) {
            try { sendSms(context, phone, reply); smsSent = true }
            catch (e: Exception) {
                smsSent = false
                smsError = "تعذر إرسال SMS؛ تحقق من الأذونات والشريحة."
                recordSmsFailure(context, phone, smsError)
            }
        }
        if (replyViaWhatsApp != null) {
            whatsappSent = sendWhatsAppReply(context, phone, reply, replyViaWhatsApp)
            transaction.put("whatsappStatus", if (whatsappSent == true) "submitted" else "failed")
            if (whatsappSent == false) {
                transaction.put("whatsappError", "تم تسجيل البيع لكن تعذر إرسال الرد؛ أُبقيت البطاقة نفسها لإعادة المحاولة.")
            } else {
                transaction.remove("whatsappError")
            }
            atomicWrite(file(context, LEDGER_NAME), ledgerContent(entries))
        }
        CardBotService.refresh(context)
        val event = when {
            smsSent == false -> "sale_sms_failed"
            whatsappSent == false -> "sale_whatsapp_failed"
            else -> "sale_success"
        }
        recordRequestEvent(context, event, phone, "باقة $id؛ سعر $price")
        return mapOf("ok" to true, "message" to reply, "card" to card, "debt" to balanceAfter, "packageId" to id, "price" to price, "paymentMethod" to paymentMethod, "smsSent" to smsSent, "smsError" to smsError, "whatsappSent" to whatsappSent, "transactionId" to transaction.optString("id"))
    }

    fun sell(context: Context, packageId: String, phone: String, name: String, send: Boolean, paymentMethod: String): Map<String, Any?> = synchronized(lock) {
        val item = (0 until packages(context).length()).mapNotNull { packages(context).optJSONObject(it) }.firstOrNull { it.optString("id") == packageId } ?: throw IllegalArgumentException("الباقة غير معروفة")
        val price = effectivePrice(context, phone, item)
        val error = checkPermission(context, phone, packageId, price, paymentMethod)
        if (error != null) throw IllegalStateException(error)
        recordSale(context, packageId, price, phone, name, send, paymentMethod)
    }

    /** Atomic multi-package sale: validate and stage everything before one journaled commit. */
    fun bulkSell(context: Context, quantities: Map<String, Int>, phone: String, name: String, paymentMethod: String): Map<String, Any?> = synchronized(lock) {
        require(phone.isNotBlank()) { "رقم العميل مطلوب" }
        require(paymentMethod == "cash" || paymentMethod == "credit") { "طريقة الدفع غير صالحة" }
        val requested = quantities.filterValues { it > 0 }
        require(requested.isNotEmpty()) { "اختر بطاقة واحدة على الأقل" }
        val bulkId = UUID.randomUUID().toString()
        val definitions = packages(context)
        val entries = transactions(context)
        val balances = balancesFrom(entries)
        val key = phoneKey(phone)
        var balance = balances[key] ?: 0L
        var total = 0L
        var index = 0
        var plannedDebt = 0L
        var plannedCount = 0
        var plannedAmount = 0L
        val stagedCards = linkedMapOf<String, MutableList<String>>()
        val stagedSales = arrayListOf<Map<String, Any?>>()

        requested.forEach { (packageId, quantity) ->
            val item = (0 until definitions.length()).mapNotNull { definitions.optJSONObject(it) }
                .firstOrNull { it.optString("id") == packageId }
                ?: throw IllegalArgumentException("الباقة غير معروفة: $packageId")
            val price = effectivePrice(context, phone, item).toLong()
            checkPermission(context, phone, packageId, price.toInt(), paymentMethod, plannedDebt, plannedCount, plannedAmount)?.let { throw IllegalStateException(it) }
            val available = file(context, "cards_$packageId.txt").takeIf { it.exists() }
                ?.readLines(Charsets.UTF_8)?.map { it.trim() }?.filter { it.isNotEmpty() }?.toMutableList()
                ?: mutableListOf()
            if (available.size < quantity) throw IllegalStateException("المخزون غير كافٍ للباقة $packageId")
            val selected = available.take(quantity)
            stagedCards[packageId] = available.drop(quantity).toMutableList()
            plannedDebt = Math.addExact(plannedDebt, if (paymentMethod == "credit") Math.multiplyExact(price, quantity.toLong()) else 0L)
            plannedCount += quantity
            plannedAmount = Math.addExact(plannedAmount, Math.multiplyExact(price, quantity.toLong()))
            selected.forEach { card ->
                val delta = if (paymentMethod == "credit") price else 0L
                balance = Math.addExact(balance, delta)
                total = Math.addExact(total, price)
                val entry = newEntry(
                    type = if (paymentMethod == "credit") "sale_credit" else "sale_cash",
                    phone = phone, amount = price, delta = delta, paymentMethod = paymentMethod,
                    packageId = packageId, clientName = name, reference = bulkId,
                    note = "بيع جماعي ذري $bulkId"
                ).put("bulkOperationId", bulkId).put("bulkIndex", index++)
                entries.put(entry)
                stagedSales += mapOf("card" to card, "packageId" to packageId, "price" to price,
                    "paymentMethod" to paymentMethod, "transactionId" to entry.optString("id"), "debt" to balance)
            }
        }

        val trigger = json(context, "trigger_config.json", "{\"triggerEnabled\":true,\"processedCount\":0,\"totalSalesCount\":0}")
        repeat(stagedSales.size) { updateCounters(trigger, stampNow()) }
        val replacements = linkedMapOf<String, String>()
        stagedCards.forEach { (packageId, cards) -> replacements["cards_$packageId.txt"] = if (cards.isEmpty()) "" else cards.joinToString("\n", postfix = "\n") }
        replacements[LEDGER_NAME] = ledgerContent(entries)
        replacements["debts.txt"] = buildDebtCache(balancesFrom(entries), entries)
        replacements["trigger_config.json"] = trigger.toString()
        val logLines = stagedSales.joinToString("") { sale ->
            "${stampNow()} | ${sale["price"]} | $phone | ${sale["card"]} | ${sale["debt"]} | $paymentMethod | ${sale["packageId"]} | ${sale["transactionId"]} | bulk:$bulkId\n"
        }
        writeBatch(context, replacements, mapOf("sales.log" to logLines))
        CardBotService.refresh(context)
        recordRequestEvent(context, "bulk_sale_success", phone, "bulk:$bulkId؛ العدد ${stagedSales.size}؛ الإجمالي $total")
        mapOf("ok" to true, "bulkOperationId" to bulkId, "count" to stagedSales.size, "total" to total, "debt" to balance, "sales" to stagedSales)
    }

    fun manualSale(context: Context, phone: String, name: String, description: String, quantity: Int, unitPrice: Long, unitCost: Long, paymentMethod: String): Map<String, Any?> = synchronized(lock) {
        require(description.isNotBlank()) { "وصف البيع مطلوب" }
        require(quantity > 0) { "الكمية يجب أن تكون أكبر من صفر" }
        require(unitPrice >= 0L && unitCost >= 0L) { "السعر والتكلفة لا يمكن أن يكونا سالبين" }
        require(paymentMethod == "cash" || paymentMethod == "credit") { "طريقة الدفع غير صالحة" }
        require(phone.isNotBlank()) { "رقم العميل مطلوب" }
        val total = Math.multiplyExact(quantity.toLong(), unitPrice)
        val totalCost = Math.multiplyExact(quantity.toLong(), unitCost)
        val profit = total - totalCost
        val entries = transactions(context)
        val current = balancesFrom(entries)[phoneKey(phone)] ?: 0L
        val delta = if (paymentMethod == "credit") total else 0L
        val balanceAfter = Math.addExact(current, delta)
        val entry = newEntry(
            type = if (paymentMethod == "credit") "manual_sale_credit" else "manual_sale_cash",
            phone = phone,
            amount = total,
            delta = delta,
            paymentMethod = paymentMethod,
            clientName = name,
            reference = "manual:${UUID.randomUUID()}",
            note = description.trim()
        ).put("saleSource", "manual")
            .put("description", description.trim())
            .put("quantity", quantity)
            .put("unitPrice", unitPrice)
            .put("unitCost", unitCost)
            .put("profit", profit)
            .put("balanceBefore", current)
            .put("balanceAfter", balanceAfter)
        entries.put(entry)
        val balances = balancesFrom(entries)
        val trigger = json(context, "trigger_config.json", "{\"triggerEnabled\":true,\"processedCount\":0,\"totalSalesCount\":0}")
        updateCounters(trigger, stampNow())
        writeBatch(context, mapOf(LEDGER_NAME to ledgerContent(entries), "debts.txt" to buildDebtCache(balances, entries), "trigger_config.json" to trigger.toString()))
        recordRequestEvent(context, "manual_sale_success", phone, "$description؛ الإجمالي $total")
        snapshot(context) + mapOf("ok" to true, "saleSource" to "manual", "description" to description.trim(), "quantity" to quantity, "unitPrice" to unitPrice, "unitCost" to unitCost, "price" to total, "profit" to profit, "paymentMethod" to paymentMethod, "debt" to balanceAfter, "balanceBefore" to current, "balanceAfter" to balanceAfter, "transactionId" to entry.optString("id"))
    }

    fun recordReceipt(context: Context, phone: String, amount: Long, paymentMethod: String, reference: String, note: String, clientName: String): Map<String, Any?> = synchronized(lock) {
        require(phone.isNotBlank()) { "رقم العميل مطلوب" }
        require(amount > 0) { "المبلغ يجب أن يكون أكبر من صفر" }
        val entries = transactions(context)
        entries.put(newEntry("receipt", phone, amount, -amount, paymentMethod, clientName = clientName, reference = reference, note = note))
        val balances = balancesFrom(entries)
        writeBatch(context, mapOf(LEDGER_NAME to ledgerContent(entries), "debts.txt" to buildDebtCache(balances, entries)))
        snapshot(context)
    }

    fun recordAdjustment(context: Context, phone: String, amount: Long, direction: String, reason: String, clientName: String): Map<String, Any?> = synchronized(lock) {
        require(phone.isNotBlank()) { "رقم العميل مطلوب" }
        require(amount > 0) { "المبلغ يجب أن يكون أكبر من صفر" }
        require(reason.isNotBlank()) { "سبب التسوية مطلوب" }
        require(direction == "increase" || direction == "decrease") { "نوع التسوية غير صحيح" }
        val delta = if (direction == "increase") amount else -amount
        val type = if (delta >= 0) "adjustment_debit" else "adjustment_credit"
        val entries = transactions(context)
        entries.put(newEntry(type, phone, amount, delta, clientName = clientName, note = reason))
        val balances = balancesFrom(entries)
        writeBatch(context, mapOf(LEDGER_NAME to ledgerContent(entries), "debts.txt" to buildDebtCache(balances, entries)))
        snapshot(context)
    }

    fun setManualDebtBalance(
        context: Context,
        phone: String,
        targetBalance: Long,
        reason: String,
        clientName: String
    ): Map<String, Any?> = synchronized(lock) {
        require(phone.isNotBlank()) { "رقم العميل مطلوب" }
        require(targetBalance >= 0L) { "الرصيد المستهدف لا يمكن أن يكون سالباً" }
        require(reason.isNotBlank()) { "سبب تعديل الرصيد مطلوب" }
        val entries = transactions(context)
        val currentBalance = balancesFrom(entries)[phoneKey(phone)] ?: 0L
        val delta = try {
            Math.subtractExact(targetBalance, currentBalance)
        } catch (_: ArithmeticException) {
            throw IllegalArgumentException("قيمة الرصيد أكبر من الحد المسموح")
        }
        if (delta == 0L) return@synchronized snapshot(context)
        require(delta != Long.MIN_VALUE) { "قيمة التعديل أكبر من الحد المسموح" }
        val type = if (delta > 0L) "adjustment_debit" else "adjustment_credit"
        entries.put(
            newEntry(
                type = type,
                phone = phone,
                amount = kotlin.math.abs(delta),
                delta = delta,
                clientName = clientName,
                note = "تعديل يدوي للرصيد: ${reason.trim()}"
            )
        )
        val balances = balancesFrom(entries)
        writeBatch(context, mapOf(LEDGER_NAME to ledgerContent(entries), "debts.txt" to buildDebtCache(balances, entries)))
        snapshot(context)
    }

    fun markSaleReceived(context: Context, transactionId: String): Map<String, Any?> = synchronized(lock) {
        require(transactionId.isNotBlank()) { "معرّف البيع غير متوفر لهذه الحركة القديمة" }
        val entries = transactions(context)
        val entry = (0 until entries.length()).mapNotNull { entries.optJSONObject(it) }
            .firstOrNull { it.optString("id") == transactionId }
            ?: throw IllegalArgumentException("عملية البيع غير موجودة")
        require(entry.optString("type") == "sale_cash" || entry.optString("type") == "sale_credit") {
            "يمكن تأكيد استلام كرت لعملية بيع فقط"
        }
        entry.put("receiptConfirmedAt", isoNow())
        entry.put("receiptConfirmedBy", "manual")
        writeBatch(context, mapOf(LEDGER_NAME to ledgerContent(entries)))
        snapshot(context)
    }

    fun returnSale(context: Context, transactionId: String, reason: String): Map<String, Any?> = synchronized(lock) {
        require(transactionId.isNotBlank()) { "معرّف البيع غير متوفر لهذه الحركة القديمة" }
        val entries = transactions(context)
        val sale = (0 until entries.length()).mapNotNull { entries.optJSONObject(it) }
            .firstOrNull { it.optString("id") == transactionId }
            ?: throw IllegalArgumentException("عملية البيع غير موجودة")
        require(sale.optString("type") == "sale_cash" || sale.optString("type") == "sale_credit") {
            "يمكن إرجاع عملية بيع فقط"
        }
        require(sale.optString("returnedAt").isBlank()) { "تم إرجاع هذه البطاقة مسبقاً" }
        val line = text(context, "sales.log").lineSequence()
            .firstOrNull { it.split(" | ").getOrNull(7) == transactionId }
            ?: throw IllegalArgumentException("تعذر العثور على البطاقة المرتبطة بالبيع")
        val parts = line.split(" | ")
        require(parts.size >= 8) { "سجل البيع غير مكتمل ولا يمكن إرجاعه تلقائياً" }
        val packageId = parts[6]
        require(packageIds(context).contains(packageId)) { "الباقة حُذفت؛ أعد إنشاء الباقة بنفس المعرف قبل إرجاع البطاقة" }
        val card = parts[3].trim()
        require(card.isNotEmpty()) { "رقم البطاقة غير موجود" }
        val cardFile = file(context, "cards_$packageId.txt")
        val inventory = cardFile.takeIf { it.exists() }?.readLines(Charsets.UTF_8)?.map { it.trim() }?.filter { it.isNotEmpty() }.orEmpty()
        require(card !in inventory) { "البطاقة موجودة في المخزون بالفعل؛ أُلغي الإرجاع لمنع التكرار" }
        val amount = sale.optLong("amount", parts[1].toLongOrNull() ?: 0L)
        val phone = sale.optString("phone", parts[2])
        val clientName = sale.optString("clientName", "")
        val isCredit = sale.optString("type") == "sale_credit"
        sale.put("returnedAt", isoNow())
        sale.put("returnReason", reason.trim())
        entries.put(newEntry(
            type = "sale_return",
            phone = phone,
            amount = amount,
            delta = if (isCredit) -amount else 0L,
            paymentMethod = if (isCredit) "credit_return" else "cash_return",
            packageId = packageId,
            clientName = clientName,
            reference = transactionId,
            note = reason.trim().ifBlank { "إرجاع بطاقة إلى المخزون" }
        ))
        val updatedBalances = balancesFrom(entries)
        writeBatch(context, mapOf(
            "cards_$packageId.txt" to (inventory + card).distinct().joinToString("\n", postfix = "\n"),
            LEDGER_NAME to ledgerContent(entries),
            "debts.txt" to buildDebtCache(updatedBalances, entries)
        ))
        recordRequestEvent(context, "sale_return", phone, "إرجاع بطاقة باقة $packageId للعملية $transactionId")
        CardBotService.refresh(context)
        snapshot(context)
    }

    fun scheduleSale(
        context: Context,
        packageId: String,
        phone: String,
        clientName: String,
        scheduledPrice: Int,
        paymentMethod: String,
        scheduledAtMillis: Long
    ): Map<String, Any?> = synchronized(lock) {
        require(phoneKey(phone).length >= 7) { "رقم الهاتف غير صالح" }
        require(scheduledPrice > 0) { "السعر المعتمد غير صالح" }
        require(paymentMethod == "cash" || paymentMethod == "credit") { "طريقة الدفع غير صالحة" }
        require(packageIds(context).contains(packageId)) { "الباقة المطلوبة غير موجودة" }
        require(scheduledAtMillis >= System.currentTimeMillis() + 30_000L) { "موعد البيع يجب أن يكون بعد 30 ثانية على الأقل" }
        require(scheduledAtMillis <= System.currentTimeMillis() + 365L * 24 * 60 * 60 * 1000) { "الموعد لا يمكن أن يتجاوز سنة" }
        val trigger = json(context, "trigger_config.json", "{\"triggerEnabled\":true}")
        val queue = trigger.optJSONArray("scheduledSales") ?: JSONArray()
        require(queue.length() < 500) { "وصلت إلى الحد الأقصى للمبيعات المجدولة" }
        val item = JSONObject()
            .put("id", UUID.randomUUID().toString())
            .put("packageId", packageId)
            .put("phone", phone.trim())
            .put("clientName", clientName.trim())
            .put("price", scheduledPrice)
            .put("paymentMethod", paymentMethod)
            .put("scheduledAtMillis", scheduledAtMillis)
            .put("scheduledAt", SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US).format(Date(scheduledAtMillis)))
            .put("createdAt", isoNow())
            .put("status", "pending")
            .put("delivery", "automatic_sms")
        queue.put(item)
        trigger.put("scheduledSales", queue)
        atomicWrite(file(context, "trigger_config.json"), trigger.toString())
        ScheduledSaleAlarm.schedule(context, item.optString("id"), scheduledAtMillis)
        mapOf("scheduledSale" to item.toMapSafe(), "snapshot" to snapshot(context))
    }

    fun cancelScheduledSale(context: Context, scheduleId: String): Map<String, Any?> = synchronized(lock) {
        val trigger = json(context, "trigger_config.json", "{}")
        val queue = trigger.optJSONArray("scheduledSales") ?: JSONArray()
        val item = (0 until queue.length()).mapNotNull { queue.optJSONObject(it) }
            .firstOrNull { it.optString("id") == scheduleId }
            ?: throw IllegalArgumentException("العملية المجدولة غير موجودة")
        require(item.optString("status") == "pending") { "لا يمكن إلغاء عملية بدأت أو اكتملت" }
        item.put("status", "cancelled")
        item.put("cancelledAt", isoNow())
        trigger.put("scheduledSales", queue)
        atomicWrite(file(context, "trigger_config.json"), trigger.toString())
        ScheduledSaleAlarm.cancel(context, scheduleId)
        snapshot(context)
    }

    fun pendingScheduledSales(context: Context): List<Pair<String, Long>> = synchronized(lock) {
        val queue = json(context, "trigger_config.json", "{}").optJSONArray("scheduledSales") ?: JSONArray()
        (0 until queue.length()).mapNotNull { index ->
            val item = queue.optJSONObject(index) ?: return@mapNotNull null
            if (item.optString("status") != "pending") return@mapNotNull null
            item.optString("id").takeIf { it.isNotBlank() }?.let { it to item.optLong("scheduledAtMillis") }
        }
    }

    /** Called by the foreground service; each due item is marked processing before dispensing inventory. */
    fun processDueSales(context: Context) = synchronized(lock) {
        var trigger = json(context, "trigger_config.json", "{}")
        var queue = trigger.optJSONArray("scheduledSales") ?: JSONArray()
        val now = System.currentTimeMillis()
        for (index in 0 until queue.length()) {
            val item = queue.optJSONObject(index) ?: continue
            if (item.optString("status") == "processing") {
                val transaction = (0 until transactions(context).length()).mapNotNull { transactions(context).optJSONObject(it) }
                    .firstOrNull { it.optString("reference") == item.optString("id") }
                if (transaction != null) {
                    item.put("status", "completed")
                    item.put("completedAt", transaction.optString("createdAt", isoNow()))
                    item.put("transactionId", transaction.optString("id"))
                    item.put("price", transaction.optLong("amount"))
                    val log = text(context, "sales.log").lineSequence().firstOrNull { it.split(" | ").getOrNull(7) == transaction.optString("id") }
                    item.put("card", log?.split(" | ")?.getOrNull(3).orEmpty())
                    item.put("smsSent", false)
                    item.put("recoveredAfterRestart", true)
                } else {
                    item.put("status", "failed")
                    item.put("failedAt", isoNow())
                    item.put("failureReason", "انقطع التطبيق أثناء التنفيذ؛ راجع سجل المبيعات قبل إعادة الجدولة")
                }
                trigger.put("scheduledSales", queue)
                atomicWrite(file(context, "trigger_config.json"), trigger.toString())
                ScheduledSaleAlarm.cancel(context, item.optString("id"))
                continue
            }
            if (item.optString("status") != "pending" || item.optLong("scheduledAtMillis") > now) continue
            item.put("status", "processing")
            item.put("startedAt", isoNow())
            trigger.put("scheduledSales", queue)
            atomicWrite(file(context, "trigger_config.json"), trigger.toString())
            ScheduledSaleAlarm.cancel(context, item.optString("id"))
            val packageId = item.optString("packageId")
            val phone = item.optString("phone")
            val payment = item.optString("paymentMethod", "cash")
            val packageInfo = packageById(context, packageId)
            val price = item.optInt("price", packageInfo?.let { effectivePrice(context, phone, it) } ?: 0)
            val denial = if (packageInfo == null) "الباقة لم تعد موجودة" else checkPermission(context, phone, packageId, price, payment)
            val result = try {
                if (denial != null) mapOf("ok" to false, "message" to denial)
                else recordSale(context, packageId, price, phone, item.optString("clientName"), true, payment, item.optString("id"))
            } catch (error: Exception) {
                mapOf("ok" to false, "message" to (error.message ?: "تعذر إتمام البيع"))
            }
            trigger = json(context, "trigger_config.json", "{}")
            queue = trigger.optJSONArray("scheduledSales") ?: JSONArray()
            val current = (0 until queue.length()).mapNotNull { queue.optJSONObject(it) }
                .firstOrNull { it.optString("id") == item.optString("id") } ?: continue
            if (result["ok"] == true) {
                current.put("status", "completed")
                current.put("completedAt", isoNow())
                current.put("transactionId", result["transactionId"]?.toString().orEmpty())
                current.put("card", result["card"]?.toString().orEmpty())
                current.put("price", result["price"] ?: price)
                current.put("smsSent", result["smsSent"] ?: false)
                current.put("smsError", result["smsError"]?.toString().orEmpty())
            } else {
                val reason = result["message"]?.toString() ?: "تعذر إتمام البيع"
                current.put("status", "failed")
                current.put("failedAt", isoNow())
                current.put("failureReason", reason)
                recordRequestEvent(context, "scheduled_sale_failed", phone, reason)
                runCatching {
                    sendSms(context, phone, renderTemplate(context, "rejected", "{reason}", mapOf("name" to item.optString("clientName"), "phone" to phone, "reason" to reason, "package" to packageId, "price" to price.toString(), "card" to "", "debt" to currentBalance(context, phone).toString())))
                }.onFailure { recordSmsFailure(context, phone, it.message.orEmpty()) }
            }
            trigger = json(context, "trigger_config.json", "{}")
            queue = trigger.optJSONArray("scheduledSales") ?: JSONArray()
            val saved = (0 until queue.length()).mapNotNull { queue.optJSONObject(it) }
                .firstOrNull { it.optString("id") == item.optString("id") } ?: continue
            // Copy final status because recordSale may have rewritten trigger_config.json.
            for (key in current.keys()) saved.put(key, current.opt(key))
            trigger.put("scheduledSales", queue)
            atomicWrite(file(context, "trigger_config.json"), trigger.toString())
            trigger = json(context, "trigger_config.json", "{}")
            queue = trigger.optJSONArray("scheduledSales") ?: JSONArray()
        }
    }

    private fun retryExistingWhatsAppSale(
        context: Context,
        eventId: String,
        phone: String,
        callback: (String) -> Boolean
    ): Boolean? {
        val entries = transactions(context)
        val transaction = (0 until entries.length()).mapNotNull { entries.optJSONObject(it) }
            .firstOrNull {
                it.optString("reference") == eventId &&
                    it.optString("type").startsWith("sale_")
            } ?: return null
        val transactionId = transaction.optString("id")
        val saleParts = text(context, "sales.log").lineSequence()
            .firstOrNull { it.split(" | ").getOrNull(7) == transactionId }
            ?.split(" | ")
        val card = saleParts?.getOrNull(3).orEmpty()
        if (card.isBlank()) {
            recordRequestEvent(context, "whatsapp_reply_failed", phone, "تعذر استعادة إيصال البيع لإعادة إرسال الرد")
            return true // لا نكرر الصرف إذا تعذر استرجاع نص الإيصال.
        }
        val packageId = transaction.optString("packageId")
        val price = transaction.optLong("amount").toString()
        val balanceAfter = saleParts?.getOrNull(4).orEmpty()
        val name = transaction.optString("clientName").ifBlank { "عميلنا" }
        val reply = renderTemplate(
            context,
            "success",
            "أهلاً {name}،\nهذا رد تلقائي لشبكة القاضي نت\nكرتك: {card} | فئة: {price} | شبكة: القاضي نت\nالمتبقي عليك: {debt} ر.ي",
            mapOf(
                "name" to name,
                "card" to card,
                "price" to price,
                "package" to packageId,
                "debt" to balanceAfter,
                "phone" to phone,
                "reason" to ""
            )
        )
        val sent = sendWhatsAppReply(context, phone, reply, callback)
        transaction.put("whatsappStatus", if (sent) "submitted" else "failed")
        if (sent) transaction.remove("whatsappError")
        else transaction.put("whatsappError", "تم تسجيل البيع؛ تعذر إرسال الرد، وستعاد المحاولة دون صرف كرت آخر.")
        atomicWrite(file(context, LEDGER_NAME), ledgerContent(entries))
        if (sent) recordRequestEvent(context, "whatsapp_reply_recovered", phone, "أُعيد إرسال إيصال البيع المسجل")
        return sent
    }

    fun processIncoming(
        context: Context,
        phone: String,
        message: String,
        channel: String = "sms",
        eventId: String = "",
        whatsappReply: ((String) -> Boolean)? = null
    ): Boolean = synchronized(lock) {
        val trigger = json(context, "trigger_config.json", "{\"triggerEnabled\":true}")
        if (!trigger.optBoolean("triggerEnabled", true)) return@synchronized true
        val viaWhatsApp = channel == "whatsapp"
        if (viaWhatsApp && (!trigger.optBoolean("whatsappAutoReplyEnabled", false) || whatsappReply == null)) {
            return@synchronized true
        }
        val name = customerName(context, phone)
        val deliverReply: (String) -> Boolean = { response ->
            if (viaWhatsApp) {
                sendWhatsAppReply(context, phone, response, whatsappReply!!)
            } else {
                try { sendSms(context, phone, response); true }
                catch (e: Exception) {
                    recordSmsFailure(context, phone, e.message.orEmpty())
                    Log.e("CardBot", "Could not send rejection SMS (${e.javaClass.simpleName})")
                    false
                }
            }
        }

        if (viaWhatsApp && eventId.isNotBlank()) {
            retryExistingWhatsAppSale(context, eventId, phone, whatsappReply!!)?.let {
                return@synchronized it
            }
        }

        val match = findPackage(context, message, phone)
        if (match.ambiguous) {
            recordRequestEvent(context, "ambiguous_keyword", phone, "تطابق الطلب مع أكثر من باقة بالدرجة نفسها")
            return@synchronized true
        }
        val item = match.item
        if (item == null) {
            recordRequestEvent(context, if (match.excluded) "excluded" else "unmatched_keyword", phone)
            return@synchronized true
        }
        val id = item.optString("id")
        val price = effectivePrice(context, phone, item)
        val denial = checkPermission(context, phone, id, price)
        if (denial != null) {
            recordRequestEvent(context, "rejected", phone, denial)
            val response = renderTemplate(context, "rejected", "{reason}", mapOf("name" to name, "phone" to phone, "reason" to denial, "package" to id, "price" to price.toString(), "card" to "", "debt" to currentBalance(context, phone).toString()))
            return@synchronized deliverReply(response)
        }
        val result = recordSale(
            context,
            id,
            price,
            phone,
            name,
            !viaWhatsApp,
            "credit",
            reference = if (viaWhatsApp) eventId else "",
            replyViaWhatsApp = if (viaWhatsApp) whatsappReply else null
        )
        if (result["ok"] == true) {
            return@synchronized result["whatsappSent"] != false
        }
        recordRequestEvent(context, "out_of_stock", phone, "باقة $id")
        val response = renderTemplate(context, "outOfStock", "{reason}", mapOf("name" to name, "phone" to phone, "reason" to result["message"].toString(), "package" to id, "price" to price.toString(), "card" to "", "debt" to currentBalance(context, phone).toString()))
        deliverReply(response)
    }

    fun sendSms(context: Context, phone: String, message: String) {
        if (context.checkSelfPermission(Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) throw SecurityException("إذن إرسال SMS غير ممنوح")
        require(phone.isNotBlank() && message.isNotBlank()) { "رقم الهاتف أو الرسالة فارغ" }
        @Suppress("DEPRECATION")
        val manager = SmsManager.getDefault()
        val parts = manager.divideMessage(message)
        if (parts.size > 1) manager.sendMultipartTextMessage(phone, null, parts, null, null) else manager.sendTextMessage(phone, null, message, null, null)
    }

    fun toggleTrigger(context: Context) = synchronized(lock) {
        val trigger = json(context, "trigger_config.json", "{\"triggerEnabled\":true}")
        trigger.put("triggerEnabled", !trigger.optBoolean("triggerEnabled", true))
        atomicWrite(file(context, "trigger_config.json"), trigger.toString())
    }

    private const val ENCRYPTED_BACKUP_FORMAT = "qadinet-encrypted-backup-v1"
    private const val BACKUP_KDF_ITERATIONS = 210000

    private fun preferredKdf(): String = try {
        SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        "PBKDF2WithHmacSHA256"
    } catch (_: Exception) {
        "PBKDF2WithHmacSHA1"
    }

    private fun deriveBackupKey(password: String, salt: ByteArray, kdf: String, iterations: Int): ByteArray {
        val spec = PBEKeySpec(password.toCharArray(), salt, iterations, 256)
        return try { SecretKeyFactory.getInstance(kdf).generateSecret(spec).encoded }
        finally { spec.clearPassword() }
    }

    private fun protectBackup(plain: String, password: String): String {
        if (password.isEmpty()) return plain
        require(password.isNotBlank()) { "كلمة المرور لا يمكن أن تكون مسافات فقط" }
        require(password.length >= 8) { "كلمة مرور النسخة يجب أن تكون 8 أحرف على الأقل" }
        val random = SecureRandom()
        val salt = ByteArray(16).also { random.nextBytes(it) }
        val iv = ByteArray(12).also { random.nextBytes(it) }
        val kdf = preferredKdf()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(deriveBackupKey(password, salt, kdf, BACKUP_KDF_ITERATIONS), "AES"), GCMParameterSpec(128, iv))
        val encrypted = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
        return JSONObject()
            .put("format", ENCRYPTED_BACKUP_FORMAT)
            .put("schemaVersion", 1)
            .put("kdf", kdf)
            .put("iterations", BACKUP_KDF_ITERATIONS)
            .put("salt", android.util.Base64.encodeToString(salt, android.util.Base64.NO_WRAP))
            .put("iv", android.util.Base64.encodeToString(iv, android.util.Base64.NO_WRAP))
            .put("ciphertext", android.util.Base64.encodeToString(encrypted, android.util.Base64.NO_WRAP))
            .toString()
    }

    private fun decodeBackup(content: String, password: String): JSONObject {
        val envelope = JSONObject(content)
        if (envelope.optString("format") != ENCRYPTED_BACKUP_FORMAT) return envelope
        require(password.isNotBlank()) { "أدخل كلمة مرور النسخة المشفّرة" }
        val kdf = envelope.optString("kdf")
        require(kdf == "PBKDF2WithHmacSHA256" || kdf == "PBKDF2WithHmacSHA1") { "خوارزمية تشفير غير معروفة" }
        val iterations = envelope.optInt("iterations", 0)
        require(iterations in 100000..1000000) { "إعداد اشتقاق المفتاح غير صالح" }
        val salt = android.util.Base64.decode(envelope.getString("salt"), android.util.Base64.NO_WRAP)
        val iv = android.util.Base64.decode(envelope.getString("iv"), android.util.Base64.NO_WRAP)
        val ciphertext = android.util.Base64.decode(envelope.getString("ciphertext"), android.util.Base64.NO_WRAP)
        require(salt.size == 16 && iv.size == 12 && ciphertext.size >= 16) { "ملف النسخة المشفّرة غير مكتمل" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(deriveBackupKey(password, salt, kdf, iterations), "AES"), GCMParameterSpec(128, iv))
        val plain = cipher.doFinal(ciphertext)
        return JSONObject(String(plain, Charsets.UTF_8))
    }

    fun exportBackup(
        context: Context,
        password: String = "",
        appPreferencesJson: String = "{}"
    ): String = synchronized(lock) {
        val snap = snapshot(context)
        val appPreferences = JSONObject(appPreferencesJson)
        require(appPreferencesJson.toByteArray(Charsets.UTF_8).size <= 1024 * 1024) {
            "تفضيلات التطبيق أكبر من الحد المسموح"
        }
        require(!appPreferences.has("dark") || appPreferences.opt("dark") is Boolean) {
            "قيمة الوضع الليلي في تفضيلات النسخة غير صالحة"
        }
        val backup = JSONObject()
            .put("schemaVersion", 2)
            .put("appId", context.packageName)
            .put("exportedAt", isoNow())
        listOf("inventory", "debts", "sales", "transactions", "packages", "permissions", "trigger", "trusted").forEach { key ->
            backup.put(key, snap[key].toBackupJsonValue())
        }
        backup.put("salesLog", text(context, "sales.log"))
        backup.put("appPreferences", appPreferences)
        protectBackup(backup.toString(), password)
    }

    private fun keepAutoBackup(context: Context, appPreferencesJson: String = "{}") {
        val dir = File(directory(context), "AutoBackups").apply { mkdirs() }
        atomicWrite(
            File(dir, "before-restore-${System.currentTimeMillis()}.json"),
            exportBackup(context, "", appPreferencesJson)
        )
        dir.listFiles()?.sortedByDescending { it.lastModified() }?.drop(3)?.forEach { it.delete() }
    }

    private fun normalizeLegacyDate(value: String, fallback: String): String {
        val input = value.trim()
        val oldFormat = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).apply { isLenient = false }
        val parsed = try { oldFormat.parse(input) } catch (_: Exception) { null }
        if (parsed != null) {
            return SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = java.util.TimeZone.getTimeZone("UTC")
            }.format(parsed)
        }
        return if (input.matches(Regex("\\d{4}-\\d{2}-\\d{2}T.*"))) input else fallback
    }

    private fun legacyLedger(debts: JSONArray, sales: JSONArray, exportedAt: String): JSONArray {
        val result = JSONArray()
        for (i in 0 until debts.length()) {
            val item = debts.optJSONObject(i) ?: continue
            val phone = item.optString("phone")
            val balance = item.optLong("amount", 0L)
            if (phone.isNotBlank() && balance != 0L) result.put(newEntry("opening_balance", phone, kotlin.math.abs(balance), balance, note = "رصيد افتتاحي من النسخة المستوردة", createdAt = exportedAt))
        }
        for (i in 0 until sales.length()) {
            val sale = sales.optJSONObject(i) ?: continue
            val phone = sale.optString("phone")
            if (phone.isNotBlank()) result.put(newEntry("legacy_sale", phone, sale.optLong("price", sale.optString("packageId").toLongOrNull() ?: 0L), 0L,
                paymentMethod = sale.optString("paymentMethod", "credit"), packageId = sale.optString("packageId"), clientName = sale.optString("clientName"),
                note = "عملية تاريخية مستوردة؛ لا تؤثر على الرصيد الافتتاحي", createdAt = normalizeLegacyDate(sale.optString("time"), exportedAt), affectsBalance = false))
        }
        return result
    }

    private fun debtsAsJson(balances: Map<String, Long>, entries: JSONArray): JSONArray {
        val phones = latestPhones(entries)
        val result = JSONArray()
        balances.forEach { (key, amount) -> if (amount != 0L) result.put(JSONObject().put("phone", phones[key] ?: key).put("amount", amount)) }
        return result
    }

    fun restoreBackup(
        context: Context,
        content: String,
        mode: String,
        password: String = "",
        currentAppPreferencesJson: String = "{}"
    ): Map<String, Any?> = synchronized(lock) {
        require(content.toByteArray(Charsets.UTF_8).size <= 80 * 1024 * 1024) { "حجم النسخة أكبر من الحد المسموح (80 ميغابايت)" }
        val root = decodeBackup(content, password)
        require(root.optInt("schemaVersion", 0) in 0..2) { "إصدار النسخة أحدث من إصدار التطبيق" }
        val inventory = root.optJSONObject("inventory") ?: throw IllegalArgumentException("النسخة لا تحتوي على المخزون")
        if (mode == "merge_cards") {
            val updates = linkedMapOf<String, String>()
            packageIds(context).forEach { id ->
                val incoming = inventory.optJSONArray(id) ?: JSONArray()
                val existing = file(context, "cards_$id.txt").takeIf { it.exists() }?.readLines(Charsets.UTF_8)?.map { it.trim() }?.filter { it.isNotEmpty() }.orEmpty()
                val combined = (existing + (0 until incoming.length()).map { incoming.optString(it).trim() }.filter { it.isNotEmpty() }).distinct()
                updates["cards_$id.txt"] = if (combined.isEmpty()) "" else combined.joinToString("\n", postfix = "\n")
            }
            writeBatch(context, updates)
            return@synchronized snapshot(context)
        }
        require(mode == "replace_all") { "نوع الاستعادة غير معروف" }
        val packagesJson = root.optJSONObject("packages") ?: throw IllegalArgumentException("ملف الباقات مفقود")
        val permissionsJson = root.optJSONObject("permissions") ?: throw IllegalArgumentException("ملف الصلاحيات مفقود")
        val triggerJson = root.optJSONObject("trigger") ?: throw IllegalArgumentException("ملف المشغل مفقود")
        val trustedJson = root.optJSONObject("trusted") ?: throw IllegalArgumentException("قائمة الموثقين مفقودة")
        val appPreferences = if (root.has("appPreferences")) {
            root.optJSONObject("appPreferences")
                ?: throw IllegalArgumentException("تفضيلات التطبيق في النسخة غير صالحة")
        } else null
        require(root.optInt("schemaVersion", 0) < 2 || appPreferences != null) {
            "النسخة الجديدة لا تحتوي على تفضيلات التطبيق"
        }
        require(appPreferences == null || !appPreferences.has("dark") || appPreferences.opt("dark") is Boolean) {
            "قيمة الوضع الليلي في النسخة غير صالحة"
        }
        require((appPreferences?.toString()?.toByteArray(Charsets.UTF_8)?.size ?: 0) <= 1024 * 1024) {
            "تفضيلات التطبيق في النسخة أكبر من الحد المسموح"
        }
        val incomingPackageIds = packageIdsFromConfig(packagesJson)
        incomingPackageIds.forEach { id -> require(inventory.has(id) && inventory.optJSONArray(id) != null) { "مخزون الباقة $id غير صالح أو مفقود" } }
        require(permissionsJson.optJSONObject("global") != null && permissionsJson.optJSONArray("clients") != null) { "ملف الصلاحيات غير مكتمل" }
        require(trustedJson.optJSONArray("clients") != null) { "قائمة الموثقين غير صالحة" }
        val sales = root.optJSONArray("sales") ?: JSONArray()
        val suppliedTransactions = root.optJSONArray("transactions")
        val entries = suppliedTransactions ?: legacyLedger(root.optJSONArray("debts") ?: JSONArray(), sales, root.optString("exportedAt", isoNow()))
        val transactionIds = mutableSetOf<String>()
        for (i in 0 until entries.length()) {
            val entry = entries.optJSONObject(i) ?: throw IllegalArgumentException("سجل حركة غير صالح")
            require(entry.optString("id").isNotBlank() && transactionIds.add(entry.optString("id"))) { "معرّف حركة مفقود أو مكرر" }
            require(entry.optString("phone").isNotBlank() && entry.optString("type").isNotBlank()) { "سجل حركة يفتقد العميل أو النوع" }
            require(entry.optLong("amount", -1L) >= 0L) { "قيمة حركة غير صالحة" }
        }
        val balances = balancesFrom(entries)
        val salesLog = if (root.has("salesLog")) root.optString("salesLog") else buildSalesLog(sales)
        require(salesLog.toByteArray(Charsets.UTF_8).size <= 50 * 1024 * 1024) { "سجل المبيعات كبير جداً" }

        // Save a private recoverable copy before replacing financial or inventory data.
        keepAutoBackup(context, currentAppPreferencesJson)
        val replacements = linkedMapOf<String, String>()
        (packageIds(context) + incomingPackageIds).forEach { id ->
            val cards = inventory.optJSONArray(id) ?: JSONArray()
            val values = (0 until cards.length()).map { cards.optString(it).trim() }.filter { it.isNotEmpty() && !it.contains('\n') && !it.contains('\r') }.distinct()
            replacements["cards_$id.txt"] = if (values.isEmpty()) "" else values.joinToString("\n", postfix = "\n")
        }
        replacements[LEDGER_NAME] = ledgerContent(entries)
        replacements["debts.txt"] = debtText(balances, entries)
        replacements["sales.log"] = salesLog
        replacements["packages.json"] = packagesJson.toString()
        replacements["permissions.json"] = permissionsJson.toString()
        replacements["trigger_config.json"] = triggerJson.toString()
        replacements["trusted_clients.json"] = trustedJson.toString()
        writeBatch(context, replacements)
        val restored = snapshot(context).toMutableMap()
        restored["hasAppPreferences"] = appPreferences != null
        if (appPreferences != null) restored["appPreferences"] = appPreferences.toMapSafe()
        restored
    }

    private fun buildSalesLog(sales: JSONArray): String = (0 until sales.length()).mapNotNull { index ->
        val sale = sales.optJSONObject(index) ?: return@mapNotNull null
        val time = sale.optString("time", stampNow())
        val price = sale.optLong("price", sale.optString("packageId").toLongOrNull() ?: 0L)
        val phone = sale.optString("phone")
        val card = sale.optString("card")
        val debt = sale.optLong("debt", 0L)
        val method = sale.optString("paymentMethod", "credit")
        val packageId = sale.optString("packageId", price.toString())
        if (phone.isBlank()) null else "$time | $price | $phone | $card | $debt | $method | $packageId"
    }.joinToString("\n").let { if (it.isEmpty()) "" else "$it\n" }
}
