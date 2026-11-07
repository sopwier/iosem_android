package dev.iosem.core

import android.app.ActivityManager
import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.util.concurrent.TimeUnit

/**
 * Launches the packaged `qemu-system-aarch64` executable with the n66 machine.
 *
 * The native binary is stored in the APK as
 * `lib/arm64-v8a/libqemu-system-aarch64.so` so Android extracts it into
 * `nativeLibraryDir`, the one app-writable location that is still exec-mapped
 * for targetSdk 29+. It is an ELF executable, not a shared object; the `.so`
 * suffix only controls packaging and extraction.
 *
 * The machine still needs the five user-supplied iOS 12.1 files. This class
 * never downloads or decrypts them.
 */
object QemuRunner {

    private const val EXECUTABLE = "libqemu-system-aarch64.so"
    private const val MAX_LOG_LINES = 4000

    /** Boot files in the order the machine exposes them. */
    private val requiredFiles = linkedMapOf(
        "kernel-filename" to "kernelcache.release.n66.out",
        "dtb-filename" to "DeviceTree.n66ap.im4p.out",
        "driver-filename" to "aleph_bdev_drv.bin",
        "qc-file-0-filename" to "hfs.main",
        "qc-file-1-filename" to "hfs.sec",
    )

    private val _log = MutableStateFlow("")
    val log: StateFlow<String> = _log.asStateFlow()

    private val _running = MutableStateFlow(false)
    val running: StateFlow<Boolean> = _running.asStateFlow()

    private var process: Process? = null
    private var stdin: OutputStreamWriter? = null
    private var scope: CoroutineScope? = null
    private var waiter: Job? = null

    fun executable(context: Context): File =
        File(context.applicationInfo.nativeLibraryDir, EXECUTABLE)

    fun isAvailable(context: Context): Boolean =
        executable(context).let { it.isFile && it.canExecute() }

    /**
     * Guest RAM to request, based on physical device memory. The upstream
     * procedure assumes 6 GiB, which no ordinary phone can give away; using
     * half of physical RAM (rounded down to 512 MiB, capped at 4 GiB) is a
     * compromise that leaves the Android system enough to keep the process
     * alive.
     */
    fun suggestedMemoryMiB(context: Context): Int {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        val totalMiB = (info.totalMem / (1024L * 1024L)).toInt()
        val half = (totalMiB / 2 / 512) * 512
        return half.coerceIn(1024, 4096)
    }

    fun missingFiles(directory: File): List<String> =
        requiredFiles.values.filter { name ->
            val file = File(directory, name)
            !file.isFile || file.length() == 0L
        }

    /**
     * Start the machine. Returns null on success, or a human-readable error.
     * The five boot files must already be present in [directory].
     */
    fun start(context: Context, directory: File, memoryMiB: Int = 4096): String? {
        if (_running.value) return "the emulator is already running"

        val binary = executable(context)
        if (!binary.isFile) {
            return "native backend missing: ${binary.absolutePath}\n" +
                "This APK was built without the cross-compiled QEMU binary."
        }
        if (!binary.canExecute()) {
            return "native backend is not executable: ${binary.absolutePath}"
        }

        val missing = missingFiles(directory)
        if (missing.isNotEmpty()) {
            return "missing boot files:\n" + missing.joinToString("\n") { "  - $it" }
        }

        val machine = buildMachineOption(directory)
            ?: return "artifact path contains a comma, which the QEMU option parser treats as a separator"

        val args = listOf(
            binary.absolutePath,
            "-M", machine,
            "-cpu", "max",
            "-m", "${memoryMiB}M",
            "-accel", "tcg",
            "-nographic",
        )

        append("$ ${binary.name} -M iPhone6splus-n66-s8000 ... -m ${memoryMiB}M -accel tcg -nographic\n")

        return try {
            val builder = ProcessBuilder(args)
                .directory(directory)
                .redirectErrorStream(true)
            builder.environment().apply {
                put("LD_LIBRARY_PATH", context.applicationInfo.nativeLibraryDir)
                put("TMPDIR", context.cacheDir.absolutePath)
                put("HOME", context.filesDir.absolutePath)
                put("XDG_CACHE_HOME", File(context.cacheDir, "xdg").apply { mkdirs() }.absolutePath)
            }

            val proc = builder.start()
            process = proc
            stdin = OutputStreamWriter(proc.outputStream)
            _running.value = true

            val runScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            scope = runScope

            runScope.launch {
                val reader = BufferedReader(InputStreamReader(proc.inputStream))
                try {
                    val buffer = CharArray(4096)
                    while (true) {
                        val count = reader.read(buffer)
                        if (count < 0) break
                        if (count > 0) append(String(buffer, 0, count))
                    }
                } catch (_: Throwable) {
                    // The process died or was stopped; the waiter reports it.
                }
            }

            waiter = runScope.launch {
                val exit = proc.waitFor()
                append("\n[process exited with code $exit]\n")
                _running.value = false
                stdin = null
                process = null
            }

            null
        } catch (t: Throwable) {
            append("\n[failed to start: ${t.javaClass.simpleName}: ${t.message}]\n")
            _running.value = false
            process = null
            stdin = null
            "could not start QEMU: ${t.message ?: t.javaClass.simpleName}"
        }
    }

    /** Run `-M help` to prove the executable and its libraries load. */
    fun selfTest(context: Context): String {
        val binary = executable(context)
        if (!binary.isFile) return "native backend missing: ${binary.absolutePath}"

        return try {
            val builder = ProcessBuilder(binary.absolutePath, "-M", "help")
                .redirectErrorStream(true)
            builder.environment().apply {
                put("LD_LIBRARY_PATH", context.applicationInfo.nativeLibraryDir)
                put("TMPDIR", context.cacheDir.absolutePath)
                put("HOME", context.filesDir.absolutePath)
            }
            val proc = builder.start()
            val output = proc.inputStream.bufferedReader().use { it.readText() }
            val finished = proc.waitFor(15, TimeUnit.SECONDS)
            if (!finished) {
                proc.destroyForcibly()
                proc.waitFor(5, TimeUnit.SECONDS)
            }
            val code = runCatching { proc.exitValue() }.getOrNull()
            buildString {
                appendLine("self-test exit=${code ?: "timeout"}")
                appendLine("machine listed: ${output.contains("iPhone6splus-n66-s8000")}")
                appendLine(output.trim())
            }
        } catch (t: Throwable) {
            "self-test failed: ${t.javaClass.simpleName}: ${t.message}"
        }
    }

    /** Send one line to the guest serial console. */
    fun send(line: String) {
        val writer = stdin ?: return
        runCatching {
            writer.write(line)
            writer.write("\n")
            writer.flush()
        }
    }

    fun stop() {
        val proc = process ?: return
        proc.destroy()
        scope?.launch {
            if (!proc.waitFor(3, TimeUnit.SECONDS)) {
                proc.destroyForcibly()
            }
        }
    }

    fun resetLog() {
        _log.value = ""
    }

    fun setLog(text: String) {
        _log.value = text
    }

    fun shutdown() {
        stop()
        waiter?.cancel()
        scope?.cancel()
        scope = null
        waiter = null
    }

    fun buildMachineOption(directory: File): String? {
        val parts = mutableListOf("iPhone6splus-n66-s8000")
        for ((property, name) in requiredFiles) {
            val file = File(directory, name)
            if (file.absolutePath.contains(',')) return null
            parts += "$property=${file.absolutePath}"
        }
        parts += "kern-cmd-args=debug=0x8 kextlog=0xfff cpus=1 rd=disk0 serial=2"
        parts += "xnu-ramfb=off"
        return parts.joinToString(",")
    }

    private fun append(text: String) {
        if (text.isNotBlank()) Log.d("iosem-qemu", text.trimEnd())
        _log.update { previous ->
            val combined = previous + text
            val lines = combined.split('\n')
            if (lines.size <= MAX_LOG_LINES) {
                combined
            } else {
                lines.takeLast(MAX_LOG_LINES).joinToString("\n")
            }
        }
    }
}
