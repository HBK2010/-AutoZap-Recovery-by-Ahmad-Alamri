#!/bin/sh
# ================================================================
#   AutoZap Recovery v1.1 - Installer
#   Designed & Developed by: Ahmad Alamri
#   (C) 2026 Ahmad Alamri - All Rights Reserved
#   OpenATV / OpenPLi / OpenBH / OpenViX / Egami / PurE2 / VTi /
#   OpenSPA / DreamOS  -  Python 2.7 & Python 3.x
# ================================================================
PLUGIN_DIR="/usr/lib/enigma2/python/Plugins/Extensions/AutoZap_AhmadAlamri"

echo ""
echo "=============================================="
echo "   AutoZap Recovery v1.1"
echo "   Designed & Developed by: Ahmad Alamri"
echo "=============================================="

if [ ! -d /usr/lib/enigma2/python/Plugins/Extensions ]; then
    echo "!!! Enigma2 was not found on this receiver. Aborting."
    exit 1
fi

# --- Python of this image ---
PY=""
if ls -d /usr/lib/python3* >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    PY=python3
elif command -v python >/dev/null 2>&1; then
    PY=python
elif command -v python3 >/dev/null 2>&1; then
    PY=python3
fi
echo ">>> Python: ${PY:-not found (skipping checks)}"

# --- remove any old version (incl. read-only / compiled-only builds) ---
if [ -d "$PLUGIN_DIR" ]; then
    echo ">>> Removing old version..."
    command -v chattr >/dev/null 2>&1 && chattr -R -i "$PLUGIN_DIR" >/dev/null 2>&1
    chmod -R u+w "$PLUGIN_DIR" >/dev/null 2>&1
    rm -rf "$PLUGIN_DIR"
fi
rm -f /tmp/*autozap*.pyc /tmp/autozap_restart.sh >/dev/null 2>&1
mkdir -p "$PLUGIN_DIR" || { echo "!!! Cannot create $PLUGIN_DIR"; exit 1; }

az_b64() {
    # $1 = base64 file, $2 = output file
    if [ -n "$PY" ] && $PY -c "import base64,sys; d=open(sys.argv[1],'rb').read(); open(sys.argv[2],'wb').write(base64.b64decode(d))" "$1" "$2" >/dev/null 2>&1; then
        :
    elif base64 -d "$1" > "$2" 2>/dev/null; then
        :
    elif openssl base64 -d -in "$1" -out "$2" >/dev/null 2>&1; then
        :
    else
        rm -f "$2"
        echo "!!! Could not write $(basename "$2") (plugin still works without it)"
    fi
    rm -f "$1"
}

echo ">>> Writing plugin files..."
cat > "$PLUGIN_DIR/__init__.py" << 'AZ_EOF'
# -*- coding: utf-8 -*-
# AutoZap Recovery
# Designed and Developed by: Ahmad Alamri
# (C) 2026 Ahmad Alamri - All Rights Reserved
AZ_EOF

cat > "$PLUGIN_DIR/plugin.py" << 'AZ_EOF'
# -*- coding: utf-8 -*-
# ========================================================================
#  Plugin Name : AutoZap Recovery
#  Version     : 1.1
#  Designed and Developed by : Ahmad Alamri
#  Copyright   : (C) 2026 Ahmad Alamri - All Rights Reserved
#  Description : Automatic recovery of frozen / dead channels on Enigma2
#  Compatible  : OpenATV, OpenPLi, OpenBH, OpenViX, Egami, PurE2, VTi,
#                OpenSPA, DreamOS  -  Python 2.7 and Python 3.x
# ========================================================================
#
#  Detection (a source is used only after it has proven to work on
#  this receiver, so healthy channels are never touched):
#    1. Decoder PTS   : picture progress counter stops moving.
#    2. IPTV position : play position of the stream stops moving.
#    3. ECM watch     : softcam stops answering (ecm.info not updated).
#    4. No video      : channel never produced a picture after zapping.
#
#  Recovery modes: restart the same channel, zap away and back, or
#  smart (restart first, then zap). Optional jump to the next channel
#  after all attempts fail.
# ========================================================================

import os
import time

from enigma import (eTimer, getDesktop, iPlayableService, iServiceInformation,
                    eServiceCenter, eServiceReference)
try:
    from enigma import iFrontendInformation
except ImportError:
    iFrontendInformation = None

from Components.ActionMap import ActionMap
from Components.ConfigList import ConfigListScreen
from Components.Label import Label
from Components.Sources.StaticText import StaticText
from Components.config import (config, configfile, ConfigSubsection, ConfigText,
                               ConfigSelection, ConfigInteger, getConfigListEntry)
from Plugins.Plugin import PluginDescriptor
from Screens.MessageBox import MessageBox
from Screens.Screen import Screen

VERSION = "1.1"
PLUGIN_TITLE = "AutoZap Recovery v1.1"
AUTHOR = "Ahmad Alamri"
PLUGIN_PATH = os.path.dirname(os.path.abspath(__file__))
LOG_FILE = "/tmp/autozap.log"
LOG_MAX_BYTES = 256 * 1024
POLL_MS = 500                      # real-time sampling (2 checks per second)
FAST_FREEZE_SEC = 2.5              # frozen picture detected after 2.5 s
IPTV_FREEZE_SEC = 5.0              # IPTV needs a little buffering tolerance
STABLE_RESET_SEC = 30
RESTART_GAP_MS = (250, 700, 1500)  # stop -> play gap per attempt
ZAP_HOLD_MS = (1200, 2000, 3000)   # time on the other channel per attempt
AUTO_COOLDOWN = (20, 40, 90, 180, 300)
PTS_PATHS = ("/proc/stb/vmpeg/0/pts", "/proc/stb/video/pts")
ECM_PATHS = ("/tmp/ecm.info", "/tmp/ecm0.info")
IPTV_TYPES = (4097, 5001, 5002, 8193, 8739)
RADIO_SERVICE_TYPES = (0x02, 0x0A)
PAGE_LINES = 14                    # lines per page in log / diagnostics

# ------------------------------------------------------------------------
# Configuration  (all choices are re-labelled when the language changes)
# ------------------------------------------------------------------------
config.plugins.autozap_alamri = ConfigSubsection()
cfg = config.plugins.autozap_alamri
cfg.language = ConfigSelection(default="auto", choices=[
    ("auto", "Box language / لغة الجهاز"), ("ar", "العربية"), ("en", "English")])


def is_arabic():
    lang = cfg.language.value
    if lang == "auto":
        try:
            return str(config.osd.language.value).lower().startswith("ar")
        except Exception:
            return False
    return lang == "ar"


def T(ar, en):
    return ar if is_arabic() else en


def choice_spec():
    def sec(v):
        return "%d %s" % (v, T("ثانية", "sec"))

    def mins(v):
        return "%d %s" % (v, T("دقيقة", "min"))
    yes_no = [("true", T("نعم", "Yes")), ("false", T("لا", "No"))]
    return [
        ("language", "auto", [("auto", T("لغة الجهاز (تلقائي)", "Box language (auto)")),
                              ("ar", "العربية"), ("en", "English")]),
        ("enabled", "true", yes_no),
        ("scope", "all", [("crypted", T("القنوات المشفرة فقط", "Encrypted channels only")),
                              ("all", T("كل القنوات", "All channels"))]),
        ("iptv", "true", yes_no),
        ("mode", "restart", [("restart", T("إعادة تشغيل نفس القناة", "Restart the same channel")),
                             ("smart", T("ذكي: إعادة تشغيل ثم تقليب", "Smart: restart, then zap")),
                           ("zap", T("تقليب لقناة أخرى ثم العودة", "Zap away and back"))]),
        ("freeze_time", "auto", [("auto", T("ذكي فائق السرعة (2.5 ث)", "Smart ultra-fast (2.5 s)"))] +
                                [(str(v), sec(v)) for v in (2, 3, 4, 5, 6, 8, 10)]),
        ("grace", "auto", [("auto", T("ذكي - يتعلم زمن كل قناة", "Smart - learns each channel"))] +
                          [(str(v), sec(v)) for v in (3, 4, 5, 6, 8, 10, 15)]),
        ("on_fail", "stay", [("stay", T("البقاء على القناة", "Stay on the channel")),
                             ("next", T("الانتقال للقناة التالية", "Go to the next channel"))]),
        ("cooldown", "auto", [("auto", T("تلقائي متدرج (20 ث ثم أطول)", "Auto progressive (20 s, then longer)")),
                              ("0", T("لا (حتى تغيير القناة)", "Never (until zap)"))] +
                             [(str(v), mins(v)) for v in (1, 2, 5, 10)]),
        ("ecm_watch", "true", yes_no),
        ("check_net", "true", yes_no),
        ("notify", "toast", [("toast", T("إشعار البلجن", "Plugin toast")),
                             ("popup", T("رسالة النظام", "System popup")),
                             ("off", T("بدون إشعار", "Off"))]),
        ("debug", "false", yes_no),
    ]


for _name, _default, _choices in choice_spec():
    if _name != "language":
        setattr(cfg, _name, ConfigSelection(default=_default, choices=_choices))
cfg.max_retries = ConfigInteger(default=5, limits=(1, 100))
cfg.excluded = ConfigText(default="", fixed_size=False)
cfg.hw_pts = ConfigText(default="", fixed_size=False)     # receiver model where PTS was verified
cfg.hw_video = ConfigText(default="", fixed_size=False)   # receiver model where video size was verified
cfg.hw_ecm = ConfigText(default="", fixed_size=False)     # receiver model where ecm.info was verified


def relabel():
    """Translate every choice label for the current language.

    The elements are re-created (value and saved state kept) instead of
    using setChoices(), because several images cache the old labels.
    """
    for name, default, choices in choice_spec():
        old = getattr(cfg, name, None)
        keys = [c[0] for c in choices]
        value = old.value if old is not None else default
        saved = getattr(old, "saved_value", None) if old is not None else None
        try:
            new = ConfigSelection(default=default, choices=choices)
            setattr(cfg, name, new)
            if saved is not None:
                new.saved_value = saved
            new.value = value if value in keys else default
        except Exception:
            pass


relabel()


def on(element):
    return element.value == "true"


def copyright_text():
    return T("تصميم وتطوير: %s  |  جميع الحقوق محفوظة (C) 2026" % AUTHOR,
             "Designed & Developed by %s  |  (C) 2026 All Rights Reserved" % AUTHOR)


# ------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------
def log(msg):
    try:
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > LOG_MAX_BYTES:
            os.rename(LOG_FILE, LOG_FILE + ".1")
        line = "%s  %s\n" % (time.strftime("%m-%d %H:%M:%S"), msg)
        if not isinstance(line, bytes):
            line = line.encode("utf-8", "ignore")
        with open(LOG_FILE, "ab") as f:
            f.write(line)
    except Exception:
        pass


def debug(msg):
    if on(cfg.debug):
        log("[debug] %s" % msg)


def read_log_tail(max_lines=200):
    try:
        with open(LOG_FILE, "rb") as f:
            data = f.read()
        if not isinstance(data, str):
            data = data.decode("utf-8", "ignore")
        lines = data.strip().splitlines()[-max_lines:]
        lines.reverse()
        return "\n".join(lines)
    except Exception:
        return ""


def has_default_route():
    """True if a default gateway exists. Unknown state -> True (never block)."""
    try:
        with open("/proc/net/route") as f:
            for line in f.readlines()[1:]:
                parts = line.split()
                if len(parts) > 3 and parts[1] == "00000000" and int(parts[3], 16) & 1:
                    return True
        return False
    except Exception:
        return True


def ecm_mtime():
    newest = None
    for path in ECM_PATHS:
        try:
            m = os.stat(path).st_mtime
            if newest is None or m > newest:
                newest = m
        except (IOError, OSError):
            continue
    return newest


def read_pts():
    for path in PTS_PATHS:
        try:
            with open(path) as f:
                value = f.read().strip()
            if value:
                return value, path
        except (IOError, OSError):
            continue
    return None, None


def box_model():
    for path in ("/proc/stb/info/vumodel", "/proc/stb/info/boxtype", "/proc/stb/info/model",
                 "/proc/stb/info/gbmodel", "/etc/hostname"):
        try:
            with open(path) as f:
                value = f.readline().strip()
            if value:
                return value
        except (IOError, OSError):
            continue
    return "enigma2"


def connect_timer(timer, fnc, keep):
    try:
        timer.callback.append(fnc)
    except AttributeError:          # DreamOS / newer enigma
        keep.append(timer.timeout.connect(fnc))


def ref_key(ref_str):
    return ":".join((ref_str or "").split(":")[:11])


def excluded_keys():
    return [k for k in cfg.excluded.value.split("|") if k]


def save_excluded(keys):
    cfg.excluded.value = "|".join(keys)
    cfg.excluded.save()
    configfile.save()


def parental_control_active():
    for path in (("ParentalControl", "configured"), ("ParentalControl", "servicepinactive")):
        try:
            if getattr(getattr(config, path[0]), path[1]).value:
                return True
        except Exception:
            pass
    return False


def infobar():
    try:
        from Screens.InfoBar import InfoBar
        return InfoBar.instance
    except Exception:
        return None


def play_ref(nav, ref):
    try:
        return nav.playService(ref, checkParentalControl=False)
    except TypeError:
        return nav.playService(ref)


# ------------------------------------------------------------------------
# Skin helpers
# ------------------------------------------------------------------------
C_BG = "#000b1a2e"
C_PANEL = "#00102440"
C_GOLD = "#00f0a500"
C_CYAN = "#0019c3e6"
C_TEXT = "#00ffffff"
C_DIM = "#009fb3c8"


def skin_scale():
    try:
        width = getDesktop(0).size().width()
    except Exception:
        width = 1280
    return max(0.55, width / 1280.0)


def logo_file(k):
    path = os.path.join(PLUGIN_PATH, "logo_fhd.png" if k >= 1.4 else "logo.png")
    return path if os.path.exists(path) else None


def logo_size(k):
    return 105 if k >= 1.4 else 70


def align():
    return "right" if is_arabic() else "left"


def _button_row(z, y, h, font):
    colors = (("key_red", "#00b3261e"), ("key_green", "#00188a2e"),
              ("key_yellow", "#00b58900"), ("key_blue", "#001c5fb8"))
    out = []
    width, gap, x0 = 235, 20, 20
    for i, (name, col) in enumerate(colors):
        x = x0 + i * (width + gap)
        out.append('<eLabel position="%d,%d" size="%d,%d" backgroundColor="%s" zPosition="1" />'
                   % (z(x), z(y + h - 5), z(width), max(2, z(5)), col))
        out.append('<widget source="%s" render="Label" position="%d,%d" size="%d,%d" font="Regular;%d" '
                   'halign="center" valign="center" foregroundColor="%s" backgroundColor="%s" '
                   'transparent="1" zPosition="2" />'
                   % (name, z(x), z(y), z(width), z(h - 5), z(font), C_TEXT, C_BG))
    return "\n  ".join(out)


def _header(z, W):
    k = skin_scale()
    logo = logo_file(k)
    size = logo_size(k)
    parts = [
        '<eLabel position="0,0" size="%d,%d" backgroundColor="%s" zPosition="0" />' % (z(W), z(80), C_BG),
        '<eLabel position="0,%d" size="%d,%d" backgroundColor="%s" zPosition="1" />'
        % (z(80), z(W), max(2, z(3)), C_GOLD),
        '<widget source="title" render="Label" position="%d,%d" size="%d,%d" font="Regular;%d" '
        'foregroundColor="%s" backgroundColor="%s" transparent="1" valign="center" zPosition="2" />'
        % (z(100), z(6), z(W - 330), z(42), z(30), C_TEXT, C_BG),
        '<widget source="subtitle" render="Label" position="%d,%d" size="%d,%d" font="Regular;%d" '
        'foregroundColor="%s" backgroundColor="%s" transparent="1" valign="center" zPosition="2" />'
        % (z(100), z(48), z(W - 330), z(26), z(18), C_GOLD, C_BG),
    ]
    if logo and size + z(15) <= z(100) and size <= z(80):
        parts.append('<ePixmap position="%d,%d" size="%d,%d" pixmap="%s" zPosition="2" />'
                     % (z(15), (z(80) - size) // 2, size, size, logo))
    return "\n  ".join(parts)


def _footer(z, W):
    return """<eLabel position="0,%d" size="%d,%d" backgroundColor="%s" zPosition="1" />
  %s
  <widget source="copyright" render="Label" position="0,%d" size="%d,%d" font="Regular;%d" halign="center" valign="center" foregroundColor="%s" backgroundColor="%s" transparent="1" zPosition="2" />""" % (
        z(528), z(W), max(1, z(2)), C_GOLD, _button_row(z, 538, 44, 20),
        z(588), z(W), z(28), z(17), C_GOLD, C_BG)


def _zfunc():
    k = skin_scale()

    def z(v):
        return int(round(v * k))
    return z


def setup_skin():
    z = _zfunc()
    W, H = 1040, 620
    return """
<screen name="AutoZapSetupV11" position="center,center" size="%(w)d,%(h)d" flags="wfNoBorder" backgroundColor="%(bg)s" title="AutoZap Recovery">
  %(header)s
  <widget name="badge_on" position="%(bx)d,%(by)d" size="%(bw)d,%(bh)d" font="Regular;%(bf)d" halign="center" valign="center" foregroundColor="#00ffffff" backgroundColor="#00188a2e" zPosition="3" />
  <widget name="badge_off" position="%(bx)d,%(by)d" size="%(bw)d,%(bh)d" font="Regular;%(bf)d" halign="center" valign="center" foregroundColor="#00ffffff" backgroundColor="#00b3261e" zPosition="3" />
  <widget name="config" position="%(cx)d,%(cy)d" size="%(cw)d,%(ch)d" backgroundColor="%(bg)s" scrollbarMode="showOnDemand" zPosition="1" />
  <eLabel position="%(px)d,%(cy)d" size="%(pw)d,%(ch)d" backgroundColor="%(panel)s" zPosition="0" />
  <eLabel position="%(px)d,%(cy)d" size="%(stripe)d,%(ch)d" backgroundColor="%(cyan)s" zPosition="1" />
  <widget source="status_title" render="Label" position="%(ptx)d,%(pty)d" size="%(ptw)d,%(pth)d" font="Regular;%(ptf)d" halign="%(al)s" foregroundColor="%(cyan)s" backgroundColor="%(panel)s" transparent="1" zPosition="2" />
  <widget source="status" render="Label" position="%(ptx)d,%(psy)d" size="%(ptw)d,%(psh)d" font="Regular;%(psf)d" halign="%(al)s" foregroundColor="%(text)s" backgroundColor="%(panel)s" transparent="1" zPosition="2" />
  <widget source="help" render="Label" position="%(cx)d,%(hy)d" size="%(fullw)d,%(hh)d" font="Regular;%(hf)d" halign="%(al)s" foregroundColor="%(dim)s" backgroundColor="%(bg)s" transparent="1" valign="center" zPosition="2" />
  %(footer)s
</screen>""" % dict(
        w=z(W), h=z(H), bg=C_BG, panel=C_PANEL, cyan=C_CYAN, text=C_TEXT, dim=C_DIM,
        header=_header(z, W), footer=_footer(z, W), al=align(),
        bx=z(W - 190), by=z(22), bw=z(170), bh=z(36), bf=z(20),
        cx=z(20), cy=z(100), cw=z(620), ch=z(390),
        px=z(660), pw=z(360), stripe=max(2, z(4)),
        ptx=z(680), pty=z(110), ptw=z(330), pth=z(34), ptf=z(24),
        psy=z(150), psh=z(330), psf=z(18),
        hy=z(495), fullw=z(1000), hh=z(28), hf=z(17))


def text_skin(name):
    z = _zfunc()
    W, H = 1040, 620
    return """
<screen name="%(name)s" position="center,center" size="%(w)d,%(h)d" flags="wfNoBorder" backgroundColor="%(bg)s" title="AutoZap Recovery">
  %(header)s
  <eLabel position="%(x)d,%(y)d" size="%(tw)d,%(th)d" backgroundColor="%(panel)s" zPosition="0" />
  <widget name="text" position="%(ix)d,%(iy)d" size="%(iw)d,%(ih)d" font="Regular;%(f)d" halign="%(al)s" valign="top" foregroundColor="%(text)s" backgroundColor="%(panel)s" transparent="1" zPosition="1" />
  %(footer)s
</screen>""" % dict(
        name=name, w=z(W), h=z(H), bg=C_BG, panel=C_PANEL, text=C_TEXT, al=align(),
        header=_header(z, W), footer=_footer(z, W),
        x=z(20), y=z(100), tw=z(1000), th=z(420),
        ix=z(35), iy=z(110), iw=z(970), ih=z(400), f=z(18))


def toast_skin():
    z = _zfunc()
    k = skin_scale()
    try:
        width = getDesktop(0).size().width()
    except Exception:
        width = 1280
    W, H = 540, 96
    logo = logo_file(k)
    size = logo_size(k)
    pix = ""
    tx = 20
    if logo and size <= z(H) - 4:
        pix = '<ePixmap position="%d,%d" size="%d,%d" pixmap="%s" zPosition="2" />' % (
            z(16), (z(H) - size) // 2, size, size, logo)
        tx = 100
    return """
<screen name="AutoZapToastV11" position="%(x)d,%(y)d" size="%(w)d,%(h)d" flags="wfNoBorder" backgroundColor="%(bg)s" zPosition="99" title="AutoZap">
  <eLabel position="0,0" size="%(stripe)d,%(h)d" backgroundColor="%(gold)s" zPosition="1" />
  %(pix)s
  <widget name="title" position="%(tx)d,%(t1y)d" size="%(tw)d,%(t1h)d" font="Regular;%(t1f)d" halign="%(al)s" valign="center" foregroundColor="%(gold)s" backgroundColor="%(bg)s" transparent="1" zPosition="2" />
  <widget name="msg" position="%(tx)d,%(t2y)d" size="%(tw)d,%(t2h)d" font="Regular;%(t2f)d" halign="%(al)s" valign="top" foregroundColor="%(text)s" backgroundColor="%(bg)s" transparent="1" zPosition="2" />
</screen>""" % dict(
        x=max(0, width - z(W) - z(40)), y=z(40), w=z(W), h=z(H), bg=C_BG, gold=C_GOLD, text=C_TEXT,
        stripe=max(3, z(6)), pix=pix, al=align(),
        tx=z(tx), tw=z(W - tx - 16), t1y=z(8), t1h=z(30), t1f=z(22),
        t2y=z(40), t2h=z(52), t2f=z(19))


class AutoZapToast(Screen):
    def __init__(self, session):
        self.skin = toast_skin()
        Screen.__init__(self, session)
        self["title"] = Label(PLUGIN_TITLE)
        self["msg"] = Label("")

    def setMessage(self, text):
        self["msg"].setText(text)


# ------------------------------------------------------------------------
# Core monitor
# ------------------------------------------------------------------------
class AutoZapCore(object):
    """Real-time freeze detector and recovery engine."""

    def __init__(self, session):
        self.session = session
        self._conns = []
        self.learn = {}                 # per channel: start time, natural gaps
        self.global_start = None        # learned average start time (all channels)
        self.restarts = 0
        self.recovered = 0
        self.best_downtime = None
        self.last_downtime = None
        self.last_action = None         # (time, channel, counter, zapped)
        self.state = ""
        self.channel = ""
        self.source = ""
        self.pending = None
        self.in_restart = False
        self.toast_dlg = None
        self.toast_lang = None
        self.last_recover_time = 0.0
        self._model = box_model()
        self._reset_state(None)

        self.poll = eTimer()
        connect_timer(self.poll, self.tick, self._conns)
        self.play_timer = eTimer()
        connect_timer(self.play_timer, self._play_pending, self._conns)
        self.toast_timer = eTimer()
        connect_timer(self.toast_timer, self._hide_toast, self._conns)
        try:
            session.nav.event.append(self._on_nav_event)
        except Exception as e:
            debug("nav.event unavailable: %s" % e)
        self.poll.start(POLL_MS, False)
        log("%s - %s (%s)" % (PLUGIN_TITLE, T("بدأ التشغيل", "started"), self._model))

    # --- hardware capabilities (remembered per receiver model) -------
    def hw_ok(self, element):
        return element.value == self._model

    def hw_mark(self, element):
        if element.value != self._model:
            element.value = self._model
            element.save()
            try:
                configfile.save()
            except Exception:
                pass
            log(T("تم التحقق من مصدر الكشف على هذا الجهاز", "Detection source verified on this receiver"))

    # --- learning -------------------------------------------------------
    def _learned(self):
        return self.learn.setdefault(self.key or "-", {"start": None, "gap": 0.0, "ecm": 0.0})

    def _learn_start(self, seconds, clean):
        # capped so a long outage can never make the plugin slow
        seconds = min(max(seconds, 0.3), 8.0)
        d = self._learned()
        d["start"] = seconds if d["start"] is None else d["start"] * 0.7 + seconds * 0.3
        if clean:   # normal zap, not the end of an outage
            self.global_start = seconds if self.global_start is None else self.global_start * 0.8 + seconds * 0.2

    def _learn_gap(self, seconds):
        d = self._learned()
        d["gap"] = max(d["gap"] * 0.9, min(seconds, 8.0))

    def freeze_threshold(self, kind):
        v = cfg.freeze_time.value
        if v != "auto":
            return float(v)
        base = IPTV_FREEZE_SEC if kind == "iptv" else FAST_FREEZE_SEC
        return min(10.0, max(base, self._learned()["gap"] * 1.5 + 0.5))

    def start_timeout(self, kind):
        v = cfg.grace.value
        if v != "auto":
            return float(v)
        s = self._learned()["start"] or self.global_start or 2.5
        base = 6.0 if kind == "iptv" else 4.0
        return min(12.0, max(base, s * 1.5 + 2.0))

    def ecm_threshold(self):
        interval = self._learned().get("ecm", 0.0) or 20.0     # unknown channel: be patient
        return min(40.0, max(8.0, interval * 1.3 + 2.0))

    # --- state ---------------------------------------------------------
    def _reset_state(self, ref_str, keep_retries=False):
        now = time.time()
        self.ref_str = ref_str
        self.key = ref_key(ref_str) if ref_str else None
        self.zap_time = now
        self.last_pos = None
        self.pos_change = now
        self.moves = 0
        self.started = False
        self.good_since = None
        self._last_skip = None
        self.ecm_last_mtime = ecm_mtime()
        self.ecm_last = now
        self.ecm_fresh = 0              # ECM answers since this (re)start
        self.unsafe_until = 0.0
        if not keep_retries:
            self.retries = 0
            self.gave_up_at = None
            self.giveups = 0
            self.awaiting_result = False
            self.freeze_began = None
            self.ecm_updates = 0
            self.ecm_max_interval = 0.0

    def reset(self):
        self._reset_state(None)

    def _on_nav_event(self, ev):
        if self.in_restart or self.pending is not None:
            return
        try:
            if ev == iPlayableService.evStart:
                ref = self.session.nav.getCurrentlyPlayingServiceReference()
                ref_str = ref.toString() if ref else None
                own = (time.time() - self.last_recover_time < 10 and ref_str is not None
                       and ref_key(ref_str) == self.key)
                self._reset_state(ref_str, keep_retries=own)
        except Exception:
            pass

    def _skip(self, reason):
        if reason != self._last_skip:
            self._last_skip = reason
            debug("%s | %s" % (reason, self.ref_str or "-"))

    # --- notifications -------------------------------------------------
    def toast(self, text, seconds=4):
        mode = cfg.notify.value
        if mode == "off" or self._in_standby():
            return
        if mode == "toast":
            try:
                if self.toast_dlg is not None and self.toast_lang != is_arabic():
                    try:
                        self.toast_dlg.hide()
                        self.session.deleteDialog(self.toast_dlg)
                    except Exception:
                        pass
                    self.toast_dlg = None
                if self.toast_dlg is None:
                    self.toast_dlg = self.session.instantiateDialog(AutoZapToast)
                    self.toast_lang = is_arabic()
                self.toast_dlg.setMessage(text)
                self.toast_dlg.show()
                self.toast_timer.start(int(seconds * 1000), True)
                return
            except Exception as e:
                log("toast failed, using popup: %s" % e)
        try:
            from Tools import Notifications
            Notifications.AddPopup(text, MessageBox.TYPE_INFO, int(seconds), "AutoZapRecovery")
        except Exception as e:
            debug("popup failed: %s" % e)

    def _hide_toast(self):
        try:
            if self.toast_dlg is not None:
                self.toast_dlg.hide()
        except Exception:
            pass

    # --- environment checks ------------------------------------------
    def _in_standby(self):
        try:
            import Screens.Standby
            return bool(Screens.Standby.inStandby)
        except Exception:
            return False

    def _is_paused(self):
        ib = infobar()
        try:
            state = getattr(ib, "seekstate", None)
            pause = getattr(ib, "SEEK_STATE_PAUSE", None)
            if ib is not None and state is not None and pause is not None and state == pause:
                return True
        except Exception:
            pass
        return False

    def _foreign_player_open(self):
        try:
            dialogs = [self.session.current_dialog]
            for item in getattr(self.session, "dialog_stack", None) or []:
                dialogs.append(item[0] if isinstance(item, (tuple, list)) else item)
            for d in dialogs:
                if d is not None and "Player" in d.__class__.__name__:
                    return True
        except Exception:
            pass
        return False

    @staticmethod
    def _timeshift_active(service):
        try:
            ts = service.timeshift()
            return bool(ts and ts.isTimeshiftActive())
        except Exception:
            return False

    @staticmethod
    def _is_crypted(info):
        try:
            return bool(info and info.getInfo(iServiceInformation.sIsCrypted) == 1)
        except Exception:
            return False

    @staticmethod
    def _video_width(info):
        try:
            w = info.getInfo(iServiceInformation.sVideoWidth) if info else -1
            return w if w is not None else -1
        except Exception:
            return -1

    def classify(self, ref, ref_str, service):
        """Return (kind, reason). kind is 'dvb', 'iptv' or None."""
        fields = ref_str.split(":")
        try:
            rtype = int(fields[0])
        except (IndexError, ValueError):
            return None, T("خدمة غير مدعومة", "Unsupported service")
        try:
            path = ref.getPath() or ""
        except Exception:
            path = ""
        if ref_key(ref_str) in excluded_keys():
            return None, T("قناة مستثناة", "Excluded channel")
        if self._foreign_player_open() or self._is_paused():
            return None, T("إيقاف مؤقت / مشغل وسائط", "Paused / media player")

        if rtype in IPTV_TYPES or "://" in path:
            if path.startswith("/"):
                return None, T("ملف محلي", "Local file")
            if not on(cfg.iptv):
                return None, T("مراقبة IPTV متوقفة", "IPTV monitoring is off")
            return "iptv", ""

        if rtype != 1 or path:
            return None, T("تسجيل أو ملف", "Recording / file")
        try:
            if int(fields[2], 16) in RADIO_SERVICE_TYPES:
                return None, T("قناة راديو", "Radio channel")
        except (IndexError, ValueError):
            pass
        info = service.info()
        if info is None:
            return None, T("بانتظار بيانات القناة", "Waiting for service info")
        vpid = info.getInfo(iServiceInformation.sVideoPID)
        if vpid is None or vpid <= 0:
            return None, T("بدون فيديو", "No video stream")
        if cfg.scope.value == "crypted" and not self._is_crypted(info):
            return None, T("قناة مفتوحة (خارج النطاق)", "Free channel (out of scope)")
        if self._timeshift_active(service):
            return None, T("التايم شفت نشط", "Timeshift active")
        return "dvb", ""

    @staticmethod
    def read_position(kind, service):
        """Return (position, trusted). trusted = from the service API."""
        if kind == "iptv":
            try:
                seek = service.seek()
                if seek is not None:
                    r = seek.getPlayPosition()
                    if r and r[0] == 0 and r[1] > 0:
                        return r[1], True
            except Exception:
                pass
        value, path = read_pts()
        return value, False

    def unsafe_reason(self, kind, service, crypted):
        if kind == "dvb" and iFrontendInformation is not None:
            try:
                fe = service.frontendInfo()
                if fe is not None and fe.getFrontendInfo(iFrontendInformation.lockState) == 0:
                    return T("لا توجد إشارة من التيونر (الدش/الكابل)", "No tuner signal lock (dish/cable)")
            except Exception:
                pass
        if on(cfg.check_net) and (kind == "iptv" or crypted) and not has_default_route():
            return T("الشبكة مفصولة - بانتظار عودتها", "Network is down - waiting")
        return None

    @staticmethod
    def _name(service):
        try:
            info = service.info()
            return (info and info.getName()) or "?"
        except Exception:
            return "?"

    def _update_ecm(self, now):
        m = ecm_mtime()
        if m is not None and m != self.ecm_last_mtime:
            if self.ecm_fresh >= 1 and not self.awaiting_result and not self.retries:
                # interval between two answers during normal playback only
                d = self._learned()
                d["ecm"] = max(d.get("ecm", 0.0) * 0.95, min(now - self.ecm_last, 30.0))
            self.ecm_updates += 1
            self.ecm_fresh += 1
            self.ecm_last = now
            if self.ecm_updates >= 3:
                self.hw_mark(cfg.hw_ecm)
        self.ecm_last_mtime = m

    def _cooldown_seconds(self):
        v = cfg.cooldown.value
        if v == "auto":
            return AUTO_COOLDOWN[min(max(self.giveups, 1), len(AUTO_COOLDOWN)) - 1]
        return int(v) * 60

    # --- main loop (every 0.5 s) ----------------------------------------
    def tick(self):
        try:
            self._tick()
        except Exception as e:
            log("tick error: %s" % e)

    def _playing_ok(self, now, source):
        """Channel shows a moving picture."""
        if self.awaiting_result:
            self.awaiting_result = False
            self.recovered += 1
            down = now - (self.freeze_began or self.zap_time)
            self.last_downtime = down
            if self.best_downtime is None or down < self.best_downtime:
                self.best_downtime = down
            log(T("عادت القناة خلال %.1f ث: %s", "Channel back after %.1fs: %s") % (down, self.channel))
            self.toast(T("عادت القناة خلال %.1f ثانية\n%s", "Channel back after %.1f seconds\n%s")
                       % (down, self.channel), 3)
        if self.good_since is None:
            self.good_since = now
        if (self.retries or self.giveups) and now - self.good_since >= STABLE_RESET_SEC:
            self.retries = 0
            self.giveups = 0
            self.gave_up_at = None
        self.freeze_began = None
        self.state = T("يراقب - البث سليم", "Monitoring - playing OK")
        self.source = source

    def _tick(self):
        if self.pending is not None:
            return
        if not on(cfg.enabled):
            self.state = T("متوقف", "Disabled")
            return
        if self._in_standby():
            self.state = T("الجهاز في وضع الاستعداد", "Standby")
            self.channel = ""
            if self.ref_str is not None:
                self._reset_state(None)
            return
        nav = self.session.nav
        ref = nav.getCurrentlyPlayingServiceReference()
        if ref is None:
            self.state = T("لا توجد قناة", "No service")
            self.channel = ""
            if self.ref_str is not None:
                self._reset_state(None)
            return
        ref_str = ref.toString()
        if ref_str != self.ref_str:
            self._reset_state(ref_str)
        service = nav.getCurrentService()
        if service is None:
            return
        self.channel = self._name(service)
        kind, why = self.classify(ref, ref_str, service)
        if kind is None:
            self.state = T("تخطي: ", "Skipped: ") + why
            self.source = ""
            self.last_pos = None
            self.started = False
            self.moves = 0
            self.zap_time = self.pos_change = time.time()
            return

        now = time.time()
        info = service.info()
        crypted = self._is_crypted(info)
        width = self._video_width(info)
        if width > 0:
            self.hw_mark(cfg.hw_video)
        use_ecm = kind == "dvb" and crypted and on(cfg.ecm_watch)
        if use_ecm:
            self._update_ecm(now)

        pos, trusted = self.read_position(kind, service)
        moved = False
        if pos is not None:
            if self.last_pos is not None and pos != self.last_pos:
                moved = True
            self.last_pos = pos
        pts_ok = pos is not None and (trusted or self.hw_ok(cfg.hw_pts))

        # ---------------- picture is moving --------------------------
        if moved:
            gap = now - self.pos_change
            self.pos_change = now
            self.moves += 1
            if not trusted and self.moves >= 3:
                self.hw_mark(cfg.hw_pts)
                pts_ok = True
            if not self.started and self.moves >= 2:
                self.started = True
                self._learn_start(now - self.zap_time, not self.awaiting_result and not self.giveups)
            elif self.started and gap >= 1.2:
                self._learn_gap(gap)            # natural hiccup that healed itself
            if self.started and pts_ok:
                self._playing_ok(now, "PTS")
                return

        freeze_thr = self.freeze_threshold(kind)
        start_thr = self.start_timeout(kind)
        stalled = 0.0
        source = None

        if pts_ok:
            if not self.started:
                waited = now - self.zap_time
                if waited < start_thr:
                    if now >= self.unsafe_until:
                        self.state = T("تشغيل القناة... %.1f ث", "Starting channel... %.1fs") % waited
                    return
                stalled, source = waited, T("لم تبدأ", "No start")
                self.freeze_began = self.freeze_began or self.zap_time
            else:
                stalled = now - self.pos_change
                if stalled < freeze_thr:
                    if stalled >= 1.0:
                        self.good_since = None
                        if now >= self.unsafe_until:
                            self.state = T("اشتباه تجمد: %.1f ث", "Possible freeze: %.1fs") % stalled
                    return
                source = "PTS"
                self.freeze_began = self.freeze_began or self.pos_change
        else:
            # fallback detectors for receivers without a usable PTS
            video_ok = self.hw_ok(cfg.hw_video)
            ecm_verified = use_ecm and (self.ecm_updates >= 3 or self.hw_ok(cfg.hw_ecm))
            fresh_ecm = self.ecm_fresh >= 1 and now - self.ecm_last < self.ecm_threshold()
            if (width > 0 or not video_ok) and (fresh_ecm or not ecm_verified) and (video_ok or ecm_verified):
                self.started = True
                self._playing_ok(now, "ECM" if ecm_verified else T("الفيديو", "Video"))
                return
            waited = now - self.zap_time
            if video_ok and width <= 0 and waited >= start_thr:
                stalled, source = waited, T("لم تبدأ", "No start")
                self.freeze_began = self.freeze_began or self.zap_time
            elif ecm_verified and self.ecm_fresh == 0 and waited >= start_thr + 2.0:
                stalled, source = waited, T("لا توجد شفرة", "No ECM")
                self.freeze_began = self.freeze_began or self.zap_time
            elif ecm_verified and self.ecm_fresh >= 1 and now - self.ecm_last >= self.ecm_threshold():
                stalled, source = now - self.ecm_last, "ECM"
                self.freeze_began = self.freeze_began or self.ecm_last
            else:
                if not (video_ok or ecm_verified):
                    self.state = T("بانتظار التحقق من مصدر الكشف", "Verifying detection source")
                    self._skip("no verified detection source yet - no action")
                elif self.ecm_fresh == 0 and ecm_verified:
                    self.state = T("بانتظار الشفرة... %.1f ث", "Waiting for ECM... %.1fs") % waited
                else:
                    self.state = T("يراقب", "Monitoring")
                return

        self.good_since = None
        self.source = source
        reason = self.unsafe_reason(kind, service, crypted)
        if reason:
            self.state = reason
            self.unsafe_until = now + 10.0
            self._skip(reason)
            self.pos_change = now
            self.zap_time = now
            self.ecm_last = now
            return

        limit = int(cfg.max_retries.value)
        if self.retries >= limit:
            if self.gave_up_at is None:
                self.gave_up_at = now
                self.giveups += 1
                log(T("توقفت المحاولات بعد %d: %s", "Gave up after %d attempts: %s") % (self.retries, self.channel))
                if cfg.on_fail.value == "next" and self._zap_next():
                    self.toast(T("القناة %s لا تستجيب\nتم الانتقال للقناة التالية",
                                 "%s is not responding\nswitched to the next channel") % self.channel)
                    return
                wait = self._cooldown_seconds()
                self.toast(T("القناة لا تستجيب حالياً\nمحاولة جديدة تلقائياً بعد %d ث",
                             "Channel is not responding\nretrying automatically in %ds") % wait
                           if wait else T("القناة لا تستجيب\nتم إيقاف المحاولات", "Channel is not responding\nattempts stopped"))
            wait = self._cooldown_seconds()
            left = int(wait - (now - self.gave_up_at)) if wait else -1
            if wait and left <= 0:
                self.retries = 0
                self.gave_up_at = None
                self.pos_change = now
                self.zap_time = now
                self.ecm_last = now
                self.started = False
                self.moves = 0
                self.state = T("إعادة المحاولة...", "Retrying...")
            else:
                self.state = (T("محاولة جديدة بعد %d ث", "Retrying in %ds") % left) if wait \
                    else T("توقفت المحاولات لهذه القناة", "Attempts stopped for this channel")
            return
        self.retries += 1
        self.recover(kind, stalled, source, "%d/%d" % (self.retries, limit))

    # --- recovery ------------------------------------------------------
    def _current_target(self):
        nav = self.session.nav
        target = None
        getter = getattr(nav, "getCurrentlyPlayingServiceOrGroup", None)
        if getter is not None:
            try:
                target = getter()
            except Exception:
                target = None
        if target is None:
            target = nav.getCurrentlyPlayingServiceReference()
        return target

    def neighbour(self, target):
        """Next playable TV channel in the current bouquet (for zap mode)."""
        if parental_control_active():
            return None
        try:
            ib = infobar()
            servicelist = getattr(ib, "servicelist", None)
            root = servicelist.getRoot()
            refs = eServiceCenter.getInstance().list(root).getContent("R")
            if not refs:
                return None
            my = ref_key(target.toString())
            keys = [ref_key(r.toString()) for r in refs]
            start = keys.index(my) if my in keys else -1
            bad = 0
            for flag in ("isMarker", "isDirectory", "isGroup"):
                bad |= getattr(eServiceReference, flag, 0)
            count = len(refs)
            for step in range(1, min(count, 40) + 1):
                r = refs[(start + step) % count]
                if r.flags & bad:
                    continue
                s = r.toString()
                f = s.split(":")
                if f[0] != "1" or r.getPath() or ref_key(s) == my:
                    continue
                try:
                    if int(f[2], 16) in RADIO_SERVICE_TYPES:
                        continue
                except (IndexError, ValueError):
                    continue
                return r
        except Exception as e:
            debug("neighbour lookup failed: %s" % e)
        return None

    def _zap_next(self):
        ib = infobar()
        for name in ("zapDown", "zapToNextChannel"):
            fnc = getattr(ib, name, None)
            if fnc is not None:
                try:
                    fnc()
                    log(T("انتقال للقناة التالية", "Switched to next channel"))
                    return True
                except Exception as e:
                    log("zap next failed: %s" % e)
        return False

    def recover(self, kind, stalled, source, counter):
        nav = self.session.nav
        target = self._current_target()
        if target is None:
            return False
        attempt = max(1, self.retries)
        step = min(attempt, 3) - 1
        mode = cfg.mode.value
        use_zap = kind == "dvb" and (mode == "zap" or (mode == "smart" and attempt >= 2))
        other = self.neighbour(target) if use_zap else None

        self.restarts += 1
        self.awaiting_result = True
        self.last_recover_time = time.time()
        if self.freeze_began is None:
            self.freeze_began = self.last_recover_time
        name = self.channel or "?"
        method = T("تقليب سريع والعودة", "quick zap & back") if other is not None else T("إعادة تشغيل فورية", "instant restart")
        self.last_action = (time.strftime("%H:%M:%S"), name, counter, other is not None)
        self.state = T("جاري الإنعاش...", "Recovering...")
        log(T("كشف [%s] بعد %.1f ث -> إنعاش %s (%s): %s", "Detected [%s] after %.1fs -> recovery %s (%s): %s")
            % (source, stalled, counter, method, name))
        self.toast(T("إنعاش تلقائي (%s)\n%s", "Auto recovery (%s)\n%s") % (counter, name))

        if other is not None:
            self.pending = {"target": target, "expect": ref_key(other.toString())}
            self.in_restart = True
            try:
                play_ref(nav, other)
            except Exception as e:
                log("zap away failed: %s" % e)
            finally:
                self.in_restart = False
            self.play_timer.start(ZAP_HOLD_MS[step], True)
        else:
            self.pending = {"target": target, "expect": None}
            try:
                nav.stopService()
            except Exception as e:
                log("stopService failed: %s" % e)
            self.play_timer.start(RESTART_GAP_MS[step], True)
        return True

    def force_recover(self):
        """Manual test from the diagnostics screen."""
        if self.pending is not None:
            return False
        nav = self.session.nav
        ref = nav.getCurrentlyPlayingServiceReference()
        service = nav.getCurrentService()
        if ref is None or service is None:
            return False
        self.channel = self._name(service)
        kind, why = self.classify(ref, ref.toString(), service)
        self.freeze_began = time.time()
        return self.recover(kind or "dvb", 0.0, T("اختبار يدوي", "manual test"), "test")

    def _play_pending(self):
        pending, self.pending = self.pending, None
        if pending is None:
            return
        nav = self.session.nav
        try:
            cur = nav.getCurrentlyPlayingServiceReference()
            if cur is not None and ref_key(cur.toString()) != pending["expect"]:
                log(T("المستخدم غيّر القناة أثناء الإنعاش - تم الإلغاء",
                      "User changed channel during recovery - cancelled"))
                self._reset_state(None)
                return
        except Exception:
            pass
        self.in_restart = True
        try:
            play_ref(nav, pending["target"])
        except Exception as e:
            log("playService failed: %s" % e)
        finally:
            self.in_restart = False
        cur_str = None
        try:
            ref = nav.getCurrentlyPlayingServiceReference()
            cur_str = ref.toString() if ref else None
        except Exception:
            pass
        self._reset_state(cur_str, keep_retries=True)

    # --- status ---------------------------------------------------------
    def status_text(self):
        lines = [
            T("الحالة: ", "State: ") + (self.state or "-"),
            T("القناة: ", "Channel: ") + (self.channel or "-"),
            T("مصدر الكشف: ", "Detection: ") + (self.source or "-"),
            T("عمليات الإنعاش: %d  |  ناجحة: %d", "Recoveries: %d  |  successful: %d") % (self.restarts, self.recovered),
        ]
        if self.last_downtime is not None:
            lines.append(T("آخر عودة خلال: %.1f ث", "Last comeback: %.1fs") % self.last_downtime)
        if self.best_downtime is not None:
            lines.append(T("أسرع عودة: %.1f ث", "Fastest comeback: %.1fs") % self.best_downtime)
        lines.append(T("القنوات المستثناة: %d", "Excluded channels: %d") % len(excluded_keys()))
        if self.last_action:
            at, name, counter, zapped = self.last_action
            method = T("تقليب والعودة", "zap & back") if zapped else T("إعادة تشغيل", "restart")
            lines.append(T("آخر إجراء:", "Last action:"))
            lines.append("%s  %s  (%s - %s)" % (at, name, counter, method))
        return "\n".join(lines)

    def diagnostics_text(self):
        nav = self.session.nav
        yes, no = T("نعم", "Yes"), T("لا", "No")
        lines = []
        ref = nav.getCurrentlyPlayingServiceReference()
        service = nav.getCurrentService()
        if ref is None or service is None:
            return T("لا توجد قناة قيد التشغيل.", "No channel is playing.")
        info = service.info()
        kind, why = self.classify(ref, ref.toString(), service)
        lines.append(T("الجهاز: ", "Receiver: ") + self._model)
        lines.append(T("القناة: ", "Channel: ") + self._name(service))
        lines.append(T("نوع المراقبة: ", "Monitor type: ") +
                     ({"dvb": "DVB", "iptv": "IPTV"}.get(kind) or (T("تخطي - ", "Skipped - ") + why)))
        lines.append(T("مشفرة: ", "Encrypted: ") + (yes if self._is_crypted(info) else no))
        w = self._video_width(info)
        try:
            h = info.getInfo(iServiceInformation.sVideoHeight) if info else -1
        except Exception:
            h = -1
        lines.append(T("أبعاد الفيديو: ", "Video size: ") +
                     ("%dx%d" % (w, h) if w > 0 else T("لا توجد صورة", "no picture")))
        value, path = read_pts()
        lines.append("PTS: " + (("%s = %s" % (path, value[-10:])) if value is not None
                                else T("غير موجود بهذا الجهاز", "not available on this box")))
        lines.append(T("PTS مؤكد العمل: ", "PTS verified: ") + (yes if self.hw_ok(cfg.hw_pts) else no))
        m = ecm_mtime()
        lines.append("ECM: " + (T("لا يوجد ملف ecm.info", "no ecm.info file") if m is None else
                                T("آخر تحديث قبل %d ث - تحديثات: %d", "updated %ds ago - updates: %d")
                                % (int(max(0, time.time() - m)), self.ecm_updates)))
        lock = "-"
        if iFrontendInformation is not None:
            try:
                fe = service.frontendInfo()
                if fe is not None:
                    lock = yes if fe.getFrontendInfo(iFrontendInformation.lockState) else no
            except Exception:
                pass
        lines.append(T("إشارة التيونر مقفلة: ", "Tuner locked: ") + lock)
        lines.append(T("الشبكة: ", "Network: ") + (T("متصلة", "up") if has_default_route() else T("مفصولة", "down")))
        k = kind or "dvb"
        learned = self._learned()["start"]
        lines.append(T("عتبة كشف التجمد: %.1f ث  |  مهلة بدء القناة: %.1f ث",
                       "Freeze threshold: %.1fs  |  start timeout: %.1fs") % (self.freeze_threshold(k), self.start_timeout(k)))
        lines.append(T("زمن بدء هذه القناة (متعلَّم): ", "Learned start time: ") +
                     ("%.1f %s" % (learned, T("ث", "s")) if learned else "-"))
        lines.append(T("قرار المراقب: ", "Monitor decision: ") + (self.state or "-"))
        return "\n".join(lines)


core = None


def sessionstart(reason, **kwargs):
    global core
    if reason == 0 and "session" in kwargs and core is None:
        try:
            core = AutoZapCore(kwargs["session"])
        except Exception as e:
            log("start failed: %s" % e)


# ------------------------------------------------------------------------
# Screens
# ------------------------------------------------------------------------
class AutoZapText(Screen):
    """Shared layout for the log and diagnostics screens.

    Uses a plain Label with its own paging (works on every image,
    unlike ScrollLabel whose implementation differs between images).
    """

    def __init__(self, session, name):
        self.skin = text_skin(name)
        Screen.__init__(self, session)
        self._lines = []
        self._page = 0
        self._subtitle = ""
        self["title"] = StaticText(PLUGIN_TITLE)
        self["subtitle"] = StaticText("")
        self["copyright"] = StaticText(copyright_text())
        self["key_red"] = StaticText("")
        self["key_green"] = StaticText("")
        self["key_yellow"] = StaticText("")
        self["key_blue"] = StaticText("")
        self["text"] = Label("")

    def set_subtitle(self, text):
        self._subtitle = text
        self._render()

    def set_lines(self, text, keep_page=True):
        self._lines = (text or "").splitlines() or [""]
        if not keep_page:
            self._page = 0
        self._render()

    def pages(self):
        return max(1, (len(self._lines) + PAGE_LINES - 1) // PAGE_LINES)

    def _render(self):
        self._page = min(self._page, self.pages() - 1)
        start = self._page * PAGE_LINES
        self["text"].setText("\n".join(self._lines[start:start + PAGE_LINES]))
        sub = self._subtitle
        if self.pages() > 1:
            sub += T("  |  صفحة %d/%d", "  |  page %d/%d") % (self._page + 1, self.pages())
        self["subtitle"].setText(sub)

    def page_up(self):
        if self._page > 0:
            self._page -= 1
            self._render()

    def page_down(self):
        if self._page < self.pages() - 1:
            self._page += 1
            self._render()


class AutoZapLog(AutoZapText):
    def __init__(self, session):
        AutoZapText.__init__(self, session, "AutoZapLogV11")
        self.set_subtitle(T("سجل الأحداث (الأحدث أولاً)", "Event log (newest first)"))
        self["key_red"].setText(T("مسح السجل", "Clear log"))
        self["key_green"].setText(T("تحديث", "Refresh"))
        self["key_yellow"].setText(T("الصفحة التالية", "Next page"))
        self["key_blue"].setText(T("رجوع", "Back"))
        self["actions"] = ActionMap(["OkCancelActions", "DirectionActions", "ColorActions"], {
            "ok": self.close, "cancel": self.close, "blue": self.close,
            "red": self.clear, "green": self.load, "yellow": self.next_page,
            "up": self.page_up, "down": self.page_down,
            "left": self.page_up, "right": self.page_down,
        }, -1)
        self.onLayoutFinish.append(self.load)

    def next_page(self):
        if self._page < self.pages() - 1:
            self.page_down()
        else:
            self._page = 0
            self._render()

    def load(self):
        self.set_lines(read_log_tail() or T(
            "السجل فارغ.\n\nتُسجَّل هنا كل عمليات الإنعاش تلقائياً.\nفعّل (سجل التشخيص) من الإعدادات لعرض أسباب التخطي أيضاً.",
            "The log is empty.\n\nEvery recovery is written here automatically.\nEnable 'Debug log' in the settings to also see skip reasons."),
            keep_page=False)

    def clear(self):
        for path in (LOG_FILE, LOG_FILE + ".1"):
            try:
                os.remove(path)
            except Exception:
                pass
        self.load()


class AutoZapDiagnostics(AutoZapText):
    def __init__(self, session):
        AutoZapText.__init__(self, session, "AutoZapDiagV11")
        self.set_subtitle(T("فحص الجهاز والقناة الحالية - مباشر", "Receiver & current channel check - live"))
        self["key_red"].setText(T("رجوع", "Back"))
        self["key_green"].setText(T("اختبار الإنعاش", "Test recovery"))
        self["key_yellow"].setText(T("اختبار الإشعار", "Test notification"))
        self["key_blue"].setText(T("السجل", "Log"))
        self._conns = []
        self["actions"] = ActionMap(["OkCancelActions", "DirectionActions", "ColorActions"], {
            "ok": self.close, "cancel": self.close, "red": self.close,
            "green": self.test_recovery, "yellow": self.test_toast,
            "blue": self.open_log,
            "up": self.page_up, "down": self.page_down,
            "left": self.page_up, "right": self.page_down,
        }, -1)
        self.timer = eTimer()
        connect_timer(self.timer, self.refresh, self._conns)
        self.onLayoutFinish.append(self._start)
        self.onClose.append(self.timer.stop)

    def _start(self):
        self.refresh()
        self.timer.start(1000, False)

    def open_log(self):
        self.session.open(AutoZapLog)

    def refresh(self):
        if core is None:
            text = T("المراقبة غير نشطة - أعد تشغيل الواجهة.", "Monitor not running - restart the GUI.")
        else:
            try:
                text = core.diagnostics_text()
            except Exception as e:
                text = "Error: %s" % e
        self.set_lines(text)

    def test_recovery(self):
        if core is None or not core.force_recover():
            self.session.open(MessageBox, T("لا يمكن الاختبار الآن - لا توجد قناة.", "Cannot test now - no channel."),
                              MessageBox.TYPE_INFO, timeout=4)

    def test_toast(self):
        if core is None:
            return
        if cfg.notify.value == "off":
            self.session.open(MessageBox, T("الإشعارات متوقفة من الإعدادات.", "Notifications are off in settings."),
                              MessageBox.TYPE_INFO, timeout=4)
            return
        core.toast(T("هذا إشعار تجريبي\nالإشعارات تعمل بشكل صحيح", "Test notification\nnotifications are working"))


class AutoZapSetup(ConfigListScreen, Screen):
    HELP = {
        "enabled": ("تشغيل أو إيقاف الإنعاش التلقائي بالكامل.", "Turn automatic recovery on or off."),
        "scope": ("المشفرة فقط = الأنسب لمشاكل الشيرنج والكروت.", "Encrypted only = best for sharing/card issues."),
        "iptv": ("مراقبة روابط IPTV الموجودة في قائمة القنوات.", "Watch IPTV streams in your bouquets."),
        "mode": ("طريقة الإنعاش: نفس القناة، أو تقليب لقناة أخرى ثم العودة.", "Restart the same channel or zap away and back."),
        "freeze_time": ("الذكي: يكشف التجمد خلال 2.5 ث ويتكيف مع كل قناة.", "Smart: detects a freeze in 2.5 s and adapts per channel."),
        "grace": ("الذكي: يتعلم كم تحتاج كل قناة لتظهر الصورة.", "Smart: learns how long each channel needs to start."),
        "max_retries": ("من 1 إلى 100 - يمين/يسار أو اكتب الرقم بالريموت.", "1 to 100 - left/right or type the number."),
        "on_fail": ("ماذا يحدث إذا فشلت كل المحاولات.", "What to do when all attempts fail."),
        "cooldown": ("بعد فشل المحاولات يعيد تلقائياً: 20 ث، 40 ث، 90 ث...", "After failed attempts retries automatically: 20s, 40s, 90s..."),
        "ecm_watch": ("كشف توقف الشفرة من ملف ecm.info (للأجهزة بدون PTS).", "Detect a stopped softcam via ecm.info."),
        "check_net": ("لا ينعش إذا كانت الشبكة مفصولة.", "Skip recovery while the network is down."),
        "notify": ("شكل الإشعار عند الإنعاش.", "How recoveries are announced."),
        "debug": ("يسجل أسباب التخطي في /tmp/autozap.log", "Writes skip reasons to /tmp/autozap.log"),
        "language": ("لغة الجهاز افتراضياً، ويمكنك اختيار العربية أو الإنجليزية.", "Box language by default, or choose Arabic / English."),
    }

    def __init__(self, session, lang_before=None):
        self.skin = setup_skin()
        Screen.__init__(self, session)
        self.session = session
        self.list = []
        ConfigListScreen.__init__(self, self.list, session=session)
        self._conns = []
        self._lang_before = cfg.language.value if lang_before is None else lang_before

        self["title"] = StaticText(PLUGIN_TITLE)
        self["subtitle"] = StaticText("")
        self["badge_on"] = Label("")
        self["badge_off"] = Label("")
        self["status_title"] = StaticText("")
        self["status"] = StaticText("")
        self["help"] = StaticText("")
        self["copyright"] = StaticText("")
        self["key_red"] = StaticText("")
        self["key_green"] = StaticText("")
        self["key_yellow"] = StaticText("")
        self["key_blue"] = StaticText("")
        self["actions"] = ActionMap(["SetupActions", "ColorActions"], {
            "green": self.save, "ok": self.save,
            "red": self.cancel, "cancel": self.cancel,
            "yellow": self.open_log,
            "blue": self.open_diagnostics,
        }, -2)
        try:
            self["menu_actions"] = ActionMap(["MenuActions"], {"menu": self.about}, -2)
        except Exception:
            pass

        self.status_timer = eTimer()
        connect_timer(self.status_timer, self._update_status, self._conns)
        self.onLayoutFinish.append(self._layout_finished)
        self.onClose.append(self.status_timer.stop)
        self._apply_texts()
        self._build()
        try:
            self["config"].onSelectionChanged.append(self._update_help)
        except Exception:
            pass

    def _apply_texts(self):
        self["subtitle"].setText(T("إنعاش فوري وذكي للقنوات", "Instant smart channel recovery"))
        self["badge_on"].setText(T("يعمل", "ACTIVE"))
        self["badge_off"].setText(T("متوقف", "OFF"))
        self["status_title"].setText(T("الحالة المباشرة", "Live status"))
        self["copyright"].setText(copyright_text())
        self["key_red"].setText(T("إلغاء", "Cancel"))
        self["key_green"].setText(T("حفظ", "Save"))
        self["key_yellow"].setText(T("السجل", "Log"))
        self["key_blue"].setText(T("الفحص والاختبار", "Diagnostics"))

    def _layout_finished(self):
        self.setTitle("%s | %s" % (PLUGIN_TITLE, AUTHOR))
        self._update_badge()
        self._update_help()
        self._update_status()
        self.status_timer.start(2000, False)

    def _update_badge(self):
        if on(cfg.enabled):
            self["badge_on"].show()
            self["badge_off"].hide()
        else:
            self["badge_on"].hide()
            self["badge_off"].show()

    def _update_status(self):
        if core is None:
            text = T("المراقبة غير نشطة - أعد تشغيل الواجهة", "Monitor not running - restart the GUI")
        elif not on(cfg.enabled):
            text = T("الإنعاش التلقائي متوقف.\nفعّله من القائمة أو من\nزر الإضافات (الأزرق).",
                     "Auto recovery is disabled.\nEnable it here or from the\nExtensions (blue) menu.")
        else:
            text = core.status_text()
        self["status"].setText(text)

    def _update_help(self):
        try:
            cur = self["config"].getCurrent()
        except Exception:
            cur = None
        text = T("زر MENU: حول البلجن", "MENU: about")
        if cur:
            for key, pair in self.HELP.items():
                if getattr(cfg, key, None) is cur[1]:
                    text = T(pair[0], pair[1])
                    break
        self["help"].setText(text)

    def _build(self):
        lst = [getConfigListEntry(T("تفعيل الإنعاش التلقائي", "Enable auto recovery"), cfg.enabled)]
        if on(cfg.enabled):
            lst += [
                getConfigListEntry(T("نطاق المراقبة", "Monitor scope"), cfg.scope),
                getConfigListEntry(T("مراقبة قنوات IPTV", "Monitor IPTV streams"), cfg.iptv),
                getConfigListEntry(T("طريقة الإنعاش", "Recovery method"), cfg.mode),
                getConfigListEntry(T("سرعة كشف التجمد", "Freeze detection speed"), cfg.freeze_time),
                getConfigListEntry(T("مهلة تشغيل القناة", "Channel start timeout"), cfg.grace),
                getConfigListEntry(T("أقصى عدد محاولات", "Max attempts"), cfg.max_retries),
                getConfigListEntry(T("عند فشل كل المحاولات", "When all attempts fail"), cfg.on_fail),
                getConfigListEntry(T("إعادة المحاولة بعد الفشل", "Retry after failure"), cfg.cooldown),
                getConfigListEntry(T("مراقبة الشفرة (ECM)", "ECM watch"), cfg.ecm_watch),
                getConfigListEntry(T("فحص الشبكة قبل الإنعاش", "Check network first"), cfg.check_net),
                getConfigListEntry(T("الإشعارات", "Notifications"), cfg.notify),
                getConfigListEntry(T("سجل التشخيص", "Debug log"), cfg.debug),
            ]
        lst.append(getConfigListEntry(T("لغة البلجن", "Plugin language"), cfg.language))
        self.list = lst
        widget = self["config"]
        try:
            index = widget.getCurrentIndex()
        except Exception:
            index = 0
        try:
            widget.list = lst
        except Exception:
            pass
        try:
            widget.l.setList(lst)
        except Exception:
            pass
        try:
            widget.setCurrentIndex(min(index, len(lst) - 1))
        except Exception:
            pass

    def _after_key(self):
        try:
            cur = self["config"].getCurrent()
        except Exception:
            cur = None
        if cur and cur[1] is cfg.language:
            # re-translate everything and reopen the screen so the layout
            # direction (right-to-left / left-to-right) follows too
            relabel()
            self.status_timer.stop()
            self.close(("reopen", self._lang_before))
            return
        elif cur and cur[1] is cfg.enabled:
            self._build()
            self._update_badge()
        self._update_status()
        self._update_help()

    def keyLeft(self):
        ConfigListScreen.keyLeft(self)
        self._after_key()

    def keyRight(self):
        ConfigListScreen.keyRight(self)
        self._after_key()

    def save(self):
        cfg.save()
        configfile.save()
        if core:
            core.reset()
        if cfg.language.value != self._lang_before:
            self.session.openWithCallback(self._restart_answer, MessageBox,
                                          T("تم تغيير اللغة.\nأسماء البلجن في القوائم تتغير بعد إعادة تشغيل الواجهة.\nإعادة التشغيل الآن؟",
                                            "Language changed.\nMenu entries update after a GUI restart.\nRestart now?"),
                                          MessageBox.TYPE_YESNO)
        else:
            self.close()

    def _restart_answer(self, answer):
        if answer:
            try:
                from Screens.Standby import TryQuitMainloop
                self.session.open(TryQuitMainloop, 3)
                return
            except Exception as e:
                log("GUI restart failed: %s" % e)
        self.close()

    def cancel(self):
        try:
            for item in cfg.dict().values():
                item.cancel()
        except Exception:
            for item in self.list:
                item[1].cancel()
        relabel()
        self.close()

    def open_log(self):
        self.session.open(AutoZapLog)

    def open_diagnostics(self):
        self.session.open(AutoZapDiagnostics)

    def about(self):
        text = "\n".join([
            PLUGIN_TITLE,
            "",
            T("تصميم وتطوير: %s", "Designed & Developed by: %s") % AUTHOR,
            T("جميع الحقوق محفوظة (C) 2026", "(C) 2026 All Rights Reserved"),
            "",
            T("ينعش القنوات تلقائياً عند التجمد أو التوقف أو عدم ظهور الصورة،",
              "Recovers channels automatically when they freeze, stop or never start,"),
            T("ولا يتدخل في القنوات السليمة أو الراديو أو التسجيلات.",
              "and never touches healthy channels, radio or recordings."),
            "",
            T("زر الإضافات (الأزرق) أثناء المشاهدة: تشغيل/إيقاف، واستثناء القناة.",
              "Extensions (blue) while watching: on/off and exclude channel."),
            "",
            "Enigma2 Pro Community",
        ])
        self.session.open(MessageBox, text, MessageBox.TYPE_INFO)


# ------------------------------------------------------------------------
# Entry points
# ------------------------------------------------------------------------
def main(session, **kwargs):
    def closed(result=None):
        if isinstance(result, tuple) and result and result[0] == "reopen":
            session.openWithCallback(closed, AutoZapSetup, result[1])
    session.openWithCallback(closed, AutoZapSetup)


def toggle(session, **kwargs):
    cfg.enabled.value = "false" if on(cfg.enabled) else "true"
    cfg.enabled.save()
    configfile.save()
    if core:
        core.reset()
    text = PLUGIN_TITLE + "\n" + (T("تم التفعيل", "Enabled") if on(cfg.enabled) else T("تم الإيقاف", "Disabled"))
    session.open(MessageBox, text, MessageBox.TYPE_INFO, timeout=3)


def toggle_exclude(session, **kwargs):
    ref = None
    try:
        ref = session.nav.getCurrentlyPlayingServiceReference()
    except Exception:
        pass
    if ref is None:
        session.open(MessageBox, T("لا توجد قناة قيد التشغيل.", "No channel is playing."),
                     MessageBox.TYPE_INFO, timeout=3)
        return
    key = ref_key(ref.toString())
    keys = excluded_keys()
    name = key
    try:
        name = AutoZapCore._name(session.nav.getCurrentService())
    except Exception:
        pass
    if key in keys:
        keys.remove(key)
        text = T("تمت إعادة القناة للمراقبة:\n%s", "Channel monitored again:\n%s") % name
    else:
        keys.append(key)
        text = T("تم استثناء القناة من الإنعاش:\n%s", "Channel excluded from recovery:\n%s") % name
    save_excluded(keys)
    if core:
        core.reset()
    log(text.replace("\n", " "))
    session.open(MessageBox, text, MessageBox.TYPE_INFO, timeout=4)


def Plugins(**kwargs):
    name = PLUGIN_TITLE
    icon = "plugin.png" if os.path.exists(os.path.join(PLUGIN_PATH, "plugin.png")) else None
    return [
        PluginDescriptor(name=name, where=PluginDescriptor.WHERE_SESSIONSTART, fnc=sessionstart),
        PluginDescriptor(name=name,
                         description=T("إنعاش القنوات المتجمدة تلقائياً", "Automatic recovery of frozen channels")
                         + " | " + AUTHOR,
                         where=PluginDescriptor.WHERE_PLUGINMENU, icon=icon, fnc=main),
        PluginDescriptor(name=T("AutoZap: تشغيل / إيقاف", "AutoZap: On / Off"),
                         description=name, where=PluginDescriptor.WHERE_EXTENSIONSMENU, fnc=toggle),
        PluginDescriptor(name=T("AutoZap: استثناء / إرجاع القناة الحالية", "AutoZap: Exclude / include this channel"),
                         description=name, where=PluginDescriptor.WHERE_EXTENSIONSMENU, fnc=toggle_exclude),
    ]
AZ_EOF

cat > /tmp/az_plugin.b64 << 'AZ_EOF'
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
ODVFO+Ox6H8AJFwvrx7kx48AAAAASUVORK5CYII=
AZ_EOF
az_b64 /tmp/az_plugin.b64 "$PLUGIN_DIR/plugin.png"

cat > /tmp/az_logo.b64 << 'AZ_EOF'
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
U0c3BOB4AzIzZCJirSjFAO596LFv3vCDP295JZfJdHW0RWZigQUxmBA7reQQQEZ0rwGJSIKq6ujO
fOGr/vwjggfvJUeLkwLNDJExRimlFD334stXXnv7b57YxExdHW3G2InyACAIE8woR9zwm2563Vru
7gHgfegS7uj2f3gr5RS0RhBMZ2kyxirFSqm33u696rrv3fXz3xRK5fbWFhFMLuoTEa1AsR+W4Xxy
U/YrQZJkHYoMz5kPraXvoHvOWnJd/94fifjEqnYsNzl9NU6b626966bv37drz7621pb21ryZuGZi
ifehipNu1L+aDE/QpCURMFFXD0SgtAwNOmecw/MW+tddI/veJsdJMnsTExExxmjtYsS06WyLIjNp
HgBBAMdBygUaT9NkmKjGVUMSQCwch+cugDFx72VoQB15tPfFLwffuRbGIgykWJwIlbGWiFIpd4xp
M/n9BeK81Lz5snePrZZhFIhiX9MANtLwACJEhnN51TNbojCZOVpLqciLj/KuvBpeOvzxHeEjD1FL
Cw49xta2ZDODheKXrrr+pw/+borTpi7M8H2av8C74r/Na3+LNj8TvfQXs3sHiYB5WFENUjc8gTGU
a6F0BtY21VipIJ1BJqtWvTd65CGYQ8VHxthsLnv/L3//3R/9fOtfX2vraJ3KtGkUIgkC59TTKZ/X
x63Qx58og/3R1heqD98fvfoS1alihLjLwyXDkHtmUz6PKGryb3GxYoGXHqtXr0XVP4TtiYibcv/0
3JZtu/Z09XQAmCYPgoC7u9VpZ0i5LL4vpSLclHv2udzegaAaN1k7car1t3buTzCGFyyC1rVDbAtj
kud4wwvRF16ETDqZbONTZTKe57pTtLRGYYZf0RdeTD2zEAaId8SuG259IXz2j+SlYcyoNZMaxluE
2jsBikkolabWNrhuQsWEqk9dPc6a86VYBB9qn2Ot2ClsGEeIUigU+KR369VrUW9RhBw3ePRBqVTi
hXSkv2sKW5XiBUeAmdrakUqZHW9Ubvif6E9PUSYLaxL+qq//+WK18niUCph8FmESwowgpLY295JP
JecuAKyldNq88Wr45GPkpWGiWlhUL0ZI3AMxoohaWtSio+y+veFvHwn//Cez7TUpDoWbn1XHHU+Z
TGJsxsBz3HWfq/7Xf0qphJSX0M6sxKtq1Xc++0VesFCGhoaHj5V/1wYpFclLN6iouXR27koQwUSU
zaljlkcvbZG+A3BdSmfgpaVYSF3wwfSnvyCDA0m91iCTta+9GlzzdSmX4XmH8emTFWZYQaXsrrtU
vX8NCjUeE1G+LfjDo+VvX0WpFMKodhqNESdJtfiClZSL4dOPo1Ki1jbyMhCgWqV0pvrw/eETv6N8
K6IoHieUSrz0GPfyK5DOoFSCnpGrlwAApRBFKJfcdZfq1eehWOOxlry03b3T/94NpDWMjbe3wEge
NOceFOVaoBQiA2sgcTFLrMq3f8e+uYuyuUQh8cQ9eql3xTd48ZHS3x8fgU4LhghKSaEAz3O/9BX9
/nNlaKDuEqCUAOWbvmX7e6FUcgdi1CKb1HS442eC40pQ1e9Yll1/DTIZVP2kJWOQyaBSDu++M/r1
wwAhnYZI00o9QRhmBAH8Cp/0bveSTzXNn/ioLJ0p33xt8MsHKJNBECStTOD4uZGq4ZIAMVxXKiV9
7Mrs+quRzsD36/YApZDJ2ueeCe+8w2x7A0qR50Gphkj5kCTWolqVIODubn3hxXr1Wlg7XH+d55br
gofuo1wLwmCylwQwUlG1qw9wXSmX9bErspdfTdmsVCrDrVpL2Zz4ZfPMxuipJ+zLf5VSiRwHjgOl
hlOcSfUCAaxBFEoQkOPw4qPUqaer086g7lkoFREHb7XxIi9dvvm64OGYJ5zaVY5RVMmFG4LrSqmk
l63M/MeV3NktxULyedw8M2WyYiL7xuvm+efsS1vsm2+iWEAUybBLFChFrJDJck8PL1vOK9+plq+k
TEYqFYTh8IQ0hjwPQPm2/wsevr/GYydyOWpS16IYjitVn7tnZdZdpt+1SoqFGCZ511oQIZUiNyWV
igz0yf79MjQou3eCGSAxEffMoq5u6uikrm7K5SSK4PswZnh0xEJALXmze2flpm9FW56nTBZhNM1r
UeNRMZigHZhIAO/ij6Yu+BB5KSmVgIZUWTx3maE1HIeIk61oDVusIIoQhfWNWa2ghRXy0tAqePIx
/3s32P5eSqcRhjNyeW0sqtplVigNZqmU1ZKl3r9+wjnpPQCJX2kabGDYPTQ6CapFyU2vWRBRyoPj
mjde9e/aEG56mrQGK0ThDF4xPCQVM7SWahXEzgnvSp33L2rZSspkUa1KUIXYJBFdZ2iqssYpAiI4
LnkewtDsfKP6qwfCJx+TUpHSGRiTGNuMXgQdk6rhaCNWl1+BVurIpe7pZ+mVJ/H8hZTyICJhCGOS
TQrVamIGKzCR44IZUWQP7Iu2vhhu/EO0dbOUSuSlQYQo+vtd1x1FhdqBTe3IEEqDIEGAKKSWNrX4
KLXkGP2OY3neQsq3UsqjTLauNwkCKRXgV8zeN822V83fXjLbXrO9b4OYUimAYKIkp4XGvd1EeSaO
1FgpmtRVP+lQDFawVoIA1oCZWvKU8qitnTu6kkiKWcol+/Y+RKEd6IeJQEyuC6UhFlHNp2FM5UyI
Z1JIY9XeBNbg6+trpRXYSBrTFUykHBDAtSTjCO88DDMVHkzyfy7qE6L2ffiqvUAIlGzUhglBUA7p
EdGDQARROIphujBTQGpsoBEs/rDWidiPCZo02SiNna779zFIxix8eJnyVqcRDM1sMRWaR30skTGe
muufikxz9zYCrOG5jjeujMc63YPHGdmQjndcM4Uk0QwcpP4/dMc3Ayfur5oAAAAASUVORK5CYII=
AZ_EOF
az_b64 /tmp/az_logo.b64 "$PLUGIN_DIR/logo.png"

cat > /tmp/az_logo_fhd.b64 << 'AZ_EOF'
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
TkSuQmCC
AZ_EOF
az_b64 /tmp/az_logo_fhd.b64 "$PLUGIN_DIR/logo_fhd.png"

chmod 755 "$PLUGIN_DIR"
chmod 644 "$PLUGIN_DIR"/*

# --- syntax check with the image's own Python (.py source is kept on
#     purpose so the plugin survives Python upgrades of the image) ---
if [ -n "$PY" ]; then
    if $PY -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$PLUGIN_DIR/plugin.py" >/dev/null 2>&1; then
        echo ">>> Syntax check OK"
    else
        echo "!!! Syntax check FAILED - installation cancelled:"
        $PY -c "import py_compile,sys; py_compile.compile(sys.argv[1], doraise=True)" "$PLUGIN_DIR/plugin.py"
        rm -rf "$PLUGIN_DIR"
        exit 1
    fi
fi

# --- settings cleanup (obsolete keys of old versions), done while GUI is stopped ---
cat > /tmp/autozap_clean.sh << 'AZ_EOF'
S=/etc/enigma2/settings
if [ -f "$S" ]; then
    grep -v '^config\.plugins\.autozap_alamri\.' "$S" > /tmp/az_settings.new
    grep -E '^config\.plugins\.autozap_alamri\.(enabled|scope|iptv|on_fail|ecm_watch|check_net|debug|language|excluded|hw_pts|hw_video|hw_ecm)=' "$S" >> /tmp/az_settings.new
    cat /tmp/az_settings.new > "$S"
    rm -f /tmp/az_settings.new
fi
AZ_EOF

# ---------------------------------------------------------------
# Safe GUI restart - runs detached so it also works when this
# script was started from a terminal plugin inside Enigma2.
# $1 = optional shell file to run while the GUI is stopped
# ---------------------------------------------------------------
az_restart_gui() {
    R=/tmp/autozap_restart.sh
    {
        echo '#!/bin/sh'
        echo 'sleep 2'
        echo 'if command -v systemctl >/dev/null 2>&1 && systemctl is-active enigma2 >/dev/null 2>&1; then'
        echo '    systemctl stop enigma2; sleep 2'
        [ -n "$1" ] && echo "    sh $1"
        echo '    systemctl start enigma2'
        echo 'else'
        echo '    init 4 >/dev/null 2>&1'
        echo '    i=0'
        echo '    while pidof enigma2 >/dev/null 2>&1 && [ $i -lt 20 ]; do sleep 1; i=$((i+1)); done'
        [ -n "$1" ] && echo "    sh $1"
        echo '    if pidof enigma2 >/dev/null 2>&1; then killall -9 enigma2 >/dev/null 2>&1; else init 3 >/dev/null 2>&1; fi'
        echo 'fi'
        [ -n "$1" ] && echo "rm -f $1"
        echo 'rm -f /tmp/autozap_restart.sh'
    } > "$R"
    chmod 755 "$R"
    if command -v nohup >/dev/null 2>&1; then
        nohup sh "$R" >/dev/null 2>&1 &
    else
        sh "$R" >/dev/null 2>&1 &
    fi
}

echo ""
echo ">>> AutoZap Recovery v1.1 installed successfully."
echo ">>> Plugins menu : AutoZap Recovery"
echo ">>> Blue button  : AutoZap On/Off  -  Exclude/include channel"
echo ">>> Restarting Enigma2 GUI in 2 seconds..."
echo "=============================================="
az_restart_gui /tmp/autozap_clean.sh
exit 0
