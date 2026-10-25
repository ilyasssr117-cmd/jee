# بناء نسخة iOS (IPA)

ملفات `lib/` جاهزة لـ iPhone. ملف IPA نفسه لا يُبنى إلا على جهاز Mac فيه Xcode
(أو عبر خدمة بناء سحابية مثل GitHub Actions / Codemagic).

## 1) الحزم المطلوبة في pubspec.yaml
```
flutter pub add video_player shared_preferences http html
```

## 2) إنشاء مجلد ios (مرة واحدة، إن لم يكن موجودًا)
```
flutter create --platforms=ios --org com.tvtube .
```
لا يمس هذا الأمر مجلد lib.

## 3) تعديل ios/Runner/Info.plist
أضف داخل `<dict>` الرئيسي:
```xml
<!-- الفيديوهات قد تأتي من روابط http -->
<key>NSAppTransportSecurity</key>
<dict>
  <key>NSAllowsArbitraryLoads</key>
  <true/>
</dict>

<!-- iPhone: طولي + أفقي (المشغل أفقي) -->
<key>UISupportedInterfaceOrientations</key>
<array>
  <string>UIInterfaceOrientationPortrait</string>
  <string>UIInterfaceOrientationLandscapeLeft</string>
  <string>UIInterfaceOrientationLandscapeRight</string>
</array>

<!-- iPad: أفقي فقط -->
<key>UISupportedInterfaceOrientations~ipad</key>
<array>
  <string>UIInterfaceOrientationLandscapeLeft</string>
  <string>UIInterfaceOrientationLandscapeRight</string>
</array>
<key>UIRequiresFullScreen</key>
<true/>
```

## 4) البناء
على Mac، مع حساب Apple Developer:
```
flutter build ipa --release
```
الناتج في `build/ios/ipa/`.

بدون حساب مدفوع (للتثبيت التجريبي عبر Sideloadly أو AltStore):
```
flutter build ios --release --no-codesign
mkdir Payload && cp -r build/ios/iphoneos/Runner.app Payload/
zip -r TVTube.ipa Payload
```

## 5) البناء بدون Mac
انسخ `build_ios_ipa.yml` إلى `.github/workflows/` في مستودع GitHub يحوي المشروع
كاملًا (pubspec.yaml + lib). شغّل الـ workflow من تبويب Actions، ونزّل
`TVTube.ipa` من Artifacts. هذا الـ IPA غير موقّع، فيحتاج Sideloadly أو AltStore.
