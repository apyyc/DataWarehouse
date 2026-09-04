#!/usr/bin/env bash
# ============================================================
# DataWarehouse 部署脚本：从「已有镜像」创建容器 → 运行 → 配置开机自启
#
# 前提：镜像已存在（如 localhost/datawarehouse:0.4.0）
#
# 数据卷：默认挂载 ${HOME}/SERVER/datawarehouse/data → /data/warehouse
#   - 用 --data-dir <路径> 指定挂载位置
#   - 加 --no-volume 可跳过挂载（用镜像内数据）
#   - 应用数据根由本脚本注入环境变量 WAREHOUSE_DIR=/data/warehouse
#     （config.py 优先级：环境变量 > 配置文件 > 内置默认），
#     因此 config.json 里的 warehouse_dir / meta_dir 不再决定数据落点，可删除。
# 仓库令牌 / DataHub 地址：
#   - token：--token <值> 或环境变量 WAREHOUSE_ACCESS_TOKEN
#   - datahub_url：--datahub-url <地址> 或环境变量 WAREHOUSE_DATAHUB_URL；
#     不传时**不注入环境变量**，以「容器内配置文件的 datahub_url」为准。
#     生产建议用 VOLUME_MAPS 挂载宿主机 config.json，在文件里显式填写正确
#     的 DataHub 地址（否则默认 http://127.0.0.1:8002/api/data 在容器里
#     连的是容器自己，token 同步会报 "All connection attempts failed"）。
#
# 用法：
#   ./deploy_container.sh                            # 默认 host 网络（同机连 collab 最稳，datahub_url 用 127.0.0.1）
#   ./deploy_container.sh --data-dir /path/to/data   # 指定挂载位置
#   ./deploy_container.sh --token xxx --datahub-url http://ip:8002/api/data
#   ./deploy_container.sh --port-map                 # 改用端口映射（默认 host 网络；桥接下连宿主 8002 常不通）
#   ./deploy_container.sh --no-systemd               # 只建容器，不配自启
#   ./deploy_container.sh --stop                     # 停止并禁用自启
#   ./deploy_container.sh --rm                       # 删除容器
#
# 依赖：podman 或 docker（自动检测）
# ============================================================

set -euo pipefail

# ---------- 可配置参数（按需修改） ----------
IMAGE_NAME="datawarehouse"           # 镜像名
IMAGE_TAG="0.5.3"                    # 镜像版本标签
FULL_IMAGE="localhost/${IMAGE_NAME}:${IMAGE_TAG}"
CONTAINER_NAME="datawarehouse"       # 容器名
HOST_PORT="8004"                     # 宿主机映射端口
CONTAINER_PORT="8004"                # 容器内端口
CONTAINER_DATA_PATH="/data/warehouse"  # 容器内数据目录（由 Dockerfile VOLUME 固定）

# 容器内状态文件目录（tokens.json / signed_links.json / audit.log）。
# 默认 = 仓库根（/data/warehouse，与 bucket 同级）；想单独放改如 "/data/warehouse/state"。
# 注入环境变量后优先级高于 config.json 的 meta_dir，可避免相对路径（如 "./warehouse"）
# 按 warehouse_dir 再解析而建出两层目录（warehouse/warehouse）。
META_DIR_CONTAINER="${CONTAINER_DATA_PATH}"

# 宿主机数据目录（挂载进容器替换镜像内数据）
DATA_DIR="${HOME}/SERVER/datawarehouse/datawarehouse_0.5.3/warehouse"
VOLUME_ENABLED=true

# 卷映射列表（每项一个映射：宿主机:容器内）。可加多个，例如：
#   VOLUME_MAPS=(
#     "/home/apyyc/SERVER/datawarehouse/config.json:/app/datawarehouse/src/datawarehouse/resources/config.json"
#   )
# 主数据卷 DATA_DIR→CONTAINER_DATA_PATH 已单独处理；这里追加的27.0.0.1映射主要
# 是「配置文件」——把改好 datahub_url / access_token / signed_links 的
# config.json 挂进容器，配置显式可改、无需重新 build 镜像。
VOLUME_MAPS=("/home/apyyc/SERVER/datawarehouse/datawarehouse_0.5.3/config/config.json:/app/datawarehouse/src/datawarehouse/resources/config.json")

# 仓库令牌与 DataHub 地址（可用 --token / --datahub-url 覆盖，也可用环境变量）
# datahub_url 留空 = 不注入环境变量，使用容器内配置文件的 datahub_url 字段——
# 生产请用上面的 VOLUME_MAPS 把宿主机 config.json 挂进容器并显式填写正确地址。
WAREHOUSE_TOKEN="${WAREHOUSE_ACCESS_TOKEN:-}"
DATAHUB_URL="${WAREHOUSE_DATAHUB_URL:-}"

SERVICE_NAME="container-${CONTAINER_NAME}"
SYSTEMD_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${SYSTEMD_DIR}/${SERVICE_NAME}.service"

# ---------- 参数解析 ----------
DO_SYSTEMD=true
DO_STOP=false
DO_RM=false
# 默认 host 网络：同机部署连 collab 的 DataHub（127.0.0.1:8002）最稳；
# rootless 桥接下容器连宿主发布端口常不通（pasta 转发问题）。
DO_HOST_NETWORK=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-systemd) DO_SYSTEMD=false ;;
    --no-volume)  VOLUME_ENABLED=false ;;
    --token)      shift; WAREHOUSE_TOKEN="${1:-}" ;;
    --datahub-url) shift; DATAHUB_URL="${1:-}" ;;
    --data-dir)   shift; DATA_DIR="${1:-}" ;;
    --network-host) DO_HOST_NETWORK=true ;;
    --port-map)     DO_HOST_NETWORK=false ;;
    --stop)       DO_STOP=true ;;
    --rm)         DO_RM=true ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
  shift
done

# ---------- 检测容器工具 ----------
if [ -n "${FORCE:-}" ]; then
  TOOL="$FORCE"
elif command -v podman >/dev/null 2>&1; then
  TOOL="podman"
elif command -v docker >/dev/null 2>&1; then
  TOOL="docker"
else
  echo "❌ 未检测到 podman 或 docker"; exit 1
fi
echo "🔧 使用容器工具: $TOOL"
echo "👤 当前用户: $(whoami)   HOME: ${HOME}"
if [ "$VOLUME_ENABLED" = true ]; then
  echo "📁 挂载数据目录: $DATA_DIR"
fi

# ---------- 停止/删除模式 ----------
if [ "$DO_STOP" = true ]; then
  systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
  "$TOOL" stop "$CONTAINER_NAME" 2>/dev/null || true
  echo "✅ 已停止。容器仍在（$TOOL ps -a 可见），自启已禁用"
  exit 0
fi
if [ "$DO_RM" = true ]; then
  systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
  "$TOOL" rm -f "$CONTAINER_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl --user daemon-reload 2>/dev/null || true
  echo "✅ 容器已删除（数据卷 $DATA_DIR 保留）"
  exit 0
fi

# ---------- 1. 检查镜像 ----------
echo ""
echo "🔍 [1/5] 检查镜像 $FULL_IMAGE ..."
if ! "$TOOL" image exists "$FULL_IMAGE" 2>/dev/null; then
  echo "❌ 镜像 $FULL_IMAGE 不存在！请先："
  echo "   podman build -t $FULL_IMAGE ."
  exit 1
fi
echo "✅ 镜像存在"

# ---------- 2. 清理同名旧容器 ----------
echo ""
echo "🧹 [2/5] 清理同名旧容器 $CONTAINER_NAME ..."
"$TOOL" rm -f "$CONTAINER_NAME" 2>/dev/null && echo "   已删除旧容器" || echo "   无旧容器"

# ---------- 3. 数据卷 + 创建容器 ----------
echo ""
echo "🚀 [3/5] 创建容器 $CONTAINER_NAME ..."
VOLUME_ARGS=()
ENV_ARGS=()
if [ "$VOLUME_ENABLED" = true ]; then
  mkdir -p "$DATA_DIR"
  VOLUME_ARGS=(-v "${DATA_DIR}:${CONTAINER_DATA_PATH}")
  echo "   挂载: ${DATA_DIR} → ${CONTAINER_DATA_PATH}"
  # 把应用数据根与状态文件目录都固定到卷挂载点：config.py 环境变量优先级高于配置文件，
  # 因此 config.json 的 warehouse_dir / meta_dir 不再决定数据落点（可删）。
  # 注入绝对路径可避免相对路径按 warehouse_dir 再解析而建出两层目录。
  ENV_ARGS+=(-e "WAREHOUSE_DIR=${CONTAINER_DATA_PATH}")
  ENV_ARGS+=(-e "WAREHOUSE_META_DIR=${META_DIR_CONTAINER}")
  echo "   WAREHOUSE_DIR=${CONTAINER_DATA_PATH}"
  echo "   WAREHOUSE_META_DIR=${META_DIR_CONTAINER}（注入环境变量，覆盖配置文件）"
else
  echo "   未挂载卷，使用镜像内数据（删除容器数据即丢失）"
fi
# 附加卷映射（配置文件等）
for m in "${VOLUME_MAPS[@]}"; do
  [ -n "$m" ] || continue
  host="${m%%:*}"
  if [ ! -e "$host" ]; then
    echo "   ⚠️  附加卷宿主机路径不存在: $host（目录会自动创建；文件需先创建好）"
  fi
  VOLUME_ARGS+=(-v "$m")
  echo "   📄 附加卷: $m"
done
if [ -n "$WAREHOUSE_TOKEN" ]; then
  ENV_ARGS+=(-e "WAREHOUSE_ACCESS_TOKEN=$WAREHOUSE_TOKEN")
  echo "   token: 已设置"
else
  echo "   ⚠️  未设置 token（--token 或 WAREHOUSE_ACCESS_TOKEN），写入操作将无法通过校验"
fi
if [ -n "$DATAHUB_URL" ]; then
  ENV_ARGS+=(-e "WAREHOUSE_DATAHUB_URL=$DATAHUB_URL")
  echo "   datahub_url: $DATAHUB_URL（显式注入环境变量）"
else
  echo "   datahub_url: 未显式指定 → 以容器内配置文件（config.json）的 datahub_url 为准"
  echo "               （生产请用 VOLUME_MAPS 挂载 config.json 并显式填写，避免默认 127.0.0.1 连不到容器外的 DataHub）"
fi

# 网络模式：host 网络下不映射端口，容器共享宿主网络（同机连 collab 的 DataHub 用
# 127.0.0.1 即可；rootless 容器互相走 pasta 转发常连不通宿主发布端口，host 网络最稳）
NETWORK_ARGS=()
PORT_ARGS=()
if [ "$DO_HOST_NETWORK" = true ]; then
  NETWORK_ARGS+=(--network=host)
  echo "   🌐 网络: host（共享宿主网络，不再映射端口；datahub_url 建议 http://127.0.0.1:8002/api/data）"
else
  PORT_ARGS+=(-p "${HOST_PORT}:${CONTAINER_PORT}")
fi

"$TOOL" run -d \
  --name "$CONTAINER_NAME" \
  "${NETWORK_ARGS[@]}" \
  "${PORT_ARGS[@]}" \
  "${ENV_ARGS[@]}" \
  "${VOLUME_ARGS[@]}" \
  "$FULL_IMAGE"
if [ "$DO_HOST_NETWORK" = true ]; then
  echo "✅ 容器已创建: $CONTAINER_NAME  （host 网络，端口 8004 即宿主端口）"
else
  echo "✅ 容器已创建: $CONTAINER_NAME  端口映射: ${PORT_ARGS[*]}"
fi

# ---------- 4. 配置开机自启（systemd user 服务） ----------
if [ "$DO_SYSTEMD" = true ]; then
  echo ""
  echo "⚙️   [4/5] 生成 systemd 开机自启服务 ..."
  mkdir -p "$SYSTEMD_DIR"
  # podman 5.x 的 --files 把 .service 生成到当前目录，需先 cd 到 systemd user 目录
  ( cd "$SYSTEMD_DIR" && "$TOOL" generate systemd \
      --name "$CONTAINER_NAME" \
      --new --files --restart-policy=always )
  if [ ! -f "$SERVICE_FILE" ]; then
    echo "❌ 未找到生成的服务文件: $SERVICE_FILE"
    ls -la "$SYSTEMD_DIR" || true
    exit 1
  fi
  echo "✅ 服务文件已生成: $SERVICE_FILE"
  systemctl --user daemon-reload
  systemctl --user enable "$SERVICE_NAME"
  # --new 模式启动时会重新创建容器，删掉第 3 步手动建的，避免同名冲突
  echo "   删除手动容器，交由 systemd 重新创建 ..."
  "$TOOL" rm -f "$CONTAINER_NAME" 2>/dev/null || true
  systemctl --user start "$SERVICE_NAME"
  echo "✅ 自启服务已启用并启动: $SERVICE_NAME"
fi

# ---------- 5. 检查结果 ----------
echo ""
echo "✅ [5/5] 当前状态："
"$TOOL" ps --filter "name=$CONTAINER_NAME"
if [ "$DO_SYSTEMD" = true ]; then
  systemctl --user status "$SERVICE_NAME" --no-pager 2>/dev/null | head -4 || true
fi

echo ""
echo "🎉 完成。"
echo "──────────────────────────────────────────"
if [ "$DO_SYSTEMD" = true ]; then
  echo "🔒 若希望『不登录也能后台运行』，请执行："
  echo "   sudo loginctl enable-linger $(whoami)"
  echo "──────────────────────────────────────────"
  echo "查看/取消自启："
  echo "   systemctl --user status $SERVICE_NAME   # 查看"
  echo "   systemctl --user stop $SERVICE_NAME     # 停止"
  echo "   systemctl --user disable $SERVICE_NAME  # 取消自启"
  echo "   ./deploy_container.sh --stop   # 停止+禁用"
  echo "   ./deploy_container.sh --rm     # 删除容器+服务（数据卷保留）"
fi
