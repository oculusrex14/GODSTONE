package io.godstone.labmesh

import android.app.Activity
import android.os.Bundle
import android.widget.TextView

/**
 * T54 / GS-LAB-001: THE LAB'S LAUNCHABLE ENTRY POINT.
 *
 * The audit found the LabMesh application targets WITHOUT launchable entry points: the manifest declared an
 * application and no activity at all, so a lab existed which nobody could start. This activity is the smallest honest
 * door: it nameth the lab, stateth what it is (EXPERIMENTAL and NONSHIPPING), and carrieth NO readiness claim and NO
 * radio work of its own -- the runtime it would drive is the canonical one, reached through
 * `io.godstone.mesh.lab.LabRuntime`, exactly as `LabMeshApp` saith.
 *
 * WHY IT EXTENDETH A PLAIN Activity RATHER THAN THE SHIPPING APP'S ComponentActivity: the lab module carrieth no
 * Compose or Hilt surface of its own, and ADDING dependencies for an entry point would widen the lab's isolation
 * footprint -- which `ci/check_lab_isolation.py` guardeth. A view with a sentence cannot manufacture readiness.
 */
class LabMainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(TextView(this).apply {
            text = "Godstone LabMesh -- EXPERIMENTAL, NONSHIPPING.\n" +
                "This build exercises the real adapters on a real device; it is never a store candidate."
        })
    }
}
