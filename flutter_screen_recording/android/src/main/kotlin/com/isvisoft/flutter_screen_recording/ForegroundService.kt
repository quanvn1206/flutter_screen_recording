package com.isvisoft.flutter_screen_recording

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import android.os.Binder

class ForegroundService : Service() {
    private val channelId = "ForegroundService Kotlin"

    companion object {
        fun startService(context: Context, title: String, message: String) {
            val startIntent = Intent(context, ForegroundService::class.java)
                .putExtra("messageExtra", message)
                .putExtra("titleExtra", title)
            ContextCompat.startForegroundService(context, startIntent)
        }

        fun stopService(context: Context) {
            val stopIntent = Intent(context, ForegroundService::class.java)
                .setAction(ACTION_STOP)
            context.startService(stopIntent)
        }

        const val ACTION_STOP = "com.foregroundservice.ACTION_STOP"
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        return try {
            startForegroundWithNotification(intent)
            START_NOT_STICKY
        } catch (error: Exception) {
            stopSelf(startId)
            START_NOT_STICKY
        }
    }

    private fun startForegroundWithNotification(intent: Intent?) {
        val title = intent?.getStringExtra("titleExtra") ?: "Flutter Screen Recording"
        val message = intent?.getStringExtra("messageExtra") ?: ""

        createNotificationChannel()
        val notificationIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = notificationIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle(title)
            .setContentText(message)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setOngoing(true)
            .apply { pendingIntent?.let(::setContentIntent) }
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                1,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            @Suppress("DEPRECATION")
            startForeground(1, notification)
        }
    }

    override fun onBind(intent: Intent): IBinder = Binder()

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                channelId,
                "Foreground Screen Recording",
                NotificationManager.IMPORTANCE_LOW,
            )
            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(serviceChannel)
        }
    }
}
