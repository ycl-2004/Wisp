#!/bin/bash
#
# 把当前代码装成本机自用的 /Applications/Wisp.app，并且**不丢系统授权**。
#
# 为什么需要这个脚本：发布包用 ad-hoc 签名，它没有证书链可以锚定，designated
# requirement 只能写成 `cdhash H"..."`。代码一改哈希就变，macOS 就当它是另一个程序，
# 屏幕录制／麦克风／语音识别的授权全部重来。改用团队证书签名后，requirement 变成
# `identifier "com.yichenlin.Wisp" and anchor apple generic and certificate leaf...`，
# 跟代码内容无关，重建多少次都还是同一个身份。
#
# 证书每年轮换、名字里的编号会变，团队 ID 不变，所以这里按团队从钥匙串里挑，
# 再用证书指纹签名（钥匙串里可能同时躺着别的账号的开发证书，按名字匹配会挑错）。
#
# 用法：
#   tools/install-local.sh              构建、签名、装到 /Applications
#   tools/install-local.sh --no-install 只构建和签名，不动 /Applications
#
# 对外分发仍然用 README 里的 ad-hoc 命令，不要用这个脚本产出的包：
# 别人的机器上没有你的开发证书，Gatekeeper 会直接拒绝。

set -euo pipefail

TEAM="BQYHJCCRMP"
APP="/Applications/Wisp.app"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILT="$ROOT/Build/Release/Wisp.app"

cd "$ROOT"

# 钥匙串里属于这个团队的开发证书，取指纹。
identity=""
while IFS= read -r line; do
    hash="${line%% *}"
    name="${line#* }"
    subject="$(security find-certificate -c "$name" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null || true)"
    if [[ "$subject" == *"OU=$TEAM"* ]]; then
        identity="$hash"
        echo "签名身份：$name"
        break
    fi
done < <(security find-identity -v -p codesigning | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "\(.*\)"$/\1 \2/p')

if [[ -z "$identity" ]]; then
    echo "钥匙串里没有团队 $TEAM 的代码签名证书。" >&2
    echo "在 Xcode → Settings → Accounts 里登录该团队的账号并下载证书后重试。" >&2
    exit 1
fi

rm -rf "$ROOT/Build/Release"
xcodebuild -project Wisp.xcodeproj -scheme Wisp -configuration Release \
    -arch arm64 -arch x86_64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_IDENTITY="$identity" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build > /dev/null

requirement="$(codesign -d -r- "$BUILT" 2>&1 | sed -n 's/^designated => //p')"
# 只要 requirement 里还有 cdhash，授权就会在下次重建时再掉一遍，那这次装了也白装。
if [[ "$requirement" == *cdhash* || "$requirement" != *"anchor apple generic"* ]]; then
    echo "签名没有锚定到证书上，装了以后授权还是会掉：" >&2
    echo "  $requirement" >&2
    exit 1
fi
codesign --verify --deep --strict "$BUILT"
echo "designated requirement：$requirement"

if [[ "${1:-}" == "--no-install" ]]; then
    echo "已构建并签名：${BUILT}（未安装）"
    exit 0
fi

# 正在运行的 app 被换掉会留下一个坏掉的 bundle。启停 Wisp 由你自己来，脚本只拦一下。
# 模式必须锚在安装路径开头：`-f` 比对的是整条命令行，写宽了会匹配到任何命令行里
# 碰巧带着这串路径的进程（跑检测的 shell 自己就是一个），于是永远说「正在运行」。
# 开发构建（Build/Debug 里那份、测试宿主）不挡：要换掉的只有 /Applications 这一份。
running_status=0
pgrep -f "^${APP}/Contents/MacOS/Wisp" > /dev/null || running_status=$?
if [[ "$running_status" == 0 ]]; then
    echo "Wisp 正在运行。请先退出它（菜单栏图标 → 退出），再重新执行。" >&2
    echo "包已经构建好了：$BUILT" >&2
    exit 1
elif [[ "$running_status" != 1 ]]; then
    echo "无法检查 Wisp 进程状态，未替换已安装应用。" >&2
    exit 1
fi

# Prepare and verify on the destination filesystem before moving the installed app.
# Keep the previous bundle: a copy/signature failure must not leave Wisp uninstalled.
staging="$(mktemp -d "$(dirname "$APP")/.Wisp-install.XXXXXX")"
ditto --norsrc "$BUILT" "$staging/Wisp.app"
codesign --verify --deep --strict "$staging/Wisp.app"
backup="$(mktemp -d "${TMPDIR:-/private/tmp}/wisp-install-backup.XXXXXX")"
had_previous=false
if [[ -e "$APP" ]]; then
    mv "$APP" "$backup/previous-Wisp.app"
    had_previous=true
fi
rollback_install() {
    trap - ERR
    if [[ -e "$APP" ]]; then mv "$APP" "$backup/failed-Wisp.app"; fi
    if [[ "$had_previous" == true ]]; then mv "$backup/previous-Wisp.app" "$APP"; fi
    echo "安装失败；已尝试恢复旧版本。检查：${APP}；诊断文件：$backup" >&2
    exit 1
}
trap rollback_install ERR
mv "$staging/Wisp.app" "$APP"
codesign --verify --deep --strict "$APP"
trap - ERR
rmdir "$staging"
echo "已安装：${APP}；旧版本备份：$backup"
echo "证书签名有助于保持授权；macOS 仍可能要求重新确认屏幕录制／麦克风／语音识别权限。"
