#!/usr/bin/env bash
# YX-H618 V11 / AIC8801, ophub Vontar image, Linux 6.18.x arm64.
# Rebuild after every kernel update. No DKMS or automatic reboot.
# Usage: sudo bash install-yx-h618-aic8801.sh [--prepare-only]
# --prepare-only installs build dependencies and builds/validates in staging,
# but does not install modules, firmware, services or change the boot selection.
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 022
PREPARE=0
case "${1:-}" in
  --prepare-only) PREPARE=1;;
  --help|-h) sed -n '2,7p' "$0"; exit 0;;
  '') ;;
  *) echo "Unknown argument: $1" >&2; exit 2;;
esac
[[ $# -le 1 ]] || exit 2
log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
[[ $EUID == 0 ]] || die 'Run with sudo bash.'
[[ $(uname -s) == Linux && $(uname -m) == aarch64 ]] || die 'Requires native arm64 Linux.'
KREL=$(uname -r)
[[ $KREL == 6.18.* ]] || die "Only 6.18.x is supported by these compatibility patches: $KREL"
[[ -d /run/systemd/system && -f /boot/armbianEnv.txt ]] || die 'Requires systemd and ophub /boot/armbianEnv.txt.'
grep -aq 'allwinner,sun50i-h618' /proc/device-tree/compatible || die 'Not an H618 device tree.'
grep -Eq '(^|[[:space:]])console=ttyS1([,[:space:]]|$)' /proc/cmdline && die 'ttyS1 is a kernel console; release it before installation.'
command -v apt-get >/dev/null || die 'Requires apt.'
command -v flock >/dev/null || die 'Requires util-linux/flock.'
exec 9>/run/lock/yx-h618-aic8801.lock
flock -n 9 || die 'Another installer is running.'
STATE=/var/lib/yx-h618-aic8801
mkdir -p "$STATE/runs"
RUN=$(mktemp -d "$STATE/runs/$(date +%Y%m%d-%H%M%S).XXXXXX")
mkdir -p "$RUN/backup" "$RUN/stage"
exec > >(tee -a "$RUN/install.log") 2>&1
trap 'rc=$?; log "FAILED at line $LINENO (exit $rc). Retained files/log: $RUN. No automatic reboot. If installation began, use the rollback instructions in this directory."; exit "$rc"' ERR
log "Target: $KREL; working directory: $RUN"
BASE=/boot/dtb/allwinner/sun50i-h618-vontar-h618.dtb
[[ -s $BASE ]] || die "Original Vontar DTB missing: $BASE (do not substitute an old patched DTB)."
# Avoid silently overwriting overlay changes to the same pins/controllers.
if grep -Eq '^(overlays|user_overlays)=.*[^=[:space:]]' /boot/armbianEnv.txt; then
  die 'Boot overlays are configured. Resolve overlapping DT overlays before running this board-specific installer.'
fi
log 'Installing build tools and BlueZ command-line tools.'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git ca-certificates build-essential bc flex bison libssl-dev libelf-dev python3 device-tree-compiler kmod bluez rfkill
KDIR=/lib/modules/$KREL/build
if [[ ! -f $KDIR/Makefile ]]; then
  log "Trying exact headers package linux-headers-$KREL"
  apt-get install -y "linux-headers-$KREL" || die "Exact headers unavailable. Install ophub headers for $KREL, then rerun. Do not use generic headers."
fi
[[ -s $KDIR/Module.symvers && -s $KDIR/include/generated/autoconf.h ]] || die 'Headers are incomplete/unprepared (Module.symvers/autoconf.h missing).'
[[ $(make -s -C "$KDIR" kernelrelease) == "$KREL" ]] || die 'Headers kernelrelease differs from uname -r.'
CCBIN=gcc
# GCC 14 resolves the previously encountered -fmin-function-alignment=4 failure.
if command -v gcc-14 >/dev/null; then
  CCBIN=gcc-14
elif ! printf 'int x;\n' | gcc -fmin-function-alignment=4 -x c -c -o "$RUN/compiler-test.o" -; then
  apt-get install -y gcc-14 || die 'gcc-14 needed but unavailable in configured repositories.'
  CCBIN=gcc-14
fi
log "Compiler: $($CCBIN --version | head -n 1)"
for bin in hciattach btmgmt rfkill; do command -v "$bin" >/dev/null || die "BlueZ tool missing: $bin"; done
# Fixed revision inspected when this installer was generated. Every run starts
# from clean source: never patch a user's modified /usr/src tree in place.
REV=516e3b087763d80c44f5e3b6d2dd63e0d925c91d
SRC=$RUN/aic8800-radxa
git init -q "$SRC"
git -C "$SRC" remote add origin https://github.com/radxa-pkg/aic8800.git
git -C "$SRC" fetch --depth 1 origin "$REV"
git -C "$SRC" checkout --detach FETCH_HEAD
git -C "$SRC" submodule update --init --recursive
[[ $(git -C "$SRC" rev-parse HEAD) == "$REV" ]] || die 'Source revision mismatch.'
DRV=$SRC/src/SDIO/driver_fw/driver/aic8800
FW=$SRC/src/SDIO/driver_fw/fw/aic8800
[[ -f $DRV/Makefile ]] || die 'Unexpected source layout.'
for file in fmacfw.bin fw_patch_table_u03.bin fw_patch_u03.bin fw_adid_u03.bin; do
  [[ -s $FW/$file ]] || die "Missing firmware: $file"
done
cd "$DRV"
log 'Applying the recorded 6.18 compatibility patches to clean source.'
python3 <<'PY_PATCH_2'
from pathlib import Path
import re

root = Path(".")

def edit(rel, fn):
    p = root / rel
    s = p.read_text()
    n = fn(s)
    if n == s:
        print("UNCHANGED:", rel)
    else:
        p.write_text(n)
        print("PATCHED:  ", rel)

# ---------------------------------------------------------
# 1. vfree() 需要 linux/vmalloc.h
# ---------------------------------------------------------
def patch_vmalloc(s):
    if "#include <linux/vmalloc.h>" in s:
        return s
    lines = s.splitlines()
    pos = 0
    for i, line in enumerate(lines):
        if line.startswith("#include"):
            pos = i + 1
    lines.insert(pos, "#include <linux/vmalloc.h>")
    return "\n".join(lines) + "\n"

edit("aic8800_bsp/aic8800d80n_compat.c", patch_vmalloc)

# ---------------------------------------------------------
# 2. Linux 6.17+ timer API
# del_timer_sync -> timer_delete_sync
# del_timer      -> timer_delete
# from_timer     -> timer_container_of
# ---------------------------------------------------------
def patch_timers(s):
    s = re.sub(r'\bdel_timer_sync\s*\(', 'timer_delete_sync(', s)
    s = re.sub(r'\bdel_timer\s*\(', 'timer_delete(', s)
    s = re.sub(r'\bfrom_timer\s*\(', 'timer_container_of(', s)
    return s

for f in [
    "aic8800_fdrv/rwnx_rx.c",
    "aic8800_fdrv/rwnx_main.c",
]:
    edit(f, patch_timers)

# ---------------------------------------------------------
# 3. cfg80211_rx_* 在新内核增加 link_id
# 单 radio / 非 MLO 设备这里用 0
# ---------------------------------------------------------
def patch_rx_cfg80211(s):
    s = re.sub(
        r'\bcfg80211_rx_spurious_frame\(\s*([^,]+),\s*([^,]+),\s*(GFP_[A-Z]+)\s*\)',
        r'\bcfg80211_rx_spurious_frame(\1, \2, 0, \3)',
        s
    )
    s = re.sub(
        r'\bcfg80211_rx_unexpected_4addr_frame\(\s*([^,]+),\s*([^,]+),\s*(GFP_[A-Z]+)\s*\)',
        r'\bcfg80211_rx_unexpected_4addr_frame(\1, \2, 0, \3)',
        s
    )
    return s

edit("aic8800_fdrv/rwnx_rx.c", patch_rx_cfg80211)

# ---------------------------------------------------------
# 4. MODULE_IMPORT_NS 从新内核开始要求字符串
# ---------------------------------------------------------
def patch_ns(s):
    return s.replace(
        'MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);',
        'MODULE_IMPORT_NS("VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver");'
    )

for p in root.rglob("*.c"):
    s = p.read_text(errors="ignore")
    if "MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver)" in s:
        p.write_text(patch_ns(s))
        print("PATCHED:  ", p.relative_to(root))

print("第一轮补丁完成")

PY_PATCH_2
python3 <<'PY_PATCH_1'
from pathlib import Path
import re
import sys

p = Path("aic8800_fdrv/rwnx_main.c")
s = p.read_text()
orig = s

def patch(pattern, repl, desc):
    global s
    ns, n = re.subn(pattern, repl, s, count=1, flags=re.S)
    print(f"{desc}: matched {n}")
    if n != 1:
        print("ERROR: 为避免半修改，停止且不写文件。")
        sys.exit(1)
    s = ns

# ------------------------------------------------------------
# 1. set_monitor_channel:
#
# static int rwnx_cfg80211_set_monitor_channel(
#     struct wiphy *wiphy,
#     struct cfg80211_chan_def *chandef)
#
# ->
# (..., struct net_device *dev, ...)
# ------------------------------------------------------------
patch(
    r'(static\s+int\s+rwnx_cfg80211_set_monitor_channel\s*'
    r'\(\s*struct\s+wiphy\s*\*\s*wiphy\s*,\s*)'
    r'(struct\s+cfg80211_chan_def\s*\*\s*chandef\s*\))',
    r'\1struct net_device *dev,\n                                             \2',
    "set_monitor_channel"
)

# ------------------------------------------------------------
# 2. wrapper
# ------------------------------------------------------------
patch(
    r'(int\s+rwnx_cfg80211_set_monitor_channel_\s*'
    r'\(\s*struct\s+wiphy\s*\*\s*wiphy\s*,\s*)'
    r'(struct\s+cfg80211_chan_def\s*\*\s*chandef\s*\)\s*\{\s*)'
    r'return\s+rwnx_cfg80211_set_monitor_channel\s*'
    r'\(\s*wiphy\s*,\s*chandef\s*\)\s*;',
    r'\1\2return rwnx_cfg80211_set_monitor_channel(wiphy, NULL, chandef);',
    "set_monitor_channel wrapper"
)

# ------------------------------------------------------------
# 3. 内部已有调用
# ------------------------------------------------------------
ns, n = re.subn(
    r'rwnx_cfg80211_set_monitor_channel\s*\(\s*wiphy\s*,\s*NULL\s*\)\s*;',
    r'rwnx_cfg80211_set_monitor_channel(wiphy, rwnx_vif->ndev, NULL);',
    s,
    count=1
)
print(f"internal set_monitor_channel call: matched {n}")
if n != 1:
    print("ERROR: 为避免半修改，停止且不写文件。")
    sys.exit(1)
s = ns

# ------------------------------------------------------------
# 4. set_wiphy_params
# ------------------------------------------------------------
patch(
    r'(static\s+int\s+rwnx_cfg80211_set_wiphy_params\s*'
    r'\(\s*struct\s+wiphy\s*\*\s*wiphy\s*,\s*)'
    r'(u32\s+changed\s*\))',
    r'\1int radio_idx, \2',
    "set_wiphy_params"
)

# ------------------------------------------------------------
# 5. set_tx_power
# ------------------------------------------------------------
patch(
    r'(static\s+int\s+rwnx_cfg80211_set_tx_power\s*'
    r'\(\s*struct\s+wiphy\s*\*\s*wiphy\s*,\s*'
    r'struct\s+wireless_dev\s*\*\s*wdev\s*,\s*)'
    r'(enum\s+nl80211_tx_power_setting\s+type\s*,\s*int\s+mbm\s*\))',
    r'\1int radio_idx,\n'
    r'                                      \2',
    "set_tx_power"
)

# ------------------------------------------------------------
# 6. get_tx_power
# 源码中间夹着 #if / #endif，所以单独匹配
# ------------------------------------------------------------
patch(
    r'(static\s+int\s+rwnx_cfg80211_get_tx_power\s*'
    r'\(\s*struct\s+wiphy\s*\*\s*wiphy\s*,\s*'
    r'#if\s+LINUX_VERSION_CODE\s*>=\s*KERNEL_VERSION\(3,\s*8,\s*0\)\s*'
    r'struct\s+wireless_dev\s*\*\s*wdev\s*,\s*'
    r'#endif\s*)'
    r'(int\s*\*\s*mbm\s*\))',
    r'\1int radio_idx,\n'
    r'\tunsigned int link_id,\n'
    r'\t\2',
    "get_tx_power"
)

if s == orig:
    print("ERROR: 内容没有发生变化")
    sys.exit(1)

p.write_text(s)
print()
print("OK: 所有 cfg80211 6.18 修改已写入")

PY_PATCH_1
python3 <<'PY_PATCH_0'
from pathlib import Path
import re
import sys

p = Path("aic8800_fdrv/rwnx_wakelock.c")
s = p.read_text()
orig = s

# 确保有正确头文件
if "#include <linux/pm_wakeup.h>" not in s:
    m = re.search(r'^(#include[^\n]*\n)', s, flags=re.M)
    if not m:
        print("ERROR: 找不到 include 区域")
        sys.exit(1)
    s = s[:m.end()] + "#include <linux/pm_wakeup.h>\n" + s[m.end():]

# old:
# ws = wakeup_source_create(name);
# wakeup_source_add(ws);
#
# new:
# ws = wakeup_source_register(NULL, name);

s, n1 = re.subn(
    r'ws\s*=\s*wakeup_source_create\s*\(\s*name\s*\)\s*;\s*'
    r'wakeup_source_add\s*\(\s*ws\s*\)\s*;',
    'ws = wakeup_source_register(NULL, name);',
    s,
    count=1,
    flags=re.S
)

# old:
# wakeup_source_remove(ws);
# wakeup_source_destroy(ws);
#
# new:
# wakeup_source_unregister(ws);

s, n2 = re.subn(
    r'wakeup_source_remove\s*\(\s*ws\s*\)\s*;\s*'
    r'wakeup_source_destroy\s*\(\s*ws\s*\)\s*;',
    'wakeup_source_unregister(ws);',
    s,
    count=1,
    flags=re.S
)

print("init patch matches:", n1)
print("deinit patch matches:", n2)

if n1 != 1 or n2 != 1:
    print("ERROR: 匹配数量异常，不写文件")
    sys.exit(1)

p.write_text(s)
print("OK: rwnx_wakelock.c 已适配 Linux 6.18")

PY_PATCH_0
python3 <<'PY_TIMER'
from pathlib import Path
import re
for p in Path('.').rglob('*'):
    if p.suffix not in ('.c', '.h'):
        continue
    s=p.read_text()
    for old,new in [('del_timer_sync','timer_delete_sync'),('del_timer','timer_delete'),('from_timer','timer_container_of')]:
        s=re.sub(r'\b'+old+r'\s*\(',new+'(',s)
    p.write_text(s)
# Respect the installer's bounded job count, including nested Kbuild reads.
p=Path('Makefile')
s,n=re.subn(r'^MAKEFLAGS \+=-j\$\(shell nproc\)\s*$', '', p.read_text(), flags=re.M)
assert n==1, 'Vendor parallelism directive changed'
p.write_text(s)
# Quiet from the earliest load; modprobe parameter also enforces the setting.
p=Path('aic8800_fdrv/rwnx_main.c')
s,n=re.subn(r'int aicwf_dbg_level = [^;]+;', 'int aicwf_dbg_level = LOGERROR|LOGINFO;',p.read_text())
assert n==1, 'Debug mask declaration changed'
p.write_text(s)
PY_TIMER
log 'Building all three modules against the running kernel headers.'
# Direct Kbuild invocation avoids the vendor Makefile forcing nproc jobs.
JOBS=${JOBS:-2}
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || die 'JOBS must be a positive integer.'
make -C "$KDIR" M="$DRV" ARCH=arm64 CONFIG_PLATFORM_UBUNTU=y CONFIG_PLATFORM_ALLWINNER=n CC="$CCBIN" HOSTCC="$CCBIN" -j"$JOBS" modules
for mod in aic8800_bsp aic8800_fdrv aic8800_btlpm; do
  ko=$DRV/$mod/$mod.ko
  [[ -s $ko ]] || die "Build did not produce $mod.ko"
  [[ $(modinfo -F vermagic "$ko") == "$KREL "* ]] || die "vermagic mismatch: $ko"
done
modinfo -F parm "$DRV/aic8800_fdrv/aic8800_fdrv.ko" | grep -q '^aicwf_dbg_level:' || die 'Missing debug parameter.'
modinfo -F parm "$DRV/aic8800_bsp/aic8800_bsp.ko" | grep -q '^aic_fw_path:' || die 'Missing firmware-path parameter.'
DTB=$RUN/stage/sun50i-h618-yx-h618-aic8801.dtb
python3 - "$BASE" "$DTB" <<'PY_DTB'
import subprocess as sp, sys
from pathlib import Path
base, out = sys.argv[1:]
Path(out).write_bytes(Path(base).read_bytes())
def cmd(*a): return sp.check_output(a,text=True).strip()
def get(n,p,t='x'): return cmd('fdtget','-t',t,out,n,p)
def props(n): return cmd('fdtget','-p',out,n).splitlines()
def children(n): return cmd('fdtget','-l',out,n).splitlines()
def put(n,p,*v,t='x'): sp.check_call(['fdtput','-t',t,out,n,p,*map(str,v)])
def delete(n,p):
    if p in props(n): sp.check_call(['fdtput','-d',out,n,p])
def walk(n='/'):
    yield n
    for c in children(n): yield from walk(n.rstrip('/')+'/'+c)
def cells(n,p): return [int(x,16) for x in get(n,p).split()]
def require(ok,msg):
    if not ok: raise SystemExit('DT validation failed: '+msg)
mmc='/soc/mmc@4021000'; pio='/soc/pinctrl@300b000'; uart='/soc/serial@5000400'
ns=list(walk()); handles={}
for n in ns:
    if 'phandle' in props(n): handles[cells(n,'phandle')[0]]=n
require('allwinner,sun50i-h618' in get('/','compatible','s'),'not H618')
require(all(n in ns for n in [mmc,pio,uart]),'controller paths differ')
pioh=cells(pio,'phandle')[0]
require(cells(pio,'#gpio-cells')==[3],'GPIO provider cell layout')
seq=handles[cells(mmc,'mmc-pwrseq')[0]]
require(get(seq,'compatible','s')=='mmc-pwrseq-simple','unexpected pwrseq')
require(cells(seq,'reset-gpios')==[pioh,6,18,1],'original Wi-Fi reset must be PG18 active-low')
vin=cells(mmc,'vmmc-supply')[0]; vq=cells(mmc,'vqmmc-supply')[0]
require(cells(handles[vin],'regulator-min-microvolt')==[3300000],'VMMC is not 3.3 V')
require(cells(handles[vq],'regulator-min-microvolt')==[1800000],'VQMMC is not 1.8 V')
# Preserve the original RTC clock provider and PG10 mux, verify wiring.
require(get(seq,'clock-names','s')=='ext_clock','missing external clock')
require(len(cells(seq,'clocks'))==2,'unexpected clock cells')
clkpin=handles[cells(seq,'pinctrl-0')[0]]
require(get(clkpin,'pins','s')=='PG10','32 kHz pin is not PG10')
uartpins=[]
for ph in cells(uart,'pinctrl-0'):
    uartpins+=get(handles[ph],'pins','s').split()
require(set(['PG6','PG7','PG8','PG9']).issubset(uartpins),'UART1 RTS/CTS pinmux missing')
if 'serial1' in props('/aliases'):
    require(get('/aliases','serial1','s')==uart,'serial1 maps to another UART')
else:
    put('/aliases','serial1',uart,t='s')
bt=uart+'/bluetooth'
require(bt in ns and 'brcm,' in get(bt,'compatible','s'),'expected Broadcom child absent')
put(bt,'status','disabled',t='s'); put(uart,'status','okay',t='s')
# Remove base properties with fdtput: overlay /delete-node/ does not remove
# an existing node when merged with fdtoverlay.
delete(seq,'reset-gpios')
for n in list(ns):
    if n==pio+'/wifi-reg-on-hog': sp.check_call(['fdtput','-r',out,n])
reg='/regulator-wifi-reg-on'
require(reg not in ns,'base DTB is already patched')
sp.check_call(['fdtput','-c',out,reg])
ph=max(handles)+1
put(reg,'compatible','regulator-fixed',t='s'); put(reg,'regulator-name','wifi-reg-on',t='s')
for p,val in [('regulator-min-microvolt',3300000),('regulator-max-microvolt',3300000),('startup-delay-us',200000),('off-on-delay-us',200000),('phandle',ph),('vin-supply',vin)]:
    put(reg,p,format(val,'x'))
put(reg,'gpio',format(pioh,'x'),'6','12','0'); put(reg,'enable-active-high')
put(mmc,'vmmc-supply',format(ph,'x')); put(mmc,'status','okay',t='s')
# AIC8801 BSP already selects 50 MHz. Cap the host to the same rate.
put(mmc,'max-frequency',format(50000000,'x'))
put(seq,'post-power-on-delay-ms',format(200,'x'))
require(cells(reg,'gpio')==[pioh,6,18,0],'PG18 regulator GPIO')
require(cells(mmc,'vmmc-supply')==[ph] and cells(mmc,'vqmmc-supply')==[vq],'supply references')
require('reset-gpios' not in props(seq),'reset-gpios remains')
require(not {'regulator-always-on','regulator-boot-on'} & set(props(reg)),'regulator must cycle')
require(get(bt,'status','s')=='disabled','Broadcom child still enabled')
print('DT validated: PG18 fixed regulator, 200 ms on/off, PG10 clock, UART1 RTS/CTS, Broadcom disabled.')

PY_DTB
dtc -I dtb -O dts -o "$RUN/stage/final.dts" "$DTB"
git -C "$SRC" diff --stat
log "Prepared source revision $REV and DTB from $BASE"
if [[ $PREPARE == 1 ]]; then
  log "PREPARE COMPLETE. Artifacts: $RUN; boot selection unchanged."
  exit 0
fi
# Record original files individually, including absence. Restore links as links.
# Package installation is not rolled back by this manifest.
: > "$RUN/files.jsonl"
backup() {
  python3 - "$RUN" "$1" <<'PY_BACKUP'
import json, os, shutil, sys
from pathlib import Path
run, name=sys.argv[1:]; p=Path(name)
records=Path(run,'files.jsonl')
if any(json.loads(x)['path']==name for x in records.read_text().splitlines()):
    raise SystemExit(0)
b=Path(run,'backup',name.lstrip('/')); b.parent.mkdir(parents=True,exist_ok=True)
exists=os.path.lexists(p)
if exists:
    if p.is_dir() and not p.is_symlink(): raise SystemExit('Refusing directory overwrite: '+name)
    shutil.copy2(p,b,follow_symlinks=False)
with records.open('a') as f: f.write(json.dumps({'path':name,'exists':exists})+'\n')
PY_BACKUP
}
putfile() {
  local src=$1 dest=$2 mode=${3:-644} tmp
  backup "$dest"
  mkdir -p "$(dirname "$dest")"
  tmp=$(mktemp "$(dirname "$dest")/.yx-install.XXXXXX")
  install -m "$mode" "$src" "$tmp"
  mv -fT "$tmp" "$dest"
}
# Save service state before masking/enabling anything.
for unit in aic8801-bluetooth.service aic8801-bluetooth-unblock.service bluetooth.service serial-getty@ttyS1.service; do
  state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
  printf '%s %s\n' "$unit" "${state:-not-found}" >> "$RUN/services.before"
done
cat > "$RUN/rollback.sh" <<'ROLLBACK'
#!/usr/bin/env bash
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root'; exit 1; }
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
# Run before making unrelated changes: rollback restores the saved file versions.
systemctl stop aic8801-bluetooth.service || true
python3 - "$HERE" <<'PY_RESTORE'
import json, os, shutil, sys
from pathlib import Path
r=Path(sys.argv[1])
for line in reversed((r/'files.jsonl').read_text().splitlines()):
    rec=json.loads(line); p=Path(rec['path'])
    if os.path.lexists(p): p.unlink()
    if rec['exists']:
        p.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(r/'backup'/str(p).lstrip('/'),p,follow_symlinks=False)
PY_RESTORE
while read -r unit state; do
  systemctl unmask "$unit" || true
  case "$state" in
    enabled) systemctl enable "$unit";;
    enabled-runtime) systemctl enable --runtime "$unit";;
    masked) systemctl mask "$unit";;
    masked-runtime) systemctl mask --runtime "$unit";;
    *) systemctl disable "$unit" 2>/dev/null || true;;
  esac
done < "$HERE/services.before"
systemctl daemon-reload
depmod -a "$(cat "$HERE/kernel-release")"
if command -v update-initramfs >/dev/null && [[ -f /boot/initrd.img-$(cat "$HERE/kernel-release") ]]; then
  update-initramfs -u -k "$(cat "$HERE/kernel-release")"
fi
sync
echo 'Saved files restored. Packages remain installed. Reboot to use the restored modules/DTB.'
ROLLBACK
chmod 700 "$RUN/rollback.sh"
printf '%s\n' "$KREL" > "$RUN/kernel-release"
log "Installing staged artifacts; rollback: sudo bash $RUN/rollback.sh"
MODDIR=/lib/modules/$KREL/updates/yx-h618-aic8801
for mod in aic8800_bsp aic8800_fdrv aic8800_btlpm; do
  putfile "$DRV/$mod/$mod.ko" "$MODDIR/$mod.ko"
done
# Copy only this chipset's firmware directory, preserving the required flat path.
while IFS= read -r -d '' f; do
  putfile "$f" "/vendor/etc/firmware/${f#"$FW/"}"
done < <(find "$FW" -type f -print0)
cat > "$RUN/stage/aic8801.conf" <<'EOF'
options aic8800_bsp aic_fw_path=/vendor/etc/firmware
options aic8800_fdrv aicwf_dbg_level=3
EOF
putfile "$RUN/stage/aic8801.conf" /etc/modprobe.d/aic8801.conf
printf 'aic8800_bsp\naic8800_fdrv\n' > "$RUN/stage/wifi.conf"
printf 'aic8800_btlpm\n' > "$RUN/stage/bt.conf"
putfile "$RUN/stage/wifi.conf" /etc/modules-load.d/aic8801-wifi.conf
putfile "$RUN/stage/bt.conf" /etc/modules-load.d/aic8801-bt.conf
cat > "$RUN/stage/aic8801-hci-ready" <<'EOF'
#!/usr/bin/env python3
"""Wait for the UART1 HCI, then unblock and power that controller (bounded)."""
import pathlib, subprocess, time, sys
for attempt in range(30):
    for p in pathlib.Path('/sys/class/bluetooth').glob('hci[0-9]*'):
        # Match the UART device ancestry, never select an unrelated USB adapter.
        if 'ttyS1' not in p.resolve().parts:
            continue
        idx=p.name[3:]
        for rf in p.glob('rfkill*'):
            try: (rf/'soft').write_text('0\n')
            except FileNotFoundError: pass
        result=subprocess.run(['btmgmt','--index',idx,'power','on'],timeout=5)
        if result.returncode==0:
            print('AIC8801 '+p.name+' powered on',flush=True)
            sys.exit(0)
    time.sleep(1)
raise SystemExit('AIC8801 UART1 HCI failed to become ready; inspect journalctl -u aic8801-bluetooth')
EOF
putfile "$RUN/stage/aic8801-hci-ready" /usr/local/sbin/aic8801-hci-ready 755
cat > "$RUN/stage/aic8801-bluetooth.service" <<'EOF'
[Unit]
Description=AIC8801 Bluetooth UART1 (YX-H618)
Requires=dev-ttyS1.device
After=dev-ttyS1.device systemd-modules-load.service systemd-rfkill.service
Before=bluetooth.service
Wants=bluetooth.service
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
Type=simple
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStartPre=/sbin/modprobe aic8800_bsp
ExecStartPre=/sbin/modprobe aic8800_btlpm
ExecStartPre=/usr/sbin/rfkill unblock bluetooth
ExecStart=/usr/bin/hciattach -n -s 1500000 /dev/ttyS1 any 1500000 flow nosleep
ExecStartPost=/usr/local/sbin/aic8801-hci-ready
Restart=on-failure
RestartSec=3
TimeoutStartSec=180
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF
# Resolve tool locations for both merged-/usr and older Ubuntu/Debian layouts.
sed -i "s|/sbin/modprobe|$(command -v modprobe)|g; s|/usr/sbin/rfkill|$(command -v rfkill)|g; s|/usr/bin/hciattach|$(command -v hciattach)|g" "$RUN/stage/aic8801-bluetooth.service"
putfile "$RUN/stage/aic8801-bluetooth.service" /etc/systemd/system/aic8801-bluetooth.service
cat > "$RUN/stage/patch-blueman-devices" <<'PY_BLUEMAN'
#!/usr/bin/env python3
import ast, hashlib, os, shutil, tempfile
from pathlib import Path
p=Path('/usr/lib/python3/dist-packages/blueman/plugins/applet/StandardItems.py')
if not p.exists():
    print('Blueman patch: not installed; hook retained for future installation.')
    raise SystemExit(0)
old='''    def on_devices(self) -> None:
        m = ManagerService()
        m.startstop()
'''
new='''    def on_devices(self) -> None:
        launch("blueman-manager", name=_("Bluetooth Devices"))
'''
s=p.read_text()
if new in s:
    print('Blueman patch: already applied.'); raise SystemExit(0)
if s.count(old)!=1:
    print('Blueman patch: version differs or upstream fixed; left untouched.'); raise SystemExit(0)
tree=ast.parse(s)
if not any(isinstance(n,ast.ImportFrom) and n.module=='blueman.Functions' and any(a.name=='launch' for a in n.names) for n in ast.walk(tree)):
    raise SystemExit('Blueman patch: launch import unavailable; left untouched.')
s2=s.replace(old,new,1); ast.parse(s2)
backup=p.with_name(p.name+'.pre-yx-'+hashlib.sha256(s.encode()).hexdigest()[:16])
if not backup.exists(): shutil.copy2(p,backup)
fd,tmp=tempfile.mkstemp(prefix='.yx-blueman-',dir=p.parent)
try:
    with os.fdopen(fd,'w') as f: f.write(s2)
    shutil.copystat(p,tmp)
    os.replace(tmp,p)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
print('Blueman patch: applied; backup: '+str(backup))
PY_BLUEMAN
putfile "$RUN/stage/patch-blueman-devices" /usr/local/sbin/patch-blueman-devices 755
cat > "$RUN/stage/99-blueman-local-patch" <<'EOF'
DPkg::Post-Invoke {
    "/usr/local/sbin/patch-blueman-devices || true";
};
EOF
putfile "$RUN/stage/99-blueman-local-patch" /etc/apt/apt.conf.d/99-blueman-local-patch
backup /usr/lib/python3/dist-packages/blueman/plugins/applet/StandardItems.py
/usr/local/sbin/patch-blueman-devices
# Installer does not force a desktop/Blueman package onto a server image.
# The hook applies the workaround whenever Blueman is later installed via apt.
depmod -a "$KREL"
for mod in aic8800_bsp aic8800_fdrv aic8800_btlpm; do
  [[ $(readlink -f "$(modinfo -k "$KREL" -F filename "$mod")") == "$(readlink -f "$MODDIR/$mod.ko")" ]] || die "Another module overrides $mod; inspect depmod/DKMS configuration. Boot selection has not changed."
done
systemd-analyze verify /etc/systemd/system/aic8801-bluetooth.service
# Update initramfs so stale AIC modules/configurations cannot win early boot.
if command -v update-initramfs >/dev/null && [[ -f /boot/initrd.img-$KREL ]]; then
  update-initramfs -u -k "$KREL"
fi
putfile "$DTB" /boot/dtb/allwinner/sun50i-h618-yx-h618-aic8801.dtb
# Keep startup changes for next boot; do not unload the user's current Wi-Fi.
backup /etc/systemd/system/serial-getty@ttyS1.service
systemctl mask serial-getty@ttyS1.service
if systemctl cat aic8801-bluetooth-unblock.service >/dev/null 2>&1; then
  systemctl disable aic8801-bluetooth-unblock.service
fi
systemctl daemon-reload
systemctl enable aic8801-bluetooth.service bluetooth.service
python3 - /boot/armbianEnv.txt "$RUN/stage/armbianEnv.txt" <<'PY_ENV'
from pathlib import Path
import sys
src,out=map(Path,sys.argv[1:])
lines=src.read_text().splitlines()
key='fdtfile=allwinner/sun50i-h618-yx-h618-aic8801.dtb'
lines=[x for x in lines if not x.startswith('fdtfile=')]+[key]
out.write_text('\n'.join(lines)+'\n')
PY_ENV
# Commit boot selection LAST, after every critical operation succeeded.
putfile "$RUN/stage/armbianEnv.txt" /boot/armbianEnv.txt
sync
log "SUCCESS: installed for $KREL. Source revision: $REV"
log "Backup/log/source: $RUN"
log "Rollback (before unrelated changes): sudo bash $RUN/rollback.sh"
log 'Reboot required: sudo reboot. If the chip was previously stuck, power off and disconnect power for 10 seconds once.'
log 'After reboot: iw dev; bluetoothctl list; systemctl status aic8801-bluetooth.service'
log 'After changing kernels, rerun this installer with exact new headers. Hardware success is determined after boot, not by this build result.'
