#!/bin/bash
# Runs INSIDE Debian chroot via bootstrap.sh. Do NOT run directly.
# MCLH-01 setup v3.2 - full reproducible Phase A build.
# pip via get-pip (no ensurepip). All HA deps pinned to the 2023.1 era.
# Clean start scripts (no chr() obfuscation). ASCII. Fails loud (die).

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LD_PRELOAD=""
die() { echo "FATAL: $*"; exit 1; }

echo "--- setup_chroot.sh v3.2 start ---"

# 1. Network -----------------------------------------------------
echo "[1/9] Network..."
echo "nameserver 8.8.8.8"  > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
python3 -c "
import re
p='/etc/nsswitch.conf'
try:
    d=open(p).read(); open(p,'w').write(re.sub(r'^hosts:.*','hosts: files dns',d,flags=re.M))
except FileNotFoundError: pass
"
echo "[1/9] OK"

# 2. APT + hold python3.9 ----------------------------------------
echo "[2/9] APT config..."
mkdir -p /etc/apt/apt.conf.d
echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99sandbox
for method in http https; do
    if [ -f /usr/lib/apt/methods/$method ] && [ ! -f /usr/lib/apt/methods/${method}.real ]; then
        mv /usr/lib/apt/methods/$method /usr/lib/apt/methods/${method}.real
    fi
    if [ -f /usr/lib/apt/methods/${method}.real ]; then
        python3 -c "
content='''#!/usr/bin/python3
import os
os.setgroups([0, 3003, 3004])
os.execv('/usr/lib/apt/methods/${method}.real', ['/usr/lib/apt/methods/${method}.real'])
'''
open('/usr/lib/apt/methods/${method}','w').write(content)
import os; os.chmod('/usr/lib/apt/methods/${method}', 0o755)
"
    fi
done
sed -i '/rcn-ee/d' /etc/apt/sources.list 2>/dev/null || true
apt-get update -q 2>&1 | tail -3
apt-mark hold python3.9 python3.9-minimal libpython3.9-stdlib libpython3.9-minimal 2>/dev/null || true
echo "[2/9] OK (python3.9 held)"

# 3. deb-extract helper ------------------------------------------
echo "[3/9] deb-extract helper..."
cat > /usr/local/bin/deb-extract << 'PYEOF'
#!/usr/bin/python3
import sys, os, glob, io, tarfile, subprocess
WORK="/tmp/debdl"; os.makedirs(WORK, exist_ok=True); os.chdir(WORK)
def ar_members(path):
    out={}
    with open(path,"rb") as f:
        assert f.read(8)==b"!<arch>\n","not ar: %s"%path
        while True:
            hdr=f.read(60)
            if len(hdr)<60: break
            name=hdr[0:16].decode().strip(); size=int(hdr[48:58].decode().strip())
            data=f.read(size)
            if size%2==1: f.read(1)
            out[name.rstrip("/")]=data
    return out
def extract_deb(deb):
    m=ar_members(deb); key=next(k for k in m if k.startswith("data.tar")); raw=m[key]
    if key.endswith(".xz"):
        import lzma; raw=lzma.decompress(raw)
    elif key.endswith(".gz"):
        import gzip; raw=gzip.decompress(raw)
    tarfile.open(fileobj=io.BytesIO(raw)).extractall("/")
    print("extracted:", os.path.basename(deb))
for pkg in sys.argv[1:]:
    subprocess.run(["apt-get","download",pkg])
    debs=sorted(glob.glob("%s/%s_*.deb"%(WORK,pkg)))
    if not debs: print("MISSING:",pkg); continue
    extract_deb(debs[-1])
PYEOF
chmod 755 /usr/local/bin/deb-extract
echo "[3/9] OK"

# 4. system distutils/setuptools/pkg_resources -------------------
echo "[4/9] System distutils/setuptools via deb-extract..."
deb-extract python3-distutils python3-lib2to3 python3-setuptools python3-pkg-resources
python3 -c "import distutils.cmd, distutils.core, setuptools, pkg_resources; print('system pkgs OK')" \
    || die "system distutils/setuptools missing"
echo "[4/9] OK"

# 5. pip via get-pip (rootfs has no pip/ensurepip) ---------------
echo "[5/9] pip via get-pip.py..."
get_getpip() {
    python3 -c "
import urllib.request as u, sys
for url in ['https://bootstrap.pypa.io/pip/3.9/get-pip.py','https://bootstrap.pypa.io/get-pip.py']:
    try:
        open('/tmp/get-pip.py','wb').write(u.urlopen(url,timeout=60).read()); print('got',url); sys.exit(0)
    except Exception as e: print('fail',url,e)
sys.exit(1)
" || die "cannot download get-pip.py"
}
if ! python3 -m pip --version 2>/dev/null; then
    get_getpip
    python3 /tmp/get-pip.py "pip==24.0" || die "get-pip failed"
fi
python3 -m pip --version || die "pip not working"
echo "[5/9] OK"

# 6. venv /opt/ha ------------------------------------------------
echo "[6/9] venv /opt/ha..."
rm -rf /opt/ha
python3 -m venv /opt/ha --without-pip || die "venv creation failed"
[ -f /tmp/get-pip.py ] || get_getpip
/opt/ha/bin/python3 /tmp/get-pip.py "pip==24.0" || die "venv get-pip failed"
/opt/ha/bin/pip --version || die "venv pip not working"
source /opt/ha/bin/activate
/opt/ha/bin/pip install "setuptools==67.8.0" wheel || die "venv setuptools failed"
/opt/ha/bin/python3 -c "import pkg_resources; print('venv pkg_resources OK')" || die "venv pkg_resources missing"
echo "[6/9] OK"

# 7. pillow (piwheels) + psutil ----------------------------------
echo "[7/9] pillow + psutil from piwheels..."
/opt/ha/bin/pip install --index-url https://www.piwheels.org/simple --only-binary :all: pillow || die "pillow failed"
/opt/ha/bin/pip install --index-url https://www.piwheels.org/simple psutil || die "psutil failed"
/opt/ha/bin/python3 -c "import PIL; print('pillow', PIL.__version__)" || die "pillow import failed"
echo "[7/9] OK"

# 8. Home Assistant 2023.1.7 -------------------------------------
echo "[8/9] Home Assistant install (10-15 min)..."
/opt/ha/bin/pip install "homeassistant==2023.1.7" || die "HA install failed"
/opt/ha/bin/pip uninstall -y numpy 2>/dev/null || true
/opt/ha/bin/pip install "setuptools==67.8.0" --force-reinstall
[ -f /opt/ha/bin/hass ] || die "hass binary missing"
echo "[8/9] Home Assistant installed"

# 8b. HA runtime deps --skip-pip won't install, ALL pinned to 2023.1 era.
#     latest breaks old HA: aiohttp_cors>=0.8 needs aiohttp>=3.9;
#     sqlalchemy 2.0 breaks recorder. libopenjp2 = .so for pillow/image_upload.
echo "[8b] HA runtime deps (pinned)..."
deb-extract libopenjp2-7
/opt/ha/bin/pip install \
    "aiohttp_cors==0.7.0" \
    "sqlalchemy==1.4.44" \
    janus fnvhash \
    "home-assistant-frontend==20230110.0" \
    || die "HA runtime deps failed"
# re-pin LAST (other installs bump these; HA needs exact)
/opt/ha/bin/pip install "aiohttp==3.8.1" "yarl==1.8.1" || die "aiohttp/yarl re-pin failed"
/opt/ha/bin/python3 -c "import aiohttp,yarl,sqlalchemy,aiohttp_cors,janus,fnvhash,hass_frontend; print('deps OK aiohttp',aiohttp.__version__,'sqlalchemy',sqlalchemy.__version__)" \
    || die "HA deps verify failed"
echo "[8b] OK"

# 9. Config + start scripts + cleanup ----------------------------
echo "[9/9] Config + start scripts..."
mkdir -p /opt/ha/config
if [ ! -f /opt/ha/config/configuration.yaml ]; then
cat > /opt/ha/config/configuration.yaml << 'CFGEOF'
# Home Assistant - MCLH-01
homeassistant:
  name: Home
  latitude: 55.75
  longitude: 37.62
  elevation: 0
  unit_system: metric
  time_zone: Europe/Moscow
  country: RU
  currency: RUB
  language: ru
frontend:
http:
api:
automation: []
script: []
scene: []
logger:
  default: warning
  logs:
    homeassistant.components.cloud: critical
    homeassistant.components.mobile_app: critical
    homeassistant.components.hardware: critical
CFGEOF
echo "configuration.yaml created (RU/RUB/ru)"
fi

# start_debian.sh - clean, PATH+HOME set, no chr()
cat > /tmp/start_debian.sh << 'DBGEOF'
#!/system/bin/sh
echo 0 > /sys/fs/selinux/enforce
mount -t proc proc /data/debian/proc 2>/dev/null
mount -t sysfs sysfs /data/debian/sys 2>/dev/null
mount -o bind /dev /data/debian/dev 2>/dev/null
mount -o bind /dev/pts /data/debian/dev/pts 2>/dev/null
/data/busybox chroot /data/debian /usr/bin/python3 -c "import os; os.setgroups([0,3003,3004]); os.environ['LD_PRELOAD']=''; os.environ['PATH']='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'; os.environ['HOME']='/root'; os.execv('/bin/bash',['/bin/bash'])"
DBGEOF
chmod 755 /tmp/start_debian.sh

# start_ha.sh - clean, --skip-pip, PATH+HOME set, no chr()
cat > /tmp/start_ha.sh << 'HAEOF'
#!/system/bin/sh
sleep 15
echo 0 > /sys/fs/selinux/enforce
mount -t proc proc /data/debian/proc 2>/dev/null
mount -t sysfs sysfs /data/debian/sys 2>/dev/null
mount -o bind /dev /data/debian/dev 2>/dev/null
mount -o bind /dev/pts /data/debian/dev/pts 2>/dev/null
/data/busybox chroot /data/debian /usr/bin/python3 -c "import os; os.setgroups([0,3003,3004]); os.environ['LD_PRELOAD']=''; os.environ['PATH']='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'; os.environ['HOME']='/root'; os.execv('/opt/ha/bin/hass',['hass','--skip-pip','-c','/opt/ha/config'])" >> /data/ha.log 2>&1
HAEOF
chmod 755 /tmp/start_ha.sh

# ha-restart helper (manual debug: kill stale hass + start)
cat > /usr/local/bin/ha-restart << 'HREOF'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LD_PRELOAD=""
python3 -c "
import os,glob,signal
me=os.getpid()
for c in glob.glob('/proc/[0-9]*/cmdline'):
    try:
        pid=int(c.split('/')[2])
        if pid==me: continue
        if b'hass' in open(c,'rb').read(): os.kill(pid,signal.SIGKILL)
    except Exception: pass
print('killed stale hass')
"
sleep 2
exec /opt/ha/bin/hass --config /opt/ha/config --skip-pip
HREOF
chmod 755 /usr/local/bin/ha-restart

# cleanup (avoid out-of-space)
rm -rf /tmp/debdl /tmp/pip-* /tmp/get-pip.py 2>/dev/null || true
/opt/ha/bin/pip cache purge 2>/dev/null || true
rm -f /var/cache/apt/archives/*.deb 2>/dev/null || true
echo "[9/9] OK"

echo ""
echo "--- setup_chroot.sh v3.2 done ---"
echo "Manual debug: ha-restart   (kills stale hass + starts, inside chroot)"