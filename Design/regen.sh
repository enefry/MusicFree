#!/bin/bash

CURRENT_DIR="$(pwd)"
SHELL_FOLDER="$(cd "$(dirname "$0")" || exit; pwd)"

function op_one(){
    # 1. 获取绝对路径（例如: /Users/xxx/Project/AppIcon.icon）
    local FULL_PATH="$(realpath "$1")"

    # 2. 获取带后缀的文件名（例如: AppIcon.icon）
    local BASE_PATH_NAME=$(basename "$FULL_PATH") 
    
    # 3. 获取不带后缀的纯名称（例如: AppIcon）
    local BASE_NAME="${BASE_PATH_NAME%.*}"

    echo "========================================="
    echo "🚀 正在处理: ${BASE_PATH_NAME}"
    
    # 4. 执行生成脚本（传入绝对路径最安全）
    gen_app_icon.sh "$FULL_PATH"


    # 5. 【修复 Bug 1】清理并同步最新的 .icon 文件夹
    # 之前 $NAME 包含了前面的路径，用 $BASE_PATH_NAME 才能保证复制到 App/ 目录下名字正确
    rm -rf "${SHELL_FOLDER}/../App/${BASE_PATH_NAME}"
    cp -rf "${FULL_PATH}" "${SHELL_FOLDER}/../App/"

    # 6. 【修复 Bug 2】清理并同步生成的 .appiconset 资产
    # 之前生成的资产应该是在当前执行目录或者 .icon 同级，
    # 且目标路径漏掉了 Assets.xcassets，这里补齐了正确的源路径和目标路径
    local SRC_APPICONSET="${CURRENT_DIR}/${BASE_NAME}.appiconset"
    local DEST_ASSETS_DIR="${SHELL_FOLDER}/../App/Assets.xcassets"
    
    rm -rf "${DEST_ASSETS_DIR}/${BASE_NAME}.appiconset"
    
    # 确保目标 Assets 目录存在再复制
    if [ -d "$SRC_APPICONSET" ]; then
        mkdir -p "$DEST_ASSETS_DIR"
        cp -rf "$SRC_APPICONSET" "$DEST_ASSETS_DIR/"
        # 复制完后清理当前目录下的临时生成文件（可选）
        rm -rf "$SRC_APPICONSET"
        
    else
        echo "⚠️ 未找到生成的资产: ${SRC_APPICONSET}"
    fi
    
    #复制preview文件
    # preview名称 比如 AppIcon-preview
    local PREVIEW_NAME="${BASE_NAME}-preview"
    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" "$1" --export-preview iOS Light 64 64 2 "${PREVIEW_NAME}.png"
    rm -rf "${DEST_ASSETS_DIR}/AppIcon_Preview/${PREVIEW_NAME}.imageset/icon.png"
    mv "${PREVIEW_NAME}.png" "${DEST_ASSETS_DIR}/AppIcon_Preview/${PREVIEW_NAME}.imageset/icon.png"
    echo "$(pwd) ${BASE_NAME}-light-1024.png" "${BASE_NAME}-dark-1024.png" "${BASE_NAME}-preview.png"
    rm -f "${BASE_NAME}-light-1024.png" "${BASE_NAME}-dark-1024.png" "${BASE_NAME}-preview.png"
}

# 1. 初始化空数组
icons=()

# 2. 兼容老版本 Bash 的安全读取方式 (-d '' 兼容路径空格)
while IFS= read -r -d '' file; do
    icons+=("$file")
done < <(find . -type d -name '*.icon' -print0)

# 3. 检查数量
echo "共找到 ${#icons[@]} 个 .icon 文件"

# 4. 遍历数组
for icon in "${icons[@]}"; do
    op_one "$icon"
done

echo "========================================="
echo "✅ 所有图标处理同步完成！"
