# kotlinx.serialization keeps generated serializers through its own rules. Keep the SDK's
# serializable models so apps that minify still decode the config and responses.
-keep,includedescriptorclasses class com.tododdle.support.**$$serializer { *; }
-keepclassmembers class com.tododdle.support.** {
    *** Companion;
}
-keepclasseswithmembers class com.tododdle.support.** {
    kotlinx.serialization.KSerializer serializer(...);
}
