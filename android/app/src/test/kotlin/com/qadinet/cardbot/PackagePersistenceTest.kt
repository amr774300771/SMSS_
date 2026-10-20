package com.qadinet.cardbot

import android.content.Context
import android.content.ContextWrapper
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
class PackagePersistenceTest {
    private val tempRoot = Files.createTempDirectory("cardbot-package-test").toFile()
    private val context: Context = object : ContextWrapper(RuntimeEnvironment.getApplication()) {
        override fun getFilesDir(): File = tempRoot
    }

    private val defaults = mapOf(
        "packages.json" to """{"schemaVersion":1,"packages":[{"id":"500","price":500,"label":"500","keywords":["500","خمس"]}]}""",
        "permissions.json" to """{"global":{"allowedPackages":["500"]},"clients":[{"phone":"700000000","allowedPackages":["500"]}]}""",
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
    fun add300And500PersistAcrossInitializeAndKeepExistingStockAndSales() {
        NativeStore.initialize(context, defaults)
        val directory = File(context.filesDir, "CardBot")
        File(directory, "cards_500.txt").writeText("CARD-500-A\n")
        val originalSales = "20261010-010000 | 500 | 700000000 | SOLD-500 | 0\n"
        File(directory, "sales.log").writeText(originalSales)

        val config = JSONObject(defaults.getValue("packages.json"))
        config.getJSONArray("packages").put(
            JSONObject().put("id", "300").put("price", 300).put("label", "300")
                .put("keywords", JSONArray().put("300").put("ثلاثمائة"))
        )
        NativeStore.saveConfig(context, "packages.json", config.toString())

        var snapshot = NativeStore.snapshot(context)
        val ids = ((snapshot["packages"] as Map<*, *>)["packages"] as List<*>)
            .map { (it as Map<*, *>)["id"].toString() }
        assertEquals(listOf("500", "300"), ids)
        assertEquals(listOf("CARD-500-A"), (snapshot["inventory"] as Map<*, *>)["500"])
        assertEquals(emptyList<String>(), (snapshot["inventory"] as Map<*, *>)["300"])
        assertEquals(originalSales, File(directory, "sales.log").readText())

        NativeStore.initialize(context, defaults)
        snapshot = NativeStore.snapshot(context)
        val reopenedPackages = ((snapshot["packages"] as Map<*, *>)["packages"] as List<*>)
        assertEquals(2, reopenedPackages.size)
        val persisted300 = reopenedPackages.map { it as Map<*, *> }.first { it["id"] == "300" }
        assertEquals(listOf("300", "ثلاثمائة"), persisted300["keywords"])
        assertEquals(listOf("CARD-500-A"), (snapshot["inventory"] as Map<*, *>)["500"])
        assertEquals(originalSales, File(directory, "sales.log").readText())
    }

    @Test
    fun seededRealPricesMatchPackageIdsAndNew1000PackageIsSaleReady() {
        val actualPackageDefaults = defaults + mapOf(
            "packages.json" to """{"schemaVersion":1,"packages":[{"id":"500","price":500,"label":"500","keywords":["500","خمس"]},{"id":"300","price":300,"label":"300","keywords":["300","ثلاثمائة","ثلاث مائة","ثلاثميه","ثلاثمية"]},{"id":"3000","price":3000,"label":"3000","keywords":["3000","ثلاثة آلاف","ثلاث آلاف","ثلاثه الاف","تلاته الاف"]},{"id":"200","price":200,"label":"200","keywords":["200","مئتان","مئتين","مائتان","مائتين"]}]}""",
            "permissions.json" to """{"global":{"allowAllClients":true},"clients":[]}"""
        )
        NativeStore.initialize(context, actualPackageDefaults)
        val initial = JSONObject(actualPackageDefaults.getValue("packages.json"))
            .getJSONArray("packages")
        val initialIds = (0 until initial.length()).map { index ->
            val item = initial.getJSONObject(index)
            assertEquals(item.getInt("price").toString(), item.getString("id"))
            item.getString("id")
        }.toSet()
        assertEquals(setOf("200", "300", "500", "3000"), initialIds)

        val updated = JSONObject(actualPackageDefaults.getValue("packages.json"))
        updated.getJSONArray("packages").put(
            JSONObject().put("id", "1000").put("price", 1000).put("label", "1000")
                .put("keywords", JSONArray().put("1000").put("ألف"))
        )
        NativeStore.saveConfig(context, "packages.json", updated.toString())

        val directory = File(context.filesDir, "CardBot")
        assertTrue(File(directory, "cards_1000.txt").exists())
        val permissions = JSONObject(File(directory, "permissions.json").readText())
        val allowed = permissions.getJSONObject("global").getJSONArray("allowedPackages")
        assertTrue((0 until allowed.length()).any { allowed.getString(it) == "1000" })
        val savedPackages = JSONObject(File(directory, "packages.json").readText())
            .getJSONArray("packages")
        assertTrue((0 until savedPackages.length()).any {
            val item = savedPackages.getJSONObject(it)
            item.getString("id") == "1000" && item.getInt("price") == 1000
        })
    }

    @Test
    fun addingPackagePreservesUnchangedLegacyDefinitionButRejectsEditingItWithoutMigration() {
        val legacyDefaults = defaults + mapOf(
            "packages.json" to """{"schemaVersion":1,"packages":[{"id":"legacy500","price":500,"label":"500","keywords":["500","خمس"]}]}""",
            "permissions.json" to """{"global":{"allowedPackages":["legacy500"]},"clients":[{"phone":"700000000","allowedPackages":["legacy500"]}]}"""
        )
        NativeStore.initialize(context, legacyDefaults)
        val config = JSONObject(legacyDefaults.getValue("packages.json"))
        config.getJSONArray("packages").put(
            JSONObject().put("id", "300").put("price", 300).put("label", "300")
                .put("keywords", JSONArray().put("300").put("ثلاثمائة"))
        )
        NativeStore.saveConfig(context, "packages.json", config.toString())

        val directory = File(context.filesDir, "CardBot")
        val saved = JSONObject(File(directory, "packages.json").readText())
        assertEquals(2, saved.getJSONArray("packages").length())
        assertTrue(File(directory, "cards_300.txt").exists())
        val permission = JSONObject(File(directory, "permissions.json").readText())
        assertTrue(permission.getJSONObject("global").getJSONArray("allowedPackages").toString().contains("300"))

        val before = File(directory, "packages.json").readText()
        val changedLegacy = JSONObject(before)
        changedLegacy.getJSONArray("packages").getJSONObject(0).put("keywords", JSONArray().put("changed"))
        assertRejected { NativeStore.saveConfig(context, "packages.json", changedLegacy.toString()) }
        assertEquals(before, File(directory, "packages.json").readText())
    }

    @Test
    fun duplicateIdAndKeywordCollisionAreRejectedWithoutReplacingSavedConfig() {
        NativeStore.initialize(context, defaults)
        val path = File(context.filesDir, "CardBot/packages.json")
        val before = path.readText()
        val duplicateId = """{"packages":[{"id":"500","price":500,"keywords":["500"]},{"id":"500","price":500,"keywords":["500 again"]}]}"""
        val duplicateKeyword = """{"packages":[{"id":"500","price":500,"keywords":["500","خمس"]},{"id":"300","price":300,"keywords":["خمس"]}]}"""
        val overlappingKeyword = """{"packages":[{"id":"500","price":500,"keywords":["500"]},{"id":"300","price":300,"keywords":["باقة 500"]}]}"""
        val mismatchedPrice = """{"packages":[{"id":"500","price":600,"keywords":["500"]}]}"""

        assertRejected { NativeStore.saveConfig(context, "packages.json", duplicateId) }
        assertRejected { NativeStore.saveConfig(context, "packages.json", duplicateKeyword) }
        assertRejected { NativeStore.saveConfig(context, "packages.json", overlappingKeyword) }
        assertRejected { NativeStore.saveConfig(context, "packages.json", mismatchedPrice) }
        assertEquals(before, path.readText())
    }

    @Test
    fun changingPriceMovesStockAndPermissionsButKeepsHistoricalSalesUntouched() {
        NativeStore.initialize(context, defaults)
        val directory = File(context.filesDir, "CardBot")
        val stockBefore = "CARD-500-A\nCARD-500-B\n"
        File(directory, "cards_500.txt").writeText(stockBefore)
        val originalSales = "20261010-010000 | 500 | 700000000 | SOLD-500 | 0\n"
        File(directory, "sales.log").writeText(originalSales)
        val originalLedger = """{"schemaVersion":1,"transactions":[{"id":"old-sale","type":"sale","packageId":"500","amount":500,"delta":0}]}"""
        File(directory, "transactions.json").writeText(originalLedger)

        val updated = """{"schemaVersion":1,"packages":[{"id":"600","price":600,"label":"600","keywords":["600","ست مئة"]}]}"""
        val snapshot = NativeStore.updatePackagePrice(context, "500", updated)
        val packages = ((snapshot["packages"] as Map<*, *>)["packages"] as List<*>)
        assertEquals("600", (packages.single() as Map<*, *>)["id"])
        assertEquals("", File(directory, "cards_500.txt").readText())
        assertEquals(stockBefore, File(directory, "cards_600.txt").readText())
        assertEquals(originalSales, File(directory, "sales.log").readText())
        assertEquals(originalLedger, File(directory, "transactions.json").readText())
        val permissionRoot = JSONObject(File(directory, "permissions.json").readText())
        assertEquals("600", permissionRoot.getJSONObject("global").getJSONArray("allowedPackages").getString(0))
        assertEquals("600", permissionRoot.getJSONArray("clients").getJSONObject(0).getJSONArray("allowedPackages").getString(0))
    }

    @Test
    fun refusesPriceMigrationIfDestinationHasCardsAndPreservesBothFiles() {
        NativeStore.initialize(context, defaults)
        val directory = File(context.filesDir, "CardBot")
        File(directory, "cards_500.txt").writeText("OLD-CARD\n")
        File(directory, "cards_600.txt").writeText("DO-NOT-OVERWRITE\n")
        val beforeConfig = File(directory, "packages.json").readText()

        assertRejected {
            NativeStore.updatePackagePrice(
                context,
                "500",
                """{"packages":[{"id":"600","price":600,"keywords":["600"]}]}"""
            )
        }
        assertEquals("OLD-CARD\n", File(directory, "cards_500.txt").readText())
        assertEquals("DO-NOT-OVERWRITE\n", File(directory, "cards_600.txt").readText())
        assertEquals(beforeConfig, File(directory, "packages.json").readText())
        assertFalse(File(directory, ".pending_transaction.json").exists())
    }

    @Test
    fun bulkInventoryEditMoveDeleteAndUndoAreAtomicAndPreserveOrder() {
        NativeStore.initialize(context, defaults)
        val directory = File(context.filesDir, "CardBot")
        val packages = JSONObject(defaults.getValue("packages.json"))
        packages.getJSONArray("packages").put(
            JSONObject().put("id", "600").put("price", 600).put("label", "600")
                .put("keywords", JSONArray().put("600"))
        )
        NativeStore.saveConfig(context, "packages.json", packages.toString())
        File(directory, "cards_500.txt").writeText("CARD-A\nCARD-B\n")
        File(directory, "cards_600.txt").writeText("CARD-C\n")

        var snapshot = NativeStore.updateInventory(
            context,
            JSONArray()
                .put(JSONObject().put("action", "edit").put("packageId", "500").put("card", "CARD-A").put("newCard", "CARD-A2"))
                .put(JSONObject().put("action", "move").put("packageId", "500").put("targetPackageId", "600").put("card", "CARD-B"))
                .toString()
        )
        var inventory = snapshot["inventory"] as Map<*, *>
        assertEquals(listOf("CARD-A2"), inventory["500"])
        assertEquals(listOf("CARD-C", "CARD-B"), inventory["600"])

        snapshot = NativeStore.undoInventoryChange(context)
        inventory = snapshot["inventory"] as Map<*, *>
        assertEquals(listOf("CARD-A", "CARD-B"), inventory["500"])
        assertEquals(listOf("CARD-C"), inventory["600"])

        snapshot = NativeStore.updateInventory(
            context,
            JSONArray().put(JSONObject().put("action", "delete").put("packageId", "500").put("card", "CARD-A")).toString()
        )
        assertEquals(listOf("CARD-B"), (snapshot["inventory"] as Map<*, *>)["500"])
        snapshot = NativeStore.undoInventoryChange(context)
        assertEquals(listOf("CARD-A", "CARD-B"), (snapshot["inventory"] as Map<*, *>)["500"])
    }

    @Test
    fun returnedHistoricalSaleCardCanBeEditedMovedAndDeletedWithoutChangingSalesHistory() {
        NativeStore.initialize(context, defaults)
        val directory = File(context.filesDir, "CardBot")
        File(directory, "cards_500.txt").writeText("AVAILABLE\nSOLD-CARD\n")
        val salesFile = File(directory, "sales.log")
        val historicalSale = "20261010-010000 | 500 | 700000000 | SOLD-CARD | 0\n"
        salesFile.writeText(historicalSale)

        val packages = JSONObject(defaults.getValue("packages.json"))
        packages.getJSONArray("packages").put(
            JSONObject().put("id", "600").put("price", 600).put("label", "600")
                .put("keywords", JSONArray().put("600"))
        )
        NativeStore.saveConfig(context, "packages.json", packages.toString())

        var snapshot = NativeStore.updateInventory(
            context,
            JSONArray().put(
                JSONObject().put("action", "edit").put("packageId", "500")
                    .put("card", "SOLD-CARD").put("newCard", "RETURNED-CARD")
            ).toString()
        )
        assertEquals(listOf("AVAILABLE", "RETURNED-CARD"), (snapshot["inventory"] as Map<*, *>)["500"])
        assertEquals(historicalSale, salesFile.readText())

        snapshot = NativeStore.updateInventory(
            context,
            JSONArray().put(
                JSONObject().put("action", "move").put("packageId", "500")
                    .put("targetPackageId", "600").put("card", "RETURNED-CARD")
            ).toString()
        )
        assertEquals(listOf("AVAILABLE"), (snapshot["inventory"] as Map<*, *>)["500"])
        assertEquals(listOf("RETURNED-CARD"), (snapshot["inventory"] as Map<*, *>)["600"])
        assertEquals(historicalSale, salesFile.readText())

        snapshot = NativeStore.updateInventory(
            context,
            JSONArray().put(
                JSONObject().put("action", "delete").put("packageId", "600")
                    .put("card", "RETURNED-CARD")
            ).toString()
        )
        assertEquals(emptyList<String>(), (snapshot["inventory"] as Map<*, *>)["600"])
        assertEquals(historicalSale, salesFile.readText())

        assertRejected {
            NativeStore.updateInventory(
                context,
                JSONArray().put(
                    JSONObject().put("action", "edit").put("packageId", "500")
                        .put("card", "AVAILABLE").put("newCard", "SOLD-CARD")
                ).toString()
            )
        }
        assertEquals("AVAILABLE\n", File(directory, "cards_500.txt").readText())
        assertEquals(historicalSale, salesFile.readText())
    }

    @Test
    fun newInventoryAdditionInvalidatesEarlierUndoWithoutLosingCards() {
        NativeStore.initialize(context, defaults)
        val directory = File(context.filesDir, "CardBot")
        File(directory, "cards_500.txt").writeText("CARD-A\nCARD-B\n")
        NativeStore.updateInventory(
            context,
            JSONArray().put(JSONObject().put("action", "delete").put("packageId", "500").put("card", "CARD-A")).toString()
        )
        NativeStore.addCards(context, "500", listOf("CARD-NEW"))

        assertRejected { NativeStore.undoInventoryChange(context) }
        assertEquals("CARD-B\nCARD-NEW\n", File(directory, "cards_500.txt").readText())
    }

    private fun assertRejected(action: () -> Unit) {
        var rejected = false
        try {
            action()
        } catch (_: IllegalArgumentException) {
            rejected = true
        }
        assertTrue("Expected the invalid operation to be rejected", rejected)
    }
}
