# 阿噗音乐

iPhone 原生音乐 App。界面为深色原生 SwiftUI，使用阿噗音乐公开 API。

## 生成 Xcode 项目

```sh
brew install xcodegen
xcodegen generate
```

## 本机构建

```sh
xcodebuild -project ApuMusic.xcodeproj -scheme ApuMusic -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions 在每次推送后生成未签名 IPA。
