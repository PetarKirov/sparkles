### Android system libraries

| Field          | Value                                                |
| -------------- | ---------------------------------------------------- |
| Version source | operating system `Android`                           |
| Licence        | `LicenseRef-Android-System-Library`                  |
| Home           | https://developer.android.com/ndk/guides/stable_apis |
| Ships as       | `-llog` and `-landroid` on Android                   |

Libraries of Android itself, which the NDK's stable APIs name: logcat
(`liblog`) and the native activity, window, input and asset manager
(`libandroid`), which `sparkles:android` calls. Nothing of them is
distributed with sparkles, so there is no licence text to carry.
