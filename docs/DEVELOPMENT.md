# 开发说明

## 目录

| 路径 | 用途 |
| --- | --- |
| `src/` | 插件入口模板及 Lua 模块 |
| `config/` | 目标、颜色、发光与估算配置 |
| `compat/build.json` | 版本、兼容指纹、布局校验与来源信息 |
| `assets/` | 构建必需的封面与 592 字节材质模板 |
| `tools/` | 当前构建、预览生成、资源生成与估算检查工具 |
| `docs/` | 本仓库的开发及架构说明 |
| `build/` | 自动生成的 Lua、预览与检查报告，不提交 |
| `release/` | 自动生成的最小安装包，不提交 |
| `research/` | 本机保留的研究与验收资料，不提交 |

本地旧检查脚本、历史说明与封面生成记录也由 `.gitignore` 排除；不删除已有开发资料。公开仓库中的工具可以在没有这些文件和历史 ZIP 的情况下运行。

## 环境

使用 Python 3.10 或更高版本，安装 `python -m pip install -r requirements.txt`。Pillow 固定为整理时本机已有的 12.1.0；生成器以游戏使用的几何模块绘制预览，避免另写一套形状。

构建与离线检查需要 Lua 5.1 动态库，可从 [LuaBinaries 项目](https://luabinaries.sourceforge.net/download.html) 获取相应平台版本，或自行编译 Lua 5.1。游戏安装目录不保证包含该库。通过以下任一方法提供：

```powershell
# 方法一：仅当本机游戏目录存在 bin/lua51.dll 时可用
$env:G60_GAME_DIR = 'C:\path\to\Helldivers 2'

# 方法二：单独的、与 Python 位数一致的 Lua 5.1 库
$env:G60_LUA_LIBRARY = 'C:\path\to\lua51.dll'
```

`G60_LUA_LIBRARY` 优先于 `G60_GAME_DIR`。未设置时依次尝试系统 Lua 5.1、常见 Steam 安装根目录及其 `libraryfolders.vdf`。自定义 Steam 根目录还可通过 `STEAM_DIR` 指定。找不到库会明确报错，不下载或复制游戏 DLL，也不使用 Lua 5.2+ 替代。

## 构建

在仓库根目录执行 `python tools/build.py`。版本来自 `compat/build.json`，输出为 `release/G60-Lock-Line-V<version>.zip`，报告为 `build/build-report.json`。

构建会组合 Lua 模块与配置，生成独立灯光／标记资源、派生白红材质及八张透明预览，嵌入必需的第三方许可，并检查 ZIP 白名单、菜单图像和所有选项组合。安装包固定为 40 个文件；描述为空，没有开发目录、研究记录或调试报告。

模板 `assets/bloom-template.material` 是构建必需的游戏派生材质子项，原始权利仍归原权利人。不要把完整游戏资源、SDK 副本或 DLL 加入仓库。封面沿用已选定的无版本号图片。

## 按修改范围检查

无需为了文档或仓库整理重复运行游戏测试。

- `python tools/check_estimation.py --continuity-only`：估算和控制器的持续显示、动态重选、稳定切换、终点刷新、真实自身锁定与结束清除，加包内 Lua 语法和最小包结构。
- `python tools/check_estimation.py`：以上检查，再检查现有敌军读取防护、预算和外圈渲染模拟；只在修改涉及这些路径时运行。

检查脚本通过 Lua 5.1 执行自写纯模块及模拟数据，不执行实时内存观察器、不连接运行中的游戏，也不部署 mod。若本地存在历史 V1.1.1 ZIP，会额外核对外观资源一致；干净克隆没有历史包时，报告明确记为 `baseline_not_available`，不会假称比较通过。

V1.2.2 游戏内连续重估仍待用户验收。历史版本验收不自动代表后续版本全部通过。

## 版本维护

`compat/build.json` 的完整指纹和布局字节是严格检查，不应为了新版本游戏跳过。当前指纹来自开发时研究的 Steam build 25480438；源码整理不修改这些数值。更新兼容性需要新的可靠依据，不能只更换版本标签。

原始日志、游戏提取数据和用户验收记录继续留在本地 `research/`。Git 提交只使用明确的源码、配置、必要资源和文档；推送前查看暂存列表，避免提交生成物或凭据。
