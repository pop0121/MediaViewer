# MediaViewer 批次4b（2026-10-31）— 第二轮反馈修正

本批覆盖批次4的 C/D 交互模型，按任务书末尾“增补（用户第二轮反馈）”执行。C' 从“硬过滤钻取”改为“落地 + 跟随”；D' 增加地图 pin 的屏幕空间二次合并。无第三方依赖，未修改任何媒体文件。

## C' 落地 + 跟随（不做范围过滤）

### 行为
- 粒度切换不再用时间焦点过滤 `groupedItems`：Months/Days 始终保留完整时间线。
- 新增 `TimeScrollTarget`（groupID + token）。`selectGranularity` 设置目标 section，`GalleryView` 用 `ScrollViewReader.scrollTo(id, anchor: .top)` 立即落地：
  - Years@2022 → Months 落到 2022-xx 月分组；
  - Months@2022-06 → Days 落到 2022-06 的日分组；
  - 精确锚点（日）存在时优先落到该日，否则落到该月第一个可用日。
- `updateTopSection` 只更新 `timeFocus`/面包屑：不调用 `group`，不清空滚动位置，不设置新 target。跟随更新后继续滚动保持惯性。
- 反向后向跟随：
  - Days 顶部 section 跨月 → `timeFocus` 月份变化，面包屑 `All / 2022 / 七月`；
  - Months 顶部跨年 → 年份变化，面包屑 `All / 2023 / 一月`；
  - All 模式不更新焦点。
- 面包屑在 Years/Months/Days 常驻（初始仅显示 `‹ All`），避免滚动中插入新行导致视口高度变化/跳动；月份显示中文“一月…十二月”。
- `All` 清空焦点并回到 All 模式；`‹` 从月退回年，从年回到 All。

### 验收数字（3,007 条合成样本）
| 项目 | 结果 | 口径 |
|---|---|---|
| Years@2022 → Months 目标 | `2022-12`（完整时间线未过滤，组数 >12） | VM，单次切换 |
| 落地目标请求耗时 | **0.044ms** | `selectGranularity` 内设置 target，单次 wall time |
| 跨年跟随（2022-12→2023-01） | 面包屑 `All / 2023 / 一月`，follow 增量 1 | VM，单次 `updateTopSection` |
| 跨月跟随（2022-06→2022-07-03） | 面包屑 `All / 2022 / 七月`，follow 增量 1 | VM，单日 section 跳跃 |
| 跟随期间 regroup | **0**（跨年/跨月均断言） | `regroupCount` 前后差 |
| 单次跟随更新 | **0.006ms** | 跨年调用 wall time |
| 连续跟随平均 | **0.0048ms/call**（500 次） | 同月日 section 循环 |
| ScrollViewReader 定位调用 | **0.040ms** | 66 个月分组/1,980 单元 SwiftUI harness；不含后续布局帧 |

## D' 地图簇屏幕空间合并

### 行为
- 新增 `PlacesClusterer.mergeOnScreen`：
  - 先做原有地理自适应聚类，再把每个簇投影到当前地图视口屏幕坐标（Mercator `MKMapPoint`）。
  - 常量：卡片 `86×74pt`、间距 `6pt`、中心阈值 `92pt`（约一个 pin 宽）。
  - 两 pin 的中心距离小于阈值，或卡片 frame 会相交，即合并；每轮合并后按成员坐标重新求中心，重复至没有重叠对（最多 k 轮，k 为当前簇数）。
  - 合并后的 `PhotoCluster.items` 为成员并集、`count` 为总数；代表照片继续按合并集合拍摄时间取首/中/尾。
- `PlacesMapView.refreshClusters` 在区域变化/聚类刷新时使用 `mapView.bounds` 视口执行二次合并；点击合并簇仍走 `showClusterGrid`，`‹ Map` 返回原区域。
- 合并后的 id 为 `screen-<最小成员id>-<count>`，保证同一次刷新内稳定且唯一。

### 验收数字（密集样本：10 个近邻坐标 × 500 张 = 5,000 张）
| 项目 | 结果 | 口径 |
|---|---|---|
| 二次合并结果 | **1 个簇 / 5,000 张** | 上海周边 0.8° 视口，1000×700pt |
| 代表照片 | 3 张，首/中/尾互异 | 合并后集合，按拍摄时间 |
| 卡片 frame 两两相交数 | **0** | 投影 frame 86×74；MapKit 层级 1 个可见注解 frame 也断言 0 |
| 簇数随 zoom（span 0.8/0.4/0.2/0.1/0.05） | **[1, 1, 1, 10, 10]** | 视口固定 1000×700pt，单调细化 |
| 屏幕合并 p95 | **0.421ms** | 100 次，10 簇/5,000 成员 |
| 聚类+合并 p95 | **13.241ms** | 50 次，5,000 点全区域重算，阈值 <100ms |
| 合并网格条目 | **5,000**，标签 `5000 photos` | `showClusterGrid` 后 `groupedItems` 求和 |
| 返回地图 region | 中心保持 `31.25, 121.50` | `backToMap` 后断言 |
| MapKit 地图首 region 回调 | **173ms** | lib3k_geo 3,000 点，`places_test` 复跑 |

## 回归

- `places_test` 全部通过：地理聚类 p95 1.46ms、上海 1° 500 张、地图首回调 173ms、区域 grid 过滤/清除正常。
- 4b 行为测试全部通过：C' landing/follow/regroup、D' merge/frame/zoom/monotonic/merge budget/merged grid。
- `swift build -c release` 通过；app（`MV_MAP=1`, `MV_DENSITY=1.4`, 3,000 张 geo 样本）5s 冒烟无崩溃。
- 旧批次4的 C 硬过滤测试已被 C' 设计取代，不再作为回归标准。

## 未尽项

1. C' 的跟随是“顶部 section 变化即更新”，未做节流；快速滚动时会更新多个月份，但仍不重建分组。真实滚动的端到端延迟未用 signpost 单独采样；上表为模型与 SwiftUI 调用级数字。
2. 程序化落地使用 `scrollTo` 调用耗时；实际首帧可见时间取决于 LazyVGrid 布局，未用 Instruments 单独量。
3. 屏幕合并基于当前 `mapView.bounds`；窗口 resize 若未触发 region 回调，可能需要下一次区域变化才重新合并。
4. 跨 ±180° 经线的屏幕投影/合并未特殊处理。
5. 合并簇卡片缓存未命中仍会后台生成 320px tier；不读全尺寸原图，但首开地图可能先显示占位色块。
6. C' 在无精确日分组时落到该月第一个可用日（当前分组排序为时间倒序，因此可能是月末），未做“月首”强制。

## macmini 收尾

- 待本批 commit 后同步 `~/Workspaces/media-viewer`，`swift build -c release`，重打
  `~/Applications/MediaViewer.app`（`local.guofu.mediaviewer`、`0.4b-batch4b`、adhoc），并做 5s 冒烟。
