# Photoframe

Photoframe 是一个原生 macOS 照片加黑边工具。拖入照片或文件夹，在预览窗口实时查看效果，再导出单张或整批照片。

## 功能

- 拖放照片或文件夹，自动查找文件夹中的图片；也可点击“导入照片”选择文件。
- 在照片列表中切换预览，使用滑条或输入百分比调整四边等宽的黑边。
- 黑边宽度按照片短边计算，范围为 `0–30%`；设置会在下次打开时恢复。
- 可选纯白色画布，默认正方形 `1:1`；可选择常用横竖画幅或原图比例。滑条设置黑边照片与画布边缘的最小留白（按原照片短边的 `0–50%` 计算），照片始终居中。
- 开启画布后，“小红书优化”默认开启：导出 JPEG，最长边不超过 3500 像素，文件大小不超过 10 MB；关闭后按原格式和分辨率导出。
- 默认输出到导入来源同级的 `Photoframe_output` 文件夹，也可手动选择其他文件夹。
- 导出文件名添加 `_framed` 后缀；同名文件自动添加序号，避免覆盖。

## 下载与使用

在 [Releases](../../releases) 下载 `Photoframe-v1.1.0-macos-arm64.zip`，解压后打开 `Photoframe.app`。需要 Apple Silicon Mac 和 macOS 13 或更新版本。

此版本使用本地临时签名，未经过 Apple 公证。若 macOS 首次打开时提示无法验证，请在 Finder 中右键点击 `Photoframe.app` 并选择“打开”。

## 支持格式

| 导入 | 导出 |
| --- | --- |
| JPEG | JPEG |
| PNG | PNG |
| TIFF | TIFF |
| HEIC、HEIF、WebP、BMP、GIF | PNG |

未启用小红书优化时，导出会按原图像素尺寸生成带黑边和可选白色画布的新图片。启用优化时，输出统一为 JPEG。GIF 按静态图片处理，不保留动画。

## 从源码构建

需要 macOS 13 或更新版本、Apple Silicon Mac 和 Xcode Command Line Tools。项目使用 AppKit，无第三方依赖。

```sh
zsh build.sh
open build/Photoframe.app
```

`main.swift` 是应用源码，`Icon.swift` 生成极简线条图标，`build.sh` 构建并签名应用包。
