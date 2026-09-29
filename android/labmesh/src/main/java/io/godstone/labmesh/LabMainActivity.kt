package io.godstone.labmesh

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import io.godstone.mesh.lab.LabRuntime

/**
 * T54 / GS-LAB-001 + GS-UX-001 `rendered-controls`: THE LAB'S LAUNCHABLE ENTRY POINT, HOSTING THE RENDERED JOURNEY.
 *
 * *THE AUDIT'S FIRST FINDING WAS THAT THE LAB TARGETS HAD **NO LAUNCHABLE ENTRY POINT AT ALL**; the second was that
 * the journey was a `TextView` -- a screen with NO controls, NO callbacks and NO `onCommand` wiring.* **This activity
 * closeth both: it is the door, and behind it standeth a screen whose commands reach the REAL
 * `io.godstone.mesh.lab.LabRuntime`.**
 *
 * *** THE RUNTIME IS THE APPLICATION'S -- NEVER A VIEW'S. *** *`LabMeshApplication.runtime` is composed ONCE at process
 * start (this file contains no `compose(` call, which `ci/check_lab_isolation.py`'s retained-runtime control asserteth:
 * a runtime composed by a view is composed again on every recomposition).*
 *
 * *** THE BINDING IS TIED TO THIS ACTIVITY'S LIFECYCLE SCOPE, AND THE FLOW IS COLLECTED LIFECYCLE-AWARE. *** *A
 * `suspend` write (`sendDirect`, the SOS commands) runneth on a scope that is CANCELLED with the activity -- an
 * unowned scope would outlive the surface reading its state -- and `collectAsStateWithLifecycle` STOPPETH collecting
 * when the owner is backgrounded, so no state is read by a surface nobody is looking at.*
 *
 * *** AND NOTHING HERE MANUFACTURETH READINESS. *** *No flag is written, no setter called, and the readiness statement
 * reacheth `LabRuntime.readinessStatement()`'s compile-time `false`. The lab remaineth EXPERIMENTAL and NONSHIPPING.*
 */
class LabMainActivity : ComponentActivity() {
    private val runtime: LabRuntime
        get() = (application as LabMeshApplication).runtime

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // THE BINDING REACHETH THE RETAINED RUNTIME'S OWN AUTHORITY, ON THIS ACTIVITY'S OWN SCOPE.
        val bindings = LabJourneyBindings(runtime, lifecycleScope)
        // *The rendered state is REFRESHED from the runtime's estate at start, so a relaunch renders what the store
        // carrieth rather than a placeholder -- the read is the runtime's, never this activity's memory.*
        bindings.refresh()
        setContent {
            val state by bindings.state.collectAsStateWithLifecycle()
            Surface {
                LabMeshJourneyScreen(state, onSend = bindings::send)
            }
        }
    }
}
