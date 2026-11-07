package dev.iosem.ui

import dev.iosem.data.Artifact
import dev.iosem.data.ArtifactStore

enum class Phase {
    MISSING,
    DOWNLOADING,
    IMPORTING,
    READY,
    FAILED,
}

data class UIState(
    val artifact: Artifact,
    val phase: Phase = Phase.MISSING,
    val progress: Int = 0,
    val message: String? = null,
    val entry: ArtifactStore.Entry? = null,
)
