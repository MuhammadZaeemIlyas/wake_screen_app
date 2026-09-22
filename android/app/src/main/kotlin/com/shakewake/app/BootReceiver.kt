package com.shakewake.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }

        val prefs = context.getSharedPreferences(
            ShakeForegroundService.PREFS_NAME,
            Context.MODE_PRIVATE
        )
        val wasEnabled = prefs.getBoolean(ShakeForegroundService.PREF_ENABLED, false)

        if (wasEnabled) {
            val sensitivity = prefs.getFloat(
                ShakeForegroundService.PREF_SENSITIVITY,
                ShakeForegroundService.DEFAULT_SENSITIVITY.toFloat()
            ).toDouble()
            ShakeForegroundService.start(context.applicationContext, sensitivity)
        }
    }
}
