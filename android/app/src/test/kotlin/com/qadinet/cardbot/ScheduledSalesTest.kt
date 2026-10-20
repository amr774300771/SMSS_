package com.qadinet.cardbot

import android.content.Context
import android.content.ContextWrapper
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
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
class ScheduledSalesTest {
    private val tempRoot = Files.createTempDirectory("cardbot-scheduled-sales").toFile()
    private val context: Context = object : ContextWrapper(RuntimeEnvironment.getApplication()) {
        override fun getFilesDir(): File = tempRoot
    }

    private val defaults = mapOf(
        "packages.json" to """{"schemaVersion":1,"packages":[{"id":"500","price":500,"label":"500","keywords":["500"]}]}""",
        "permissions.json" to """{"global":{"allowAllClients":true,"allowedPackages":["500"],"maxDebt":50000,"maxDailyTransactions":10,"maxDailyAmount":100000},"clients":[]}""",
        "trigger_config.json" to """{"triggerEnabled":true,"processedCount":0,"totalSalesCount":0,"errorCount":0}""",
        "trusted_clients.json" to """{"filterEnabled":false,"clients":[]}""",
        "transactions.json" to """{"schemaVersion":1,"transactions":[]}""",
        "debts.txt" to "",
        "sales.log" to ""
    )

    @After
    fun cleanup() {
        tempRoot.deleteRecursively()
    }

    @Test
    fun dueCreditSaleSendsAutomaticSmsAndReturnRestoresCardAndReversesDebt() {
        NativeStore.initialize(context, defaults)
        NativeStore.addCards(context, "500", listOf("CARD-500-RETURN"))
        val scheduledAt = System.currentTimeMillis() + 60_000L
        val scheduled = NativeStore.scheduleSale(context, "500", "700000000", "عميل اختبار", 500, "credit", scheduledAt)
        assertEquals(500, (((scheduled["scheduledSale"] as Map<*, *>) ["price"]) as Number).toInt())
        val triggerFile = File(context.filesDir, "CardBot/trigger_config.json")
        val trigger = JSONObject(triggerFile.readText())
        trigger.getJSONArray("scheduledSales").getJSONObject(0)
            .put("scheduledAtMillis", System.currentTimeMillis() - 1_000L)
        triggerFile.writeText(trigger.toString())

        NativeStore.processDueSales(context)
        var snapshot = NativeStore.snapshot(context)
        val sales = snapshot["sales"] as List<*>
        assertEquals(1, sales.size)
        val sale = sales.single() as Map<*, *>
        assertEquals("CARD-500-RETURN", sale["card"])
        assertEquals("completed", (((snapshot["trigger"] as Map<*, *>) ["scheduledSales"] as List<*>).single() as Map<*, *>) ["status"])
        val transactionId = sale["transactionId"].toString()

        snapshot = NativeStore.returnSale(context, transactionId, "استرجاع للاختبار")
        assertEquals(listOf("CARD-500-RETURN"), (snapshot["inventory"] as Map<*, *>) ["500"])
        assertTrue((snapshot["debts"] as List<*>).isEmpty())
        val returnedSale = (snapshot["sales"] as List<*>).single() as Map<*, *>
        assertTrue(returnedSale["returnedAt"].toString().isNotBlank())
        val transactions = snapshot["transactions"] as List<*>
        assertTrue(transactions.any { (it as Map<*, *>) ["type"] == "sale_return" })

        try {
            NativeStore.returnSale(context, transactionId, "تكرار")
            throw AssertionError("A sale must not be returned twice")
        } catch (_: IllegalArgumentException) {
            // Expected: idempotency guard prevents duplicate inventory and ledger changes.
        }
    }

    @Test
    fun pendingScheduleCanBeCancelledWithoutSellingOrConsumingStock() {
        NativeStore.initialize(context, defaults)
        NativeStore.addCards(context, "500", listOf("CARD-500-KEEP"))
        val scheduled = NativeStore.scheduleSale(
            context,
            "500",
            "700000000",
            "عميل اختبار",
            500,
            "cash",
            System.currentTimeMillis() + 60_000L
        )
        val scheduleId = ((scheduled["scheduledSale"] as Map<*, *>) ["id"]).toString()
        val snapshot = NativeStore.cancelScheduledSale(context, scheduleId)
        assertEquals("cancelled", (((snapshot["trigger"] as Map<*, *>) ["scheduledSales"] as List<*>).single() as Map<*, *>) ["status"])
        NativeStore.processDueSales(context)
        val after = NativeStore.snapshot(context)
        assertTrue((after["sales"] as List<*>).isEmpty())
        assertEquals(listOf("CARD-500-KEEP"), (after["inventory"] as Map<*, *>) ["500"])
    }

    @Test
    fun manualDebtBalanceCreatesAuditedAdjustmentsAndPreservesEarlierEntries() {
        NativeStore.initialize(context, defaults)

        var snapshot = NativeStore.setManualDebtBalance(
            context, "700000000", 1200L, "رصيد سابق", "عميل اختبار"
        )
        assertEquals(1200L, (((snapshot["debts"] as List<*>).single() as Map<*, *>)["amount"] as Number).toLong())
        var entries = snapshot["transactions"] as List<*>
        assertEquals(1, entries.size)
        assertEquals("adjustment_debit", (entries.single() as Map<*, *>)["type"])
        assertEquals("تعديل يدوي للرصيد: رصيد سابق", (entries.single() as Map<*, *>)["note"])

        snapshot = NativeStore.setManualDebtBalance(
            context, "700000000", 700L, "تصحيح المبلغ", "عميل اختبار"
        )
        assertEquals(700L, (((snapshot["debts"] as List<*>).single() as Map<*, *>)["amount"] as Number).toLong())
        entries = snapshot["transactions"] as List<*>
        assertEquals(2, entries.size)
        assertEquals(-500L, ((entries.last() as Map<*, *>)["delta"] as Number).toLong())

        snapshot = NativeStore.setManualDebtBalance(
            context, "700000000", 0L, "تسديد الرصيد", "عميل اختبار"
        )
        assertTrue((snapshot["debts"] as List<*>).isEmpty())
        assertEquals(3, (snapshot["transactions"] as List<*>).size)
    }

    @Test
    fun manualCreditSaleAccumulatesDebtWithoutConsumingInventory() {
        NativeStore.initialize(context, defaults)
        NativeStore.addCards(context, "500", listOf("CARD-KEEP"))
        NativeStore.setManualDebtBalance(context, "700000000", 2000L, "رصيد سابق", "عميل اختبار")
        val snapshot = NativeStore.manualSale(context, "700000000", "عميل اختبار", "خدمة يدوية", 2, 700L, 400L, "credit")
        assertEquals(3400L, snapshot["balanceAfter"])
        assertEquals(600L, snapshot["profit"])
        assertEquals(listOf("CARD-KEEP"), (snapshot["inventory"] as Map<*, *>) ["500"])
        val sale = (snapshot["sales"] as List<*>).single() as Map<*, *>
        assertEquals("manual", sale["saleSource"])
        assertEquals(3400L, (snapshot["debts"] as List<*>).single().let { (it as Map<*, *>) ["amount"] })
    }
}
