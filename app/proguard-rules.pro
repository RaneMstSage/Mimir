# JNI: libmimir.so binds these by name (RegisterNatives / CallStaticVoidMethod)
-keep class com.mstsage.mimir.Native { *; }
-keep class com.mstsage.mimir.RubyRuntime { *; }
# Loaded reflectively by Support.create()
-keep class com.mstsage.mimir.BillingSupport { *; }
# WebView JavaScript bridge
-keepclassmembers class * { @android.webkit.JavascriptInterface <methods>; }
-keepattributes JavascriptInterface
# Loaded reflectively by MainActivity
-keep class com.mstsage.mimir.WebViewTuning { *; }
