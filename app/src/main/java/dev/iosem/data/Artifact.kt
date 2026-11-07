package dev.iosem.data

/**
 * One file the emulator needs in order to boot.
 *
 * Nothing Apple-authored is ever shipped with the app. A [Source.Download]
 * points at an upstream open-source archive; a [Source.UserImport] must be
 * supplied by the user from hardware they own.
 */
data class Artifact(
    val id: String,
    val name: String,
    val summary: String,
    val detail: String,
    val kind: String,
    val required: Boolean,
    val fileName: String,
    val license: String,
    val approxBytes: Long?,
    val source: Source,
)

sealed interface Source {
    data class Download(val url: String, val sha256: String?) : Source

    data class UserImport(val mimeTypes: List<String>, val hint: String) : Source
}
