#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR="$1"
CFG="$BUILD_DIR/config.json"
OUT="project"

APP_NAME=$(jq -r '.appName' "$CFG")
PKG=$(jq -r '.packageId' "$CFG")
VERSION_NAME=$(jq -r '.versionName' "$CFG")
VERSION_CODE=$(jq -r '.versionCode' "$CFG")
MODE=$(jq -r '.mode' "$CFG")
URL=$(jq -r '.url // ""' "$CFG")
ORIENT=$(jq -r '.orientation // "unspecified"' "$CFG")
THEME=$(jq -r '.themeColor // "#101014"' "$CFG")
ALLOW_EXTERNAL=$(jq -r '.allowExternal // true' "$CFG")

PKG_PATH=${PKG//./\/}

rm -rf "$OUT"
mkdir -p "$OUT/app/src/main/java/$PKG_PATH"
mkdir -p "$OUT/app/src/main/res/values" "$OUT/app/src/main/res/xml" "$OUT/app/src/main/res/layout"
mkdir -p "$OUT/app/src/main/assets/www"

# ---------- web payload ----------
if [ "$MODE" = "file" ]; then
  if [ -f "$BUILD_DIR/web.zip" ]; then
    unzip -q -o "$BUILD_DIR/web.zip" -d "$OUT/app/src/main/assets/www"
  fi
  # flatten single wrapper directory
  if [ ! -f "$OUT/app/src/main/assets/www/index.html" ]; then
    FOUND=$(find "$OUT/app/src/main/assets/www" -maxdepth 3 -name index.html | head -n 1 || true)
    if [ -n "$FOUND" ]; then
      SRC=$(dirname "$FOUND")
      if [ "$SRC" != "$OUT/app/src/main/assets/www" ]; then
        mv "$SRC" "$OUT/app/src/main/assets/_w"
        rm -rf "$OUT/app/src/main/assets/www"
        mv "$OUT/app/src/main/assets/_w" "$OUT/app/src/main/assets/www"
      fi
    fi
  fi
  START_URL="file:///android_asset/www/index.html"
else
  START_URL="$URL"
  echo "<html><body></body></html>" > "$OUT/app/src/main/assets/www/index.html"
fi

# ---------- gradle ----------
cat > "$OUT/settings.gradle" <<'EOF'
pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "webtoapp"
include ':app'
EOF

cat > "$OUT/build.gradle" <<'EOF'
plugins {
    id 'com.android.application' version '8.5.2' apply false
}
EOF

cat > "$OUT/gradle.properties" <<'EOF'
org.gradle.jvmargs=-Xmx3g
android.useAndroidX=true
android.nonTransitiveRClass=true
EOF

# ---------- keystore ----------
keytool -genkeypair -v -keystore "$OUT/app/release.jks" -storepass android -keypass android \
  -alias apkkey -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=$APP_NAME, OU=Mobile, O=WebToApp, C=ID" >/dev/null 2>&1

cat > "$OUT/app/build.gradle" <<EOF
plugins { id 'com.android.application' }

android {
    namespace '$PKG'
    compileSdk 34

    defaultConfig {
        applicationId "$PKG"
        minSdk 21
        targetSdk 34
        versionCode $VERSION_CODE
        versionName "$VERSION_NAME"
    }

    signingConfigs {
        release {
            storeFile file('release.jks')
            storePassword 'android'
            keyAlias 'apkkey'
            keyPassword 'android'
        }
    }

    buildTypes {
        release {
            minifyEnabled false
            signingConfig signingConfigs.release
        }
    }

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
}

dependencies {
    implementation 'androidx.appcompat:appcompat:1.7.0'
    implementation 'androidx.swiperefreshlayout:swiperefreshlayout:1.1.0'
}
EOF

# ---------- manifest ----------
PERMS=$(jq -r '.permissions // [] | map("    <uses-permission android:name=\"" + (if (. | test("\\.")) then . else "android.permission." + . end) + "\" />") | join("\n")' "$CFG")

cat > "$OUT/app/src/main/AndroidManifest.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-permission android:name="android.permission.INTERNET" />
$PERMS

    <application
        android:allowBackup="true"
        android:icon="@mipmap/ic_launcher"
        android:label="@string/app_name"
        android:usesCleartextTraffic="true"
        android:hardwareAccelerated="true"
        android:theme="@style/AppTheme">
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:screenOrientation="$ORIENT"
            android:configChanges="orientation|screenSize|keyboardHidden|uiMode">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF

# ---------- resources ----------
cat > "$OUT/app/src/main/res/values/strings.xml" <<EOF
<resources>
    <string name="app_name">$(printf '%s' "$APP_NAME" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</string>
</resources>
EOF

cat > "$OUT/app/src/main/res/values/colors.xml" <<EOF
<resources>
    <color name="themeColor">$THEME</color>
</resources>
EOF

cat > "$OUT/app/src/main/res/values/styles.xml" <<'EOF'
<resources>
    <style name="AppTheme" parent="Theme.AppCompat.DayNight.NoActionBar">
        <item name="android:windowBackground">@color/themeColor</item>
        <item name="android:statusBarColor">@color/themeColor</item>
    </style>
</resources>
EOF

cat > "$OUT/app/src/main/res/layout/activity_main.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<androidx.swiperefreshlayout.widget.SwipeRefreshLayout
    xmlns:android="http://schemas.android.com/apk/res/android"
    android:id="@+id/refresh"
    android:layout_width="match_parent"
    android:layout_height="match_parent">

    <WebView
        android:id="@+id/webview"
        android:layout_width="match_parent"
        android:layout_height="match_parent" />
</androidx.swiperefreshlayout.widget.SwipeRefreshLayout>
EOF

# launcher icon (simple adaptive-free mipmap using a vector drawable)
mkdir -p "$OUT/app/src/main/res/mipmap-anydpi-v26" "$OUT/app/src/main/res/drawable"
cat > "$OUT/app/src/main/res/drawable/ic_launcher_fg.xml" <<'EOF'
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <path android:fillColor="#FFFFFF"
        android:pathData="M54,26c-15.5,0 -28,12.5 -28,28s12.5,28 28,28s28,-12.5 28,-28S69.5,26 54,26zM54,34c3.6,0 7.9,6.1 9.5,16h-19C46.1,40.1 50.4,34 54,34zM40.2,38.6c-1.2,3.3 -2.1,7.2 -2.6,11.4h-8.3C31.4,45 35.3,40.9 40.2,38.6zM67.8,38.6c4.9,2.3 8.8,6.4 11,11.4h-8.3C70,45.8 69.1,41.9 67.8,38.6zM29.3,58h8.3c0.5,4.2 1.4,8.1 2.6,11.4C35.3,67.1 31.4,63 29.3,58zM44.5,58h19c-1.6,9.9 -5.9,16 -9.5,16S46.1,67.9 44.5,58zM70.4,58h8.3c-2.1,5 -6,9.1 -11,11.4C69.1,66.1 70,62.2 70.4,58z"/>
</vector>
EOF
cat > "$OUT/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/themeColor"/>
    <foreground android:drawable="@drawable/ic_launcher_fg"/>
</adaptive-icon>
EOF
mkdir -p "$OUT/app/src/main/res/mipmap-mdpi"
cat > "$OUT/app/src/main/res/drawable/ic_launcher_legacy.xml" <<'EOF'
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item android:drawable="@color/themeColor"/>
    <item android:drawable="@drawable/ic_launcher_fg"/>
</layer-list>
EOF
cp "$OUT/app/src/main/res/drawable/ic_launcher_legacy.xml" "$OUT/app/src/main/res/mipmap-mdpi/ic_launcher.xml"

# ---------- MainActivity ----------
cat > "$OUT/app/src/main/java/$PKG_PATH/MainActivity.java" <<EOF
package $PKG;
EOF

cat >> "$OUT/app/src/main/java/$PKG_PATH/MainActivity.java" <<'EOF'

import android.annotation.SuppressLint;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.webkit.GeolocationPermissions;
import android.webkit.PermissionRequest;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.CookieManager;
import android.app.DownloadManager;
import android.content.Context;
import android.webkit.URLUtil;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.swiperefreshlayout.widget.SwipeRefreshLayout;

import java.util.ArrayList;
import java.util.List;

public class MainActivity extends AppCompatActivity {

    private WebView web;
    private SwipeRefreshLayout refresh;
    private ValueCallback<Uri[]> filePathCallback;
    private ActivityResultLauncher<Intent> fileChooser;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        web = findViewById(R.id.webview);
        refresh = findViewById(R.id.refresh);

        fileChooser = registerForActivityResult(
                new ActivityResultContracts.StartActivityForResult(),
                result -> {
                    if (filePathCallback == null) return;
                    Uri[] uris = null;
                    if (result.getResultCode() == RESULT_OK && result.getData() != null) {
                        Intent data = result.getData();
                        if (data.getClipData() != null) {
                            int n = data.getClipData().getItemCount();
                            uris = new Uri[n];
                            for (int i = 0; i < n; i++) uris[i] = data.getClipData().getItemAt(i).getUri();
                        } else if (data.getData() != null) {
                            uris = new Uri[]{data.getData()};
                        }
                    }
                    filePathCallback.onReceiveValue(uris);
                    filePathCallback = null;
                });

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setAllowFileAccess(true);
        s.setAllowContentAccess(true);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        s.setBuiltInZoomControls(false);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setJavaScriptCanOpenWindowsAutomatically(true);
        s.setSupportMultipleWindows(false);
        s.setGeolocationEnabled(true);
        if (Build.VERSION.SDK_INT >= 21) {
            s.setMixedContentMode(WebSettings.MIXED_CONTENT_ALWAYS_ALLOW);
            CookieManager.getInstance().setAcceptThirdPartyCookies(web, true);
        }
        CookieManager.getInstance().setAcceptCookie(true);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                String u = request.getUrl().toString();
                if (u.startsWith("http://") || u.startsWith("https://") || u.startsWith("file://")) {
                    return false;
                }
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(u)));
                } catch (Exception ignored) {
                }
                return true;
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                refresh.setRefreshing(false);
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> cb, FileChooserParams params) {
                filePathCallback = cb;
                try {
                    fileChooser.launch(params.createIntent());
                } catch (Exception e) {
                    filePathCallback = null;
                    return false;
                }
                return true;
            }

            @Override
            public void onPermissionRequest(final PermissionRequest request) {
                runOnUiThread(() -> request.grant(request.getResources()));
            }

            @Override
            public void onGeolocationPermissionsShowPrompt(String origin, GeolocationPermissions.Callback cb) {
                cb.invoke(origin, true, false);
            }
        });

        web.setDownloadListener((url, userAgent, contentDisposition, mimeType, contentLength) -> {
            try {
                DownloadManager.Request req = new DownloadManager.Request(Uri.parse(url));
                req.setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
                req.setDestinationInExternalPublicDir(android.os.Environment.DIRECTORY_DOWNLOADS,
                        URLUtil.guessFileName(url, contentDisposition, mimeType));
                ((DownloadManager) getSystemService(Context.DOWNLOAD_SERVICE)).enqueue(req);
            } catch (Exception ignored) {
            }
        });

        refresh.setOnRefreshListener(() -> web.reload());

        requestDangerousPermissions();

        if (savedInstanceState != null) {
            web.restoreState(savedInstanceState);
        } else {
            web.loadUrl(START_URL);
        }

        getOnBackPressedDispatcher().addCallback(this, new androidx.activity.OnBackPressedCallback(true) {
            @Override
            public void handleOnBackPressed() {
                if (web.canGoBack()) web.goBack();
                else finish();
            }
        });
    }

    private void requestDangerousPermissions() {
        if (Build.VERSION.SDK_INT < 23) return;
        try {
            PackageInfo pi = getPackageManager().getPackageInfo(getPackageName(), PackageManager.GET_PERMISSIONS);
            if (pi.requestedPermissions == null) return;
            List<String> need = new ArrayList<>();
            for (String p : pi.requestedPermissions) {
                try {
                    android.content.pm.PermissionInfo info = getPackageManager().getPermissionInfo(p, 0);
                    int prot = Build.VERSION.SDK_INT >= 28 ? info.getProtection() : (info.protectionLevel & 0xf);
                    if (prot == android.content.pm.PermissionInfo.PROTECTION_DANGEROUS
                            && checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) {
                        need.add(p);
                    }
                } catch (Exception ignored) {
                }
            }
            if (!need.isEmpty()) requestPermissions(need.toArray(new String[0]), 1001);
        } catch (Exception ignored) {
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        web.saveState(outState);
    }
}
EOF

# inject START_URL constant
python3 - "$OUT/app/src/main/java/$PKG_PATH/MainActivity.java" "$START_URL" <<'PY'
import sys
path, url = sys.argv[1], sys.argv[2]
src = open(path).read()
const = '    private static final String START_URL = %s;\n\n' % ('"' + url.replace('\\', '\\\\').replace('"', '\\"') + '"')
src = src.replace('    private WebView web;', const + '    private WebView web;', 1)
open(path, 'w').write(src)
PY

echo "Generated project for $PKG ($MODE) -> $START_URL"
