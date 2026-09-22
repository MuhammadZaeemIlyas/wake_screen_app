package com.shakewake.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import kotlin.math.sqrt

class ShakeForegroundService : Service(), SensorEventListener {

    companion object {
        const val CHANNEL_ID = "shake_wake_channel"
        const val NOTIFICATION_ID = 4201

        const val ACTION_START = "com.shakewake.app.action.START"
        const val ACTION_STOP = "com.shakewake.app.action.STOP"
        const val EXTRA_SENSITIVITY = "extra_sensitivity"

        const val PREFS_NAME = "shake_wake_native_prefs"
        const val PREF_ENABLED = "pref_enabled"
        const val PREF_SENSITIVITY = "pref_sensitivity"

        const val DEFAULT_SENSITIVITY = 2.0

        // How many detected "spikes" within the window count as one shake gesture.
        private const val SHAKE_COUNT_THRESHOLD = 2
        // Minimum gap between two counted spikes, to avoid counting sensor noise twice.
        private const val SHAKE_SLOP_TIME_MS = 350L
        // If no second spike happens within this window, the shake count resets.
        private const val SHAKE_COUNT_RESET_TIME_MS = 3000L
        // Once we wake the screen, ignore further shakes for this long.
        private const val WAKE_COOLDOWN_MS = 4000L
        // How long the wake lock is held before it is force-released.
        private const val WAKE_LOCK_TIMEOUT_MS = 8000L

        @Volatile
        var isRunning: Boolean = false
            private set

        fun start(context: Context, sensitivity: Double) {
            savePrefs(context, enabled = true, sensitivity = sensitivity)
            val intent = Intent(context, ShakeForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_SENSITIVITY, sensitivity)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            savePrefs(context, enabled = false, sensitivity = null)
            val intent = Intent(context, ShakeForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }

        private fun savePrefs(context: Context, enabled: Boolean, sensitivity: Double?) {
            val prefs: SharedPreferences =
                context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val editor = prefs.edit()
            editor.putBoolean(PREF_ENABLED, enabled)
            if (sensitivity != null) {
                editor.putFloat(PREF_SENSITIVITY, sensitivity.toFloat())
            }
            editor.apply()
        }
    }

    private lateinit var sensorManager: SensorManager
    private var accelerometer: Sensor? = null
    private lateinit var powerManager: PowerManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var shakeThreshold: Double = DEFAULT_SENSITIVITY
    private var shakeCount = 0
    private var shakeWindowStart = 0L
    private var lastSpikeTimestamp = 0L
    private var lastWakeTime = 0L

    override fun onCreate() {
        super.onCreate()
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        accelerometer = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action

        if (action == ACTION_STOP) {
            stopSelfCleanly()
            return START_NOT_STICKY
        }

        // Read sensitivity either from the intent (fresh start from Flutter) or,
        // if this is a boot restart with no extras, from persisted prefs.
        shakeThreshold = intent?.getDoubleExtra(EXTRA_SENSITIVITY, -1.0)?.takeIf { it > 0 }
            ?: readSavedSensitivity()

        startForeground(NOTIFICATION_ID, buildNotification())
        registerSensorListener()
        isRunning = true

        return START_STICKY
    }

    override fun onDestroy() {
        unregisterSensorListener()
        isRunning = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun stopSelfCleanly() {
        unregisterSensorListener()
        isRunning = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun registerSensorListener() {
        accelerometer?.let {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
        }
    }

    private fun unregisterSensorListener() {
        sensorManager.unregisterListener(this)
    }

    private fun readSavedSensitivity(): Double {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getFloat(PREF_SENSITIVITY, DEFAULT_SENSITIVITY.toFloat()).toDouble()
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
        // No-op, required by SensorEventListener.
    }

    override fun onSensorChanged(event: SensorEvent) {
        val now = System.currentTimeMillis()

        // Skip processing while we're within the post-wake cooldown window.
        if (now - lastWakeTime < WAKE_COOLDOWN_MS) {
            return
        }

        val x = event.values[0]
        val y = event.values[1]
        val z = event.values[2]

        val gX = x / SensorManager.GRAVITY_EARTH
        val gY = y / SensorManager.GRAVITY_EARTH
        val gZ = z / SensorManager.GRAVITY_EARTH

        // Magnitude of the acceleration vector in "g" units. At rest this is ~1.0.
        val gForce = sqrt((gX * gX + gY * gY + gZ * gZ).toDouble())

        if (gForce < shakeThreshold) {
            return
        }

        if (now - lastSpikeTimestamp < SHAKE_SLOP_TIME_MS) {
            // Too soon after the previous spike, likely the same physical jolt.
            return
        }
        lastSpikeTimestamp = now

        if (shakeWindowStart == 0L || now - shakeWindowStart > SHAKE_COUNT_RESET_TIME_MS) {
            shakeWindowStart = now
            shakeCount = 0
        }

        shakeCount++

        if (shakeCount >= SHAKE_COUNT_THRESHOLD) {
            shakeCount = 0
            shakeWindowStart = 0L
            triggerWake()
        }
    }

    @Suppress("DEPRECATION")
    private fun triggerWake() {
        val now = System.currentTimeMillis()
        if (now - lastWakeTime < WAKE_COOLDOWN_MS) {
            return
        }
        lastWakeTime = now

        // NOTE: PowerManager wake-lock "levels" (FULL_WAKE_LOCK, SCREEN_BRIGHT_WAKE_LOCK, etc.)
        // are mutually exclusive on the platform and cannot both be OR'd together as a level.
        // FULL_WAKE_LOCK already implies keeping the screen at full brightness, so it is
        // combined here only with the two flag constants that actually matter for waking
        // a screen that is fully off: ACQUIRE_CAUSES_WAKEUP (turn the screen ON immediately,
        // even though the device is idle) and ON_AFTER_RELEASE (keep the screen on briefly
        // via the normal timeout logic once the lock is released).
        val wakeLock = powerManager.newWakeLock(
            PowerManager.FULL_WAKE_LOCK or
                PowerManager.ACQUIRE_CAUSES_WAKEUP or
                PowerManager.ON_AFTER_RELEASE,
            "ShakeWakeApp:ShakeWakeLock"
        )
        wakeLock.setReferenceCounted(false)
        wakeLock.acquire(WAKE_LOCK_TIMEOUT_MS)

        mainHandler.postDelayed({
            if (wakeLock.isHeld) {
                wakeLock.release()
            }
        }, WAKE_LOCK_TIMEOUT_MS)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Shake to Wake service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps the shake-to-wake background listener alive."
                setShowBadge(false)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val stopIntent = Intent(this, ShakeForegroundService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            0,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentPendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Shake to Wake is active")
            .setContentText("Shake your phone firmly to turn on the screen.")
            .setSmallIcon(R.drawable.ic_stat_shake)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(contentPendingIntent)
            .addAction(0, "Stop", stopPendingIntent)
            .build()
    }
}
