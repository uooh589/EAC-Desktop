#!/usr/bin/env bash
# 把 EAC 的 deb 产物转成 Arch/CachyOS 可用的 pacman 包
#
# 上游与 fork 的 CI 只产出 deb（Tauri 打包链不支持 pacman）。本脚本复用
# deb 里的载荷，重新生成 .PKGINFO / .MTREE 并打为 zstd 压缩的 pacman 包，
# 使 `pacman -U` 可直接安装。
#
# 用法：
#   ./make-pacman-pkg.sh <deb 路径> [输出目录]
#
# 产物：<输出目录>/deepseek-harness-eac-<版本>-1-x86_64.pkg.tar.zst
set -euo pipefail

PKGNAME="deepseek-harness-eac"
PRODUCT="Deepseek Harness EAC"          # deb 内的目录名，也是 Tauri 资源目录名
APPDIR="/usr/lib/$PRODUCT"
DEB="${1:-}"
OUTDIR="${2:-$(pwd)}"

[ -n "$DEB" ] || { echo "用法：$0 <deb 路径> [输出目录]" >&2; exit 1; }
[ -f "$DEB" ] || { echo "deb 不存在：$DEB" >&2; exit 1; }

log() { printf '\033[36m[pkg]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[pkg] 错误：%s\033[0m\n' "$*" >&2; exit 1; }

for c in bsdtar zstd; do
  command -v "$c" >/dev/null || die "缺少工具：$c"
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 1. 解出 deb 载荷 --------------------------------------------------------
log "解包 deb …"
bsdtar xf "$DEB" -C "$WORK" data.tar.gz control.tar.gz || die "deb 解包失败"
bsdtar xf "$WORK/data.tar.gz" -C "$WORK" || die "data.tar.gz 解包失败"
bsdtar xf "$WORK/control.tar.gz" -C "$WORK" || die "control.tar.gz 解包失败"

[ -d "$WORK/usr/lib/$PRODUCT" ] || die "deb 内未找到 $APPDIR"
[ -f "$WORK/usr/bin/dsh-eac-shell" ] || die "deb 内未找到 /usr/bin/dsh-eac-shell"

# --- 2. 版本与体积 -----------------------------------------------------------
# deb 的 Version 字段可能滞后于 tag（上游未同步），优先从 control 读，
# 允许调用方用 EAC_VERSION 覆盖以对齐 release tag。
DEB_VER="$(awk '/^Version:/ {print $2; exit}' "$WORK/control")"
VER="${EAC_VERSION:-$DEB_VER}"
VER="${VER#[Vv]}"
[ -n "$VER" ] || die "无法确定版本号"
log "版本：$VER（deb control 声明 $DEB_VER）"

SIZE="$(du -sb --apparent-size "$WORK/usr" | cut -f1)"

# --- 3. 生成 .PKGINFO --------------------------------------------------------
# depends 用 Arch 包名。deb 声明 libappindicator3-1 / libwebkit2gtk-4.1-0 /
# libgtk-3-0，对应 Arch 的 libayatana-appindicator / webkit2gtk-4.1 / gtk3。
# 其余 soname 由这些包传递带入；glibc/gcc-libs 属 base，不重复声明。
cat > "$WORK/.PKGINFO" <<EOF
pkgname = $PKGNAME
pkgbase = $PKGNAME
pkgver = $VER-1
pkgdesc = Deepseek Harness EAC — DeepSeek Harness 桌面工作台（Linux 构建）
url = https://github.com/uooh589/EAC-Desktop
builddate = $(date +%s)
packager = uooh589 <uooh589@users.noreply.github.com>
size = $SIZE
arch = x86_64
license = MIT
depend = webkit2gtk-4.1
depend = gtk3
depend = libayatana-appindicator
depend = libnotify
depend = xdg-utils
depend = glib2
depend = cairo
depend = gdk-pixbuf2
depend = dbus
depend = libsoup3
EOF

# --- 4. 打 .MTREE（pacman 用于校验文件清单）----------------------------------
log "生成 .MTREE …"
( cd "$WORK" && bsdtar -czf .MTREE --format=mtree \
    --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
    .PKGINFO usr ) 2>/dev/null || die ".MTREE 生成失败"

# --- 5. 打 pacman 包 ---------------------------------------------------------
mkdir -p "$OUTDIR"
PKGFILE="$OUTDIR/$PKGNAME-$VER-1-x86_64.pkg.tar.zst"
rm -f "$PKGFILE"

log "打包 …"
# pacman 包内条目顺序无关，但需排除解包用的中间文件
( cd "$WORK" && bsdtar -cf - .PKGINFO .MTREE usr ) \
  | zstd -q -T0 -19 -o "$PKGFILE" -f \
  || die "打包失败"

log "产物：$PKGFILE（$(du -h "$PKGFILE" | cut -f1)）"

# --- 6. 自检：用 pacman 读元数据 ---------------------------------------------
if command -v pacman >/dev/null; then
  log "自检（pacman -Qip）…"
  pacman -Qip "$PKGFILE" 2>&1 | sed 's/^/  /' || die "pacman 无法读取该包"
fi

echo
log "安装：sudo pacman -U $PKGFILE"
log "卸载：sudo pacman -R $PKGNAME"
