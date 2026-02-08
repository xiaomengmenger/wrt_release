#!/bin/bash
set -e

# 核心配置（仅保留OpenClash，删所有多余插件）
LAN_ADDR="192.168.1.1"
THEME_SET="argon"
FEEDS_CONF="feeds.conf.default"

# 1. 校验传参（必填：仓库URL、分支、编译目录、Commit哈希）
if [ $# -ne 4 ]; then
    echo "用法：$0 <REPO_URL> <REPO_BRANCH> <BUILD_DIR> <COMMIT_HASH>" >&2
    echo "示例：$0 https://github.com/xiaomengmenger/wrt_release main /tmp/build none" >&2
    exit 1
fi
REPO_URL="$1"
REPO_BRANCH="$2"
BUILD_DIR="$3"
COMMIT_HASH="$4"

# 校验传参非空
for var in REPO_URL REPO_BRANCH BUILD_DIR; do
    if [ -z "${!var}" ]; then
        echo "错误：参数 $var 不能为空" >&2
        exit 1
    fi
done
[ -z "$COMMIT_HASH" ] && COMMIT_HASH="none"

# 2. 检查依赖工具
check_dependencies() {
    local deps=("git" "curl" "sed" "awk" "find" "cp" "rm" "mkdir" "install")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "错误：缺少依赖工具 $dep，请先安装" >&2
            exit 1
        fi
    done
    # 可选依赖jq，缺失仅警告
    if ! command -v jq >/dev/null 2>&1; then
        echo "警告：未安装jq，部分更新功能不可用（不影响OpenClash安装）" >&2
    fi
}

# 3. 克隆仓库（关键修改：因为pre_clone_action.sh已克隆，这里直接跳过）
clone_repo() {
    echo "⚠️ 检测到pre_clone_action.sh已克隆仓库，跳过clone_repo步骤"
    return 0  # 直接返回成功，不执行克隆逻辑
}

# 4. 重置feeds配置
reset_feeds_conf() {
    cd "$BUILD_DIR" || exit 1
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "错误：$BUILD_DIR 不是Git仓库" >&2
        exit 1
    fi
    git reset --hard origin/"$REPO_BRANCH"
    git clean -f -d
    git pull
    if [[ "$COMMIT_HASH" != "none" && -n "$COMMIT_HASH" ]]; then
        if git cat-file -e "$COMMIT_HASH^{commit}" 2>/dev/null; then
            git checkout "$COMMIT_HASH"
        else
            echo "警告：Commit Hash无效，跳过检出" >&2
        fi
    fi
}

# 5. 更新feeds（仅保留small8源，删passwall/bandix等）
update_feeds() {
    cd "$BUILD_DIR" || exit 1
    local FEEDS_PATH="$BUILD_DIR/$FEEDS_CONF"
    [[ -f "$BUILD_DIR/feeds.conf" ]] && FEEDS_PATH="$BUILD_DIR/feeds.conf"
    
    # 清理无效行
    sed -i '/^#/d' "$FEEDS_PATH" 2>/dev/null
    sed -i '/packages_ext/d' "$FEEDS_PATH" 2>/dev/null
    sed -i '/openwrt-passwall/d' "$FEEDS_PATH" 2>/dev/null
    sed -i '/openwrt_bandix/d' "$FEEDS_PATH" 2>/dev/null
    sed -i '/luci_app_bandix/d' "$FEEDS_PATH" 2>/dev/null
    
    # 仅添加small8源（OpenClash所在）
    if ! grep -q "small-package" "$FEEDS_PATH"; then
        [ -z "$(tail -c 1 "$FEEDS_PATH")" ] || echo "" >>"$FEEDS_PATH"
        echo "src-git small8 https://github.com/kenzok8/small-package" >>"$FEEDS_PATH"
    fi
    
    # 避免bpf.mk报错
    [ -f "$BUILD_DIR/include/bpf.mk" ] || touch "$BUILD_DIR/include/bpf.mk"
    ./scripts/feeds update -i
}

# 6. 安装插件（仅装OpenClash，删所有多余）
install_small8() {
    cd "$BUILD_DIR" || exit 1
    # 仅安装OpenClash，无任何多余插件
    ./scripts/feeds install -p small8 -f luci-app-openclash
}

install_feeds() {
    cd "$BUILD_DIR" || exit 1
    ./scripts/feeds update -i
    for dir in "$BUILD_DIR/feeds/"*; do
        if [ -d "$dir" ] && [[ ! "$dir" == *.tmp ]] && [[ ! "$dir" == *.index ]]; then
            local feed_name=$(basename "$dir")
            if [[ "$feed_name" == "small8" ]]; then
                install_small8
                install_fullconenat  # 保留网络优化插件（不影响）
            elif [[ "$feed_name" == "passwall" ]]; then
                :  # 空指令，跳过passwall安装
            else
                ./scripts/feeds install -f -ap "$feed_name" --no-install-recommends
            fi
        fi
    done
}

install_fullconenat() {
    cd "$BUILD_DIR" || exit 1
    ./scripts/feeds install -p small8 -f fullconenat 2>/dev/null || true
}

# 7. 彻底删除多余插件文件
remove_unwanted_packages() {
    cd "$BUILD_DIR" || exit 1
    local unwanted_pkgs=(
        "luci-app-passwall" "luci-app-smartdns" "luci-app-lucky" "luci-app-mosdns"
        "luci-app-homeproxy" "luci-app-daed" "luci-app-dae" "luci-app-ssr-plus"
        "luci-app-vssr" "luci-app-alist" "luci-app-ddns-go" "smartdns" "mosdns" "lucky"
        "xray-core" "v2ray-core" "sing-box" "hysteria" "naiveproxy" "trojan-plus"
    )
    for pkg in "${unwanted_pkgs[@]}"; do
        rm -rf "./feeds/luci/applications/$pkg" 2>/dev/null
        rm -rf "./feeds/small8/$pkg" 2>/dev/null
        rm -rf "./feeds/packages/net/$pkg" 2>/dev/null
    done
    rm -rf "./package/istore" 2>/dev/null
}

# 8. 清理缓存
clean_up() {
    cd "$BUILD_DIR" || exit 1
    rm -rf "$BUILD_DIR/tmp" "$BUILD_DIR/.config" 2>/dev/null
    rm -rf "$BUILD_DIR/feeds/passwall" 2>/dev/null
}

# 9. 主执行流程
main() {
    check_dependencies
    clone_repo
    reset_feeds_conf
    update_feeds
    install_feeds
    remove_unwanted_packages
    clean_up
    echo "✅ 脚本执行完成！仅保留OpenClash，所有多余插件已删除"
    echo "📌 编译目录：$BUILD_DIR"
}

# 启动主流程
main
