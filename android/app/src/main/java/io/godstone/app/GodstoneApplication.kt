package io.godstone.app

import android.app.Application
import dagger.hilt.android.HiltAndroidApp

/** Archive-only production composition root. No radio, SOS, or model work starts. */
@HiltAndroidApp
class GodstoneApplication : Application()
