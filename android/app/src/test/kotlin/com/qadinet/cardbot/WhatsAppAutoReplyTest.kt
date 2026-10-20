package com.qadinet.cardbot

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Bundle
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File
import java.nio.file.Files

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class WhatsAppAutoReplyTest {
    private val tempRoot = Files.createTempDirectory("cardbot-whatsapp-auto").toFile()
    private val context: Context = object : ContextWrapper(RuntimeEnvironment.getApplication()) {
        override fun getFilesDir(): File = tempRoot
    }

    private fun defaults(autoReply: Boolean) = mapOf(
        "packages.json" to """{"schemaVersion":1,"packages":[{"id":"500","price":500,"label":"500","keywords":["500"]}]}""",
        "permissions.json" to """{"global":{"allowAllClients":true,"allowedPackages":["500"],"maxDebt":50000,"maxDailyTransactions":10,"maxDailyAmount":100000},"clients":[]}""",
        "trigger_config.json" to """{"triggerEnabled":true,"whatsappAutoReplyEnabled":$autoReply,"processedCount":0,"totalSalesCount":0,"errorCount":0}""",
        "trusted_clients.json" to """{"filterEnabled":false,"clients":[{"phone":"700000000","name":"عميل اختبار"},{"phone":"700000001","name":"اسم مكرر"},{"phone":"700000002","name":"اسم مكرر"}]}""",
        "transactions.json" to """{"schemaVersion":1,"transactions":[]}""",
        "debts.txt" to "",
        "sales.log" to ""
    )

    @After
    fun cleanup() {
        tempRoot.deleteRecursively()
    }

    @Test
    fun enabledWhatsAppOrderSellsOnceAndRepliesThroughProvidedAction() {
        NativeStore.initialize(context, defaults(autoReply = true))
        NativeStore.addCards(context, "500", listOf("WA-CARD-500"))
        val replies = mutableListOf<String>()

        NativeStore.processIncoming(context, "700000000", "500", channel = "whatsapp") {
            replies.add(it)
            true
        }

        val snapshot = NativeStore.snapshot(context)
        assertEquals(1, (snapshot["sales"] as List<*>).size)
        assertEquals(emptyList<String>(), (snapshot["inventory"] as Map<*, *>) ["500"])
        assertEquals(1, replies.size)
        assertTrue(replies.single().contains("WA-CARD-500"))
        assertTrue(replies.single().contains("500"))
    }

    @Test
    fun WhatsAppAutoReplyIsDisabledByDefaultAndDoesNotSell() {
        NativeStore.initialize(context, defaults(autoReply = false))
        NativeStore.addCards(context, "500", listOf("WA-CARD-KEEP"))
        val replies = mutableListOf<String>()

        NativeStore.processIncoming(context, "700000000", "500", channel = "whatsapp") {
            replies.add(it)
            true
        }

        val snapshot = NativeStore.snapshot(context)
        assertTrue((snapshot["sales"] as List<*>).isEmpty())
        assertEquals(listOf("WA-CARD-KEEP"), (snapshot["inventory"] as Map<*, *>) ["500"])
        assertTrue(replies.isEmpty())
    }

    @Test
    fun trustedNameResolutionRequiresOneExactUniqueMatch() {
        NativeStore.initialize(context, defaults(autoReply = false))

        assertEquals("700000000", NativeStore.trustedPhoneForWhatsAppLabel(context, "  عميل   اختبار "))
        assertNull(NativeStore.trustedPhoneForWhatsAppLabel(context, "اسم مكرر"))
        assertNull(NativeStore.trustedPhoneForWhatsAppLabel(context, "عميل غير مسجل"))
    }

    @Test
    fun notificationWithMatchingConversationTitleIsStillTreatedAsOneToOne() {
        val extras = Bundle().apply {
            putCharSequence(Notification.EXTRA_TITLE, "عميل اختبار")
            putCharSequence(Notification.EXTRA_CONVERSATION_TITLE, "عميل اختبار")
        }
        assertEquals(false, WhatsAppNotificationListener.isGroupConversation(extras, 35))
        extras.putBoolean(Notification.EXTRA_IS_GROUP_CONVERSATION, true)
        assertTrue(WhatsAppNotificationListener.isGroupConversation(extras, 35))
    }

    @Test
    fun notificationTextHasPriorityOverBigText() {
        val extras = Bundle().apply {
            putCharSequence(Notification.EXTRA_BIG_TEXT, "300")
            putCharSequence(Notification.EXTRA_TEXT, "500")
        }
        assertEquals("500", WhatsAppNotificationListener.extractNotificationMessage(extras))
    }

    @Test
    fun notificationMessageFallsBackToBigTextThenTitle() {
        val extras = Bundle().apply {
            putCharSequence(Notification.EXTRA_BIG_TEXT, "  300  ")
            putCharSequence(Notification.EXTRA_TITLE, "500")
        }
        assertEquals("300", WhatsAppNotificationListener.extractNotificationMessage(extras))
        extras.putCharSequence(Notification.EXTRA_BIG_TEXT, " ")
        assertEquals("500", WhatsAppNotificationListener.extractNotificationMessage(extras))
    }

    @Test
    fun explicitOneToOneClassificationOverridesDifferentConversationTitle() {
        val extras = Bundle().apply {
            putBoolean(Notification.EXTRA_IS_GROUP_CONVERSATION, false)
            putCharSequence(Notification.EXTRA_TITLE, "عميل")
            putCharSequence(Notification.EXTRA_CONVERSATION_TITLE, "القاضي نت")
        }
        assertEquals(false, WhatsAppNotificationListener.isGroupConversation(extras, 35))
    }

    @Test
    fun dynamicallyExtractsFreeFormRemoteInputFromNotificationActions() {
        val app = RuntimeEnvironment.getApplication()
        val icon = Icon.createWithResource(app, android.R.drawable.ic_dialog_info)
        val firstPendingIntent = PendingIntent.getBroadcast(
            app,
            1,
            Intent(app, MainActivity::class.java).setAction("reply.nontext"),
            PendingIntent.FLAG_IMMUTABLE
        )
        val secondPendingIntent = PendingIntent.getBroadcast(
            app,
            2,
            Intent(app, MainActivity::class.java).setAction("reply.text"),
            PendingIntent.FLAG_IMMUTABLE
        )
        val nonTextInput = RemoteInput.Builder("data_reply")
            .setAllowFreeFormInput(false)
            .build()
        val textInput = RemoteInput.Builder("text_reply")
            .setAllowFreeFormInput(true)
            .build()
        val nonTextAction = Notification.Action.Builder(
            icon, "إجراء بيانات", firstPendingIntent
        ).addRemoteInput(nonTextInput).build()
        val textAction = Notification.Action.Builder(
            icon, "رد نصي", secondPendingIntent
        ).addRemoteInput(textInput).build()
        val notification = Notification.Builder(app, "test-channel")
            .addAction(nonTextAction)
            .addAction(textAction)
            .build()

        val extractedAction =
            WhatsAppNotificationListener.firstTextReplyAction(notification)
                ?: throw AssertionError("لم يُستخرج إجراء الرد النصي")
        val extractedInputs =
            WhatsAppNotificationListener.textReplyInputs(extractedAction)

        assertEquals("رد نصي", extractedAction.title)
        assertEquals(1, extractedInputs.size)
        assertEquals("text_reply", extractedInputs.single().resultKey)
    }

    @Test
    fun repeatedIdenticalMessageInLaterNotificationHasItsOwnDedupeIdentity() {
        val first = WhatsAppNotificationListener.notificationDedupeDigest(
            "whatsapp|conversation", 1000L, "700000000", "500"
        )
        val repeated = WhatsAppNotificationListener.notificationDedupeDigest(
            "whatsapp|conversation", 2000L, "700000000", "500"
        )
        val duplicateDelivery = WhatsAppNotificationListener.notificationDedupeDigest(
            "whatsapp|conversation", 1000L, "700000000", "500"
        )
        assertTrue(first != repeated)
        assertEquals(first, duplicateDelivery)
    }

    @Test
    fun smsAddressNormalizationSupportsYemeniLocalAndInternationalForms() {
        assertEquals("+967777123456", PhoneNumberNormalizer.toSmsAddress("777123456"))
        assertEquals("+967777123456", PhoneNumberNormalizer.toSmsAddress("0777123456"))
        assertEquals("+967777123456", PhoneNumberNormalizer.toSmsAddress("00967 777 123 456"))
        assertEquals("+967777123456", PhoneNumberNormalizer.toSmsAddress("+٩٦٧ ٧٧٧ ١٢٣ ٤٥٦"))
        assertNull(PhoneNumberNormalizer.toSmsAddress("12345"))
    }

    @Test
    fun failedWhatsAppReplyRetryUsesTheAlreadySoldCard() {
        NativeStore.initialize(context, defaults(autoReply = true))
        NativeStore.addCards(context, "500", listOf("WA-CARD-ONCE", "WA-CARD-SECOND"))
        val eventId = "stable-notification-event"

        val first = NativeStore.processIncoming(
            context,
            "700000000",
            "500",
            channel = "whatsapp",
            eventId = eventId,
            whatsappReply = { false }
        )
        assertEquals(false, first)
        assertEquals(1, (NativeStore.snapshot(context)["sales"] as List<*>).size)

        val replies = mutableListOf<String>()
        val retry = NativeStore.processIncoming(
            context,
            "700000000",
            "500",
            channel = "whatsapp",
            eventId = eventId,
            whatsappReply = {
                replies.add(it)
                true
            }
        )
        val snapshot = NativeStore.snapshot(context)
        assertEquals(true, retry)
        assertEquals(1, (snapshot["sales"] as List<*>).size)
        assertEquals(listOf("WA-CARD-SECOND"),
            (snapshot["inventory"] as Map<*, *>) ["500"])
        assertTrue(replies.single().contains("WA-CARD-ONCE"))
        assertEquals("submitted",
            ((snapshot["transactions"] as List<*>).single() as Map<*, *>)["whatsappStatus"])
    }

    @Test
    fun mostSpecificKeywordWinsRegardlessOfPackagePriceOrder() {
        NativeStore.initialize(context, defaults(autoReply = true).toMutableMap().apply {
            put(
                "packages.json",
                """{"schemaVersion":1,"packages":[{"id":"300","price":300,"label":"300","keywords":["نت"]},{"id":"500","price":500,"label":"500","keywords":["نت 500"]}]}"""
            )
            put(
                "permissions.json",
                """{"global":{"allowAllClients":true,"allowedPackages":["300","500"],"maxDebt":50000,"maxDailyTransactions":50,"maxDailyAmount":100000},"clients":[]}"""
            )
        })
        NativeStore.addCards(context, "300", listOf("BROAD-CARD"))
        NativeStore.addCards(context, "500", listOf("SPECIFIC-CARD"))

        NativeStore.processIncoming(
            context,
            "700000000",
            "أريد نت 500",
            channel = "whatsapp",
            eventId = "specific-keyword-event",
            whatsappReply = { true }
        )

        val sales = NativeStore.snapshot(context)["sales"] as List<*>
        assertEquals(1, sales.size)
        assertEquals("500", (sales.single() as Map<*, *>) ["packageId"])
    }

    @Test
    fun equallySpecificPackageMatchesDoNotSellAnyCard() {
        NativeStore.initialize(context, defaults(autoReply = true).toMutableMap().apply {
            put(
                "packages.json",
                """{"schemaVersion":1,"packages":[{"id":"300","price":300,"label":"300","keywords":["طلب"]},{"id":"500","price":500,"label":"500","keywords":["طلب"]}]}"""
            )
            put(
                "permissions.json",
                """{"global":{"allowAllClients":true,"allowedPackages":["300","500"],"maxDebt":50000,"maxDailyTransactions":50,"maxDailyAmount":100000},"clients":[]}"""
            )
        })
        NativeStore.addCards(context, "300", listOf("CARD-300"))
        NativeStore.addCards(context, "500", listOf("CARD-500"))
        val replies = mutableListOf<String>()

        NativeStore.processIncoming(
            context,
            "700000000",
            "طلب",
            channel = "whatsapp",
            eventId = "ambiguous-package-event",
            whatsappReply = { replies.add(it); true }
        )

        val snapshot = NativeStore.snapshot(context)
        assertTrue((snapshot["sales"] as List<*>).isEmpty())
        assertEquals(listOf("CARD-300"), (snapshot["inventory"] as Map<*, *>) ["300"])
        assertEquals(listOf("CARD-500"), (snapshot["inventory"] as Map<*, *>) ["500"])
        assertTrue(replies.isEmpty())
    }

    @Test
    fun outOfStockRequestDoesNotCreateSaleOrConsumeInventory() {
        NativeStore.initialize(context, defaults(autoReply = true))
        val replies = mutableListOf<String>()

        NativeStore.processIncoming(
            context,
            "700000000",
            "500",
            channel = "whatsapp",
            eventId = "out-of-stock-event",
            whatsappReply = { replies.add(it); true }
        )

        val snapshot = NativeStore.snapshot(context)
        assertTrue((snapshot["sales"] as List<*>).isEmpty())
        assertEquals(emptyList<String>(), (snapshot["inventory"] as Map<*, *>) ["500"])
        assertEquals(1, replies.size)
        assertTrue(replies.single().isNotBlank())
    }

    @Test
    fun packageDeleteUndoRestoresDefinitionStockAndAllowedLists() {
        val originalPackages = """{"schemaVersion":1,"packages":[{"id":"500","price":500,"label":"500","keywords":["500"]},{"id":"600","price":600,"label":"600","keywords":["600"]}]}"""
        val originalPermissions = """{"global":{"allowAllClients":false,"allowedPackages":["500","600"],"maxDebt":50000,"maxDailyTransactions":10,"maxDailyAmount":100000},"clients":[{"phone":"777123456","allowedPackages":["600"]}]}"""
        NativeStore.initialize(context, defaults(autoReply = false).toMutableMap().apply {
            put("packages.json", originalPackages)
            put("permissions.json", originalPermissions)
        })
        NativeStore.addCards(context, "600", listOf("RESTORE-CARD-600"))

        NativeStore.deletePackage(context, "600")
        NativeStore.restoreDeletedPackage(
            context,
            "600",
            originalPackages,
            originalPermissions,
            listOf("RESTORE-CARD-600")
        )

        val snapshot = NativeStore.snapshot(context)
        val packageConfig = snapshot["packages"] as Map<*, *>
        val packages = packageConfig["packages"] as List<*>
        assertEquals(2, packages.size)
        assertEquals(listOf("RESTORE-CARD-600"),
            (snapshot["inventory"] as Map<*, *>) ["600"])
        val permissions = snapshot["permissions"] as Map<*, *>
        val global = permissions["global"] as Map<*, *>
        assertTrue((global["allowedPackages"] as List<*>).contains("600"))
        val client = (permissions["clients"] as List<*>).single() as Map<*, *>
        assertTrue((client["allowedPackages"] as List<*>).contains("600"))
    }
}
