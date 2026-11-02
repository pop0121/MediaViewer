# MediaViewer 兼容 macOS Photos `.photoslibrary` 可行性调研（只读）

日期：2026-11-02  
范围：只读调研；未修改 MediaViewer 源码、未写入/移动任何媒体文件。本文是唯一新增文件。

## 结论

1. **不能把 `.photoslibrary` 当作普通文件夹直接兼容。** 普通目录扫描会进入 `originals/`，看到的是 UUID 文件名和无相册/无人脸/无编辑结果的原始文件；HEIC/TIFF 等还可能被现有扩展名过滤掉。
2. **直接读 `Photos.sqlite` + `originals` 技术上可行，但只适合“高级/本地只读”模式。** 它依赖未公开的 Core Data schema、Full Disk Access（FDA）和 Photos 的 TCC 服务；schema 随 macOS/Photos 版本变化，iCloud 未下载、编辑版本、相册/人物/回忆都不能只靠文件目录还原。
3. **当前 MediaViewer 的沙盒权限不足。** 现有 entitlements 只有 App Sandbox + `user-selected.read-only` + network；没有 Photos Library entitlement，也没有 `NSPhotoLibraryUsageDescription`。即使用户用 NSOpenPanel 选中图库，TCC/Photos 权限仍需单独解决。
4. **目标图库本机当前无法完成真实读取：** `~/Pictures/Photos Library.photoslibrary` 是指向外部卷的符号链接，目标卷 `/Volumes/Kingston XS2000 Media` 未挂载，外部磁盘列表为空。因此下文的真实结构来自本机可读的 `Syndication.photoslibrary`（同机 Photos 9.0 / macOS 14.7.1 的库格式样本），不是用户主图库；主图库的 TCC 拒绝/成功、真实 schema 版本和规模仍需挂载后复测。
5. **建议：** 若产品要正式浏览 Photos 图库，优先 **PhotoKit（Photos framework）**；若只是内部/高级用户，做一个 **FDA + 只读 SQLite 快照** 的可选数据源；若只需偶尔导入，走 **Photos 导出到普通文件夹** 的桥接方案。不要把直接读库作为默认路径，不要用私有 API。

## 1. 调研环境与目标路径

| 项 | 实测值 |
|---|---|
| macOS | 14.7.1（23H222），x86_64 |
| Photos.app | 9.0 |
| 用户图库路径 | `~/Pictures/Photos Library.photoslibrary` |
| 路径类型 | 符号链接 |
| 链接目标 | `/Volumes/Kingston XS2000 Media/照片 图库.photoslibrary` |
| 目标卷状态 | 未挂载；`/Volumes` 无该卷；`diskutil list external` 为空 |
| 本机可读的 Photos 库样本 | `~/Library/Photos/Libraries/Syndication.photoslibrary` |
| 样本数据库 | `.../database/Photos.sqlite`，约 16.5 MB |
| 样本 WAL | `Photos.sqlite-wal`，约 3.5 MB；另有 `-shm`、`.lock` |

`stat -L`、`ls -L` 对用户图库路径返回 `ENOENT`；这是**目标卷不存在**，不是已确认的 TCC 拒绝。`~/Library/Photos` 下的 `Syndication` 可正常读取，说明本机当前 shell 对 `~/Library/Photos` 的样本路径有访问能力。

Photos 偏好中还能看到该图库的 bookmark/path；`photolibraryd` 的 bookmarks 也包含该路径。外部磁盘当前没有出现在 `diskutil`/USB 设备列表中。

## 2. 实测到的真实结构（样本库）

### 2.1 包目录

样本 `Syndication.photoslibrary` 顶层：

```text
database/
  Photos.sqlite
  Photos.sqlite-wal
  Photos.sqlite-shm
  Photos.sqlite.lock
  DataModelVersion.plist
  metaSchema.db
  photos.db
  search/
originals/                 # 普通库通常在这里；样本为空
resources/
  derivatives/
    masters/
    thumbs/
  caches/
private/
external/
scopes/
  syndication/
  cloudsharing/
  momentshared/
```

普通用户库通常使用顶层 `originals/<bucket>/<UUID>.<ext>`；`Syndication` 是系统“共享/同步”库，实际原图在 `scopes/syndication/originals/<bucket>/...`，所以顶层 `originals/` 为空。本文不把它误称为用户主库结构，只把它作为同版本 Photos 数据库/包布局的样本。

### 2.2 数据库规模与版本

| 指标 | 样本值 |
|---|---:|
| `DataModelVersion.plist` | `LibrarySchemaVersion=5001`，`MetaSchemaVersion=3` |
| `sqlite_master` 表数量 | 80 |
| 索引数量 | 430 |
| Core Data `Z_PRIMARYKEY` 实体数 | 65 |
| `ZASSET` 行数 | 61 |
| `ZINTERNALRESOURCE` 行数 | 122 |
| `ZADDITIONALASSETATTRIBUTES` 行数 | 61 |
| `ZGENERICALBUM` 行数 | 252 |
| `ZASSET` 中视频 | 0（样本全是照片） |
| 实际 `scopes/.../originals` 文件 | 57 |
| `originals` 扩展名 | 28 jpeg、27 png、1 svg、1 tiff |

`Photos.sqlite` 是 Core Data 生成的私有 schema，不是 Apple 公开的数据库 API。`Z_METADATA` 保存模型版本/哈希；`DataModelVersion.plist` 只给出库 schema 版本。样本是 Photos 9.0 的 `5001`，但不同 macOS/Photos 版本会迁移。

### 2.3 关键表与字段

| 表 | 用途 | 实测关键字段 |
|---|---|---|
| `ZASSET` | 一条资产：照片/视频 | `Z_PK`、`ZUUID`、`ZKIND`、`ZDIRECTORY`、`ZFILENAME`、`ZDATECREATED`、`ZADDEDDATE`、`ZLATITUDE`、`ZLONGITUDE`、`ZTRASHEDSTATE`、`ZHIDDEN`、`ZFAVORITE`、`ZHASADJUSTMENTS`、`ZCLOUDLOCALSTATE`、`ZVIDEODURATION...` |
| `ZADDITIONALASSETATTRIBUTES` | 原始文件名、EXIF/导入信息 | `ZASSET`、`ZORIGINALFILENAME`、`ZEXIFTIMESTAMPSTRING`、`ZORIGINALFILESIZE`、`ZIMPORTEDBYBUNDLEIDENTIFIER` |
| `ZINTERNALRESOURCE` | 原图/衍生资源、本地可用性 | `ZASSET`、`ZRESOURCETYPE`、`ZUTICONFORMANCEHINT`、`ZDATALENGTH`、`ZLOCALAVAILABILITY`、`ZFILESYSTEMBOOKMARK`、`ZFILESYSTEMVOLUME` |
| `ZFILESYSTEMBOOKMARK` | 外部/引用库路径 | `ZPATHRELATIVETOVOLUME`、`ZBOOKMARKDATA` |
| `ZFILESYSTEMVOLUME` | 外部卷标识 | `ZNAME`、`ZVOLUMEUUIDSTRING` |
| `ZGENERICALBUM` / `Z_28ALBUMLISTS` | 用户/智能相册及关系 | 需多表 join |
| `ZCLOUDRESOURCE` / `ZCLOUDMASTER` | iCloud 资源状态 | `ZFILEPATH`、`ZISLOCALLYAVAILABLE`、`ZASSETUUID` |

实测 `ZASSET` 的 `ZDIRECTORY` 取值是 `0`–`9`、`A`–`F` 的 16 个桶，`ZFILENAME` 是 `UUID.ext`；实际文件路径为：

```text
originals/<ZASSET.ZDIRECTORY>/<ZASSET.ZFILENAME>
```

样本中可用 join 找到 `scopes/syndication/originals/9/96C49A41-....png` 等文件；`ZADDITIONALASSETATTRIBUTES.ZORIGINALFILENAME` 是 `IMG_...` / 中文截屏名，不能当物理文件名使用。也就是说，直接扫描目录得到的 `UUID.ext` 不是用户可见文件名。

`ZASSET` 有 119 列，`ZINTERNALRESOURCE` 有 38 列；样本 80 张表/430 个索引。这不是一个稳定的小接口，而是一整套 Core Data 关系模型。

### 2.4 资源/原图关系

- 样本 61 个资产对应 122 个 `ZINTERNALRESOURCE` 行（每个资产 2 条资源记录），其中 113 条标记本地可用；0 条通过 `ZFILESYSTEMBOOKMARK` 引用。
- 57 个实际原图文件 vs 61 个资产，说明**不能假设每个 `ZASSET` 都有可直接打开的本地原图**；iCloud 未下载、资源在别处、共享库/同步库都会导致缺失。
- 原图不是全部在顶层 `originals`：`Syndication` 在 `scopes/syndication/originals`；普通库才通常在顶层 `originals`。代码不能只拼一个固定路径。
- 视频/实况照片、编辑版本、缩略图还涉及 `ZINTERNALRESOURCE`、`ZCLOUDRESOURCE`、`resources/derivatives`，不能只看 `ZASSET.ZFILENAME`。

### 2.5 SQLite 只读实测

对样本数据库执行：

```bash
sqlite3 -readonly Photos.sqlite 'pragma integrity_check;'
sqlite3 -readonly Photos.sqlite 'select count(*) from ZASSET;'
```

结果：

- `integrity_check = ok`
- `ZASSET = 61`
- `journal_mode = wal`
- 查询过程未写 `Photos.sqlite`；但库正在被 Photos/`photolibraryd` 使用，存在 `-wal`、`-shm`、`.lock`。

**只拷贝 `Photos.sqlite` 不够**：最新数据可能在 `Photos.sqlite-wal`。正确做法是只读复制 `Photos.sqlite` + `-wal` + `-shm` 到临时目录，或在 PhotoKit 允许的情况下用官方 API 导出；不要对活动库做 `immutable=1` 后声称是最新状态。最稳妥是让 Photos 停止写入或用 SQLite backup API 生成一致性快照，然后只读打开快照。

## 3. TCC / Full Disk Access / 沙盒实测与判断

### 3.1 当前 shell 的权限

- 当前进程为 `omp`，父进程是 fish，最终由 iTerm2 提供终端会话。
- 系统 TCC 数据库 `/Library/Application Support/com.apple.TCC/TCC.db` 中 `com.googlecode.iterm2` 有 `kTCCServiceSystemPolicyAllFiles = 2`（允许）。
- 用户 TCC 数据库中 `kTCCServicePhotos` 只看到 Keynote、Picsee 等条目，没有 MediaViewer。
- 当前 shell 能读取 `~/Library/Messages/chat.db`、`~/Library/Safari/History.db` 和样本 Photos 库，符合“继承 iTerm2 的 Full Disk Access”的表现。
- **但这不能说明 MediaViewer 有权限**：TCC 归属看 responsible process，不随子进程继承到另一个 app bundle。

### 3.2 目标库的 TCC 实测状态

对 `~/Pictures/Photos Library.photoslibrary`：

```text
stat -L → No such file or directory
test -r → not-readable
```

原因是符号链接目标卷未挂载，**尚未到达 TCC 判定**。因此不能把这次结果写成“TCC 拒绝”；正确说法是：**目标库当前不可用，TCC 结果待挂载后复测**。

样本 `Syndication.photoslibrary` 在 `~/Library/Photos` 下可读；它不等价于 `~/Pictures` 下受 Photos 隐私保护的普通图库，不能作为 TCC 放行的证据。

### 3.3 MediaViewer 当前签名/entitlements

`Resources/MediaViewer.entitlements`：

```text
com.apple.security.app-sandbox = 1
com.apple.security.files.user-selected.read-only = 1
com.apple.security.network.client = 1
```

`Resources/Info.plist` 没有 `NSPhotoLibraryUsageDescription`。源码中也没有 Photos framework 依赖。

因此：

- 用户选择 `.photoslibrary` 后，App Sandbox 只给该 security-scoped URL 的文件访问；**TCC 是独立的一层**。
- 直接 SQLite/原图读取需要用户给 MediaViewer 授 **Full Disk Access**（或相应 Photos 授权）；当前 app 没有，也不能由代码自行获得。
- 如果走 PhotoKit，至少需要 `NSPhotoLibraryUsageDescription` + Photos 授权；沙盒下还需要 Photos Library entitlement：

```text
com.apple.security.personal-information.photos-library
```

Apple 文档把它定义为“read-write access to the user’s Photos library”。MediaViewer 现在没有这个 entitlement。
- 本机是 ad-hoc/本地构建路径；FDA 可在系统设置里手动添加，但每次重签名/更新可能改变 TCC 身份，需重新授权。App Store 沙盒分发与“直接读库”天然冲突，审核风险高。

### 3.4 结论性权限判断

| 访问方式 | 当前 MediaViewer | 需要什么 |
|---|---|---|
| 普通文件夹 `originals/` | 用户选择后可读 | 仅文件权限；但内容不完整、UUID 命名 |
| 直接读 `Photos.sqlite` | **不可行** | Full Disk Access（或等效 Photos 授权）；且不能由 app 自动申请 FDA |
| PhotoKit `PHPhotoLibrary` | **未配置** | `NSPhotoLibraryUsageDescription`、Photos 授权、沙盒 Photos entitlement |
| Photos 导出目录 | 可读 | 用户先导出；不需要读库 TCC |

> TCC 对普通 `~/Pictures/Photos Library.photoslibrary` 的直接文件读取通常需要 FDA；Apple 的 PhotoKit 是官方支持路径。实际主库的 TCC 结果要在外部卷挂载后用 MediaViewer 本体复测。

## 4. 直接读库的可行性、风险

### 4.1 可行性

- **能做**：只读查询 `ZASSET`，用 `ZDIRECTORY + ZFILENAME` 拼原图路径，用 `ZADDITIONALASSETATTRIBUTES` 取原始文件名/EXIF 时间；样本已验证可以读出资产数和物理路径。
- **必要条件**：FDA（当前 shell 的 iTerm2 有；MediaViewer 没有）、目标卷在线、本地原图可用、schema 版本匹配。
- **不适合直接当默认功能**：MediaViewer 的现有 `MediaScanner` 面向普通文件系统，直接指向图库只能得到 `originals` 的 UUID 文件，无法还原相册、编辑、iCloud 状态。

### 4.2 风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| 私有 schema 漂移 | Core Data 表/列随 macOS/Photos 升级；样本已是 80 表、119 列 `ZASSET` | schema/`DataModelVersion` 白名单；启动探测失败就禁用，不做写回 |
| TCC/FDA | 普通图库受保护；沙盒 app 无 Photos/FDA；FDA 是手动系统设置 | 明确 onboarding；PhotoKit 优先；本地高级模式单独分发 |
| WAL/活动库一致性 | `Photos.sqlite-wal` 有最新事务；`.lock` 表示活动库；拷贝单文件会丢数据 | 快照 `sqlite + wal + shm` 或 SQLite backup；只读打开；完整性检查 |
| iCloud 未下载 | 资产在 DB 中但原图不在本地；`ZCLOUDLOCALSTATE`/`ZCLOUDRESOURCE` 可表明 | PhotoKit 按需下载；直接读库则跳过并标注“iCloud” |
| 编辑/实况/视频 | `ZHASADJUSTMENTS`、多资源、衍生缩略图；只看原图会显示未编辑版本 | 用 `ZINTERNALRESOURCE`/derivatives；或导出官方渲染版本 |
| 相册/人物/回忆 | 大量关系表，不是 `ZASSET` 一行能表达 | 单独查询/映射，工作量高；或 PhotoKit |
| 文件名/格式 | 物理名是 UUID；HEIC/TIFF/PNG 等扩展名需额外支持 | 用 `ZORIGINALFILENAME` 显示；扩展 ImageIO 支持 |
| 沙盒/分发 | 用户选择 URL 不等于 FDA；直接库路径在 App Store 不可取 | 本地版本/helper 单独授权；或导出方案 |
| 隐私/安全 | 原始库包含位置、人物、隐藏/删除资产 | 只读、最小字段、过滤 `ZTRASHEDSTATE/HIDDEN`、不日志化路径 |

## 5. 备选方案对比

| 方案 | 数据来源 | 权限 | iCloud/编辑 | schema 风险 | 工作量（粗估） | 适合 |
|---|---|---|---|---|---|---|
| **A. 直接 SQLite + originals** | `Photos.sqlite` + 文件 | FDA（或等效）；沙盒需额外处理 | 原图本地可用才行；编辑/云资源需额外逻辑 | **高**，随系统升级维护 | PoC 0.5–1 天；可用 MVP 2–3 周；生产 4–6 周+ | 内部/高级只读，愿意授 FDA |
| **B. PhotoKit（官方）** | `PHPhotoLibrary` / `PHAsset` | `NSPhotoLibraryUsageDescription` + Photos 授权 + `personal-information.photos-library` | 官方处理 iCloud、编辑、相册、人物 | 低（公开 API） | 2–3 周 | 正式产品默认方案；但只访问系统图库 |
| **C. Photos 导出/导入桥接** | 用户导出的普通文件夹，或用 `osxphotos export --sidecar` | 由 Photos/导出工具处理；MediaViewer 只读目录 | 导出时决定；不是实时 | 低 | 手工 2–5 天；自动化 1–2 周 | 偶尔导入、备份/归档、低风险 |
| **D. 第三方 `osxphotos` 作为后端** | 直接 DB（同 A） | 同 A，FDA | 支持部分云/元数据 | 中高（项目自行适配） | 1–2 周接入+维护 | 研究/导出，不想自己维护 schema |
| **E. Photos 私有 API** | 私有框架/服务 | 不可控 | 不可控 | **极高**，版本/签名/审核风险 | 不建议 | 拒绝 |

### 关于 PhotoKit 的边界

- macOS 14 SDK 的 `PHPhotoLibrary` 公开入口是 `sharedPhotoLibrary`，访问**系统照片图库**；它不是“任意 `.photoslibrary` URL 打开器”。
- 当前用户图库是外部卷上的库，PhotoKit 能否访问取决于它是否是系统照片图库；如果不是，PhotoKit 不能直接替代“选择任意图库”。
- `PHImageManager` 可请求缩略图/全尺寸，`PHAssetResourceManager` 可请求原图资源；这能正确处理 iCloud 和编辑版本，避免 schema 猜测。
- 但需要把 MediaViewer 的数据模型从“路径扫描”改成“asset identifier + 请求图像”，工作量大于只读 SQLite 的 PoC。

### 关于导出桥接

- 最小实现：用户在 Photos 中选择“导出未修改的原片”到一个普通目录，MediaViewer 作为普通文件夹扫描；无需 FDA、无 schema 风险。
- 代价：不是实时；重复导出/增量识别需要自己处理；相册结构、编辑版本、iCloud 仍取决于导出选项。
- `osxphotos export` 可作为自动化导出器，但它本身也是直接读库，仍需要 FDA（不是绕过 TCC）。

## 6. 工作量估算（按现有 MediaViewer）

| 阶段 | 内容 | 估算 |
|---|---|---:|
| 0. 挂载后复测 | 确认目标卷、真实库版本、TCC、资产数、原图本地率 | 0.5–1 天 |
| 1. 只读 PoC | `ZASSET` + `ZADDITIONALASSETATTRIBUTES` + `originals` 路径；schema 探测 | 1–2 天 |
| 2. 最小可用 | 新 `PhotosLibrarySource`、资产模型映射、日期/GPS、原图/缩略图、错误/云缺失标记 | 2–3 周 |
| 3. 产品化 | schema 版本门禁、相册/人物/编辑/视频、iCloud 处理、TCC onboarding、快照、测试 | 4–6 周 + 每版维护 |
| B. PhotoKit 路径 | 授权、`PHAsset` 分页、缩略图/全图请求、现有网格适配 | 2–3 周 |
| C. 导出桥接 | 目录扫描/增量/导出说明 | 2–5 天（手工）；1–2 周（自动化） |

以上是工程量级，不含设计评审和真实大库性能调优。

## 7. 建议

1. **不要把直接 SQLite 作为 MediaViewer 默认的 Photos 兼容方案。** 它需要 FDA、私有 schema 和大量边界处理，和当前沙盒定位冲突。
2. **如果 Photos 是正式功能：先做 PhotoKit PoC。** 确认目标库是否为系统图库；若是，使用 `PHAsset`/`PHImageManager`/`PHAssetResourceManager`，保持只读授权，避免直接读库。
3. **如果只是“把图库里的原片导入 MediaViewer”：做导出桥接。** 让用户导出到普通目录，MediaViewer 用现有扫描器；风险最低。
4. **如果必须直接读库：** 做成独立的“Photos Library（只读/高级）”数据源：
   - 仅支持已挂载的本地库；
   - 启动时读 `DataModelVersion.plist`/`Z_METADATA`，版本不匹配直接禁用；
   - 只读快照 `sqlite + wal + shm`，不写库；
   - 过滤 `ZTRASHEDSTATE`/`ZHIDDEN`，标注 iCloud 未下载、编辑版本、缺失资源；
   - 明确要求用户给 app 授 FDA，不能假装是普通文件夹权限；
   - 不写回、不删除、不移动媒体文件。
5. **不要使用 Photos 私有 API。** 版本/签名/审核风险高于收益。

## 8. 待完成/待复测

- [ ] 挂载 `/Volumes/Kingston XS2000 Media`，确认 `~/Pictures/Photos Library.photoslibrary` 目标存在。
- [ ] 用 MediaViewer 本体（而非当前继承 iTerm2 FDA 的 shell）读取该库，记录 TCC 是拒绝还是成功。
- [ ] 读取目标库 `DataModelVersion.plist`，记录真实 `LibrarySchemaVersion`、资产数、视频数、本地原图率。
- [ ] 若目标库不是系统照片图库，验证 PhotoKit 是否只能访问系统库，决定是否只能走导出或直接读库。
- [ ] 在目标库上验证 `ZASSET` 的 `ZDIRECTORY/ZFILENAME` 与实际 `originals` 文件一致，及 iCloud 未下载比例。

## 参考

- Apple：Photos Library Entitlement（`com.apple.security.personal-information.photos-library`）  
  https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.photos-library
- Apple：`NSPhotoLibraryUsageDescription`  
  https://developer.apple.com/documentation/bundleresources/information-property-list/nsphotolibraryusagedescription
- Apple：PhotoKit / `PHPhotoLibrary`、`PHImageManager`、`PHAssetResourceManager`
- osxphotos（直接读库的成熟第三方实现，需 FDA）  
  https://github.com/RhetTbull/osxphotos
- Duplicati 社区：macOS Photos Library 访问拒绝与 FDA 实测  
  https://forum.duplicati.com/t/macos-access-denied-to-backup-fotos-library-photoslibrary/20745
- apple-photos-mcp：FDA 对直接读 `Photos.sqlite` 的必要性  
  https://github.com/sweetrb/apple-photos-mcp/blob/main/docs/FULL-DISK-ACCESS.md
