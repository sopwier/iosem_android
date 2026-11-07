package dev.iosem.data

import android.content.Context
import org.json.JSONArray

/**
 * Loads the artifact catalogue from assets. The catalogue is data, not code:
 * adding a new downloadable upstream or a new user-supplied slot does not
 * require touching the UI.
 */
object Catalog {
    fun load(context: Context): List<Artifact> {
        val text = context.assets.open("catalog.json").bufferedReader().use { it.readText() }
        val array = JSONArray(text)
        return (0 until array.length()).map { index ->
            val item = array.getJSONObject(index)
            val sourceJson = item.getJSONObject("source")
            val source = when (sourceJson.getString("type")) {
                "download" -> Source.Download(
                    url = sourceJson.getString("url"),
                    sha256 = sourceJson.optString("sha256").takeIf { it.isNotBlank() },
                )

                else -> Source.UserImport(
                    mimeTypes = sourceJson.optJSONArray("mimeTypes")?.let { mimes ->
                        (0 until mimes.length()).map { mimes.getString(it) }
                    } ?: listOf("*/*"),
                    hint = sourceJson.optString("hint"),
                )
            }

            Artifact(
                id = item.getString("id"),
                name = item.getString("name"),
                summary = item.getString("summary"),
                detail = item.optString("detail"),
                kind = item.optString("kind"),
                required = item.optBoolean("required", false),
                fileName = item.getString("fileName"),
                license = item.optString("license"),
                approxBytes = if (item.has("approxBytes")) item.getLong("approxBytes") else null,
                source = source,
            )
        }
    }
}
