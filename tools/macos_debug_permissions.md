# macOS 调试版屏幕录制授权

屏幕录制授权与代码签名关联。临时签名（ad-hoc）可能在重新构建后变化；删除旧安装包也不一定清除系统记录。开发时优先使用稳定的 Apple Development 证书。

## 本机签名

```sh
tools/configure_macos_debug_signing.sh
flutter run -d macos
```

脚本查找本机唯一的有效 Apple Development 证书，并写入被 Git 忽略的 `macos/Runner/Configs/Signing.local.xcconfig`。有多个证书时，将 `security find-identity -v -p codesigning` 输出中的目标证书 SHA-1 作为脚本参数。证书与私钥通过 macOS 钥匙串管理。

配置只作用于 Debug；没有本机配置时仍使用临时签名。发布签名和打包方式不变。删除该本机配置文件即可恢复默认。

## 列表没有应用或旧授权无效

1. 从菜单栏完全退出「定格」，停止旧的 `flutter run`；关闭截图窗口不会退出后台进程。
2. 在终端只重置本应用的屏幕录制授权：

   ```sh
   tccutil reset ScreenCapture com.example.screenClipWin
   ```

3. 重新运行应用，主动截图，在系统弹窗中允许访问。
4. 系统设置 → 隐私与安全性 → 屏幕与系统音频录制，开启当前应用，并按系统提示完全退出后重新打开。

列表仍没有应用时，可通过系统设置的添加按钮，或从 Finder 将当前运行的 `.app` 拖入列表。应用错误提示提供当前运行位置；调试版通常位于 `build/macos/Build/Products/Debug/定格.app`。

不要重置所有应用的授权，也不要直接修改 TCC 数据库。
