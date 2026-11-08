package org.boardgamescafe.dicetower

import android.Manifest
import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class CameraUiTest {
    @get:Rule val compose=createEmptyComposeRule()
    @Test fun localOnboardingCameraAndTimingAreVisibleWithoutPublishing() {
        val instrumentation=InstrumentationRegistry.getInstrumentation()
        val context=instrumentation.targetContext
        context.getSharedPreferences("tower",0).edit().clear().commit()
        ActivityScenario.launch(MainActivity::class.java).use { activity ->
            compose.onNodeWithText("Name your DiceTower").assertExists()
            compose.onNodeWithText("Keep local").performClick()
            instrumentation.uiAutomation.grantRuntimePermission(context.packageName,Manifest.permission.CAMERA)
            activity.moveToState(Lifecycle.State.CREATED);activity.moveToState(Lifecycle.State.RESUMED)
            try {
                compose.waitUntil(30000) { compose.onAllNodesWithText("inferences ·",substring=true).fetchSemanticsNodes().any { node -> node.config[SemanticsProperties.Text].any { Regex("^[1-9][0-9]* inferences").containsMatchIn(it.text) } } }
            } finally {
                File(context.noBackupFilesDir,"android-ui-tree.txt").writeText(compose.onRoot(useUnmergedTree=true).printToString())
                val debug=instrumentation.uiAutomation.takeScreenshot()
                File(context.noBackupFilesDir,"android-ui.png").outputStream().use { debug.compress(Bitmap.CompressFormat.PNG,100,it) }
            }
            compose.onNodeWithText("DiceTower").assertExists()
            compose.onNodeWithTag("torch-toggle").assertExists().assertIsOff()
            // The emulator virtual scene animates its TV; idle is tested separately with controlled frames.
            compose.onNodeWithText("Inference ",substring=true).assertExists()
            compose.onNodeWithText("Target",substring=true).assertExists()
            val shot=instrumentation.uiAutomation.takeScreenshot()
            File(context.noBackupFilesDir,"android-ui.png").outputStream().use { shot.compress(Bitmap.CompressFormat.PNG,100,it) }
        }
    }
}
