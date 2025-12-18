#!/bin/bash

current_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${current_dir}/common.sh"
. "${current_dir}/log.sh"

# ================= 配置区域 =================
# 目标路径
UPLOAD_DIR="/operators/upload"
EXTRACT_DIR="/operators/extract"
PACKAGE_DIR="/usr/local/lib/ops/site-packages"

# 1. 输入参数检查
NAMESPACE="$1"
INPUT_PATH="$2"

if [ -z "$INPUT_PATH" ]; then
    log_error "请提供输入路径！"
    echo "Usage: $0 <path_to_zip_or_dir>"
    exit 1
fi

if [ ! -e "$INPUT_PATH" ]; then
    log_error "输入路径不存在: $INPUT_PATH"
    exit 1
fi

# 创建临时工作目录
WORK_DIR="$current_dir/operators"

# 退出时自动清理
cleanup() {
    log_info "清理临时文件..."
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# 2. 处理输入源（解压或复制到工作区）
SOURCE_DIR="$WORK_DIR/source"
mkdir -p "$SOURCE_DIR"

if [ -d "$INPUT_PATH" ]; then
    log_info "输入为目录，复制文件..."
    SOURCE_DIR=$INPUT_PATH
elif [[ "$INPUT_PATH" == *.zip ]]; then
    log_info "输入为zip包，解压中..."
    unzip -q "$INPUT_PATH" -d "$SOURCE_DIR"
elif [[ "$INPUT_PATH" == *.tar ]]; then
    log_info "输入为tar包，解压中..."
    tar -xf "$INPUT_PATH" -C "$SOURCE_DIR"
elif [[ "$INPUT_PATH" == *.tar.gz ]] || [[ "$INPUT_PATH" == *.tgz ]]; then
    log_info "输入为tgz包，解压中..."
    tar -xzf "$INPUT_PATH" -C "$SOURCE_DIR"
else
    log_error "不支持的文件格式，仅支持 Directory, .zip, .tar.gz"
    exit 1
fi

BACKEND_POD_NAME=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=datamate-backend -o jsonpath='{.items[*].metadata.name}')
HEAD_POD_NAME=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=kuberay,ray.io/node-type=head -o jsonpath='{.items[*].metadata.name}')

# 3. 遍历并处理子压缩包
# 查找目录下所有的 zip 或 tar.gz
while read -r pkg; do
    PKG_NAME=$(basename "$pkg")
    PKG_BASE="${PKG_NAME%.*}" # 去掉后缀的文件名

    # 针对 .tar.gz 的特殊处理
    if [[ "$PKG_NAME" == *.tar.gz ]]; then
        PKG_BASE="${PKG_NAME%.tar.gz}"
    fi

    log_info "正在处理子包: $PKG_NAME"

    # 创建该包的专属解压目录
    PKG_EXTRACT_DIR="$WORK_DIR/extracted/$PKG_BASE"
    mkdir -p "$PKG_EXTRACT_DIR"

    # 解压子包
    if [[ "$pkg" == *.zip ]]; then
        unzip -q "$pkg" -d "$PKG_EXTRACT_DIR"
    else
        tar -xf "$pkg" -C "$PKG_EXTRACT_DIR"
    fi

    # 检查关键文件是否存在
    if [ ! -f "$PKG_EXTRACT_DIR/metadata.yml" ] || [ ! -f "$PKG_EXTRACT_DIR/__init__.py" ] || [ ! -f "$PKG_EXTRACT_DIR/process.py" ]; then
        log_warn "包 $PKG_NAME 缺少必要文件(metadata.yml/__init__.py/process.py)，跳过。"
        continue
    fi

    # A. 移动文件到业务容器
    # 假设每个包在目标目录下应该有一个独立的文件夹
    REMOTE_PATH="$EXTRACT_DIR/$PKG_BASE"

    log_info "  -> 部署文件到容器 $BACKEND_POD_NAME:$REMOTE_PATH"

#    kubectl cp "$SOURCE_DIR/$PKG_NAME" "$BACKEND_POD_NAME:$UPLOAD_DIR/" -n "$NAMESPACE"
    kubectl cp "$PKG_EXTRACT_DIR" "$BACKEND_POD_NAME:$REMOTE_PATH/" -n "$NAMESPACE"

    if [ -f "$PKG_EXTRACT_DIR/wheels" ]; then
      kubectl exec "$HEAD_POD_NAME" -n "$NAMESPACE" -- bash -c "uv pip install --target $PACKAGE_DIR /opt/runtime/datamate/ops/user/$PKG_BASE/wheels/*.whl"
    fi
done < <(find "$SOURCE_DIR" -maxdepth 1 -type f \( -name "*.zip" -o -name "*.tar" \))


FULL_SQL=$(kubectl exec -i "$HEAD_POD_NAME" -n "$NAMESPACE" -- python3 - << EOF
from pathlib import Path
import sys, yaml

operator_sql='INSERT IGNORE INTO t_operator
(id, name, description, version, inputs, outputs, runtime, settings, file_name, is_star)
VALUES '
category_sql='INSERT IGNORE INTO t_operator_category_relation(category_id, operator_id) VALUES '
modal_map = {
    'text': 'd8a5df7a-52a9-42c2-83c4-01062e60f597',
    'image': 'de36b61c-9e8a-4422-8c31-d30585c7100f',
    'audio': '42dd9392-73e4-458c-81ff-41751ada47b5',
    'video': 'a233d584-73c8-4188-ad5d-8f7c8dda9c27',
    'multimodal': '4d7dbd77-0a92-44f3-9056-2cd62d4a71e4'
}
language_map = {
    'python': '9eda9d5d-072b-499b-916c-797a0a8750e1',
    'java': 'b5bfc548-8ef6-417c-b8a6-a4197c078249'
}

base_path = Path('/opt/runtime/datamate/ops/user')
for metadata_file in base_path.rglob('metadata.yml'):
    try:
        with open(metadata_file, 'r') as f:
            data = yaml.safe_load(f)
            id = data.get('raw_id')
            name = data.get('name')
            desc = data.get('description')
            version = data.get('version')
            modal = data.get('modal').lower()
            language = data.get('language').lower()
            inputs = data.get('inputs')
            outputs = data.get('outputs')
            file_name = Path(metadata_file).parent.name

            operator_sql += "('{}', '{}', '{}', '{}', '{}', '{}', '{}', '{}', '{}', 'false'),".format(id, name, desc, version, inputs, outputs, runtime, settings, file_name)
            category_sql += "('{}', '{}'),".format(id, modal_map.get(modal, 'd8a5df7a-52a9-42c2-83c4-01062e60f597'))
            category_sql += "('{}', '{}'),".format(id, language_map.get(language, '9eda9d5d-072b-499b-916c-797a0a8750e1'))
    except Exception as e:
        print(f'ERROR: {e}', file=sys.stderr)
        sys.exit(1)
    print(operator_sql[:-1] + ';\n' + category_sql[:-1] + ';')
EOF
)

DATABASE_POD_NAME=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=datamate-database -o jsonpath='{.items[*].metadata.name}')
kubectl exec -i "$DATABASE_POD_NAME" -n "$NAMESPACE" -- mysql -uroot -p"\$MYSQL_ROOT_PASSWORD" "datamate" -e "$FULL_SQL" 2>/dev/null

log_info "所有任务执行完毕。"