#!/bin/bash
# =============================================================================
# DataMate 数据迁移脚本 - 阶段一：旧版本数据库导出（A环境）
# =============================================================================
# 功能：从旧版本PostgreSQL导出数据到CSV，生成UUID映射关系
# 执行环境：有psql命令的环境（A环境）
# 输出：/dataset/runtime/ 目录下的CSV文件
# =============================================================================

set -e

# ======================== 配置部分 ========================

# 数据库连接配置（请根据实际环境修改）
DB_HOST="backend-db"
DB_PORT="5432"
DB_NAME="backend"
DB_USER="postgres"
export PGPASSWORD="$(source /kmc/kmc-adapter/kmc_encrypt_decrypt_tool.sh && kmc_decrypt $POSTGRES_PASSWORD modelenginepublic)"

# 导出目录
EXPORT_DIR="/dataset/runtime"

# ======================== 函数定义 ========================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 生成UUID
gen_uuid() {
    uuidgen | tr '[:upper:]' '[:lower:]'
}

# 清理键值（去除引号和空白）
clean_key() {
    echo "$1" | tr -d '"' | tr -d "'" | tr -d ' ' | tr -d '\t' | tr -d '\r'
}

# 执行SQL查询并导出CSV
export_csv() {
    local sql="$1"
    local output="$2"
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -c "COPY ($sql) TO STDOUT WITH CSV HEADER" > "$output"
}

# ======================== 主流程 ========================

log "开始数据迁移导出..."

# 创建导出目录
mkdir -p "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR/files"

# 清理旧数据
rm -f "$EXPORT_DIR/*.csv"

log "步骤1：导出 dataset_version → datasets.csv"
log "规则：每个 dataset_version 创建一个新 dataset，名称 = {dataset.name}_v{version}"

# 导出 datasets 映射
# 生成新UUID，映射旧版本到新数据集
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" << 'EOF' > "$EXPORT_DIR/datasets_uuid.tmp"
COPY (
SELECT
    dv.id as old_version_id,
    dv.dataset as old_dataset_id,
    dv.version as old_version_number,
    ds.name as old_dataset_name,
    dv.type as old_type,
    dv.remark as description,
    dv.created_on as created_at,
    dv.updated_on as updated_at,
    dv.user_id as created_by,
    dv.source_type,
    dv.data_location,
    dv.status
FROM dataset_version dv
LEFT JOIN dataset ds ON dv.dataset = ds.id
WHERE dv.is_deleted = false AND ds.is_deleted = false
) TO STDOUT WITH CSV HEADER
EOF

# 为每个 dataset_version 生成新UUID并写入最终CSV
echo "new_uuid,name,description,dataset_type,category,path,format,size_bytes,file_count,record_count,status,is_public,is_featured,created_at,updated_at,created_by,updated_by,old_dataset_id,old_version_id" > "$EXPORT_DIR/datasets.csv"

# dataset_type 映射：旧版本type ID → 新版本类型字符串
# 旧版本：1=QUERY_QUESTION_SET, 2=PLAIN_TEXT_WITH_NO_LABELS, 3=IMAGE, 5=AUDIO, 6=OTHER, 7=SINGLE_CHOICE, 8=GSM8K, 9=PATHOLOGICAL_IMAGES
# 新版本：IMAGE/TEXT/QA/MULTIMODAL/OTHER

declare -A TYPE_MAP
TYPE_MAP[1]="TEXT"
TYPE_MAP[2]="TEXT"
TYPE_MAP[3]="IMAGE"
TYPE_MAP[5]="OTHER"
TYPE_MAP[6]="OTHER"
TYPE_MAP[7]="TEXT"
TYPE_MAP[8]="TEXT"
TYPE_MAP[9]="IMAGE"

# status 映射：旧版本 status → 新版本 status
# 旧版本：0=创建中, 1=可用, 4=上传中, 5=清洗中, 6=增强中, 7=标注中
# 新版本：DRAFT/ACTIVE/ARCHIVED
declare -A STATUS_MAP
STATUS_MAP[0]="DRAFT"
STATUS_MAP[1]="ACTIVE"
STATUS_MAP[4]="DRAFT"
STATUS_MAP[5]="ACTIVE"
STATUS_MAP[6]="ACTIVE"
STATUS_MAP[7]="ACTIVE"

# 处理 datasets_uuid.tmp 生成最终 CSV
tail -n +2 "$EXPORT_DIR/datasets_uuid.tmp" | while IFS=',' read -r old_version_id old_dataset_id old_version_number old_dataset_name old_type description created_at updated_at created_by source_type data_location status; do
    new_uuid=$(gen_uuid)
    # 新名称：{old_dataset_name}_v{old_version_number}
    new_name="${old_dataset_name}_v${old_version_number}"
    # 类型映射
    new_type="${TYPE_MAP[$old_type]:-TEXT}"
    # 状态映射
    new_status="${STATUS_MAP[$status]:-DRAFT}"
    # 计算文件数量和大小
    file_count=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM file WHERE dataset_version = $old_version_id AND status != 4")
    size_bytes=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COALESCE(SUM(size), 0) FROM file WHERE dataset_version = $old_version_id AND status != 4")

    echo "$new_uuid,$new_name,$description,$new_type,,,$source_type,$size_bytes,$file_count,,$new_status,false,false,$created_at,$updated_at,$created_by,,\"$old_dataset_id\",\"$old_version_id\"" >> "$EXPORT_DIR/datasets.csv"
done

log "步骤2：导出 file → files.csv"
log "规则：生成新UUID，file_name = 原始文件名，file_path = 新路径"

# 先导出文件基本信息
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" << 'EOF' > "$EXPORT_DIR/files_base.tmp"
COPY (
SELECT
    f.id as old_file_id,
    f.dataset_version as old_version_id,
    f.name as original_filename,
    f.path as old_file_uuid,
    f.extension as file_extension,
    f.type as file_type_code,
    f.size as file_size,
    f.hash as check_sum,
    f.status as old_status,
    f.created_on as created_at,
    f.updated_on as updated_at
FROM file f
LEFT JOIN dataset_version dv ON f.dataset_version = dv.id
LEFT JOIN dataset ds ON dv.dataset = ds.id
WHERE f.status != 4  -- 排除无效文件
AND dv.is_deleted = false
AND ds.is_deleted = false
) TO STDOUT WITH CSV HEADER
EOF

# 生成最终 files.csv，需要匹配 dataset 的 UUID
echo "new_uuid,dataset_uuid,file_name,file_path,file_type,file_size,check_sum,status,upload_time,created_at,updated_at,old_file_id,old_version_id,old_dataset_id,old_file_uuid" > "$EXPORT_DIR/files.csv"

# 从 datasets.csv 读取 UUID 映射
declare -A VERSION_UUID_MAP
while IFS=',' read -r new_uuid name desc dtype cat path fmt size fcnt rcnt stat pub feat created updated cby uby old_ds old_ver; do
    # 跳过 header 行和空行
    if [[ "$new_uuid" == "new_uuid" ]] || [[ -z "$new_uuid" ]]; then continue; fi
    # 清理键值，统一处理引号和空白
    clean_old_ver=$(clean_key "$old_ver")
    VERSION_UUID_MAP["$clean_old_ver"]="$new_uuid"
done < "$EXPORT_DIR/datasets.csv"

# 处理 files_base.tmp
# file_type 映射：旧版本 type code → 文件扩展名
# type: 1=conversation, 2=plain_text, 3=image, 7=single_choice
while IFS=',' read -r old_file_id old_version_id original_filename old_file_uuid file_extension file_type_code file_size check_sum old_status created_at updated_at; do
    clean_old_version_id=$(clean_key "$old_version_id")
    dataset_uuid="${VERSION_UUID_MAP[$clean_old_version_id]}"
    if [[ -z "$dataset_uuid" ]]; then
        log "警告：找不到 version_id=$clean_old_version_id 对应的 dataset_uuid，跳过文件 $old_file_id"
        continue
    fi

    new_uuid=$(gen_uuid)
    new_file_path="/dataset/${dataset_uuid}/${original_filename}"
    file_type="$file_extension"
    new_status="ACTIVE"
    if [[ "$old_status" == "1" ]]; then
        new_status="DELETED"
    fi

    old_dataset_id=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT dataset FROM dataset_version WHERE id = $clean_old_version_id")
    old_dataset_id=$(clean_key "$old_dataset_id")

    echo "$new_uuid,$dataset_uuid,\"$original_filename\",\"$new_file_path\",\"$file_type\",$file_size,$check_sum,$new_status,$created_at,$created_at,$updated_at,\"$old_file_id\",\"$clean_old_version_id\",\"$old_dataset_id\",\"$old_file_uuid\"" >> "$EXPORT_DIR/files.csv"
done < <(tail -n +2 "$EXPORT_DIR/files_base.tmp")

log "步骤3：导出 tag → tags.csv"

# 导出标签，生成新UUID
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" << 'EOF' > "$EXPORT_DIR/tags_base.tmp"
COPY (
SELECT id as old_tag_id, name, description
FROM tag
) TO STDOUT WITH CSV HEADER
EOF

echo "new_uuid,name,description,category,color,usage_count,created_at,updated_at,created_by,updated_by,old_tag_id" > "$EXPORT_DIR/tags.csv"

tail -n +2 "$EXPORT_DIR/tags_base.tmp" | while IFS=',' read -r old_tag_id name description; do
    new_uuid=$(gen_uuid)
    echo "$new_uuid,$name,$description,,,$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM tag2dataset WHERE tag = $old_tag_id"),,$(date '+%Y-%m-%d %H:%M:%S'),$(date '+%Y-%m-%d %H:%M:%S'),,,$old_tag_id" >> "$EXPORT_DIR/tags.csv"
done

log "步骤4：导出 tag2dataset → dataset_tags.csv"

# 导出标签关联，使用新UUID
# 需要从 datasets.csv 和 tags.csv 获取映射
# 先创建临时映射文件

# 创建 tag UUID 映射
declare -A TAG_UUID_MAP
while IFS=',' read -r new_uuid name desc cat color usage created updated cby uby old_tag; do
    if [[ "$new_uuid" == "new_uuid" ]] || [[ -z "$new_uuid" ]]; then continue; fi
    clean_old_tag=$(clean_key "$old_tag")
    TAG_UUID_MAP["$clean_old_tag"]="$new_uuid"
done < "$EXPORT_DIR/tags.csv"

echo "dataset_uuid,tag_uuid" > "$EXPORT_DIR/dataset_tags.csv"

psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" << 'EOF' > "$EXPORT_DIR/tags_rel.tmp"
COPY (
SELECT t2d.dataset as old_dataset_id, t2d.tag as old_tag_id
FROM tag2dataset t2d
LEFT JOIN dataset ds ON t2d.dataset = ds.id
WHERE ds.is_deleted = false
) TO STDOUT WITH CSV HEADER
EOF

while IFS=',' read -r old_dataset_id old_tag_id; do
    clean_old_tag_id=$(clean_key "$old_tag_id")
    clean_old_dataset_id=$(clean_key "$old_dataset_id")
    tag_uuid="${TAG_UUID_MAP[$clean_old_tag_id]}"
    if [[ -z "$tag_uuid" ]]; then
        continue
    fi
    grep ",\"$clean_old_dataset_id\"" "$EXPORT_DIR/datasets.csv" | cut -d',' -f1 | while read dataset_uuid; do
        if [[ -n "$dataset_uuid" ]]; then
            echo "$dataset_uuid,$tag_uuid" >> "$EXPORT_DIR/dataset_tags.csv"
        fi
    done
done < <(tail -n +2 "$EXPORT_DIR/tags_rel.tmp")

# 清理临时文件
rm -f "$EXPORT_DIR/*.tmp"

log "步骤5：生成统计信息"

total_datasets=$(tail -n +2 "$EXPORT_DIR/datasets.csv" | wc -l)
total_files=$(tail -n +2 "$EXPORT_DIR/files.csv" | wc -l)
total_tags=$(tail -n +2 "$EXPORT_DIR/tags.csv" | wc -l)

log "导出完成！"
log "----------------------------------------"
log "数据集数量：$total_datasets"
log "文件数量：$total_files"
log "标签数量：$total_tags"
log "----------------------------------------"
log "输出目录：$EXPORT_DIR"
log "输出文件："
log "  - datasets.csv"
log "  - files.csv"
log "  - tags.csv"
log "  - dataset_tags.csv"
log "----------------------------------------"
log "下一步：将 $EXPORT_DIR 目录传输到 B环境（文件服务器）执行 export_files.sh"