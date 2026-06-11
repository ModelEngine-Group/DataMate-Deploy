#!/bin/bash
# =============================================================================
# DataMate 数据迁移脚本 - 阶段三：新版本数据库导入（C环境）
# =============================================================================

set -e

# ======================== 配置部分 ========================

DB_NAME="datamate"
DB_USER="postgres"
export PGPASSWORD="$POSTGRES_PASSWORD"

CSV_DIR="/migrate_export"

# ======================== 函数定义 ========================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ======================== 主流程 ========================

log "开始数据库导入..."

if [[ ! -f "$CSV_DIR/datasets.csv" ]]; then
    log "错误：找不到 $CSV_DIR/datasets.csv"
    exit 1
fi

log "步骤1：导入 datasets"

psql -U "$DB_USER" -d "$DB_NAME" << EOF
CREATE TEMP TABLE tmp_datasets (
    id VARCHAR(36),
    name VARCHAR(255),
    description TEXT,
    dataset_type VARCHAR(50),
    category VARCHAR(100),
    path VARCHAR(500),
    format VARCHAR(50),
    size_bytes BIGINT,
    file_count BIGINT,
    record_count BIGINT,
    status VARCHAR(50),
    is_public BOOLEAN,
    is_featured BOOLEAN,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    created_by VARCHAR(255),
    updated_by VARCHAR(255),
    old_dataset_id VARCHAR(36),
    old_version_id VARCHAR(36)
);

\COPY tmp_datasets FROM '$CSV_DIR/datasets.csv' WITH CSV HEADER

INSERT INTO t_dm_datasets (id, name, description, dataset_type, category, path, format, size_bytes, file_count, record_count, status, is_public, is_featured, created_at, updated_at, created_by, updated_by)
SELECT id, name, description, dataset_type, category, '/dataset/' || id, format, size_bytes, file_count, record_count, status, is_public, is_featured, created_at, updated_at, COALESCE(created_by, 'system'), updated_by
FROM tmp_datasets
ON CONFLICT (id) DO NOTHING;

INSERT INTO t_lineage_node (id, graph_id, node_type, name, description)
SELECT id, gen_random_uuid()::text, 'DATASET', name, description
FROM tmp_datasets
ON CONFLICT (id) DO NOTHING;

DROP TABLE tmp_datasets;
EOF

log "步骤2：导入 tags"

psql -U "$DB_USER" -d "$DB_NAME" << EOF
CREATE TEMP TABLE tmp_tags (
    id VARCHAR(36),
    name VARCHAR(100),
    description TEXT,
    category VARCHAR(50),
    color VARCHAR(7),
    usage_count BIGINT,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    created_by VARCHAR(255),
    updated_by VARCHAR(255),
    old_tag_id VARCHAR(36)
);

\COPY tmp_tags FROM '$CSV_DIR/tags.csv' WITH CSV HEADER

INSERT INTO t_dm_tags (id, name, description, category, color, usage_count, created_at, updated_at, created_by, updated_by)
SELECT id, name, description, category, color, usage_count, created_at, updated_at, created_by, updated_by
FROM tmp_tags
ON CONFLICT (name) DO NOTHING;

DROP TABLE tmp_tags;
EOF

log "步骤3：导入 dataset_tags"

psql -U "$DB_USER" -d "$DB_NAME" << EOF
CREATE TEMP TABLE tmp_dataset_tags (
    dataset_id VARCHAR(36),
    tag_id VARCHAR(36)
);

\COPY tmp_dataset_tags FROM '$CSV_DIR/dataset_tags.csv' WITH CSV HEADER

INSERT INTO t_dm_dataset_tags (dataset_id, tag_id, created_at)
SELECT dataset_id, tag_id, CURRENT_TIMESTAMP
FROM tmp_dataset_tags
ON CONFLICT (dataset_id, tag_id) DO NOTHING;

DROP TABLE tmp_dataset_tags;
EOF

log "步骤4：导入 files"

psql -U "$DB_USER" -d "$DB_NAME" << EOF
CREATE TEMP TABLE tmp_files (
    id VARCHAR(36),
    dataset_id VARCHAR(64),
    file_name VARCHAR(255),
    file_path VARCHAR(1000),
    file_type VARCHAR(50),
    file_size BIGINT,
    check_sum VARCHAR(64),
    status VARCHAR(50),
    upload_time TIMESTAMP,
    created_at TIMESTAMP,
    updated_at TIMESTAMP,
    old_file_id VARCHAR(64),
    old_version_id VARCHAR(64),
    old_dataset_id VARCHAR(64),
    old_file_uuid VARCHAR(64)
);

\COPY tmp_files FROM '$CSV_DIR/files.csv' WITH CSV HEADER

INSERT INTO t_dm_dataset_files (id, dataset_id, file_name, file_path, file_type, file_size, check_sum, status, upload_time, created_at, updated_at)
SELECT id, dataset_id, file_name, file_path, file_type, file_size, check_sum, status, upload_time, created_at, updated_at
FROM tmp_files
ON CONFLICT (id) DO NOTHING;

DROP TABLE tmp_files;
EOF

log "步骤5：验证数据"

datasets_count=$(psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM t_dm_datasets")
files_count=$(psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM t_dm_dataset_files")
tags_count=$(psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM t_dm_tags")
tag_rel_count=$(psql -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM t_dm_dataset_tags")

log "----------------------------------------"
log "导入完成"
log "数据集：$datasets_count"
log "文件：$files_count"
log "标签：$tags_count"
log "标签关联：$tag_rel_count"