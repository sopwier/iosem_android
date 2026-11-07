package dev.iosem.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import dev.iosem.data.Artifact
import dev.iosem.data.Source
import dev.iosem.ui.Phase
import dev.iosem.ui.SetupViewModel
import dev.iosem.ui.UIState
import java.util.Locale

@Composable
fun SetupScreen(vm: SetupViewModel, states: List<UIState>, onOpenConsole: () -> Unit) {
    val required = states.filter { it.artifact.required }
    val ready = required.count { it.phase == Phase.READY }

    var pendingImport by remember { mutableStateOf<Artifact?>(null) }

    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        val artifact = pendingImport
        pendingImport = null
        if (uri != null && artifact != null) {
            vm.importFile(artifact, uri)
        }
    }

    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            BootFilesHeader(
                ready = ready,
                total = required.size,
                onDownloadAll = vm::downloadAll,
            )
        }

        item { LegalNotice() }

        items(states, key = { it.artifact.id }) { state ->
            ArtifactCard(
                state = state,
                onDownload = { vm.download(state.artifact) },
                onImport = {
                    val source = state.artifact.source
                    if (source is Source.UserImport) {
                        pendingImport = state.artifact
                        picker.launch(source.mimeTypes.toTypedArray())
                    }
                },
                onRemove = { vm.remove(state.artifact) },
            )
        }

        item {
            StartCard(
                enabled = ready == required.size && required.isNotEmpty(),
                ready = ready,
                total = required.size,
                onStart = onOpenConsole,
            )
        }

        item { Spacer(Modifier.height(16.dp)) }
    }
}

@Composable
private fun BootFilesHeader(ready: Int, total: Int, onDownloadAll: () -> Unit) {
    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
    ) {
        Column(Modifier.fillMaxWidth().padding(16.dp)) {
            Text("Boot files", style = MaterialTheme.typography.titleLarge)
            Spacer(Modifier.height(4.dp))
            Text(
                "$ready of $total required files ready",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Spacer(Modifier.height(12.dp))
            LinearProgressIndicator(
                progress = { if (total == 0) 0f else ready.toFloat() / total.toFloat() },
                modifier = Modifier.fillMaxWidth(),
            )

            Spacer(Modifier.height(16.dp))
            Button(onClick = onDownloadAll) {
                Icon(Icons.Filled.Download, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Download available")
            }
            Spacer(Modifier.height(6.dp))
            Text(
                "Only open-source archives can be fetched. Firmware rows use Import.",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun LegalNotice() {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.error.copy(alpha = 0.10f),
        ),
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                Icons.Filled.Warning,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.error,
            )
            Column {
                Text(
                    "No Apple firmware is bundled or downloaded",
                    style = MaterialTheme.typography.titleSmall,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    "kernelcache, device tree, disk images and userland must be supplied by you " +
                        "from hardware you own. This app will not fetch them. The n66 machine " +
                        "loads a decoded kernel directly; it does not run iBoot.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun ArtifactCard(
    state: UIState,
    onDownload: () -> Unit,
    onImport: () -> Unit,
    onRemove: () -> Unit,
) {
    val artifact = state.artifact

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(artifact.name, style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.width(8.dp))
                        Text(
                            if (artifact.required) "REQUIRED" else "OPTIONAL",
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = FontFamily.Monospace,
                            color = if (artifact.required) {
                                MaterialTheme.colorScheme.primary
                            } else {
                                MaterialTheme.colorScheme.onSurfaceVariant
                            },
                        )
                    }
                    Spacer(Modifier.height(2.dp))
                    Text(
                        artifact.summary,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.width(8.dp))
                StatusChip(state)
            }

            if (state.phase == Phase.READY) {
                state.entry?.let { entry ->
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "${formatBytes(entry.size)}  ·  sha256 ${entry.sha256.take(12)}…  ·  ${entry.origin}",
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            if (state.phase == Phase.DOWNLOADING) {
                Spacer(Modifier.height(12.dp))
                LinearProgressIndicator(
                    progress = { state.progress / 100f },
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    "${state.progress}%",
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            if (state.phase == Phase.IMPORTING) {
                Spacer(Modifier.height(12.dp))
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            }

            state.message?.let { message ->
                Spacer(Modifier.height(8.dp))
                Text(
                    message,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }

            if (artifact.detail.isNotBlank()) {
                Spacer(Modifier.height(8.dp))
                Text(
                    artifact.detail,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            if (artifact.license.isNotBlank()) {
                Spacer(Modifier.height(4.dp))
                Text(
                    "License: ${artifact.license}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            Spacer(Modifier.height(12.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                when (state.phase) {
                    Phase.READY -> {
                        TextButton(onClick = onRemove) {
                            Icon(Icons.Filled.Delete, contentDescription = null)
                            Spacer(Modifier.width(6.dp))
                            Text("Remove")
                        }
                    }

                    Phase.DOWNLOADING, Phase.IMPORTING -> {
                        Text(
                            if (state.phase == Phase.DOWNLOADING) "Downloading…" else "Copying…",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }

                    else -> {
                        when (artifact.source) {
                            is Source.Download -> Button(onClick = onDownload) {
                                Icon(Icons.Filled.Download, contentDescription = null)
                                Spacer(Modifier.width(6.dp))
                                Text(if (state.phase == Phase.FAILED) "Retry" else "Download")
                            }

                            is Source.UserImport -> OutlinedButton(onClick = onImport) {
                                Icon(Icons.Filled.Add, contentDescription = null)
                                Spacer(Modifier.width(6.dp))
                                Text("Import")
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun StatusChip(state: UIState) {
    val (label, color) = when (state.phase) {
        Phase.READY -> "READY" to MaterialTheme.colorScheme.primary
        Phase.DOWNLOADING -> "GET" to MaterialTheme.colorScheme.secondary
        Phase.IMPORTING -> "COPY" to MaterialTheme.colorScheme.secondary
        Phase.FAILED -> "ERROR" to MaterialTheme.colorScheme.error
        Phase.MISSING -> "MISSING" to MaterialTheme.colorScheme.onSurfaceVariant
    }

    Surface(
        color = color.copy(alpha = 0.14f),
        shape = RoundedCornerShape(50),
    ) {
        Text(
            label,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
            style = MaterialTheme.typography.labelSmall,
            fontFamily = FontFamily.Monospace,
            color = color,
        )
    }
}

@Composable
private fun StartCard(enabled: Boolean, ready: Int, total: Int, onStart: () -> Unit) {

    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.08f),
        ),
    ) {
        Column(Modifier.fillMaxWidth().padding(16.dp)) {
            Text("Boot", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(4.dp))
            Text(
                if (enabled) {
                    "Required files are present. Open the Console, press Self-test to verify " +
                        "the packaged QEMU backend, then Start."
                } else {
                    "$ready of $total required files present. Import the rest to complete the set."
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(12.dp))
            Button(onClick = onStart, enabled = enabled) {
                Icon(Icons.Filled.PlayArrow, contentDescription = null)
                Spacer(Modifier.width(6.dp))
                Text("Open Console")
            }
        }
    }
}

private fun formatBytes(bytes: Long): String = when {
    bytes >= 1_000_000_000 -> String.format(Locale.US, "%.2f GB", bytes / 1_000_000_000.0)
    bytes >= 1_000_000 -> String.format(Locale.US, "%.1f MB", bytes / 1_000_000.0)
    bytes >= 1_000 -> String.format(Locale.US, "%.1f kB", bytes / 1_000.0)
    else -> "$bytes B"
}
