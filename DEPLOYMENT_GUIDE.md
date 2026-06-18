# DataMate 安装部署指南

## 概述

DataMate 是一个基于 Kubernetes 的机器学习平台，支持模型训练、数据标注等功能。本指南将帮助您完成 DataMate 在 Kubernetes 集群上的安装部署。

## 前置条件

- Kubernetes 集群（建议版本 >= 1.20）
- Helm 3.x 已安装
- kubectl 已配置并可访问集群
- 有足够的集群权限（包括创建命名空间、PVC、Service 等权限）
- 镜像仓库访问权限

## 快速安装

### 基础安装

```bash
cd tools
./install.sh --repo <镜像仓库地址> -n model-engine
```

安装过程中会交互式提示输入以下信息：

| 步骤 | 提示 | 说明 |
|------|------|------|
| 镜像仓库密码 | `Enter your registry password:` | 如果未跳过镜像加载/推送 |
| 节点隔离 | `Configure dedicated nodes?` | 可选，按回车跳过 |  
| 数据库密码 | `Enter database password:` | 必填，DB_PASSWORD |
| 证书密码 | `Enter SSL certificate password (enter to skip):` | 可选，按回车跳过 |
| 域名 | `Enter domain (enter to skip):` | 可选，按回车跳过 |
| JWT 密钥 | 自动生成 | 无需手动输入 |
| Label Studio 密码 | `Enter Label Studio admin password (enter to skip):` | 可选，按回车跳过 |
| Label Studio Token | 自动生成 | 无需手动输入 |
| MinIO 密钥 | 自动生成 | 无需手动输入（Milvus 模式） |

> **注意：** `POSTGRE_PASSWORD` 自动使用 `DB_PASSWORD`，无需单独输入。

### 完整安装（包含 Milvus 和 Label Studio）

```bash
./install.sh --repo <镜像仓库地址> -n model-engine
```

### 最小化安装（不包含 Milvus 和 Label Studio）

```bash
./install.sh --repo <镜像仓库地址> -n model-engine --skip-milvus --skip-label-studio
```

## 配套 ModelEngine 安装

当 DataMate 需要配套 ModelEngine 安装时，需使用以下参数：

### 参数

| 参数                            | 说明 | 示例 |
|-------------------------------|------|------|
| `--ns` / `-n` / `--namespace` | Kubernetes 命名空间，需与 ModelEngine 一致 | model-engine |
| `--repo`                      | 镜像仓库地址 | https://registry.example.com/ |
| `--repo-user`                 | 镜像仓库用户名 | admin |
| `--storage-class` / `--sc`    | 存储类名称 | sc-system-manage |
| `--dataset`                   | dataset pvc 容量 | 500Gi |
| `--operator`                  | operator pvc 容量 | 50Gi |
| `--skip-haproxy`              | 跳过 HAProxy 配置（由 ModelEngine 统一管理） | - |

### 安装命令示例

#### ACE场景

```bash
bash ./install.sh \
  --ns model-engine \
  --repo https://registry.example.com/ \
  --repo-user admin \
  --storage-class sc-system-manage \
  --dataset 500Gi \
  --operator 50Gi \
  --port 30000
```

#### ECE场景

```bash
bash ./install.sh \
  --ns model-engine \
  --repo https://registry.example.com/ \
  --repo-user admin \
  --storage-class sc-system-manage \
  --dataset 500Gi \
  --operator 50Gi \
  --skip-haproxy
```

需要额外执行如下步骤：
1. 通过terrabase指定datamate端口号，进入terrabase安装目录执行如下命令：
其中ip为《ModelEngine 25.0.RC1 安装部署指南》5.4.1步骤1设置的弹性ip地址，端口为自定义的datamate访问的前端端口号，建议为ModelEngine访问的前端端口号+1
```bash
bash ./install.sh --install \
  --ns model-engine \
  --repo https://registry.example.com/ \
  --repo-user admin \
  --sc sc-system-manage \
  --datamate https://<ip>:<port>
```
2. 参考《ModelEngine 25.0.RC1 安装部署指南》5.4.1步骤4，创建用于数据使能的弹性负载均衡，其中5.4.1-表elb-service参数说明的参数“容器端口”与“服务端口”分别设置为上一步datamate访问的前端端口号和3000

### 注意事项

- 命名空间必须与 ModelEngine 保持一致
- dataset 和 operator 的 PVC 容量需根据实际业务需求合理设置

## 参数说明

### 必需参数

- `--repo <url>`: 指定镜像仓库 URL
  - 示例：`--repo https://registry.example.com/`

### 可选参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `-n, --ns, --namespace` | Kubernetes 命名空间 | model-engine |
| `--sc, --storage-class` | 存储类名称 | sc-system-manage |
| `--repo-user` | 镜像仓库用户名 | admin |
| `--port` | 服务端口 | 30000 |
| `--address-type` | 地址类型（ip/domain） | management |
| `--node-port` | NodePort 端口 | - |
| `--operator` | operator pvc 容量 | - |
| `--dataset` | dataset pvc 容量 | - |
| `--path` | 本地存储主机路径（local-storage 时使用） | /opt/k8s/<namespace> |
| `--package` | 部署包文件路径 | - |
| `--real-ip-mode` | 真实 IP 转发模式（off / proxy_protocol） | proxy_protocol |

### 功能开关参数

| 参数 | 说明 |
|------|------|
| `--skip-push` | 跳过镜像推送 |
| `--skip-load` | 跳过镜像加载 |
| `--skip-milvus` | 跳过 Milvus 安装 |
| `--skip-label-studio` / `--skip-ls` | 跳过 Label Studio 安装 |
| `--skip-haproxy` | 跳过 HAProxy 配置 |
| `--skip-node-setup` | 跳过节点隔离配置 |
| `--disable-jwt` | 禁用 JWT 用户数据隔离 |
| `-h, --help` | 显示帮助信息 |

## 安装模式

### 1. 使用网络存储

```bash
./install.sh --repo https://registry.example.com/ \
  --sc nfs-storage \
  -n model-engine
```

### 2. 使用本地存储

```bash
./install.sh --repo https://registry.example.com/ \
  --sc local-storage \
  --path /opt/k8s \
  -n model-engine
```

注意：使用本地存储时，脚本会在指定路径下创建以下目录：
- datamate/dataset
- datamate/flow
- datamate/database
- datamate/operator
- datamate/log
- milvus/etcd
- milvus/minio
- milvus/milvus
- milvus/milvus-log
- label-studio/data
- label-studio/dataset

### 3. 使用 NodePort 暴露服务

```bash
./install.sh --repo https://registry.example.com/ \
  --node-port 30080 \
  -n model-engine
```

### 4. 指定 PVC 容量

```bash
./install.sh --repo https://registry.example.com/ \
  --operator 50Gi \
  --dataset 500Gi \
  -n model-engine
```

### 5. 安装到已有环境（不加载镜像）

如果镜像已经存在于集群的镜像仓库中：

```bash
./install.sh --repo https://registry.example.com/ \
  --skip-load \
  --skip-push \
  -n model-engine
```

### 6. 安装自定义算子包

```bash
./install.sh --repo https://registry.example.com/ \
  --package /path/to/operator-package.zip \
  -n model-engine
```

## 组件说明

### DataMate
核心平台，提供模型训练、任务管理等功能。

### Milvus
向量数据库，用于存储和检索向量数据。

### Label Studio
数据标注工具，支持多种标注类型。

## 安装流程

脚本会按以下顺序执行：

1. **配置解析**：读取命令行参数
2. **配置写入**：更新 values.yaml 配置文件（命名空间、镜像仓库、存储类等）
3. **存储配置**：创建必要的本地存储目录并设置权限（如使用 local-storage）
4. **镜像处理**：加载并推送镜像到镜像仓库
5. **节点隔离**：交互式配置节点标签和污点（可选，`--skip-node-setup` 跳过）
6. **Sealed Secrets 控制器**：安装 sealed-secrets controller
7. **密钥生成**：交互式收集密钥并生成 SealedSecret 资源
8. **Helm 安装**：依次部署 DataMate、Milvus、Label Studio
9. **路由配置**：配置 HAProxy 路由规则（如未跳过）
10. **等待就绪**：等待所有 Pod 进入 Ready 状态（最长 300 秒）
11. **算子安装**：加载自定义算子包（如指定）

## 访问服务

### 默认访问方式

安装完成后，可通过以下方式访问：

- DataMate 前端：`http://<节点IP>:30000`
- Label Studio：`http://<节点IP>:30001`

### 使用 NodePort

如果指定了 `--node-port`：

- DataMate 前端：`http://<节点IP>:<node-port>`
- Label Studio：`http://<节点IP>:<node-port+1>`

### 查看服务状态

```bash
# 查看 Pod 状态
kubectl get pods -n model-engine

# 查看 Service
kubectl get svc -n model-engine

# 查看 PVC
kubectl get pvc -n model-engine
```

## 故障排查

### 镜像加载失败

检查镜像仓库地址和密码是否正确，网络是否可达。

### Sealed Secrets 安装失败

使用私有 registry 时可能出现 `allowInsecureImages` 错误，已被安装脚本自动处理。如仍有问题，检查 sealed-secrets chart 包是否存在于 `helm/sealed-secrets/` 目录。

### Pod 无法启动

```bash
kubectl describe pod <pod-name> -n model-engine
kubectl logs <pod-name> -n model-engine
```

### PVC 无法绑定

检查存储类是否配置正确，集群是否有足够的存储资源。

### Label Studio 挂载失败

使用 local-storage 时，确保宿主机目录已创建且有正确权限。如遇 `/label-studio/data/media` permission denied，请确认安装时 `mkdir -p` 和 `chmod` 已正确执行。

### HAProxy 配置失败

确保 HAProxy 组件正常运行，且有相应权限。

## 升级与卸载

### 升级

```bash
./install.sh --repo https://registry.example.com/ -n model-engine
```

### 卸载

```bash
# 卸载 Helm releases
helm uninstall label-studio -n model-engine --ignore-not-found
helm uninstall milvus -n model-engine --ignore-not-found
helm uninstall datamate -n model-engine --ignore-not-found

# 清理 local-storage PV（如有残留）
kubectl delete pv label-studio-data-pv label-studio-dataset-pv --ignore-not-found

# 删除命名空间
kubectl delete ns model-engine --ignore-not-found
```

## 注意事项

1. 使用本地存储（local-storage）时，请确保节点有足够的磁盘空间
2. Label Studio 使用三方镜像，local-storage 模式下脚本会自动创建目录并设置 777 权限
3. 如果目录已存在且包含数据，脚本会提示确认是否删除
4. 镜像仓库密码不会被存储，仅用于本次安装
5. 安装过程会等待最多 300 秒让所有 Pod 就绪
6. 重装前建议先清理旧的 PV/PVC（尤其是 label-studio），避免路径冲突
7. 建议在测试环境先验证配置后再在生产环境部署

## 帮助与支持

查看完整参数说明：

```bash
./install.sh --help
```
