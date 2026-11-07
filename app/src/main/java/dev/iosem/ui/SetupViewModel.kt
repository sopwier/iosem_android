package dev.iosem.ui

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.workDataOf
import dev.iosem.data.Artifact
import dev.iosem.data.ArtifactStore
import dev.iosem.data.Catalog
import dev.iosem.data.DownloadWorker
import dev.iosem.data.Source
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

class SetupViewModel(application: Application) : AndroidViewModel(application) {

    private val app = application
    private val store = ArtifactStore(application)
    private val workManager = WorkManager.getInstance(application)
    private val catalog = Catalog.load(application)

    private val _states = MutableStateFlow(catalog.map { UIState(it) })
    val states: StateFlow<List<UIState>> = _states.asStateFlow()

    private val observations = mutableMapOf<String, Job>()

    init {
        refresh()
    }

    fun refresh() {
        val entries = store.entries()
        _states.value = _states.value.map { state ->
            val entry = entries[state.artifact.id]
            when {
                entry != null &&
                    state.phase != Phase.IMPORTING &&
                    state.phase != Phase.DOWNLOADING ->
                    state.copy(phase = Phase.READY, progress = 100, message = null, entry = entry)

                entry == null && state.phase == Phase.READY ->
                    state.copy(phase = Phase.MISSING, progress = 0, entry = null)

                else -> state
            }
        }
    }

    fun download(artifact: Artifact) {
        val source = artifact.source as? Source.Download ?: return

        val request = OneTimeWorkRequestBuilder<DownloadWorker>()
            .setInputData(
                workDataOf(
                    DownloadWorker.KEY_ID to artifact.id,
                    DownloadWorker.KEY_URL to source.url,
                    DownloadWorker.KEY_SHA256 to source.sha256.orEmpty(),
                    DownloadWorker.KEY_FILE_NAME to artifact.fileName,
                    DownloadWorker.KEY_LABEL to artifact.name,
                ),
            )
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(NetworkType.CONNECTED)
                    .build(),
            )
            .addTag(TAG)
            .build()

        workManager.enqueueUniqueWork(uniqueName(artifact.id), ExistingWorkPolicy.REPLACE, request)
        update(artifact.id) { it.copy(phase = Phase.DOWNLOADING, progress = 0, message = null) }
        observe(artifact.id)
    }

    fun downloadAll() {
        _states.value
            .filter { it.artifact.source is Source.Download }
            .filter { it.phase != Phase.READY && it.phase != Phase.DOWNLOADING }
            .forEach { download(it.artifact) }
    }

    fun importFile(artifact: Artifact, uri: Uri) {
        update(artifact.id) { it.copy(phase = Phase.IMPORTING, progress = 0, message = null) }

        viewModelScope.launch {
            val outcome = withContext(Dispatchers.IO) {
                runCatching {
                    val temp = File(app.cacheDir, "import-${artifact.id}.tmp")
                    val expectedSize = runCatching {
                        app.contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1L
                    }.getOrDefault(-1L)
                    if (expectedSize > 0 && app.filesDir.usableSpace < expectedSize) {
                        error("not enough free space for ${expectedSize / (1024 * 1024)} MB")
                    }
                    val stream = app.contentResolver.openInputStream(uri)
                        ?: error("could not open the selected file")
                    stream.use { input ->
                        temp.outputStream().use { output -> input.copyTo(output) }
                    }
                    if (temp.length() == 0L) error("the selected file is empty")
                    store.adopt(artifact.id, temp, artifact.fileName, origin = "import")
                }
            }

            outcome.onSuccess {
                refresh()
                update(artifact.id) { it.copy(phase = Phase.READY, progress = 100, message = null) }
            }.onFailure { error ->
                update(artifact.id) {
                    it.copy(
                        phase = Phase.FAILED,
                        progress = 0,
                        message = error.message ?: "import failed",
                    )
                }
            }
        }
    }

    fun remove(artifact: Artifact) {
        store.remove(artifact.id)
        update(artifact.id) {
            it.copy(phase = Phase.MISSING, progress = 0, message = null, entry = null)
        }
    }

    fun artifactDirectory(): File = store.directory()

    private fun observe(id: String) {
        observations.remove(id)?.cancel()

        val job = viewModelScope.launch {
            val self = coroutineContext[Job]

            workManager.getWorkInfosForUniqueWorkFlow(uniqueName(id)).collect { infos ->
                val info = infos.firstOrNull() ?: return@collect
                when (info.state) {
                    WorkInfo.State.ENQUEUED, WorkInfo.State.RUNNING -> {
                        val progress = info.progress.getInt(DownloadWorker.KEY_PROGRESS, 0)
                        update(id) {
                            it.copy(phase = Phase.DOWNLOADING, progress = progress, message = null)
                        }
                    }

                    WorkInfo.State.SUCCEEDED -> {
                        refresh()
                        update(id) {
                            it.copy(phase = Phase.READY, progress = 100, message = null)
                        }
                        self?.cancel()
                    }

                    WorkInfo.State.FAILED -> {
                        val message = info.outputData.getString(DownloadWorker.KEY_ERROR)
                            ?: "download failed"
                        update(id) {
                            it.copy(phase = Phase.FAILED, progress = 0, message = message)
                        }
                        self?.cancel()
                    }

                    WorkInfo.State.CANCELLED -> {
                        update(id) {
                            it.copy(phase = Phase.MISSING, progress = 0, message = null)
                        }
                        self?.cancel()
                    }

                    else -> Unit
                }
            }
        }
        observations[id] = job
    }

    private fun update(id: String, transform: (UIState) -> UIState) {
        _states.value = _states.value.map { state ->
            if (state.artifact.id == id) transform(state) else state
        }
    }

    companion object {
        private const val TAG = "artifact-download"

        fun uniqueName(id: String): String = "artifact-$id"
    }
}
