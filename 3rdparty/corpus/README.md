# 彝文语料（Yi corpus）

从 `/data/trit/pyBitNet` 复制，用于 `Ii`（彝文/Nuosu）界面支持之外的语料参考。

| 文件 | 内容 | 来源 | 许可 |
|---|---|---|---|
| `yiwen/yiwen_nayin_tokens.json` | 彝文 → 纳音 token 序列（`step`/`polar`/`toroidal`/`wuxing`/`clutch`/`nayin`/`op`/`script`/`id`，`id` 为彝文音节） | `/data/trit/pyBitNet/data/象形古文/yiwen_nayin_tokens.json` | MIT（见 `yiwen/LICENSE-pyBitNet.txt`） |
| `yiwen/yiwen_sovereign_mapping.json` | 彝文 ↔ 卦象 / token 映射 | `/data/trit/pyBitNet/data/象形古文/yiwen_sovereign_mapping.json` | MIT |

## 与字体的关系

TUI 的 `Ii` 语言只需要**字形**（`../fonts/NotoSansYi-Regular.ttf`，U+A000–U+A48F）；
这里的 JSON 是**语料**，用于未来的彝文分词/词元映射，不参与渲染。

## 未复制的内容

`/data/trit/pyBitNet/datasets/图片/彝文数据集`（按码位 `A000`… 分目录的图片数据集）体积大，
未纳入仓库；需要时从原路径读取。
