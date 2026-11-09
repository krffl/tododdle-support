// A minimal Android activity that opens the ToDoddle report sheet.
// Copy it into an app that depends on com.github.krffl.tododdle-support:support-compose.
// It is a snippet, not part of the Gradle build.
package com.example.mosslight

import android.os.Bundle
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import com.tododdle.support.Configuration
import com.tododdle.support.ReportContext
import com.tododdle.support.TododdleSupport
import com.tododdle.support.compose.ReportSheet

class MainActivity : ComponentActivity() {
    // Create the client once, for example in your Application or DI graph.
    private val support by lazy {
        TododdleSupport(applicationContext, Configuration(key = "tdsk_pub_YOUR_PUBLIC_KEY"))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                var showReport by remember { mutableStateOf(false) }
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Button(onClick = { showReport = true }) { Text("Report a problem") }
                }
                if (showReport) {
                    ReportSheet(
                        support = support,
                        onDismissRequest = { showReport = false },
                        context = ReportContext(screen = "Home"),
                        onReported = { receipt ->
                            Toast.makeText(this, "Sent (${receipt.reportId})", Toast.LENGTH_SHORT).show()
                        },
                    )
                }
            }
        }
    }
}
