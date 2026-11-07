package dev.iosem.data

import android.content.Context
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/**
 * Flat on-disk store for boot artifacts.
 *
 * Files live in `filesDir/artifacts` under stable names so the native core can
 * find them without a database. An index records provenance and hashes.
 *
 * The lock is shared across instances because the download worker and the
 * view model each hold their own store object.
 */
class ArtifactStore(context: Context) {

    data class Entry(
        val id: String,
        val fileName: String,
        val size: Long,
        val addedAt: Long,
        val origin: String,
        val sha256: String,
    )

    private val dir = File(context.filesDir, "artifacts").apply { mkdirs() }
    private val indexFile = File(dir, INDEX_FILE)

    fun directory(): File = dir

    fun entries(): Map<String, Entry> = synchronized(LOCK) {
        if (!indexFile.isFile) return@synchronized emptyMap()

        runCatching {
            val root = JSONObject(indexFile.readText())
            buildMap {
                root.keys().forEach { key ->
                    val item = root.getJSONObject(key)
                    put(
                        key,
                        Entry(
                            id = key,
                            fileName = item.getString("fileName"),
                            size = item.getLong("size"),
                            addedAt = item.getLong("addedAt"),
                            origin = item.optString("origin"),
                            sha256 = item.optString("sha256"),
                        ),
                    )
                }
            }
        }.getOrDefault(emptyMap())
    }

    fun fileFor(id: String): File? {
        val entry = entries()[id] ?: return null
        return File(dir, entry.fileName).takeIf { it.isFile }
    }

    /**
     * Moves a freshly written file into the store and records it.
     */
    fun adopt(id: String, source: File, fileName: String, origin: String): Entry =
        synchronized(LOCK) {
            require(source.isFile && source.length() > 0) { "refusing to adopt an empty file" }
            require(fileName.isNotBlank() && '/' !in fileName && '\\' !in fileName) {
                "invalid artifact file name"
            }

            val destination = File(dir, fileName)
            if (source.canonicalPath != destination.canonicalPath) {
                source.copyTo(destination, overwrite = true)
                source.delete()
            }

            val map = entries().toMutableMap()
            map[id]?.let { previous ->
                if (previous.fileName != fileName) File(dir, previous.fileName).delete()
            }

            val entry = Entry(
                id = id,
                fileName = fileName,
                size = destination.length(),
                addedAt = System.currentTimeMillis(),
                origin = origin,
                sha256 = sha256(destination),
            )
            map[id] = entry
            writeIndex(map)
            entry
        }

    fun remove(id: String) {
        synchronized(LOCK) {
            val map = entries().toMutableMap()
            val entry = map.remove(id) ?: return@synchronized
            File(dir, entry.fileName).delete()
            writeIndex(map)
        }
    }

    private fun writeIndex(map: Map<String, Entry>) {
        val root = JSONObject()
        map.forEach { (key, entry) ->
            root.put(
                key,
                JSONObject()
                    .put("fileName", entry.fileName)
                    .put("size", entry.size)
                    .put("addedAt", entry.addedAt)
                    .put("origin", entry.origin)
                    .put("sha256", entry.sha256),
            )
        }
        indexFile.writeText(root.toString(2))
    }

    companion object {
        private const val INDEX_FILE = "index.json"

        private val LOCK = Any()

        fun sha256(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(1 shl 16)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    digest.update(buffer, 0, read)
                }
            }
            return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
        }
    }
}
