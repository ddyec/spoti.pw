# 流行歌曲歌词检索抽样 — 2026-09-30

## 结论

规则可以继续作为检索基础。六个地区各随机抽取 4 首，共 24 首不同歌曲；
23 首在至少一个平台通过歌名、歌手及时长筛选，并实际取回歌词响应。
此数字衡量接口候选覆盖情况，不能视为真机歌词匹配正确率。
网易云 20/24、QQ 16/24、酷狗 16/24 取回歌词。

本次发现并修正了尾部 `(feat. …)` 导致的标题差异，并在版本排除中增加了
摇滚、爵士等改编标记。参与歌手标注可以省略，录音版本标记仍保留。
《WAIT FOR U (feat. Drake & Tems)》和《So Good (feat. Kendrick Lamar)》现可取回网易云歌词。

《Tu connais》未取得合适来源：网易云返回了一个符合元数据的候选，但未返回
可用原文；其他同名、时长相近的候选歌手不同，需要原文证据，不能直接选用。
未将这些候选计为命中。

## 方法与限制

- 从 Apple Music 官方 most-played 榜采样，参考种子 20260930；保存标题、艺人、地区、排名及 ID。
- 榜单请求失败时保留错误，并尝试该地区 top-10；不会把请求失败计成平台没有歌词。
- 使用 Apple 曲目元数据作国际发行输入，并通过 lookup 获取时长；未获取手机实际 Spotify 元数据。
- 使用 Windows Python 重放元数据规则，直接提取生产代码里的正则表达式；不是原生 Objective-C 执行。
- Foundation 的假名转写没有用猜测映射替代；跨文字歌手候选保留为待验证。
- 无 Spotify 原文的候选不执行“不同署名但原文相同”的最终接受步骤。
- 网易云读取 LRC/YRC，QQ 读取 LRC，酷狗下载并解码 KRC；未只凭搜索结果声称歌词可用。
- 同步漂移、不同分句、翻译完整度与最终页面来源仍需下一次真机验收。
- 输出仅包含元数据和响应长度，不保存完整歌词、凭证或歌词访问密钥。

## 结果

| 地区 | 曲目 | 艺人 | 秒 | 网易云 | QQ | 酷狗 |
|---|---|---|---:|---|---|---|
| kr | 0+0 | 한로로 | 192 | 已取回歌词 | 已取回歌词 | 已取回歌词 |
| kr | hate that i made you love me | Ariana Grande | 197 | 已取回歌词 | 已取回歌词 | 已取回歌词 |
| kr | Runaway | 리센느 | 182 | 待原文验证 | 已取回歌词 | 未命中 |
| kr | The Chase | Hearts2Hearts | 178 | 待原文验证 | 已取回歌词 | 已取回歌词 |
| gb | Boston | STELLA LEFTY | 170 | 已取回歌词 | 已取回歌词 | 已取回歌词 |
| gb | Training Season | Dua Lipa | 209 | 已取回歌词 | 已取回歌词 | 已取回歌词 |
| gb | Dai Dai | Shakira & Burna Boy | 223 | 已取回歌词 | 已取回歌词 | 未命中 |
| gb | iloveitiloveitiloveit | Bella Kay | 183 | 已取回歌词 | 待原文验证 | 已取回歌词 |
| us | I'm The Problem | Morgan Wallen | 177 | 已取回歌词 | 已取回歌词 | 已取回歌词 |
| us | WAIT FOR U (feat. Drake & Tems) | Future | 189 | 已取回歌词 | 待原文验证 | 未命中 |
| us | Frozen | Lil Baby | 179 | 已取回歌词 | 未命中 | 已取回歌词 |
| us | So Good (feat. Kendrick Lamar) | Jhené Aiko | 237 | 已取回歌词 | 未命中 | 未命中 |
| jp | 共犯 | Mrs. GREEN APPLE | 231 | 待原文验证 | 已取回歌词 | 已取回歌词 |
| jp | マイオンリー | SixTONES | 226 | 已取回歌词 | 已取回歌词 | 已取回歌词 |
| jp | You!Joy!Parade! | M!LK | 181 | 已取回歌词 | 已取回歌词 | 已取回歌词 |
| jp | ダーリン | Mrs. GREEN APPLE | 280 | 已取回歌词 | 已取回歌词 | 已取回歌词 |
| cn | 爱情转移 | 陈奕迅 | 259 | 已取回歌词 | 已取回歌词 | 已取回歌词 |
| cn | 我不难过 | 孙燕姿 | 320 | 已取回歌词 | 已取回歌词 | 已取回歌词 |
| cn | 情歌 | 梁静茹 | 260 | 已取回歌词 | 已取回歌词 | 已取回歌词 |
| cn | 可惜没如果 | 林俊杰 | 298 | 已取回歌词 | 已取回歌词 | 已取回歌词 |
| fr | Tu connais | Werenoi | 169 | 待原文验证 | 待原文验证 | 未命中 |
| fr | Pocahontas | PLK | 168 | 已取回歌词 | 未命中 | 未命中 |
| fr | Argent Sale - A COLORS SHOW | La Rvfleuze | 164 | 已取回歌词 | 未命中 | 未命中 |
| fr | melodrama | disiz & Theodora | 176 | 已取回歌词 | 待原文验证 | 未命中 |

详细响应摘要与榜单链接见 [JSON](lyrics-catalogue-audit-2026-09-30.json)。
执行脚本：`scripts/probe-lyrics-catalogue.py`；`--replay` 重跑已采样的曲目。

## 罗马音接口实测

《夏霞》：网易云同次歌词响应含 `romalrc`（1456 字符）；QQ 的 `roma` 为十六进制加密 QRC。
用 MSVC 编译仓库的 `QQMusicQRC.c`，真实解密并解压 QQ 原文与罗马音：两者均有 32 个 QRC 行头。
31 对行的首字时间差在 800ms 内；另 1 对超过容差，将跳过而不借用邻行。
实际请求到的两份酷狗 KRC 没有 language 数据，此时显示原文，不生成猜测读音。

本轮已通过 Python 语法、生产代码抽取、规则静态检查和实际 C 解码器验证。
新增加的 Foundation 发音对齐/解析回归用例已写入现有原生测试脚本，尚未在 macOS 执行。
