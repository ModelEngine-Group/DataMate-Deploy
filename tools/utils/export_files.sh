#!/bin/bash
# =============================================================================
# DataMate 数据迁移脚本 - 阶段二：旧版本文件迁移（B环境）
# =============================================================================
# 功能：读取CSV，复制旧版本文件并重命名为原始文件名
# 执行环境：有文件存储的环境（B环境）
# 输入：migrate_export/ 目录下的CSV文件（从A环境传输）
# 输出：migrate_export/files/ 目录下的重命名文件
# =============================================================================

set -e

# ======================== 配置部分 ========================

# CSV文件目录（从A环境传输过来的）
CSV_DIR="/migrate_export"

# 输出文件目录
OUTPUT_DIR="/migrate_export/files"

# ======================== 函数定义 ========================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ======================== 主流程 ========================

log "开始文件迁移..."

# 检查CSV文件是否存在
if [[ ! -f "$CSV_DIR/files.csv" ]]; then
    log "错误：找不到 $CSV_DIR/files.csv"
    log "请先从A环境传输CSV文件到此目录"
    exit 1
fi

# 创建输出目录
mkdir -p "$OUTPUT_DIR"

# 统计变量
total_files=0
success_count=0
fail_count=0
skip_count=0

# 读取 files.csv 并处理
log "处理文件..."

# CSV字段：new_uuid,dataset_uuid,file_name,file_path,file_type,file_size,check_sum,status,upload_time,created_at,updated_at,old_file_id,old_version_id,old_dataset_id,old_file_uuid

while IFS=',' read -r new_uuid dataset_uuid file_name file_path file_type file_size check_sum status upload_time created_at updated_at old_file_id old_version_id old_dataset_id old_file_uuid; do
    total_files=$((total_files + 1))

    # 清理引号
    file_name=$(echo "$file_name" | tr -d '"')
    file_path=$(echo "$file_path" | tr -d '"')
    old_file_uuid=$(echo "$old_file_uuid" | tr -d '"')
    dataset_uuid=$(echo "$dataset_uuid" | tr -d '"')

    old_file_path="${old_file_uuid}"
    new_file_dir="${OUTPUT_DIR}/${dataset_uuid}"
    new_file_path="${new_file_dir}/${file_name}"

    # 检查旧文件是否存在
    if [[ ! -f "$old_file_path" ]]; then
        log "警告：旧文件不存在，跳过 - $old_file_path"
        skip_count=$((skip_count + 1))
        continue
    fi

    # 创建新目录
    mkdir -p "$new_file_dir"

    # 复制文件
    if cp "$old_file_path" "$new_file_path"; then
        success_count=$((success_count + 1))
        if [[ $((success_count % 100)) -eq 0 ]]; then
            log "已处理 $success_count 个文件..."
        fi
    else
        log "错误：复制失败 - $old_file_path -> $new_file_path"
        fail_count=$((fail_count + 1))
    fi
done < <(tail -n +2 "$CSV_DIR/files.csv")

log "----------------------------------------"
log "文件迁移完成"
log "总数：$total_files"
log "成功：$success_count"
log "失败：$fail_count"
log "跳过：$skip_count"
log "----------------------------------------"
log "输出目录：$OUTPUT_DIR"
log "下一步："
log "  1. 将 $OUTPUT_DIR 目录传输到 新版本服务器"
log "  2. 将 $CSV_DIR/*.csv 文件传输到 新版本服务器"
log "  3. 在 新版本环境执行 import_db.sh"