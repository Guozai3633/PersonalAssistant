# Android APK 打包

Flutter 客户端发布 APK 时可使用以下命令：

```powershell
$env:PUB_CACHE="E:\pub_cache"
cd client
flutter clean
flutter pub get
flutter build apk --release
```

产物位于：

```text
client/build/app/outputs/flutter-apk/app-release.apk
```
