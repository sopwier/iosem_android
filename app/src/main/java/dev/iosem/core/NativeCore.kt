package dev.iosem.core

/**
 * Thin JNI surface over the native core.
 *
 * The shipped library reports device capabilities and validates the artifact
 * set. Execution is handled by [QemuRunner], which launches the packaged
 * executable from nativeLibraryDir.
 */
object NativeCore {
    init {
        System.loadLibrary("iosem_core")
    }

    external fun version(): String

    external fun capabilities(): String

    external fun probeBoot(artifactDir: String): String
}
