package dev.iosem.data

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import dev.iosem.MainActivity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Streams an artifact to disk and adopts it into [ArtifactStore].
 *
 * Only upstream open-source archives are ever fetched (the XNU source and the
 * n66 QEMU fork). Apple firmware is user-supplied and lands here via import.
 */
class DownloadWorker(
    appContext: Context,
    params: WorkerParameters,
) : CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val id = inputData.getString(KEY_ID)
            ?: return@withContext Result.failure(workDataOf(KEY_ERROR to "missing artifact id"))
        val url = inputData.getString(KEY_URL)
            ?: return@withContext Result.failure(workDataOf(KEY_ERROR to "missing url"))
        val fileName = inputData.getString(KEY_FILE_NAME) ?: "$id.bin"
        val label = inputData.getString(KEY_LABEL) ?: id
        val expectedSha = inputData.getString(KEY_SHA256)?.takeIf { it.isNotBlank() }

        val temp = File(applicationContext.cacheDir, "download-$id.tmp")

        try {
            try {
                setForeground(foregroundInfo(label))
            } catch (t: Throwable) {
                Log.w(TAG, "could not enter foreground; continuing in background", t)
            }

            val connection = (URL(url).openConnection() as HttpURLConnection).apply {
                instanceFollowRedirects = true
                connectTimeout = 30_000
                readTimeout = 60_000
                requestMethod = "GET"
                setRequestProperty("User-Agent", "iosem/0.2 (+https://github.com/apple-oss-distributions/xnu)")
                setRequestProperty("Accept", "application/octet-stream")
            }

            try {
                val code = connection.responseCode
                if (code !in 200..299) {
                    return@withContext Result.failure(workDataOf(KEY_ERROR to "HTTP $code"))
                }

                val total = connection.contentLengthLong
                var received = 0L
                var lastPercent = -1

                if (total > 0 && applicationContext.filesDir.usableSpace < total + 32L * 1024 * 1024) {
                    return@withContext Result.failure(
                        workDataOf(KEY_ERROR to "not enough free space for ${total / (1024 * 1024)} MB"),
                    )
                }

                connection.inputStream.use { input ->
                    temp.outputStream().use { output ->
                        val buffer = ByteArray(64 * 1024)
                        while (true) {
                            if (isStopped) {
                                temp.delete()
                                return@withContext Result.failure(workDataOf(KEY_ERROR to "cancelled"))
                            }
                            val read = input.read(buffer)
                            if (read < 0) break
                            output.write(buffer, 0, read)
                            received += read
                            if (total > 0) {
                                val percent = ((received * 100) / total).toInt()
                                if (percent != lastPercent) {
                                    lastPercent = percent
                                    setProgress(workDataOf(KEY_PROGRESS to percent))
                                }
                            }
                        }
                    }
                }
            } finally {
                connection.disconnect()
            }

            if (temp.length() == 0L) {
                temp.delete()
                return@withContext Result.failure(workDataOf(KEY_ERROR to "empty response"))
            }

            val actualSha = ArtifactStore.sha256(temp)
            if (expectedSha != null && !actualSha.equals(expectedSha, ignoreCase = true)) {
                temp.delete()
                return@withContext Result.failure(
                    workDataOf(KEY_ERROR to "sha256 mismatch (expected $expectedSha)"),
                )
            }

            ArtifactStore(applicationContext).adopt(id, temp, fileName, origin = "download")
            Result.success(workDataOf(KEY_SHA256 to actualSha))
        } catch (t: Throwable) {
            temp.delete()
            Result.failure(workDataOf(KEY_ERROR to (t.message ?: t.javaClass.simpleName)))
        }
    }

    private fun foregroundInfo(label: String): ForegroundInfo {
        val context = applicationContext
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW),
                )
            }
        }

        val intent = Intent(context, MainActivity::class.java)
        val pending = PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle("Downloading $label")
            .setContentText("iosem fetches open-source archives only")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setContentIntent(pending)
            .build()

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        const val CHANNEL_ID = "iosem-downloads"
        const val NOTIFICATION_ID = 41

        const val KEY_ID = "id"
        const val KEY_URL = "url"
        const val KEY_SHA256 = "sha256"
        const val KEY_FILE_NAME = "fileName"
        const val KEY_LABEL = "label"
        const val KEY_PROGRESS = "progress"
        const val KEY_ERROR = "error"

        private const val TAG = "iosem-download"
    }
}
