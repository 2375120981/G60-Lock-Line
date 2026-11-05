# G60 锁定线 · MDL 1.0.2

[下载管理器安装包](release/G60-Lock-Line-MDL-v1.0.2.zip)。导入管理器，启用并部署，重启游戏后在 MDL 中启用“G60 锁定线”。旧版独立补丁与本版请勿同时启用。

依赖 [MDL3](https://ayakamods.com/mods/mdl3-preview-%E9%BA%A6%E5%BD%93%E5%8A%B33-%E9%A2%84%E8%A7%88%E7%89%88%EF%BC%81.5710/)，建议同时启用 HD2 Data Hub。两者作者为 M!ni$try0fSc!eиce，安装包不包含依赖组件。开发环境使用 MDL 3.0.0-dev.36、Native 0.4.5、Lua 5.1；字段解码限定于 `stingray:46805 437a3d445f9df7662b60086ac8ae3c65b5c95da6`。

显示视角周围 80 米内 G60 的定位圈、锁定线和目标标记。优先使用网络目标，队友目标不可读时可使用估算，估算准星附加圆环。模型匹配后使用包围盒中心，匹配不可用时使用网络位置。MDL 设置项支持点击循环选择白／红／蓝／黄及方框十字／十字／飞矛准星，默认白色＋方框十字。没有屏幕调试文字。

1.0.2 为完整目标快照为空或布局不匹配时增加公开 `position` 字段读取回退，允许模型缓存未预热时连线，并记录目标等待原因供排查。保留无 G60 时暂停场景及模型查询的优化，恢复轻量敌人事件记录用于估算。

1.0.0 的显示与设置已获用户游戏内验收；1.0.1 后用户反馈自身投掷仅有定位圈。1.0.2 已通过离线回归和打包验证，**尚待游戏内投掷验证，根因未在游戏内确认**。[验证记录](verification/1.0.2.json) 中的调用量改善来自模拟环境，不代表实际帧率。

## 构建与测试

从仓库根目录执行（Python 3.10+）：

```powershell
python -m pip install -r mdl/requirements.txt
python mdl/tools/build_release.py
python mdl/tests/check_discovery_center.py
python mdl/tests/check_squad_estimation.py
python mdl/tests/check_visual.py
python mdl/tests/check_target_fallback.py
python mdl/tests/check_performance.py
```

构建器自动校验 Lua 5.1 语法、资源路径、补丁回读与打包生命周期。性能测试使用 `tests/fixtures/spatial_center_1_0_0.lua` 作为旧算法基线，无需游戏日志。模块沿用开发期 `probe_` 文件名；只加载 17 个生产模块，不包含旧测试 HUD。

源码沿用原项目的投影、标记、估算及外观参数；MDL 生命周期与读取适配独立实现。循环设置参考 BFV Hit And Kill Feedback V2.2.0 的 ModOptionsMenu 接口用法，不包含该模组组件。原项目第三方来源见 [THIRD-PARTY-NOTICES](../THIRD-PARTY-NOTICES.md)。
