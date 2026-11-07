package dev.iosem.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Send
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.iosem.core.NativeCore
import dev.iosem.core.QemuRunner
import dev.iosem.data.Source
import dev.iosem.ui.Phase
import dev.iosem.ui.SetupViewModel
import dev.iosem.ui.UIState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun ConsoleScreen(vm: SetupViewModel, states: List<UIState>) {
    val context = LocalContext.current
    val directory = remember { vm.artifactDirectory() }
    val backend = remember { QemuRunner.isAvailable(context) }
    val log by QemuRunner.log.collectAsState()
    val running by QemuRunner.running.collectAsState()
    var busy by remember { mutableStateOf(false) }
    var command by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()

    val required = states.filter { it.artifact.required }
    val bootable = required.isNotEmpty() && required.all { it.phase == Phase.READY }
    val missing = remember(states) { QemuRunner.missingFiles(directory) }
    val guestMiB = remember { QemuRunner.suggestedMemoryMiB(context) }

    val view = LocalView.current
    DisposableEffect(running) {
        view.keepScreenOn = running
        onDispose { view.keepScreenOn = false }
    }

    LaunchedEffect(Unit) {
        if (log.isEmpty()) {
            QemuRunner.resetLog()
            appendHeader(states, backend, directory, guestMiB)
        }
    }

    Column(Modifier.fillMaxSize().padding(16.dp)) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Button(
                enabled = !running && !busy && backend && bootable,
                onClick = {
                    busy = true
                    scope.launch {
                        val error = withContext(Dispatchers.IO) {
                            QemuRunner.start(context, directory, guestMiB)
                        }
                        if (error != null) appendBlock(error)
                        busy = false
                    }
                },
            ) {
                Icon(Icons.Filled.PlayArrow, contentDescription = null)
                Spacer(Modifier.width(6.dp))
                Text("Start")
            }
            OutlinedButton(enabled = running, onClick = { QemuRunner.stop() }) {
                Icon(Icons.Filled.Stop, contentDescription = null)
                Spacer(Modifier.width(6.dp))
                Text("Stop")
            }
            OutlinedButton(onClick = { QemuRunner.resetLog() }) {
                Text("Clear")
            }
        }

        Spacer(Modifier.height(6.dp))

        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedButton(
                enabled = backend && !busy,
                onClick = {
                    busy = true
                    scope.launch {
                        val report = withContext(Dispatchers.IO) { QemuRunner.selfTest(context) }
                        appendBlock(report)
                        busy = false
                    }
                },
            ) {
                Text("Self-test")
            }
            OutlinedButton(
                onClick = {
                    busy = true
                    scope.launch {
                        val probe = withContext(Dispatchers.IO) {
                            safe { NativeCore.probeBoot(directory.absolutePath) }
                        }
                        appendBlock(probe)
                        busy = false
                    }
                },
            ) {
                Text("Check files")
            }
        }

        Spacer(Modifier.height(8.dp))

        if (!backend) {
            Text(
                text = "Native backend not packaged. Rebuild the APK with the " +
                    "arm64 QEMU executable (host/build-qemu-android.sh).",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.error,
            )
            Spacer(Modifier.height(6.dp))
        } else if (!bootable) {
            Text(
                text = if (missing.isEmpty()) {
                    "All files are present. Start the machine."
                } else {
                    "Missing: " + missing.joinToString(", ")
                },
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(6.dp))
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = command,
                onValueChange = { command = it },
                modifier = Modifier.weight(1f),
                singleLine = true,
                label = { Text("Serial input") },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(
                    onSend = {
                        if (command.isNotEmpty()) {
                            appendBlock("> $command")
                            QemuRunner.send(command)
                            command = ""
                        }
                    },
                ),
            )
            Button(
                enabled = running && command.isNotEmpty(),
                onClick = {
                    appendBlock("> $command")
                    QemuRunner.send(command)
                    command = ""
                },
            ) {
                Icon(Icons.Filled.Send, contentDescription = null)
            }
        }

        Spacer(Modifier.height(12.dp))

        Surface(
            modifier = Modifier.fillMaxSize(),
            color = Color(0xFF070A0C),
            shape = RoundedCornerShape(12.dp),
        ) {
            SelectionContainer {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(12.dp),
                ) {
                    Text(
                        text = log,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp,
                        lineHeight = 17.sp,
                        color = Color(0xFF9FE8C8),
                    )
                }
            }
        }
    }
}

private fun appendHeader(states: List<UIState>, backend: Boolean, directory: java.io.File, guestMiB: Int) {
    val required = states.filter { it.artifact.required }
    val bootableNow = required.isNotEmpty() && required.all { it.phase == Phase.READY }

    val text = buildString {
        appendLine("iosem core ${safe { NativeCore.version() }}")
        appendLine(safe { NativeCore.capabilities() })
        appendLine("----------------------------------------------")
        appendLine("artifact dir    : ${directory.absolutePath}")
        appendLine("artifacts ready : ${states.count { it.phase == Phase.READY }}/${states.size}")
        appendLine("downloadable    : ${states.count { it.artifact.source is Source.Download }}")
        appendLine("user-supplied   : ${states.count { it.artifact.source is Source.UserImport }}")
        appendLine("boot files      : ${if (bootableNow) "complete" else "incomplete"}")
        appendLine("native backend  : ${if (backend) "packaged" else "missing"}")
        appendLine("guest RAM       : ${guestMiB} MiB (about half of physical memory)")
        appendLine()
        appendLine("The machine loads a decoded iOS 12.1 kernel directly.")
        appendLine("It does not run iBoot, and it needs you to supply hfs.main/hfs.sec.")
    }
    appendBlock(text)
}

private fun appendBlock(text: String) {
    val current = QemuRunner.log.value
    QemuRunner.setLog(if (current.isEmpty()) text else current.trimEnd() + "\n\n" + text + "\n")
}

private inline fun safe(block: () -> String): String = try {
    block()
} catch (t: Throwable) {
    "unavailable: ${t.javaClass.simpleName}: ${t.message}"
}
