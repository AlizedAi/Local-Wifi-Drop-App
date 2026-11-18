package com.alizedai.local_wifi_drop

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.content.ContentValues
import android.database.Cursor
import android.os.Environment
import android.provider.MediaStore
import android.provider.DocumentsContract
import android.content.pm.PackageManager
import android.os.Build
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private var wifiDiscoveryMulticastLock: WifiManager.MulticastLock? = null
    private var notificationPermissionResult: MethodChannel.Result? = null
    private val notificationPermissionRequestCode = 7401
    private var storagePermissionResult: MethodChannel.Result? = null
    private var pendingStorageAction: (() -> Unit)? = null
    private val storagePermissionRequestCode = 7402

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == notificationPermissionRequestCode) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            notificationPermissionResult?.success(granted)
            notificationPermissionResult = null
        } else if (requestCode == storagePermissionRequestCode) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            val result = storagePermissionResult
            val action = pendingStorageAction
            storagePermissionResult = null
            pendingStorageAction = null
            if (granted && result != null && action != null) {
                action.invoke()
            } else {
                result?.error("STORAGE_PERMISSION_DENIED", "Storage permission is required to save files in Documents.", null)
            }
        }
    }

    private val networkChannel = "local_wifi_drop/network"
    private val storageChannel = "local_wifi_drop/storage"
    private val settingsChannel = "local_wifi_drop/settings"
    private val soundChannel = "local_wifi_drop/sound"

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Android filters Wi-Fi broadcast/multicast packets unless the app holds
        // a MulticastLock. Keep it while the activity (and its discovery UI) lives.
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifiDiscoveryMulticastLock = wifi.createMulticastLock("LocalWifiDropDiscovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
            wifiDiscoveryMulticastLock = null
        }
    }

    override fun onDestroy() {
        try {
            wifiDiscoveryMulticastLock?.let { lock ->
                if (lock.isHeld) lock.release()
            }
        } catch (_: Exception) {
            // Activity shutdown must not be blocked by a Wi-Fi lock cleanup failure.
        } finally {
            wifiDiscoveryMulticastLock = null
        }
        super.onDestroy()
    }

    override fun onPostResume() {
        super.onPostResume()
        // Re-apply adjustResize after returning from background. Some Samsung
        // One UI versions can retain the keyboard-shrunken window bounds.
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        window.decorView.post {
            window.decorView.requestApplyInsets()
            window.decorView.requestLayout()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, settingsChannel)
            .setMethodCallHandler { call, result ->
                val preferences = getSharedPreferences("local_wifi_drop_settings", Context.MODE_PRIVATE)
                when (call.method) {
                    "getLanguage" -> result.success(preferences.getString("language", "en"))
                    "setLanguage" -> {
                        val language = call.arguments as? String
                        if (language == "en" || language == "fa") {
                            preferences.edit().putString("language", language).apply()
                            result.success(true)
                        } else {
                            result.error("INVALID_LANGUAGE", "Supported languages are en and fa.", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, networkChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getNotificationsEnabled" -> {
                        try {
                            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                            val appEnabled = Build.VERSION.SDK_INT < 24 || manager.areNotificationsEnabled()
                            val runtimeGranted = Build.VERSION.SDK_INT < 33 ||
                                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                                PackageManager.PERMISSION_GRANTED
                            result.success(appEnabled && runtimeGranted)
                        } catch (error: Exception) {
                            result.error("NOTIFICATION_STATE_FAILED", error.message, null)
                        }
                    }
                    "requestNotificationPermission" -> {
                        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        val appEnabled = Build.VERSION.SDK_INT < 24 || manager.areNotificationsEnabled()
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            if (notificationPermissionResult != null) {
                                result.error("PERMISSION_REQUEST_IN_PROGRESS", "Notification permission request is already active.", null)
                            } else {
                                notificationPermissionResult = result
                                requestPermissions(
                                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                                    notificationPermissionRequestCode
                                )
                            }
                        } else if (appEnabled) {
                            result.success(true)
                        } else {
                            try {
                                startActivity(
                                    Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(
                                        Settings.EXTRA_APP_PACKAGE,
                                        packageName
                                    )
                                )
                                result.success(false)
                            } catch (error: Exception) {
                                result.error("NOTIFICATION_SETTINGS_FAILED", error.message, null)
                            }
                        }
                    }
                    "openNotificationSettings" -> {
                        try {
                            startActivity(
                                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(
                                    Settings.EXTRA_APP_PACKAGE,
                                    packageName
                                )
                            )
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("NOTIFICATION_SETTINGS_FAILED", error.message, null)
                        }
                    }
                    "getWifiEnabled" -> {
                        try {
                            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                            result.success(wifiManager.isWifiEnabled)
                        } catch (error: Exception) {
                            result.error("WIFI_STATE_FAILED", error.message, null)
                        }
                    }
                    "openWifiSettings" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("WIFI_SETTINGS_FAILED", error.message, null)
                        }
                    }
                    "getWifiGateway" -> {
                        try {
                            result.success(findWifiGateway())
                        } catch (error: Exception) {
                            result.error("GATEWAY_LOOKUP_FAILED", error.message, null)
                        }
                    }
                    "scanWifiDevices" -> {
                        Thread {
                            try {
                                val devices = scanWifiDevices()
                                runOnUiThread { result.success(devices) }
                            } catch (error: Exception) {
                                runOnUiThread {
                                    result.error("WIFI_SCAN_FAILED", error.message, null)
                                }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStorageAccessEnabled" -> {
                        try {
                            result.success(isStorageAccessEnabled())
                        } catch (error: Exception) {
                            result.error("STORAGE_STATE_FAILED", error.message, null)
                        }
                    }
                    "requestStorageAccess" -> {
                        if (isStorageAccessEnabled()) {
                            result.success(true)
                        } else if (Build.VERSION.SDK_INT >= 30) {
                            val preferences = getSharedPreferences("local_wifi_drop_permissions", Context.MODE_PRIVATE)
                            if (preferences.getBoolean("all_files_access_prompted", false)) {
                                result.success(false)
                            } else {
                                preferences.edit().putBoolean("all_files_access_prompted", true).apply()
                                try {
                                    startActivity(
                                        Intent(
                                            Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                            android.net.Uri.parse("package:$packageName")
                                        )
                                    )
                                    result.success(false)
                                } catch (error: Exception) {
                                    result.error("STORAGE_SETTINGS_FAILED", error.message, null)
                                }
                            }
                        } else if (Build.VERSION.SDK_INT >= 23 &&
                            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                            PackageManager.PERMISSION_GRANTED
                        ) {
                            if (storagePermissionResult != null) {
                                result.error("PERMISSION_REQUEST_IN_PROGRESS", "A storage permission request is already active.", null)
                            } else {
                                storagePermissionResult = result
                                pendingStorageAction = {
                                    result.success(isStorageAccessEnabled())
                                }
                                requestPermissions(
                                    arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                                    storagePermissionRequestCode
                                )
                            }
                        } else {
                            result.success(isStorageAccessEnabled())
                        }
                    }
                    "openReceivedFolder" -> {
                        try {
                            val documentId = "primary:Documents/Local Wi-Fi Drop/Received"
                            val directoryUri = DocumentsContract.buildDocumentUri(
                                "com.android.externalstorage.documents",
                                documentId
                            )
                            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(directoryUri, "vnd.android.document/directory")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                putExtra(
                                    "org.openintents.extra.ABSOLUTE_PATH",
                                    File(
                                        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS),
                                        "Local Wi-Fi Drop/Received"
                                    ).absolutePath
                                )
                            }
                            if (viewIntent.resolveActivity(packageManager) != null) {
                                startActivity(viewIntent)
                            } else {
                                val pickerIntent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                    putExtra(DocumentsContract.EXTRA_INITIAL_URI, directoryUri)
                                }
                                startActivity(pickerIntent)
                            }
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("OPEN_RECEIVED_FOLDER_FAILED", error.message, null)
                        }
                    }
                    "openStorageFolder" -> {
                        try {
                            val documentId = "primary:Documents/Local Wi-Fi Drop"
                            val directoryUri = DocumentsContract.buildDocumentUri(
                                "com.android.externalstorage.documents",
                                documentId
                            )
                            val viewIntent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(directoryUri, "vnd.android.document/directory")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                putExtra("org.openintents.extra.ABSOLUTE_PATH",
                                    File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS),
                                        "Local Wi-Fi Drop").absolutePath)
                            }
                            if (viewIntent.resolveActivity(packageManager) != null) {
                                startActivity(viewIntent)
                            } else {
                                val pickerIntent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                    putExtra(
                                        DocumentsContract.EXTRA_INITIAL_URI,
                                        directoryUri
                                    )
                                }
                                startActivity(pickerIntent)
                            }
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("OPEN_STORAGE_FOLDER_FAILED", error.message, null)
                        }
                    }
                    "openStorageSettings" -> {
                        try {
                            val settingsIntent = if (Build.VERSION.SDK_INT >= 30) {
                                Intent(
                                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                    android.net.Uri.parse("package:$packageName")
                                )
                            } else {
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    android.net.Uri.parse("package:$packageName")
                                )
                            }
                            startActivity(settingsIntent)
                            result.success(true)
                        } catch (error: Exception) {
                            result.error("STORAGE_SETTINGS_FAILED", error.message, null)
                        }
                    }
                    "getStagingDirectory" -> {
                        val directory = File(filesDir, "received-staging")
                        if (directory.mkdirs() || directory.isDirectory) {
                            result.success(directory.absolutePath)
                        } else {
                            result.error("STAGING_DIRECTORY_FAILED", "Could not create the receive staging directory.", null)
                        }
                    }
                    "publishReceivedFile" -> {
                        val sourcePath = call.argument<String>("sourcePath")
                        val fileName = call.argument<String>("fileName")
                        if (sourcePath.isNullOrBlank() || fileName.isNullOrBlank()) {
                            result.error("INVALID_FILE", "A source path and file name are required.", null)
                        } else {
                            withStoragePermission(result) {
                                publishReceivedFile(File(sourcePath), fileName, result)
                            }
                        }
                    }
                    "deleteReceivedFile" -> {
                        val uriText = call.argument<String>("uri")
                        val sourcePath = call.argument<String>("sourcePath")
                        if (uriText.isNullOrBlank() || sourcePath.isNullOrBlank()) {
                            result.error("INVALID_FILE", "A saved file location is required.", null)
                        } else {
                            try {
                                val deletedPublished = if (uriText.startsWith("content://")) {
                                    contentResolver.delete(android.net.Uri.parse(uriText), null, null) > 0
                                } else {
                                    File(uriText).delete()
                                }
                                val staging = File(sourcePath)
                                val deletedStaging = !staging.exists() || staging.delete()
                                if (deletedPublished && deletedStaging) {
                                    result.success(true)
                                } else {
                                    result.error("DELETE_FAILED", "Android could not delete the received file from all storage locations.", null)
                                }
                            } catch (error: Exception) {
                                result.error("DELETE_FAILED", error.message, null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, soundChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "playSent" -> result.success(
                        playMessageTone(ToneGenerator.TONE_PROP_ACK, 130)
                    )
                    "playReceived" -> result.success(
                        playMessageTone(ToneGenerator.TONE_PROP_BEEP2, 230)
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun playMessageTone(tone: Int, durationMs: Int): Boolean {
        val generator = try {
            ToneGenerator(AudioManager.STREAM_NOTIFICATION, 85)
        } catch (_: Exception) {
            return false
        }
        val started = try {
            generator.startTone(tone, durationMs)
        } catch (_: Exception) {
            false
        }
        if (started) {
            Handler(Looper.getMainLooper()).postDelayed(
                { generator.release() },
                durationMs.toLong() + 100L
            )
        } else {
            generator.release()
        }
        return started
    }

    private fun isStorageAccessEnabled(): Boolean {
        val storageMounted = Environment.getExternalStorageState() == Environment.MEDIA_MOUNTED
        if (!storageMounted) return false
        return when {
            Build.VERSION.SDK_INT >= 30 -> Environment.isExternalStorageManager()
            Build.VERSION.SDK_INT >= 23 ->
                checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                    PackageManager.PERMISSION_GRANTED
            else -> true
        }
    }

    private fun withStoragePermission(result: MethodChannel.Result, action: () -> Unit) {
        val hasAccess = when {
            Build.VERSION.SDK_INT >= 30 -> Environment.isExternalStorageManager()
            Build.VERSION.SDK_INT >= 23 ->
                checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                    PackageManager.PERMISSION_GRANTED
            else -> true
        }
        if (hasAccess) {
            action()
            return
        }
        if (Build.VERSION.SDK_INT >= 30) {
            result.error("STORAGE_PERMISSION_DENIED", "Allow all-files access in Android settings to save files.", null)
            return
        }
        if (storagePermissionResult != null) {
            result.error("PERMISSION_REQUEST_IN_PROGRESS", "A storage permission request is already active.", null)
            return
        }
        storagePermissionResult = result
        pendingStorageAction = action
        requestPermissions(
            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
            storagePermissionRequestCode
        )
    }

    private fun publishReceivedFile(source: File, fileName: String, result: MethodChannel.Result) {
        if (!source.isFile) {
            result.error("SOURCE_FILE_MISSING", "The completed received file could not be found.", null)
            return
        }
        Thread {
            try {
                val uri = source.inputStream().use { input ->
                    writePublicDocument(
                        input = input,
                        relativePath = "Documents/Local Wi-Fi Drop/Received/",
                        requestedName = fileName,
                        overwrite = false
                    )
                }
                runOnUiThread { result.success(uri) }
            } catch (error: Exception) {
                runOnUiThread { result.error("PUBLIC_SAVE_FAILED", error.message, null) }
            }
        }.start()
    }

    private fun writePublicDocument(
        input: java.io.InputStream,
        relativePath: String,
        requestedName: String,
        overwrite: Boolean
    ): String {
        if (Build.VERSION.SDK_INT < 29) {
            val root = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
            val directory = File(root, relativePath.removePrefix("Documents/"))
            if (!directory.exists() && !directory.mkdirs()) {
                throw IllegalStateException("Could not create Documents/Local Wi-Fi Drop.")
            }
            val target = File(directory, if (overwrite) requestedName else uniqueLegacyName(directory, requestedName))
            input.use { source -> target.outputStream().use { source.copyTo(it) } }
            return target.absolutePath
        }

        val resolver = contentResolver
        val collection = MediaStore.Files.getContentUri("external")
        val existing = resolver.query(
            collection,
            arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND ${MediaStore.MediaColumns.DISPLAY_NAME}=?",
            arrayOf(relativePath, requestedName),
            null
        )
        val existingUri = existing.use { cursor ->
            if (cursor != null && cursor.moveToFirst()) {
                android.content.ContentUris.withAppendedId(collection, cursor.getLong(0))
            } else null
        }
        if (overwrite && existingUri != null) resolver.delete(existingUri, null, null)
        val displayName = if (overwrite || existingUri == null) requestedName
            else uniqueMediaStoreName(collection, relativePath, requestedName)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, if (displayName.endsWith(".json", true)) "application/json" else "application/octet-stream")
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("Android could not create the document.")
        try {
            val output = resolver.openOutputStream(uri, "w")
                ?: throw IllegalStateException("Android could not open the new document.")
            input.use { source -> output.use { source.copyTo(it) } }
            val published = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            resolver.update(uri, published, null, null)
            return uri.toString()
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    private fun uniqueMediaStoreName(collection: android.net.Uri, relativePath: String, name: String): String {
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val extension = if (dot > 0) name.substring(dot) else ""
        for (index in 1..9999) {
            val candidate = "$stem ($index)$extension"
            val cursor = contentResolver.query(
                collection,
                arrayOf(MediaStore.MediaColumns._ID),
                "${MediaStore.MediaColumns.RELATIVE_PATH}=? AND ${MediaStore.MediaColumns.DISPLAY_NAME}=?",
                arrayOf(relativePath, candidate),
                null
            )
            val exists = cursor.use { it != null && it.moveToFirst() }
            if (!exists) return candidate
        }
        throw IllegalStateException("No available filename remains.")
    }

    private fun uniqueLegacyName(directory: File, name: String): String {
        if (!File(directory, name).exists()) return name
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val extension = if (dot > 0) name.substring(dot) else ""
        for (index in 1..9999) {
            val candidate = "$stem ($index)$extension"
            if (!File(directory, candidate).exists()) return candidate
        }
        throw IllegalStateException("No available filename remains.")
    }

    @Suppress("DEPRECATION")
    private fun findWifiGateway(): String? {
        val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val wifiNetworks = connectivity.allNetworks.filter { network ->
            connectivity.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }

        for (network in wifiNetworks) {
            val route = connectivity.getLinkProperties(network)
                ?.routes
                ?.firstOrNull { it.isDefaultRoute }
            val gateway = route?.gateway
            if (gateway is Inet4Address && !gateway.isAnyLocalAddress) {
                return gateway.hostAddress
            }
        }

        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val gateway = wifi.dhcpInfo?.gateway ?: 0
        if (gateway == 0) return null
        return listOf(
            gateway and 0xff,
            gateway shr 8 and 0xff,
            gateway shr 16 and 0xff,
            gateway shr 24 and 0xff
        ).joinToString(".")
    }

    @Suppress("DEPRECATION")
    private fun scanWifiDevices(): List<String> {
        val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val wifiNetwork = connectivity.allNetworks.firstOrNull { network ->
            connectivity.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }

        // Newer Android versions expose the Wi-Fi IPv4 address through
        // LinkProperties. Older Samsung/Android builds may omit it there,
        // even while Wi-Fi is connected, so fall back to the DHCP lease.
        val link = wifiNetwork?.let { network ->
            connectivity.getLinkProperties(network)
                ?.linkAddresses
                ?.firstOrNull { it.address is Inet4Address }
        }

        // Some older Samsung firmware returns zeroed DhcpInfo even while
        // connected to Wi-Fi. Try the OS network-interface table before DHCP.
        val interfaceAddress = if (link == null) findWifiInterfaceAddress() else null
        val localAddress: Inet4Address
        val prefix: Int
        when {
            link != null -> {
                localAddress = link.address as Inet4Address
                prefix = link.prefixLength
            }
            interfaceAddress != null -> {
                localAddress = interfaceAddress.first
                prefix = interfaceAddress.second
            }
            else -> {
                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val dhcp = wifi.dhcpInfo
                    ?: throw IllegalStateException("Wi-Fi is connected, but Android did not provide its network details. Check Wi-Fi permission and reconnect.")
                val ip = dhcp.ipAddress
                val netmask = Integer.reverseBytes(dhcp.netmask)
                if (ip == 0 || dhcp.netmask == 0) {
                    throw IllegalStateException("Note 8 did not expose its Wi-Fi IP or subnet mask. Android network-interface lookup also failed.")
                }

                // WifiManager.DhcpInfo stores IPv4 integers in little-endian order.
                val bytes = byteArrayOf(
                    (ip and 0xff).toByte(),
                    (ip ushr 8 and 0xff).toByte(),
                    (ip ushr 16 and 0xff).toByte(),
                    (ip ushr 24 and 0xff).toByte()
                )
                localAddress = InetAddress.getByAddress(bytes) as Inet4Address
                prefix = Integer.bitCount(netmask)
                val contiguousMask = if (prefix == 0) 0 else (-1 shl (32 - prefix))
                if (prefix !in 16..30 || netmask != contiguousMask) {
                    throw IllegalStateException("The Wi-Fi IPv4 subnet mask is unavailable or unsupported.")
                }
            }
        }
        if (prefix !in 16..30) {
            throw IllegalStateException("This Wi-Fi subnet is not supported for device scanning.")
        }

        val local = ipv4ToInt(localAddress)
        val mask = (-1 shl (32 - prefix))
        val network = local and mask
        val broadcast = network or mask.inv()
        val hostCount = broadcast - network - 1
        if (hostCount > 4094) {
            throw IllegalStateException("The Wi-Fi network is too large to scan safely.")
        }

        val candidates = (network + 1 until broadcast).filter { it != local }
        val executor = Executors.newFixedThreadPool(64)
        try {
            // UDP probes trigger ARP resolution even when a phone has no open
            // TCP ports and ignores ICMP ping. This is important for Android devices.
            val probes = candidates.map { host ->
                Callable {
                    try {
                        val target = InetAddress.getByName(intToIpv4(host))
                        DatagramSocket().use { socket ->
                            socket.send(DatagramPacket(byteArrayOf(0), 1, target, 9))
                        }
                    } catch (_: Exception) {
                        // Continue; the ARP table and fallback probes are best effort.
                    }
                }
            }
            executor.invokeAll(probes, 5, TimeUnit.SECONDS)
            Thread.sleep(350)

            val discovered = readResolvedArpEntries(network, broadcast, local).toMutableSet()

            // Some Android builds restrict access to the ARP table. Keep active
            // reachability checks as a fallback for those devices/networks.
            val ports = intArrayOf(80, 443, 22, 445, 5555, 8080, 8443, 3389, 9100)
            val remaining = candidates.filterNot { intToIpv4(it) in discovered }
            val fallbackTasks = remaining.map { host ->
                Callable<String?> {
                    val address = intToIpv4(host)
                    val reachable = try {
                        InetAddress.getByName(address).isReachable(250)
                    } catch (_: Exception) {
                        false
                    }
                    if (reachable) return@Callable address

                    for (port in ports) {
                        try {
                            Socket().use { socket ->
                                socket.connect(InetSocketAddress(address, port), 110)
                            }
                            return@Callable address
                        } catch (_: Exception) {
                            // Closed or filtered ports are not proof that a host is offline.
                        }
                    }
                    null
                }
            }
            executor.invokeAll(fallbackTasks, 7, TimeUnit.SECONDS)
                .forEach { future ->
                    try {
                        if (!future.isCancelled) future.get()?.let(discovered::add)
                    } catch (_: Exception) {
                        // Ignore an individual host that did not respond.
                    }
                }

            return discovered.sortedBy {
                ipv4ToInt(InetAddress.getByName(it) as Inet4Address)
            }
        } finally {
            executor.shutdownNow()
        }
    }

    @Suppress("DEPRECATION")
    private fun findWifiInterfaceAddress(): Pair<Inet4Address, Int>? {
        return try {
            val interfaces = NetworkInterface.getNetworkInterfaces() ?: return null
            val candidates = mutableListOf<Pair<Int, Pair<Inet4Address, Int>>>()
            while (interfaces.hasMoreElements()) {
                val networkInterface = interfaces.nextElement()
                val name = networkInterface.name.lowercase()
                if (!name.contains("wlan") && !name.contains("wifi")) continue
                if (!networkInterface.isUp || networkInterface.isLoopback) continue
                for (entry in networkInterface.interfaceAddresses) {
                    val address = entry.address as? Inet4Address ?: continue
                    val bytes = address.address
                    val firstOctet = bytes[0].toInt() and 0xff
                    val secondOctet = bytes[1].toInt() and 0xff
                    val isPrivate = firstOctet == 10 ||
                        (firstOctet == 172 && secondOctet in 16..31) ||
                        (firstOctet == 192 && secondOctet == 168)
                    val prefix = entry.networkPrefixLength.toInt()
                    if (isPrivate && prefix in 16..30) {
                        // Prefer wlan interfaces; retain wifi-named vendor interfaces too.
                        val priority = if (name.contains("wlan")) 0 else 1
                        candidates.add(priority to (address to prefix))
                    }
                }
            }
            candidates.minByOrNull { it.first }?.second
        } catch (_: Exception) {
            null
        }
    }

    private fun readResolvedArpEntries(
        network: Int,
        broadcast: Int,
        local: Int
    ): Set<String> {
        val arpFile = File("/proc/net/arp")
        if (!arpFile.canRead()) return emptySet()

        return try {
            arpFile.readLines()
                .drop(1)
                .mapNotNull { line ->
                    val fields = line.trim().split(Regex("\\s+"))
                    if (fields.size < 6) return@mapNotNull null

                    val address = fields[0]
                    val host = try {
                        ipv4ToInt(InetAddress.getByName(address) as Inet4Address)
                    } catch (_: Exception) {
                        return@mapNotNull null
                    }
                    val flags = fields[2].removePrefix("0x").toIntOrNull(16) ?: 0
                    val mac = fields[3]
                    val validMac = mac != "00:00:00:00:00:00"
                    if (host > network && host < broadcast && host != local &&
                        (flags and 0x2) != 0 && validMac
                    ) address else null
                }
                .toSet()
        } catch (_: Exception) {
            emptySet()
        }
    }

    private fun ipv4ToInt(address: Inet4Address): Int {
        val bytes = address.address
        return ((bytes[0].toInt() and 0xff) shl 24) or
            ((bytes[1].toInt() and 0xff) shl 16) or
            ((bytes[2].toInt() and 0xff) shl 8) or
            (bytes[3].toInt() and 0xff)
    }

    private fun intToIpv4(value: Int): String =
        listOf(
            (value ushr 24) and 0xff,
            (value ushr 16) and 0xff,
            (value ushr 8) and 0xff,
            value and 0xff
        ).joinToString(".")
}
