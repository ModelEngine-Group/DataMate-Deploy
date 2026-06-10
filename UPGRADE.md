# DataMate 升级文档

本文档用于指导 DataMate 从ModelEngine eDataMate旧版本升级到当前版本。整体流程采用“先备份、再停旧、后部署、再导入”的方式，避免升级过程中旧版本继续写入数据，降低数据不一致风险。

## 升级前准备

升级前需要确认以下信息：

1. 命名空间、镜像仓库地址、DataMate部署的端口号，存储数据所用存储类的名称。
2. 本地备份目录和可用磁盘空间是否满足数据导出需求。
3. 是否已安排升级窗口，并停止用户写入或后台任务写入。

## 开始升级

```bash
# 进入安装包解压后目录
bash tools/upgrade.sh -n model-engine --repo <镜像仓库地址> --port <自定义端口号> --sc sc-system-manage
```

`upgrade.sh` 通过内置标签识别旧版本资源、迁移 Pod 和新版本 Pod。除升级脚本自身参数外，已支持的安装参数会透传给 `install.sh`。

通过terrabase指定datamate端口号，进入terrabase安装目录执行如下命令：
其中ip为《ModelEngine 25.1.0 安装部署指南》5.4.1步骤1设置的弹性ip地址，端口为上一步中自定义的datamate访问的前端端口号，建议为ModelEngine访问的前端端口号+1，sc为部署ME时使用的存储类
```bash
bash tools/install.sh --install \
  --ns model-engine \
  --repo https://registry.example.com/ \
  --sc sc-system-manage \
  --datamate https://<ip>:<port>
```

## 参数说明

`upgrade.sh` 当前支持以下参数。不在表内的参数会中断脚本并提示不支持。

| 参数 | 是否需要值 | 说明 |
| --- | --- | --- |
| `-n`, `--ns`, `--namespace` | 是 | 指定 Kubernetes 命名空间，默认 `model-engine`。 |
| `--backup-dir` | 是 | 指定本地升级备份根目录，默认 `tools/upgrade-state/<namespace>-backup`。 |
| `--confirm` | 否 | 确认升级完成，调用 `uninstall.sh` 卸载旧版本 `edatamate` 和 `vdb`，并删除备份目录。 |
| `--rollback` | 否 | 回滚升级，调用 `uninstall.sh` 卸载新版本 `datamate`，并将旧版本 Deployment 扩容为 1。 |
| `-h`, `--help` | 否 | 打印帮助信息。 |

升级模式下，以下安装参数会透传给 `install.sh`：

| 参数 | 是否需要值 | 说明 |
| --- | --- | --- |
| `--address-type` | 是 | 指定访问地址类型。 |
| `--sc`, `--storage-class` | 是 | 指定存储类。 |
| `--repo` | 是 | 指定镜像仓库地址。 |
| `--repo-user` | 是 | 指定镜像仓库用户名。 |
| `--operator` | 是 | 指定算子 PVC 容量。 |
| `--path` | 是 | 指定本地存储路径。 |
| `--port` | 是 | 指定服务端口。 |
| `--dataset` | 是 | 指定数据集 PVC 容量。 |
| `--package` | 是 | 指定自定义算子包路径。 |
| `--node-port` | 是 | 指定 NodePort 端口。 |
| `--skip-push` | 否 | 跳过镜像推送。 |
| `--skip-load` | 否 | 跳过镜像加载。 |
| `--skip-milvus` | 否 | 跳过 Milvus 安装。 |
| `--skip-label-studio`, `--skip-ls` | 否 | 跳过 Label Studio 安装。 |

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
bash tools/upgrade.sh -n model-engine --confirm
```

确认完成后，脚本会删除升级备份目录。

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
bash tools/upgrade.sh -n model-engine --rollback
```

回滚会调用 `uninstall.sh` 卸载新版本 `datamate` release，并将旧版本 DataMate Deployment 扩容为 1 个副本。
