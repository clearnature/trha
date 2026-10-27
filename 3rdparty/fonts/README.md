# Bundled fonts

Terminal fonts for scripts the TUI can display (藏文 / 彝文) but most terminals
do not ship.  Brick/vty never loads these files itself — the terminal must be
configured to use them, otherwise those strings render as tofu (□□□).

| File | Script | Codepoints | Source | License |
|---|---|---|---|---|
| `NotoSansYi-Regular.ttf` | Nuosu Yi（彝文） | U+A000–U+A48F | **Google Noto**，v2.003（`foundry=GOOG`；取自本地 OpenHarmony SDK 预览器字库，331 KB，fontversion 131203） | SIL OFL 1.1（见 `LICENSE-noto.txt`） |
| `NotoSerifTibetan-Regular.ttf` | Tibetan（藏文） | U+0F00–U+0FFF | **Google Noto**（`fonts-noto-core`） | SIL OFL 1.1 |
| `NotoSerifTibetan-Bold.ttf` | Tibetan bold | U+0F00–U+0FFF | `fonts-noto-core` (Debian) | SIL OFL 1.1 |
| `LICENSE-noto.txt` | — | — | `/usr/share/doc/fonts-noto-core/copyright` | SIL OFL 1.1 |

彝文字体即 Google 开源的 **Noto Sans Yi**（`fc-scan` 显示 `family=Noto Sans Yi`, `foundry=GOOG`）；
Google Fonts 上该字体目前只有 Regular 一个字重，所以仓库里也只有这一个。

仓库里这一份是本地已有的**较新版本**（v2.003，331 KB，fontversion 131203），
取自：

```
/data/training/cli/commandline-tools-linux-x64-26.0.0.821/command-line-tools/
  sdk/default/openharmony/previewer/common/bin/fonts/NotoSansYi-Regular.ttf
```

Debian `fonts-noto-core` 打包的是 v2.000（182 KB，fontversion 131072，md5 `c5c97d13…`）；
两者同为 OFL 1.1，v2.003 新增了更多语言覆盖。若要回退：

```bash
cp /usr/share/fonts/truetype/noto/NotoSansYi-Regular.ttf 3rdparty/fonts/
```

## Install

```bash
mkdir -p ~/.local/share/fonts
cp 3rdparty/fonts/*.ttf ~/.local/share/fonts/
fc-cache -f
# then select a terminal font that falls back to Noto Sans Yi / Noto Serif Tibetan
```

## Why these files are here

The interface carries `Bo`（藏语）and `Ii`（彝文）language skeletons, so the
strings exist; the glyphs are the terminal's job.  Keeping the fonts next to the
source makes the dependency explicit and reproducible.

## Note on `pyBitNet`

`/data/trit/pyBitNet` ships **Shu-script** (水书) and **seal-script** fonts —
`BabelStoneShuishu*.ttf`, `quanzikushuowenjiezi.ttf`, and
`font-i8beo9m0.ttf` (HakusyuSyoutenNenga) — none of which cover Nuosu Yi.
Its `README.md` only lists 彝文 as a corpus source (纳音 tokenisation), not a
font.  The Yi font bundled here is Noto's `NotoSansYi-Regular.ttf`.

## 命令行（终端）下的中文渲染

`trha` 输出的是 UTF-8 字节；能不能显示中文取决于**终端**，不是程序本身。
三种场景：

| 场景 | 做法 |
|---|---|
| 终端模拟器（GNOME Terminal / Konsole / xterm / tmux） | `source 3rdparty/fonts/activate.sh`，终端字体选 `Noto Sans CJK SC`（或 `monospace`，由 fontconfig 解析到本项目字体） |
| SSH / 远程 | 字体在**本地**客户端生效：把 `3rdparty/fonts/*.ttc|ttf` 装到本地 `~/.local/share/fonts` 后 `fc-cache -f` |
| Linux 文本控制台（Ctrl+Alt+F1，无 X/Wayland） | TTY 只认 PSF 位图字体（`setfont`），TTF 不适用；需加载 CJK PSF（如 `zh_CN.psf.gz`），否则只能改用终端模拟器 |

`trha serve` 是 HTTP/JSON 服务：响应头始终 `charset=utf-8`，服务端不负责字形渲染；
日志里的中文方块属于上表第 1/3 行的问题。

### 验证

```bash
source 3rdparty/fonts/activate.sh          # 打印 FONTCONFIG_FILE 与命中字体
fc-match :lang=zh                          # NotoSansCJK-Regular.ttc
fc-match "Noto Sans CJK SC"                # 项目自带的 SC 面
```

## Linux 文本控制台（TTY）显示方块

TTY 只使用 **PSF 位图字体**（`setfont`），无法加载 TTF。Ubuntu 默认
`FONTFACE="Fixed"`（8x16）不含 CJK 字形，所以纯命令行下中文是方块。
两条解决路径（脚本 `tty-cjk.sh` 会检测本机并打印完整命令）：

**项目自带 `trha-cjk-16.psf`（21 391 字形，727 KB），用户无需安装任何软件**
（`setfont` 随 Ubuntu 的 `console-setup` 预装）。

| 方案 | 做法 | 效果 |
|---|---|---|
| **fbterm**（已装时推荐） | `source activate.sh`；`fbterm -f "Noto Sans CJK SC"` | 真实 TTF 渲染 |
| **自带 PSF**（零安装回退） | `sudo setfont 3rdparty/fonts/trha-cjk-16.psf -m 512` | 16 px 位图，**23 167 字形**：ASCII + SC 中文 + 藏文 + 彝文 + 缅甸文 + 泰文 |
| SSH / 终端模拟器 | 字体在**客户端** | 最省事 |

> `otf2bdf` + `bdf2psf` 无法转换 CJK 比例字体（实测 `the width is not integer number`），
> 所以 `trha-cjk-16.psf` 由 `make-psf.py`（Pillow）从 TTC 直接光栅化。

持久化（可选）：

```bash
gzip -c trha-cjk-16.psf | sudo tee /usr/share/consolefonts/trha-cjk-16.psf.gz >/dev/null
# /etc/default/console-setup: FONT="trha-cjk-16.psf.gz"
sudo setupcon
```

重新生成（开发机，需要 Pillow）：`python3 3rdparty/fonts/make-psf.py`

```bash
bash 3rdparty/fonts/tty-cjk.sh   # 检测 + 打印上述命令
```
