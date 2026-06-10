# DataMate 升级文档

本文档用于指导 DataMate 从旧版本升级到新版本。整体流程采用“先备份、再停旧、后部署、再导入”的方式，避免升级过程中旧版本继续写入数据，降低数据不一致风险。

## 升级前准备

升级前需要确认以下信息：

1. 旧版本和新版本的版本号、镜像地址、部署包来源。
2. 本地备份目录和可用磁盘空间是否满足数据导出需求。
3. 是否已安排升级窗口，并停止用户写入或后台任务写入。

## 开始升级

```bash
# 进入安装包解压后目录
bash tools/upgrade.sh -n model-engine --repo <镜像仓库地址> --port 5444 --sc sc-system-manage
```

`upgrade.sh` 通过内置标签识别旧版本资源、迁移 Pod 和新版本 Pod。除升级脚本自身参数外，已支持的安装参数会透传给 `install.sh`。

默认本地备份根目录为 `tools/upgrade-state/<namespace>-backup`。如需指定本地备份根目录，可增加 `--backup-dir <dir>`：

```bash
./upgrade.sh -n model-engine --backup-dir /tmp/datamate-upgrade-backup --repo <镜像仓库地址>
```

## 升级后验证

升级完成后，需要进行功能和数据完整性验证：

1. 前端页面可正常访问。
2. 数据集列表和数据集详情可正常加载。
3. 历史流程可查看，流程文件可访问。
4. 自定义算子可查看、加载和执行。
5. 新建测试任务可正常运行。
6. 后端、Python 后端、运行时、数据库日志无持续异常。
7. 可选组件功能符合预期。

验证通过后，执行确认升级命令清理旧版本 DataMate 资源。该操作会调用 `uninstall.sh` 卸载旧版本 `edatamate` 和 `vdb` release，并删除升级备份目录：

```bash
cd tools
./upgrade.sh -n model-engine --confirm
```

确认完成后，脚本会删除升级备份目录。如果升级时指定了 `--backup-dir`，确认升级时也需要传入同一个目录：

```bash
./upgrade.sh -n model-engine --backup-dir <dir> --confirm
```

## 回滚说明

如果新版本验证失败，应优先停止新版本写入，并根据备份数据回滚。

回滚时需要确认：

1. 旧版本部署包或旧版本镜像仍可用。
2. 旧版本配置仍可恢复。
3. 旧版本数据卷或本地备份仍完整。
4. 新版本运行期间产生的数据是否需要丢弃、合并或单独保留。

如果新版本已经写入过数据，不能直接混用新旧版本数据。应根据升级前导出的备份恢复旧版本环境，避免版本结构差异导致数据异常。

若需要回滚脚本流程，执行：

```bash
cd tools
./upgrade.sh -n model-engine --rollback
```

回滚会调用 `uninstall.sh` 卸载新版本 `datamate` release，并将旧版本 DataMate Deployment 扩容为 1 个副本。
