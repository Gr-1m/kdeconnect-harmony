#!/usr/bin/env bash
# 本地 debug 签名 + 安装 + 启动（宿主 Linux，配合 ~/WorkSpace2/openharmony-qemu-* 模拟器）
#
# 用法:
#   tools/sign-debug.sh            # 构建 + 签名 + 安装（不启动 app）
#   tools/sign-debug.sh sign-only  # 只构建 + 签名
#   tools/sign-debug.sh install    # 不重新构建，直接装已有签名 HAP
#
# 启动 app 用 tools/launch-app.sh
#
# 依赖: /opt/ohos-sdk (paru ohos-sdk)、/opt/command-line-tools (Command Line Tools, PATH 里有 hvigorw)、hdc 已连上设备
#
# 踩坑记录（2026-09-03 实测）:
#  - keytool -exportcert 默认输出 DER 二进制，PEM 链必须加 -rfc
#  - hap-sign-tool 的 appCertFile / profileCertFile 都要完整证书链（leaf, 中间CA, root），单张报 11013004
#  - p12 里 "openharmony application release" 条目是私钥的自签名包装（issuer=自己），
#    真正配对的叶证书是 profile 模板 JSON 里的 development-certificate（由 App CA 签发），必须用它
#  - 模板 validity 已过期（2021~2023），要重填 not-before / not-after
#  - debug profile 的 device-ids 必须填目标设备 UDID（hdc shell bm get --udid）
#  - sign-app 的 -compatibleVersion 对 .hap 必填
#  - 签名算法: 证书实际是 ecdsa-with-SHA384，sign-app 用 SHA384withECDSA

set -euo pipefail
MODE="${1:-all}"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_LIB=/opt/ohos-sdk/26/toolchains/lib
TOOL="$SDK_LIB/hap-sign-tool.jar"
SIGN_DIR="$PROJECT_ROOT/sign"
BUNDLE_NAME="org.kde.kdeconnect"
MAIN_ABILITY="EntryAbility"
API_VERSION=26
KS_PWD=123456

mkdir -p "$SIGN_DIR"

build() {
  (cd "$PROJECT_ROOT" && hvigorw assembleHap --no-daemon 2>&1 | tail -3)
}

prepare_materials() {
  cd "$SIGN_DIR"
  # 1. 证书链材料（root / app-ca 从 SDK 自带 pem 拆出；pem 顺序是 root, app-ca, profile-debug）
  python3 - <<'EOF'
import json, re
lib = "/opt/ohos-sdk/26/toolchains/lib"
raw = open(f"{lib}/OpenHarmonyProfileDebug.pem").read()
certs = re.findall(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", raw, re.S)
open("root-ca.cer", "w").write(certs[0] + "\n")
open("app-ca.cer", "w").write(certs[1] + "\n")
# 模板里的 development-certificate 才是配对的叶证书
tpl = json.load(open(f"{lib}/UnsgnedDebugProfileTemplate.json"))
open("app-release.cer", "w").write(tpl["bundle-info"]["development-certificate"])
# 证书链: leaf, 中间CA, root
open("app-release-chain.cer", "w").write(
    tpl["bundle-info"]["development-certificate"] + certs[1] + "\n" + certs[0] + "\n")
open("profile-debug-chain.cer", "w").write(certs[2] + "\n" + certs[1] + "\n" + certs[0] + "\n")
EOF
  cp -n "$SDK_LIB/OpenHarmony.p12" . 2>/dev/null || true
}

sign_profile() {
  cd "$SIGN_DIR"
  local udid version_name version_code
  udid="$(hdc shell bm get --udid | tail -1 | tr -d '\r')"
  [ ${#udid} -eq 64 ] || { echo "UDID 获取失败: $udid" >&2; exit 1; }
  version_name="$(python3 -c "import re;print(re.search(r'versionName.\s*:\s*\"([^\"]+)\"',open('$PROJECT_ROOT/AppScope/app.json5').read()).group(1))")"
  version_code="$(python3 -c "import re;print(re.search(r'versionCode.\s*:\s*(\d+)',open('$PROJECT_ROOT/AppScope/app.json5').read()).group(1))")"

  # 基于模板填 profile: bundle-name / 版本 / 有效期 2 年 / 设备 UDID
  python3 - "$BUNDLE_NAME" "$version_name" "$version_code" "$udid" <<'EOF'
import json, sys, time
bundle, vname, vcode, udid = sys.argv[1:5]
now = int(time.time())
t = json.load(open("/opt/ohos-sdk/26/toolchains/lib/UnsgnedDebugProfileTemplate.json"))
t["version-name"], t["version-code"] = vname, int(vcode)
t["validity"] = {"not-before": now - 86400, "not-after": now + 730 * 86400}
t["bundle-info"]["bundle-name"] = bundle
t["debug-info"]["device-ids"] = [udid]
json.dump(t, open("profile-debug.json", "w"), indent=4)
EOF
  java -jar "$TOOL" sign-profile -mode localSign \
    -keyAlias "openharmony application profile debug" -keyPwd "$KS_PWD" \
    -profileCertFile profile-debug-chain.cer \
    -inFile profile-debug.json -signAlg SHA256withECDSA \
    -keystoreFile OpenHarmony.p12 -keystorePwd "$KS_PWD" \
    -outFile profile-debug.p7b >/dev/null
}

sign_hap() {
  cd "$SIGN_DIR"
  local in_hap out_hap
  in_hap="$PROJECT_ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap"
  out_hap="$SIGN_DIR/entry-debug-signed.hap"
  java -jar "$TOOL" sign-app -mode localSign \
    -keyAlias "openharmony application release" -keyPwd "$KS_PWD" \
    -appCertFile app-release-chain.cer \
    -profileFile profile-debug.p7b \
    -inFile "$in_hap" -signAlg SHA384withECDSA \
    -keystoreFile OpenHarmony.p12 -keystorePwd "$KS_PWD" \
    -outFile "$out_hap" -compatibleVersion "$API_VERSION" -signCode 1 >/dev/null
  echo "签名 HAP: $out_hap"
}

install_only() {
  hdc install "$SIGN_DIR/entry-debug-signed.hap"
}

case "$MODE" in
  sign-only) build; prepare_materials; sign_profile; sign_hap ;;
  install)   install_only ;;
  all)       build; prepare_materials; sign_profile; sign_hap; install_only ;;
  *) echo "用法: $0 [all|sign-only|install]" >&2; exit 2 ;;
esac
