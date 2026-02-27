#!/bin/bash

current_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
. "${current_dir}/common.sh"
. "${current_dir}/log.sh"

# ================= 配置区域 =================
# 目标路径
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
    log_info "输入为目录，跳过解压..."
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
        unzip -oq "$pkg" -d "$PKG_EXTRACT_DIR"
    elif [[ "$pkg" == *.tar ]]; then
        tar -xf "$pkg" -C "$PKG_EXTRACT_DIR"
    else
      continue
    fi

    # 检查关键文件是否存在
    if [ ! -f "$PKG_EXTRACT_DIR/metadata.yml" ] || [ ! -f "$PKG_EXTRACT_DIR/__init__.py" ] || [ ! -f "$PKG_EXTRACT_DIR/process.py" ]; then
        log_warn "包 $PKG_NAME 缺少必要文件(metadata.yml/__init__.py/process.py)，跳过。"
        continue
    fi

    # A. 移动文件到业务容器
    # 假设每个包在目标目录下应该有一个独立的文件夹
    REMOTE_PATH="$EXTRACT_DIR/$PKG_BASE"

    log_info "拷贝目录${PKG_BASE}到容器..."

#    kubectl cp "$SOURCE_DIR/$PKG_NAME" "$BACKEND_POD_NAME:$UPLOAD_DIR/$PKG_BASE/" -n "$NAMESPACE"
    kubectl exec "$BACKEND_POD_NAME" -n "$NAMESPACE" -- sh -c "rm -rf $REMOTE_PATH/ && mkdir -p $REMOTE_PATH"
    kubectl cp "$PKG_EXTRACT_DIR/." "$BACKEND_POD_NAME:$REMOTE_PATH/" -n "$NAMESPACE"

    if [ -d "$PKG_EXTRACT_DIR/wheels" ]; then
      log_info "安装算子依赖..."
      kubectl exec "$HEAD_POD_NAME" -n "$NAMESPACE" -- bash -c "uv pip install --target $PACKAGE_DIR /opt/runtime/datamate/ops/user/$PKG_BASE/wheels/*.whl"
    fi
done < <(find "$SOURCE_DIR" -maxdepth 1 -type f \( -name "*.zip" -o -name "*.tar" \))

read -r -d '' PY_SCRIPT << 'EOF'
from pathlib import Path
import json, sys, yaml, base64

operator_sql = 'INSERT INTO t_operator (id, name, description, version, inputs, outputs, runtime, settings, file_name, is_star, metrics, file_size) VALUES '
category_sql = 'INSERT INTO t_operator_category_relation(category_id, operator_id) VALUES '
release_sql = 'INSERT INTO t_operator_release (id, version, release_date, changelog) VALUES '

# Modal类型映射 (与前端分类ID对应)
modal_map = {
    'text': 'd8a5df7a-52a9-42c2-83c4-01062e60f597',
    'image': 'de36b61c-9e8a-4422-8c31-d30585c7100f',
    'audio': '42dd9392-73e4-458c-81ff-41751ada47b5',
    'video': 'a233d584-73c8-4188-ad5d-8f7c8dda9c27',
    'multimodal': '4d7dbd77-0a92-44f3-9056-2cd62d4a71e4'
}

function_map = {
    'cleaning': '8c09476a-a922-418f-a908-733f8a0de521',
    'annotation': 'cfa9d8e2-5b5f-4f1e-9f12-1234567890ab'
}

# 系统预置分类ID
PREDEFINED_ID = 'ec2cdd17-8b93-4a81-88c4-ac9e98d10757'
VENDOR_CATEGORY_ID = 'f00eaa3e-96c1-4de4-96cd-9848ef5429ec'
PYTHON_CATEGORY_ID = '9eda9d5d-072b-499b-916c-797a0a8750e1'

base_path = Path('/opt/runtime/datamate/ops/user')
for metadata_file in base_path.rglob('metadata.yml'):
    try:
        with open(metadata_file, 'r') as f:
            data = yaml.safe_load(f)
            id = data.get('raw_id', '').strip("'\"")
            name = data.get('name', '').strip("'\"")
            desc = data.get('description', '').strip("'\"")
            version = data.get('version', '').strip("'\"")
            modal = data.get('modal', '').lower().strip("'\"")
            language = data.get('language', '').lower().strip("'\"")
            inputs = data.get('inputs', '').strip("'\"")
            outputs = data.get('outputs', '').strip("'\"")

            runtime = f"'{json.dumps(data.get('runtime'), ensure_ascii=False)}'" if 'runtime' in data else 'null'
            settings = f"'{json.dumps(data.get('settings'), ensure_ascii=False)}'" if 'settings' in data else 'null'
            metrics = f"'{json.dumps(data.get('metrics', []), ensure_ascii=False)}'" if 'metrics' in data else 'null'

            # 计算文件大小
            root_dir = Path(metadata_file).parent
            file_size = sum(f.stat().st_size for f in root_dir.rglob('*') if f.is_file())

            file_name = root_dir.name

            # 构建operator插入SQL
            operator_sql += "('{}', '{}', '{}', '{}', '{}', '{}', {}, {}, '{}', 'false', {}, {}),".format(
                id, name, desc, version, inputs, outputs, runtime, settings, file_name, metrics, file_size
            )

            # 功能类型分类（支持多个types）
            types = data.get('types', [])
            has_type = False
            if isinstance(types, list):
                for func_type in types:
                    func_category_id = function_map.get(func_type)
                    if func_category_id:
                        has_type = True
                        category_sql += f"('{func_category_id}', '{id}'),"
            if not has_type:
                category_sql += f"('{function_map.get('cleaning')}', '{id}'),"

            # 系统预置分类
            category_sql += f"('{PREDEFINED_ID}', '{id}'),"
            category_sql += f"('{VENDOR_CATEGORY_ID}', '{id}'),"
            category_sql += f"('{PYTHON_CATEGORY_ID}', '{id}'),"
            category_sql += f"('{modal_map.get(modal, modal_map.get('text'))}', '{id}'),"

            # Release信息
            releases = data.get('release', [])
            if isinstance(releases, list) and releases:
                release_sql += f"('{id}', '{version}', NOW(), '{json.dumps(releases, ensure_ascii=False)}'),"

    except Exception as e:
        print(f'ERROR: {e}', file=sys.stderr)
        sys.exit(1)

# 输出SQL
full_sql = ''
if operator_sql != 'INSERT INTO t_operator (id, name, description, version, inputs, outputs, runtime, settings, file_name, is_star, metrics, file_size) VALUES ':
    full_sql += operator_sql[:-1] + ' ON CONFLICT DO NOTHING;\n'

if category_sql != 'INSERT INTO t_operator_category_relation(category_id, operator_id) VALUES ':
    full_sql += category_sql[:-1] + ' ON CONFLICT DO NOTHING;\n'

if release_sql != 'INSERT INTO t_operator_release (id, version, release_date, changelog) VALUES ':
    full_sql += release_sql[:-1] + ' ON CONFLICT DO NOTHING;\n'

print(full_sql)
EOF

B64_CODE=$(python3 -c "import base64, sys; print(base64.b64encode(sys.stdin.read().encode('utf-8')).decode('utf-8'))" <<< "$PY_SCRIPT")
FULL_SQL=$(kubectl exec -i "$HEAD_POD_NAME" -n "$NAMESPACE" -c ray-head -- /bin/sh -c "echo '$B64_CODE' | base64 -d | python3 -")

log_info "插入数据库..."
DATABASE_POD_NAME=$(kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=datamate-database -o jsonpath='{.items[*].metadata.name}')
kubectl exec -i "$DATABASE_POD_NAME" -n "$NAMESPACE" -c database -- sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d datamate' << EOF
$FULL_SQL
EOF

log_info "所有任务执行完毕。"
