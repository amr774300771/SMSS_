package com.qadinet.cardbot

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.qadinet.cardbot/native"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "initialize" -> {
                        NativeStore.initialize(this, call.argument<Map<String, String>>("defaults") ?: emptyMap())
                        result.success(NativeStore.snapshot(this))
                    }
                    "snapshot" -> result.success(NativeStore.snapshot(this))
                    "addCards" -> {
                        NativeStore.addCards(this, call.argument<String>("packageId") ?: "", call.argument<List<String>>("cards") ?: emptyList())
                        result.success(NativeStore.snapshot(this))
                    }
                    "updateInventory" -> result.success(
                        NativeStore.updateInventory(this, call.argument<String>("changes") ?: "[]")
                    )
                    "undoInventoryChange" -> result.success(NativeStore.undoInventoryChange(this))
                    "deletePackage" -> result.success(
                        NativeStore.deletePackage(this, call.argument<String>("packageId") ?: "")
                    )
                    "restoreDeletedPackage" -> result.success(
                        NativeStore.restoreDeletedPackage(
                            this,
                            call.argument<String>("packageId") ?: "",
                            call.argument<String>("originalPackages") ?: "{}",
                            call.argument<String>("originalPermissions") ?: "{}",
                            call.argument<ArrayList<String>>("cards")?.toList().orEmpty()
                        )
                    )
                    "sell" -> result.success(
                        NativeStore.sell(
                            this,
                            call.argument<String>("packageId") ?: "",
                            call.argument<String>("phone") ?: "",
                            call.argument<String>("clientName") ?: "",
                            call.argument<Boolean>("sendSms") ?: false,
                            call.argument<String>("paymentMethod") ?: "cash"
                        )
                    )
                    "bulkSell" -> result.success(
                        NativeStore.bulkSell(
                            this,
                            (call.argument<Map<String, Any?>>("quantities") ?: emptyMap()).mapValues { (_, value) ->
                                (value as? Number)?.toInt() ?: 0
                            },
                            call.argument<String>("phone") ?: "",
                            call.argument<String>("clientName") ?: "",
                            call.argument<String>("paymentMethod") ?: "cash"
                        )
                    )
                    "manualSale" -> result.success(
                        NativeStore.manualSale(
                            this,
                            call.argument<String>("phone") ?: "",
                            call.argument<String>("clientName") ?: "",
                            call.argument<String>("description") ?: "",
                            call.argument<Number>("quantity")?.toInt() ?: 1,
                            call.argument<Number>("unitPrice")?.toLong() ?: 0L,
                            call.argument<Number>("unitCost")?.toLong() ?: 0L,
                            call.argument<String>("paymentMethod") ?: "cash"
                        )
                    )
                    "scheduleSale" -> {
                        val scheduled = NativeStore.scheduleSale(
                            this,
                            call.argument<String>("packageId") ?: "",
                            call.argument<String>("phone") ?: "",
                            call.argument<String>("clientName") ?: "",
                            call.argument<Number>("price")?.toInt() ?: 0,
                            call.argument<String>("paymentMethod") ?: "cash",
                            call.argument<Number>("scheduledAtMillis")?.toLong() ?: 0L
                        )
                        CardBotService.refresh(this)
                        result.success(scheduled)
                    }
                    "cancelScheduledSale" -> result.success(
                        NativeStore.cancelScheduledSale(this, call.argument<String>("scheduleId") ?: "")
                    )
                    "returnSale" -> result.success(
                        NativeStore.returnSale(
                            this,
                            call.argument<String>("transactionId") ?: "",
                            call.argument<String>("reason") ?: ""
                        )
                    )
                    "recordReceipt" -> result.success(
                        NativeStore.recordReceipt(
                            this,
                            call.argument<String>("phone") ?: "",
                            call.argument<Number>("amount")?.toLong() ?: 0L,
                            call.argument<String>("paymentMethod") ?: "cash",
                            call.argument<String>("reference") ?: "",
                            call.argument<String>("note") ?: "",
                            call.argument<String>("clientName") ?: ""
                        )
                    )
                    "recordAdjustment" -> result.success(
                        NativeStore.recordAdjustment(
                            this,
                            call.argument<String>("phone") ?: "",
                            call.argument<Number>("amount")?.toLong() ?: 0L,
                            call.argument<String>("direction") ?: "",
                            call.argument<String>("reason") ?: "",
                            call.argument<String>("clientName") ?: ""
                        )
                    )
                    "setManualDebtBalance" -> result.success(
                        NativeStore.setManualDebtBalance(
                            this,
                            call.argument<String>("phone") ?: "",
                            call.argument<Number>("targetBalance")?.toLong() ?: 0L,
                            call.argument<String>("reason") ?: "",
                            call.argument<String>("clientName") ?: ""
                        )
                    )
                    "saveConfig" -> {
                        NativeStore.saveConfig(this, call.argument<String>("filename") ?: "", call.argument<String>("content") ?: "")
                        result.success(NativeStore.snapshot(this))
                    }
                    "updatePackagePrice" -> result.success(
                        NativeStore.updatePackagePrice(
                            this,
                            call.argument<String>("oldPackageId") ?: "",
                            call.argument<String>("content") ?: "{}"
                        )
                    )
                    "saveClientAndTrusted" -> {
                        NativeStore.saveClientAndTrusted(this, call.argument<String>("permissions") ?: "{}", call.argument<String>("trusted") ?: "{}")
                        result.success(NativeStore.snapshot(this))
                    }
                    "exportBackup" -> result.success(
                        NativeStore.exportBackup(
                            this,
                            call.argument<String>("password") ?: "",
                            call.argument<String>("appPreferences") ?: "{}"
                        )
                    )
                    "restoreBackup" -> {
                        val restored = NativeStore.restoreBackup(
                            this,
                            call.argument<String>("content") ?: "",
                            call.argument<String>("mode") ?: "",
                            call.argument<String>("password") ?: "",
                            call.argument<String>("currentAppPreferences") ?: "{}"
                        )
                        if (call.argument<String>("mode") == "replace_all") {
                            ScheduledSaleAlarm.rescheduleAll(this)
                            CardBotService.refresh(this)
                        }
                        result.success(restored)
                    }
                    "sendSms" -> {
                        NativeStore.sendSms(this, call.argument<String>("phone") ?: "", call.argument<String>("message") ?: "")
                        result.success(true)
                    }
                    "openSmsComposer" -> {
                        val rawPhone = call.argument<String>("phone")?.trim().orEmpty()
                        val message = call.argument<String>("message").orEmpty()
                        val phone = PhoneNumberNormalizer.toSmsAddress(rawPhone)
                            ?: throw IllegalArgumentException("رقم الهاتف غير صالح؛ أدخل رقماً يمنياً أو دولياً صحيحاً")
                        require(message.isNotBlank()) { "نص الرسالة فارغ" }
                        val intent = Intent(Intent.ACTION_SENDTO).apply {
                            data = Uri.fromParts("smsto", phone, null)
                            putExtra("sms_body", message)
                        }
                        startActivity(intent)
                        result.success(true)
                    }
                    "markSaleReceived" -> result.success(
                        NativeStore.markSaleReceived(this, call.argument<String>("transactionId") ?: "")
                    )
                    "serviceDiagnostics" -> {
                        val status = NativeStore.serviceDiagnostics(this, CardBotService.running).toMutableMap()
                        status["whatsappNotificationAccess"] = WhatsAppNotificationListener.hasNotificationAccess(this)
                        result.success(status)
                    }
                    "hasWhatsAppNotificationAccess" -> result.success(
                        WhatsAppNotificationListener.hasNotificationAccess(this)
                    )
                    "openWhatsAppNotificationSettings" -> {
                        WhatsAppNotificationListener.openNotificationAccessSettings(this)
                        result.success(true)
                    }
                    "startService" -> { CardBotService.start(this); result.success(true) }
                    "stopService" -> { stopService(Intent(this, CardBotService::class.java)); result.success(true) }
                    "toggleService" -> { NativeStore.toggleTrigger(this); CardBotService.refresh(this); result.success(true) }
                    "openBatterySettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName"))
                            startActivity(intent)
                        }
                        result.success(true)
                    }
                    "dataPath" -> result.success(NativeStore.directory(this).absolutePath)
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.e("CardBotNative", "MethodChannel method=${call.method} failed: ${e.message}", e)
                result.error(
                    "NATIVE_ERROR",
                    e.message ?: "تعذر إكمال العملية",
                    mapOf("method" to call.method, "exception" to e.javaClass.name)
                )
            }
        }
    }
}
