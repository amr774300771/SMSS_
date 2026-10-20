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
class BackupRestoreTest {
    private val tempRoot = Files.createTempDirectory("cardbot-backup-test").toFile()
    private val context: Context = object : ContextWrapper(RuntimeEnvironment.getApplication()) {
        override fun getFilesDir(): File = tempRoot
    }

    private val defaults = mapOf(
        "packages.json" to """{"schemaVersion":1,"packages":[{"id":"500","price":500,"label":"500","keywords":["500"]}]}""",
        "permissions.json" to """{"global":{"allowAllClients":true,"allowedPackages":["500"]},"clients":[]}""",
        "trigger_config.json" to """{"triggerEnabled":true,"processedCount":0,"totalSalesCount":0,"errorCount":0}""",
        "trusted_clients.json" to """{"filterEnabled":false,"mode":"all","clients":[]}""",
        "transactions.json" to """{"schemaVersion":1,"transactions":[]}""",
        "debts.txt" to "",
        "sales.log" to ""
    )

    @After
    fun cleanup() {
        tempRoot.deleteRecursively()
    }

    @Test
    fun encryptedFullBackupRestoresUiAndOperationalSettingsAndAutoBackupKeepsCurrentPrefs() {
        NativeStore.initialize(context, defaults)
        val directory = File(context.filesDir, "CardBot")
        File(directory, "cards_500.txt").writeText("CARD-BACKED-UP\n")
        File(directory, "sales.log").writeText(
            "20261010-010000 | 500 | 777123456 | SOLD-BACKED-UP | 250 | credit | 500\n"
        )
        File(directory, "transactions.json").writeText(
            JSONObject()
                .put("schemaVersion", 1)
                .put(
                    "transactions",
                    JSONArray().put(
                        JSONObject()
                            .put("id", "receipt-1")
                            .put("type", "receipt")
                            .put("phone", "777123456")
                            .put("amount", 250)
                            .put("delta", -250)
                            .put("affectsBalance", true)
                            .put("clientName", "عميل النسخة")
                    )
                )
                .toString()
        )
        NativeStore.saveConfig(
            context,
            "trigger_config.json",
            """{"triggerEnabled":false,"processedCount":7,"totalSalesCount":4,"errorCount":2,"lastRun":"2026-10-10T01:00:00Z"}"""
        )
        NativeStore.saveConfig(
            context,
            "permissions.json",
            """{"global":{"allowAllClients":false,"allowedPackages":["500"],"maxDebt":1200},"clients":[{"phone":"777123456","allowedPackages":["500"],"maxDebt":900}]}"""
        )
        NativeStore.saveConfig(
            context,
            "trusted_clients.json",
            """{"filterEnabled":true,"mode":"only","clients":[{"phone":"777123456","name":"عميل نشط"}],"archivedClients":[{"phone":"771111111","name":"عميل مؤرشف","archivedAt":"2026-10-01T00:00:00Z"}]}"""
        )

        val encryptedBackup = NativeStore.exportBackup(
            context,
            "secure-pass-123",
            """{"dark":true,"compactReports":false}"""
        )

        // Change the live state so the restore and its automatic recovery copy are observable.
        File(directory, "cards_500.txt").writeText("CURRENT-CARD\n")
        File(directory, "sales.log").writeText("CURRENT-SALE\n")
        NativeStore.saveConfig(
            context,
            "trigger_config.json",
            """{"triggerEnabled":true,"processedCount":1,"totalSalesCount":1,"errorCount":0}"""
        )
        NativeStore.saveConfig(
            context,
            "trusted_clients.json",
            """{"filterEnabled":false,"mode":"all","clients":[],"archivedClients":[]}"""
        )

        val restored = NativeStore.restoreBackup(
            context,
            encryptedBackup,
            "replace_all",
            "secure-pass-123",
            """{"dark":false,"currentOnly":"preserved-in-recovery"}"""
        )

        assertTrue(restored["hasAppPreferences"] as Boolean)
        val restoredPrefs = restored["appPreferences"] as Map<*, *>
        assertEquals(true, restoredPrefs["dark"])
        assertEquals(false, restoredPrefs["compactReports"])
        assertEquals(listOf("CARD-BACKED-UP"), (restored["inventory"] as Map<*, *>) ["500"])
        assertEquals("20261010-010000 | 500 | 777123456 | SOLD-BACKED-UP | 250 | credit | 500\n", File(directory, "sales.log").readText())
        assertEquals(false, ((restored["trigger"] as Map<*, *>) ["triggerEnabled"]))
        val permissions = restored["permissions"] as Map<*, *>
        assertEquals(900, (((permissions["clients"] as List<*>).single() as Map<*, *>) ["maxDebt"]))
        val trusted = restored["trusted"] as Map<*, *>
        assertEquals(1, (trusted["archivedClients"] as List<*>).size)
        assertEquals(1, (restored["transactions"] as List<*>).size)

        val autoBackup = File(directory, "AutoBackups").listFiles()!!.single()
        val autoJson = JSONObject(autoBackup.readText())
        assertEquals(2, autoJson.getInt("schemaVersion"))
        assertEquals(false, autoJson.getJSONObject("appPreferences").getBoolean("dark"))
        assertEquals(
            "CURRENT-CARD",
            autoJson.getJSONObject("inventory").getJSONArray("500").getString(0)
        )
    }

    @Test
    fun legacyBackupWithoutUiPreferencesRestoresWithoutOverwritingCurrentPreferences() {
        NativeStore.initialize(context, defaults)
        val legacyRoot = JSONObject(NativeStore.exportBackup(context))
        legacyRoot.put("schemaVersion", 1)
        legacyRoot.remove("appPreferences")
        val legacy = legacyRoot.toString()

        val result = NativeStore.restoreBackup(
            context,
            legacy,
            "replace_all",
            currentAppPreferencesJson = """{"dark":true}"""
        )

        assertFalse(result["hasAppPreferences"] as Boolean)
        assertFalse(result.containsKey("appPreferences"))
    }
}
