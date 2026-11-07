package dev.iosem.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp

@Composable
fun AboutScreen() {
    val uriHandler = LocalUriHandler.current

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
    ) {
        Text("iosem 0.3.0", style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(4.dp))
        Text(
            "An Android front-end for a user-supplied-firmware XNU and iOS research emulator.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Section("What this build does") {
            Bullet("Downloads Apple's open-source XNU tree (APSL-2.0) and the GPL-2.0 n66 QEMU source on demand.")
            Bullet("Imports the decoded kernel, device tree, driver and disk images you select into a stable artifact directory.")
            Bullet("Validates the artifact set through a JNI probe and reports device capabilities.")
            Bullet("Never ships, bundles or fetches Apple firmware, iBoot, kernelcache, device trees or userland.")
        }

        Section("What this build does not do") {
            Bullet("It packages the n66 QEMU backend and can launch it from the Console; it still needs the five Apple files you supply.")
            Bullet("It does not provide a usable iOS experience: no GUI, no App Store, no general networking stack, no cellular.")
            Bullet("It does not run at native speed. Android apps cannot use KVM, so the backend is TCG-only.")
            Bullet("It does not replace the host n66 harness: build and run that from host/ first.")
        }

        Section("The n66 machine") {
            Text(
                "The closest public work is Aleph Research's xnu-qemu-arm64 fork. Its " +
                    "iPhone6splus-n66-s8000 machine targets iOS 12.1 build 16B92 and loads a " +
                    "decoded kernel directly; it does not emulate iBoot. It patches hard-coded " +
                    "kernel addresses in memory, exposes two HFS+ images through a custom block " +
                    "driver, and reaches launchd plus bash over serial or the upstream SSH " +
                    "tunnel. It has no GUI, SEP, cellular or usable phone stack.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        Section("Sources") {
            Link("Apple XNU (APSL-2.0)", "https://github.com/apple-oss-distributions/xnu", uriHandler)
            Link(
                "Aleph Research: xnu-qemu-arm64",
                "https://github.com/alephsecurity/xnu-qemu-arm64",
                uriHandler,
            )
            Link(
                "Aleph Research: Running iOS in QEMU",
                "https://alephsecurity.com/2019/06/17/xnu-qemu-arm64-1",
                uriHandler,
            )
            Link(
                "Booting a macOS Apple Silicon kernel in QEMU",
                "https://worthdoingbadly.com/xnuqemu3",
                uriHandler,
            )
            Link(
                "Asahi Linux: ARM64 XNU boot protocol",
                "https://asahilinux.org/docs/platform/introduction",
                uriHandler,
            )
        }

        Section("Legal") {
            Text(
                "XNU is distributed by Apple under the Apple Public Source License 2.0. " +
                    "Everything else in an IPSW is Apple copyright and is not redistributable. " +
                    "Importing a file you own is your responsibility; do not share extracted " +
                    "firmware. See docs/LEGAL.md in the repository.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        Spacer(Modifier.height(32.dp))
    }
}

@Composable
private fun Section(title: String, content: @Composable () -> Unit) {
    Spacer(Modifier.height(24.dp))
    Text(title, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
    Spacer(Modifier.height(8.dp))
    Column { content() }
}

@Composable
private fun Bullet(text: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp),
    ) {
        Text("• ", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(
            text,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun Link(label: String, url: String, uriHandler: androidx.compose.ui.platform.UriHandler) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { uriHandler.openUri(url) }
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
            color = MaterialTheme.colorScheme.secondary,
        )
    }
}
