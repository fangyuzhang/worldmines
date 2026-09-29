# assets/fonts —— 圆体 UI 字体

2026-09-29 随「CozyStyle 美术风格改造」引入。

## 为什么换字体

改版前工程**没有任何字体文件**，全部中文靠引擎内置兜底字形渲染（实测界面里是
Noto/思源系的黑体，骨架方正、字面内白偏小）。CozyStyle 的观感有一半来自**字形**：
圆体（笔端收圆、字面饱满）＋ 粉彩浅底 ＋ 大圆角，三者是一套语言。只换配色不换字，
界面会"颜色变了但气质没变"——这是网页稿搬到引擎里最常见的翻车点之一。

## 文件

| 文件 | 用途 | 体积 | 授权 |
|---|---|---|---|
| `WenYuanRoundedSCVF.ttf` | **全局 UI 默认字体**（文渊圆体，简体中文可变字体） | 46.5 MB | SIL OFL 1.1（见 `licenses/`） |
| `GenJyuuGothic-Heavy.ttf` | 备用/标题加粗（源柔ゴシック Heavy，含繁体字形） | 11.4 MB | SIL OFL 1.1（见 `licenses/`） |

接入方式：`project.godot` 的 `[gui] theme/custom_font` 指向圆体 → 全工程默认字体，
不需要逐控件设置。棋盘上的线索数字走 `board_view` 的 `get_theme_default_font()`，
因此也一并跟随。

## ⚠️ 体积提醒（发布前要做的事）

两个字体现占 **≈58 MB**，且 Godot 的 TTF 导入**不做子集化**——导出时会原样打包进
pck，直接把安装包撑大一个量级。发布前建议二选一：

1. **子集化**：本作界面用到的汉字是有限集（关卡名 + 固定文案 + 规则术语），
   用 `pyftsubset` 按实际用字裁剪后再入库。做法：
   ```bash
   pip install fonttools brotli
   # 先收集全工程的可见文案，得到 chars.txt（去重汉字）
   pyftsubset WenYuanRoundedSCVF.ttf \
       --text-file=chars.txt --layout-features='*' \
       --output-file=WenYuanRoundedSCVF-subset.ttf
   ```
   注意：**可变字体要先例化**（`fonttools varLib.instancer`），否则子集化后轴信息可能
   与 Godot 的默认实例不一致。
2. **只留一款**：把 `GenJyuuGothic-Heavy.ttf` 移出仓库（它当前只作为备用，
   运行期没有任何引用），可省 11.4 MB。

## 授权与署名

三个文件都是 SIL OFL 1.1，**允许商用与再分发**，条件是：

- 随附许可证原文（已放 `licenses/`）；
- **不得使用保留字体名（RFN）**：文渊圆体的 RFN 来自上游思源字体（`Source`），
  源柔ゴシック的 RFN 同理。也就是说**修改/子集化后不能再叫原字体名**，
  要在包内改名并在 `licenses/` 里保留原始版权声明。上表列的文件名沿用上游原名，
  属于"原样分发"，不触发改名义务；一旦做子集化（上面第 1 条）就必须改名。
