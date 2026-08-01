package io.godstone.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.lifecycle.lifecycleScope
import dagger.hilt.android.AndroidEntryPoint
import io.godstone.app.ui.GodstoneNavHost
import io.godstone.app.ui.theme.GodstoneTheme
import io.godstone.mesh.MeshNode
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : ComponentActivity() {

    @Inject lateinit var meshNode: MeshNode

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        setContent {
            val nightMode by meshNode.nightModeFlow.collectAsState(initial = false)
            GodstoneTheme(redNightMode = nightMode) {
                GodstoneNavHost(meshNode = meshNode)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        // Foreground raises the mesh duty cycle; background lowers it.
        meshNode.onAppForegrounded()
    }

    override fun onStop() {
        super.onStop()
        meshNode.onAppBackgrounded()
    }
}
