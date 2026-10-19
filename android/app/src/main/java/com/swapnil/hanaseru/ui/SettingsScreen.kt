package com.swapnil.hanaseru.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.swapnil.hanaseru.coach.CoachClient
import com.swapnil.hanaseru.coach.CoachSettings
import kotlinx.coroutines.launch

/** Your name, and how to reach the AI coach that writes your own scenes. */
@Composable
fun SettingsScreen(settings: CoachSettings, coach: CoachClient, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    var showPassphrase by remember { mutableStateOf(false) }
    var checking by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf("") }
    var good by remember { mutableStateOf(false) }

    Scaffold(topBar = { BackBar("Settings", onBack) }) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("You", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            OutlinedTextField(
                value = settings.learnerName,
                onValueChange = { settings.learnerName = it },
                label = { Text("Your name") },
                placeholder = { Text("e.g. スワプニル or Swapnil") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Text("Used where a line says your name. Written in katakana, the Japanese voice says it best.",
                 style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

            Text("AI coach", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
                 modifier = Modifier.padding(top = 12.dp))
            Text("The coach writes your own scenes from a description. It runs on your own server.",
                 style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            OutlinedTextField(
                value = settings.serverURL,
                onValueChange = {
                    settings.serverURL = it
                    result = ""
                },
                label = { Text("Server address") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )
            if (settings.serverURL.trim().trimEnd('/') != CoachSettings.DEFAULT_URL) {
                TextButton(onClick = { settings.serverURL = CoachSettings.DEFAULT_URL }) { Text("Use the usual address") }
            }
            OutlinedTextField(
                value = settings.passphrase,
                onValueChange = {
                    settings.passphrase = it
                    result = ""
                },
                label = { Text("Passphrase") },
                singleLine = true,
                visualTransformation = if (showPassphrase) VisualTransformation.None else PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                trailingIcon = {
                    IconButton(onClick = { showPassphrase = !showPassphrase }) {
                        Icon(if (showPassphrase) Icons.Filled.VisibilityOff else Icons.Filled.Visibility,
                             contentDescription = if (showPassphrase) "Hide the passphrase" else "Show the passphrase")
                    }
                },
                modifier = Modifier.fillMaxWidth(),
            )
            Text("Kept only on this phone (not in backups) and sent only to the server above.",
                 style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Button(
                onClick = {
                    checking = true
                    result = ""
                    scope.launch {
                        try {
                            result = coach.health()
                            good = true
                        } catch (failure: CoachClient.Failure) {
                            result = failure.message ?: "Couldn't reach the coach."
                            good = false
                        } finally {
                            checking = false
                        }
                    }
                },
                enabled = !checking && settings.isSetUp,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Check the connection")
            }
            if (checking) {
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                Text("Checking… the free server can take up to a minute to wake up.",
                     style = MaterialTheme.typography.bodyMedium)
            }
            if (result.isNotEmpty()) {
                Text(result, style = MaterialTheme.typography.bodyMedium,
                     color = if (good) Palette.go else MaterialTheme.colorScheme.error)
            }
        }
    }
}
