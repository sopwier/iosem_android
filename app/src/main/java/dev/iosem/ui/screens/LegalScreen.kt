package dev.iosem.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun LegalScreen(onAccept: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
    ) {
        Spacer(Modifier.height(24.dp))

        Text("Before you continue", style = MaterialTheme.typography.headlineMedium)
        Spacer(Modifier.height(8.dp))
        Text(
            "iosem is an emulator shell and research tool. It contains no Apple software: " +
                "no iOS, no iBoot, no kernelcache, no device tree, no userland, no signing keys. " +
                "It ships an open-source QEMU backend built for Android. That backend can run a " +
                "decoded iOS 12.1 kernel you supply to a serial shell; it is not a phone, and it " +
                "does not run iBoot or a signed boot chain.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(24.dp))

        Bullet(
            "The XNU kernel is open source under APSL-2.0 and may be downloaded from Apple's " +
                "official source release.",
        )
        Bullet(
            "Every other boot component must come from hardware you own. iosem only copies a " +
                "file you select; it never fetches firmware from the network.",
        )
        Bullet(
            "Do not redistribute Apple firmware or extracted components. Redistribution is " +
                "restricted by copyright and, for signed components, by anti-circumvention law.",
        )
        Bullet(
            "Booting iOS on non-Apple hardware is not supported by Apple. The public n66 " +
                "harness patches the guest kernel in memory to bypass CoreTrust; that may be " +
                "restricted by anti-circumvention law even for firmware you own.",
        )
        Bullet(
            "Expect research-grade results at best: launchd and bash over serial or an SSH " +
                "tunnel, no GUI, no App Store, no SEP, no cellular, and software emulation only. " +
                "Android apps cannot use KVM.",
        )

        Spacer(Modifier.height(24.dp))

        Surface(
            color = MaterialTheme.colorScheme.surfaceVariant,
            shape = MaterialTheme.shapes.medium,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                modifier = Modifier.padding(16.dp),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("!", style = MaterialTheme.typography.titleLarge)
                Text(
                    "By continuing you confirm that you own the device and firmware you will " +
                        "import, that you will not redistribute it, and that you understand the " +
                        "app boots a research harness, not a usable iPhone.",
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }

        Spacer(Modifier.height(24.dp))

        Button(onClick = onAccept, modifier = Modifier.fillMaxWidth()) {
            Text("I own the hardware and firmware I will import")
        }

        Spacer(Modifier.height(32.dp))
    }
}

@Composable
private fun Bullet(text: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text("•", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary)
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
