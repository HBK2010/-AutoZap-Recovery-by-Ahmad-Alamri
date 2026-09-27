#!/bin/sh
# ================================================================
#   AutoZap Recovery v2.1 Final - Installer
#   Designed & Developed by: Ahmad Alamri
#   (C) 2026 Ahmad Alamri - All Rights Reserved
#   OpenATV / OpenPLi / OpenBH / OpenViX / Egami / PurE2 / VTi /
#   OpenSPA / DreamOS  -  Python 2.7 & Python 3.x
# ================================================================
PLUGIN_DIR="/usr/lib/enigma2/python/Plugins/Extensions/AutoZap_AhmadAlamri"

echo ""
echo "=============================================="
echo "   AutoZap Recovery v2.1 Final"
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
#  Version     : 2.1 Final
#  Designed and Developed by : Ahmad Alamri
#  Copyright   : (C) 2026 Ahmad Alamri - All Rights Reserved
#  Description : Smart auto-recovery for frozen channels on Enigma2
#  Compatible  : OpenATV, OpenPLi, OpenBH, OpenViX, Egami, PurE2, VTi,
#                OpenSPA, DreamOS  -  Python 2.7 and Python 3.x
# ========================================================================
#
#  Detection principle (healthy channels are never touched):
#    A channel is treated as frozen ONLY when a playback-progress counter
#    that is PROVEN to work on this receiver stops moving for
#    "freeze_time" seconds, after the start-up grace period, while the
#    tuner still has signal lock. Radio, recordings, media files,
#    timeshift, paused playback, excluded channels and receivers without
#    a usable progress source are skipped.
# ========================================================================

import os
import time

from enigma import eTimer, getDesktop, iPlayableService, iServiceInformation
try:
    from enigma import iFrontendInformation
except ImportError:
    iFrontendInformation = None

from Components.ActionMap import ActionMap
from Components.ConfigList import ConfigListScreen
from Components.Label import Label
from Components.ScrollLabel import ScrollLabel
from Components.Sources.StaticText import StaticText
from Components.config import (config, configfile, ConfigSubsection, ConfigText,
                               ConfigYesNo, ConfigSelection, getConfigListEntry)
from Plugins.Plugin import PluginDescriptor
from Screens.MessageBox import MessageBox
from Screens.Screen import Screen

VERSION = "2.1"
AUTHOR = "Ahmad Alamri"
COPYRIGHT = "(C) 2026 Ahmad Alamri - All Rights Reserved"
PLUGIN_PATH = os.path.dirname(os.path.abspath(__file__))
LOG_FILE = "/tmp/autozap.log"
LOG_MAX_BYTES = 256 * 1024
POLL_MS = 2000
STABLE_RESET_SEC = 60
PTS_PATHS = ("/proc/stb/vmpeg/0/pts", "/proc/stb/video/pts")
IPTV_TYPES = (4097, 5001, 5002, 8193, 8739)
RADIO_SERVICE_TYPES = (0x02, 0x0A)

# ------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------
config.plugins.autozap_alamri = ConfigSubsection()
cfg = config.plugins.autozap_alamri
cfg.language = ConfigSelection(default="auto", choices=[
    ("auto", "Auto / تلقائي"), ("ar", "العربية"), ("en", "English")])


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


def _secs(values):
    return [(str(v), "%d %s" % (v, T("ثانية", "sec"))) for v in values]


cfg.enabled = ConfigYesNo(default=True)
cfg.scope = ConfigSelection(default="crypted", choices=[
    ("crypted", T("القنوات المشفرة فقط", "Encrypted channels only")),
    ("all", T("كل القنوات", "All channels"))])
cfg.iptv = ConfigYesNo(default=True)
cfg.freeze_time = ConfigSelection(default="10", choices=_secs((6, 8, 10, 12, 15, 20, 30)))
cfg.grace = ConfigSelection(default="15", choices=_secs((8, 10, 15, 20, 30, 45)))
cfg.max_retries = ConfigSelection(default="3", choices=[(str(v), str(v)) for v in range(1, 6)])
cfg.cooldown = ConfigSelection(default="5", choices=[
    ("0", T("لا (حتى تغيير القناة)", "Never (until zap)"))] +
    [(str(v), "%d %s" % (v, T("دقيقة", "min"))) for v in (2, 5, 10, 30)])
cfg.check_net = ConfigYesNo(default=True)
cfg.notify = ConfigYesNo(default=True)
cfg.debug = ConfigYesNo(default=False)
cfg.excluded = ConfigText(default="", fixed_size=False)


# ------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------
def log(msg):
    try:
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > LOG_MAX_BYTES:
            os.rename(LOG_FILE, LOG_FILE + ".1")
        line = "%s  %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
        if not isinstance(line, bytes):
            line = line.encode("utf-8", "ignore")
        with open(LOG_FILE, "ab") as f:
            f.write(line)
    except Exception:
        pass


def debug(msg):
    if cfg.debug.value:
        log("[debug] %s" % msg)


def read_log_tail(max_lines=200):
    try:
        with open(LOG_FILE, "rb") as f:
            data = f.read()
        if not isinstance(data, str):
            data = data.decode("utf-8", "ignore")
        lines = data.strip().splitlines()[-max_lines:]
        lines.reverse()                     # newest first
        return "\n".join(lines)
    except Exception:
        return ""


def notify(text, timeout=4):
    if not cfg.notify.value:
        return
    try:
        from Tools import Notifications
        Notifications.AddPopup(text, MessageBox.TYPE_INFO, timeout, "AutoZapRecovery")
    except Exception as e:
        debug("popup failed: %s" % e)


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


def connect_timer(timer, fnc, keep):
    try:
        timer.callback.append(fnc)
    except AttributeError:          # DreamOS / newer enigma
        keep.append(timer.timeout.connect(fnc))


def ref_key(ref_str):
    """Stable key of a service reference (without the display name)."""
    return ":".join((ref_str or "").split(":")[:11])


def excluded_keys():
    return [k for k in cfg.excluded.value.split("|") if k]


def save_excluded(keys):
    cfg.excluded.value = "|".join(keys)
    cfg.excluded.save()
    configfile.save()


def skin_scale():
    try:
        width = getDesktop(0).size().width()
    except Exception:
        width = 1280
    return max(0.55, width / 1280.0)


def logo_file(k):
    name = "logo_fhd.png" if k >= 1.4 else "logo.png"
    path = os.path.join(PLUGIN_PATH, name)
    return path if os.path.exists(path) else None


# ------------------------------------------------------------------------
# Core monitor
# ------------------------------------------------------------------------
class AutoZapCore(object):
    def __init__(self, session):
        self.session = session
        self._conns = []
        self.pts_validated = False   # decoder PTS proven to move on this box
        self.restarts = 0
        self.recovered = 0
        self.last_action = ""
        self.state = ""
        self.channel = ""
        self.pending_ref = None
        self.in_restart = False
        self._reset_state(None)

        self.poll = eTimer()
        connect_timer(self.poll, self.tick, self._conns)
        self.play_timer = eTimer()
        connect_timer(self.play_timer, self._play_pending, self._conns)
        try:
            session.nav.event.append(self._on_nav_event)
        except Exception as e:
            debug("nav.event unavailable: %s" % e)
        self.poll.start(POLL_MS, False)
        log("AutoZap Recovery v%s started - %s" % (VERSION, AUTHOR))

    # --- state ---------------------------------------------------------
    def _reset_state(self, ref_str, keep_retries=False):
        now = time.time()
        self.ref_str = ref_str
        self.zap_time = now
        self.last_pos = None
        self.last_change = now
        self.good_since = None
        self._last_skip = None
        if not keep_retries:
            self.retries = 0
            self.gave_up_at = None
            self.ever_advanced = False
            self.awaiting_result = False

    def reset(self):
        self._reset_state(None)

    def _on_nav_event(self, ev):
        if self.in_restart or self.pending_ref is not None:
            return
        try:
            if ev == iPlayableService.evStart:
                ref = self.session.nav.getCurrentlyPlayingServiceReference()
                self._reset_state(ref.toString() if ref else None)
        except Exception:
            pass

    def _skip(self, reason):
        if reason != self._last_skip:
            self._last_skip = reason
            debug("%s | %s" % (reason, self.ref_str or "-"))

    # --- environment checks ------------------------------------------
    def _in_standby(self):
        try:
            import Screens.Standby
            return bool(Screens.Standby.inStandby)
        except Exception:
            return False

    def _is_paused(self):
        try:
            from Screens.InfoBar import InfoBar
            ib = InfoBar.instance
            state = getattr(ib, "seekstate", None)
            play = getattr(ib, "SEEK_STATE_PLAY", None)
            if ib is not None and state is not None and play is not None and state != play:
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

    def _timeshift_active(self, service):
        try:
            ts = service.timeshift()
            return bool(ts and ts.isTimeshiftActive())
        except Exception:
            return False

    def _classify(self, ref, ref_str, service):
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
            if not cfg.iptv.value:
                return None, T("مراقبة IPTV متوقفة", "IPTV monitoring off")
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
        if cfg.scope.value == "crypted" and info.getInfo(iServiceInformation.sIsCrypted) != 1:
            return None, T("قناة مفتوحة (خارج النطاق)", "Free channel (out of scope)")
        if self._timeshift_active(service):
            return None, T("التايم شفت نشط", "Timeshift active")
        return "dvb", ""

    def _read_position(self, kind, service):
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
        for path in PTS_PATHS:
            try:
                with open(path) as f:
                    value = f.read().strip()
                if value:
                    return value, False
            except (IOError, OSError):
                continue
        return None, False

    def _unsafe_reason(self, kind, service):
        crypted = False
        try:
            info = service.info()
            crypted = bool(info and info.getInfo(iServiceInformation.sIsCrypted) == 1)
        except Exception:
            pass
        if kind == "dvb" and iFrontendInformation is not None:
            try:
                fe = service.frontendInfo()
                if fe is not None and fe.getFrontendInfo(iFrontendInformation.lockState) == 0:
                    return T("لا توجد إشارة من التيونر", "No tuner signal lock")
            except Exception:
                pass
        if cfg.check_net.value and (kind == "iptv" or crypted) and not has_default_route():
            return T("الشبكة مفصولة - بانتظار عودتها", "Network down - waiting")
        return None

    def _limit(self):
        # a channel never seen playing gets a single attempt only
        return int(cfg.max_retries.value) if self.ever_advanced else 1

    @staticmethod
    def _name(service):
        try:
            info = service.info()
            return (info and info.getName()) or "?"
        except Exception:
            return "?"

    # --- main loop -----------------------------------------------------
    def tick(self):
        try:
            self._tick()
        except Exception as e:
            log("tick error: %s" % e)

    def _tick(self):
        if self.pending_ref is not None:
            return
        if not cfg.enabled.value:
            self.state = T("متوقف", "Disabled")
            return
        if self._in_standby():
            self.state = T("الجهاز في وضع الاستعداد", "Standby")
            self.channel = ""
            self._reset_state(None)
            return
        nav = self.session.nav
        ref = nav.getCurrentlyPlayingServiceReference()
        if ref is None:
            self.state = T("لا توجد قناة", "No service")
            self.channel = ""
            self._reset_state(None)
            return
        ref_str = ref.toString()
        if ref_str != self.ref_str:
            self._reset_state(ref_str)
            return
        service = nav.getCurrentService()
        if service is None:
            return
        self.channel = self._name(service)
        kind, why = self._classify(ref, ref_str, service)
        if kind is None:
            self.state = T("تخطي: ", "Skipped: ") + why
            self.last_pos = None
            return

        pos, trusted = self._read_position(kind, service)
        if pos is None:
            self.state = T("لا يوجد مصدر كشف بهذا الجهاز", "No detection source on this box")
            self._skip("no progress source on this receiver - no action")
            return
        now = time.time()

        # ---- picture is moving ----
        if pos != self.last_pos:
            if self.last_pos is not None:
                self.ever_advanced = True
                if not trusted:
                    self.pts_validated = True
                if self.awaiting_result:
                    self.awaiting_result = False
                    self.recovered += 1
                    log("Recovered OK: %s" % self.channel)
                self.state = T("يراقب - البث سليم", "Monitoring - playing OK")
            if self.good_since is None:
                self.good_since = now
            self.last_pos = pos
            self.last_change = now
            if self.retries and now - self.good_since >= STABLE_RESET_SEC:
                self.retries = 0
                self.gave_up_at = None
            return

        # ---- picture did not move ----
        self.good_since = None
        if now - self.zap_time < int(cfg.grace.value):
            self.state = T("مهلة بدء القناة", "Start-up grace")
            return
        if not (self.ever_advanced or trusted or self.pts_validated):
            self.state = T("بانتظار التحقق من مصدر الكشف", "Verifying detection source")
            self._skip("progress source not verified yet - no action")
            return
        stalled = now - self.last_change
        if stalled < int(cfg.freeze_time.value):
            self.state = T("اشتباه تجمد: %d ث", "Possible freeze: %ds") % int(stalled)
            return
        reason = self._unsafe_reason(kind, service)
        if reason:
            self.state = reason
            self._skip(reason)
            self.last_change = now          # demand a full new freeze window
            return

        limit = self._limit()
        if self.retries >= limit:
            if self.gave_up_at is None:
                self.gave_up_at = now
                log("Gave up after %d attempts: %s" % (self.retries, self.channel))
                notify(T("AutoZap: القناة لم تستجب، تم إيقاف المحاولات مؤقتاً",
                         "AutoZap: channel did not respond, attempts paused"))
            cooldown = int(cfg.cooldown.value) * 60
            self.state = T("توقفت المحاولات لهذه القناة", "Attempts paused for this channel")
            if cooldown and now - self.gave_up_at >= cooldown:
                self.retries = 0
                self.gave_up_at = None
                self.last_change = now
            return
        self._restart(stalled, limit)

    # --- recovery ------------------------------------------------------
    def _restart(self, stalled, limit):
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
        if target is None:
            return

        self.retries += 1
        self.restarts += 1
        self.awaiting_result = True
        name = self.channel or "?"
        self.last_action = "%s  %s  (%d/%d)" % (time.strftime("%H:%M"), name, self.retries, limit)
        self.state = T("جاري الإنعاش...", "Recovering...")
        log("Frozen %ds -> restart %d/%d: %s" % (int(stalled), self.retries, limit, name))
        notify(T("AutoZap: جاري إنعاش %s (%d/%d)", "AutoZap: recovering %s (%d/%d)")
               % (name, self.retries, limit))

        # stopService + playService is a real restart on every image
        # (playService() on the running reference alone is ignored).
        self.pending_ref = target
        try:
            nav.stopService()
        except Exception as e:
            log("stopService failed: %s" % e)
        # longer gap on each attempt so the softcam drops the old ECM session
        self.play_timer.start(500 + 700 * (self.retries - 1), True)

    def _play_pending(self):
        target, self.pending_ref = self.pending_ref, None
        if target is None:
            return
        nav = self.session.nav
        try:
            if nav.getCurrentlyPlayingServiceReference() is not None:
                log("User changed channel during recovery - skipped")
                self._reset_state(None)
                return
        except Exception:
            pass
        self.in_restart = True
        try:
            try:
                nav.playService(target, checkParentalControl=False)
            except TypeError:
                nav.playService(target)
        except Exception as e:
            log("playService failed: %s" % e)
        finally:
            self.in_restart = False
        cur = None
        try:
            ref = nav.getCurrentlyPlayingServiceReference()
            cur = ref.toString() if ref else None
        except Exception:
            pass
        self._reset_state(cur, keep_retries=True)

    # --- status for the setup screen ----------------------------------
    def status_text(self):
        src = T("مؤكد", "Verified") if self.pts_validated else T("قيد التحقق", "Checking")
        lines = [
            T("الحالة: ", "State: ") + (self.state or "-"),
            T("القناة: ", "Channel: ") + (self.channel or "-"),
            T("مصدر الكشف: ", "Detection: ") + src,
            T("محاولات الإنعاش: %d", "Restarts: %d") % self.restarts,
            T("إنعاش ناجح: %d", "Recovered: %d") % self.recovered,
            T("القنوات المستثناة: %d", "Excluded channels: %d") % len(excluded_keys()),
        ]
        if self.last_action:
            lines.append(T("آخر إجراء:", "Last action:"))
            lines.append(self.last_action)
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
# Skins (drawn by the plugin itself - same look on every image skin)
# ------------------------------------------------------------------------
C_BG = "#000b1a2e"
C_PANEL = "#00102440"
C_GOLD = "#00f0a500"
C_CYAN = "#0019c3e6"
C_TEXT = "#00ffffff"
C_DIM = "#009fb3c8"


def _button_row(z, y, h, font, x0, width, gap):
    colors = (("key_red", "#00b3261e"), ("key_green", "#00188a2e"),
              ("key_yellow", "#00b58900"), ("key_blue", "#001c5fb8"))
    out = []
    for i, (name, col) in enumerate(colors):
        x = x0 + i * (width + gap)
        out.append('<eLabel position="%d,%d" size="%d,%d" backgroundColor="%s" zPosition="1" />'
                   % (z(x), z(y + h - 5), z(width), z(5), col))
        out.append('<widget source="%s" render="Label" position="%d,%d" size="%d,%d" font="Regular;%d" '
                   'halign="center" valign="center" foregroundColor="%s" backgroundColor="%s" '
                   'transparent="1" zPosition="2" />'
                   % (name, z(x), z(y), z(width), z(h - 5), z(font), C_TEXT, C_BG))
    return "\n  ".join(out)


def _header(z, W, title_font=30):
    k = skin_scale()
    logo = logo_file(k)
    size = 105 if k >= 1.4 else 70
    parts = [
        '<eLabel position="0,0" size="%d,%d" backgroundColor="%s" zPosition="0" />' % (z(W), z(80), C_BG),
        '<eLabel position="0,%d" size="%d,%d" backgroundColor="%s" zPosition="1" />' % (z(80), z(W), max(2, z(3)), C_GOLD),
        '<widget source="title" render="Label" position="%d,%d" size="%d,%d" font="Regular;%d" '
        'foregroundColor="%s" backgroundColor="%s" transparent="1" valign="center" zPosition="2" />'
        % (z(100), z(6), z(W - 330), z(42), z(title_font), C_TEXT, C_BG),
        '<widget source="subtitle" render="Label" position="%d,%d" size="%d,%d" font="Regular;%d" '
        'foregroundColor="%s" backgroundColor="%s" transparent="1" valign="center" zPosition="2" />'
        % (z(100), z(48), z(W - 330), z(26), z(18), C_GOLD, C_BG),
    ]
    if logo and size + z(15) <= z(100) and size <= z(80):
        # opaque image drawn at its native pixel size, centred in the header
        parts.append('<ePixmap position="%d,%d" size="%d,%d" pixmap="%s" zPosition="2" />'
                     % (z(15), (z(80) - size) // 2, size, size, logo))
    return "\n  ".join(parts)


def setup_skin():
    k = skin_scale()

    def z(v):
        return int(round(v * k))

    W, H = 1040, 620
    return """
<screen name="AutoZapSetupV2" position="center,center" size="%(w)d,%(h)d" flags="wfNoBorder" backgroundColor="%(bg)s" title="AutoZap Recovery">
  %(header)s
  <widget name="badge_on" position="%(bx)d,%(by)d" size="%(bw)d,%(bh)d" font="Regular;%(bf)d" halign="center" valign="center" foregroundColor="#00ffffff" backgroundColor="#00188a2e" zPosition="3" />
  <widget name="badge_off" position="%(bx)d,%(by)d" size="%(bw)d,%(bh)d" font="Regular;%(bf)d" halign="center" valign="center" foregroundColor="#00ffffff" backgroundColor="#00b3261e" zPosition="3" />
  <widget name="config" position="%(cx)d,%(cy)d" size="%(cw)d,%(ch)d" backgroundColor="%(bg)s" scrollbarMode="showOnDemand" zPosition="1" />
  <eLabel position="%(px)d,%(cy)d" size="%(pw)d,%(ch)d" backgroundColor="%(panel)s" zPosition="0" />
  <eLabel position="%(px)d,%(cy)d" size="%(stripe)d,%(ch)d" backgroundColor="%(cyan)s" zPosition="1" />
  <widget source="status_title" render="Label" position="%(ptx)d,%(pty)d" size="%(ptw)d,%(pth)d" font="Regular;%(ptf)d" halign="%(al)s" foregroundColor="%(cyan)s" backgroundColor="%(panel)s" transparent="1" zPosition="2" />
  <widget source="status" render="Label" position="%(ptx)d,%(psy)d" size="%(ptw)d,%(psh)d" font="Regular;%(psf)d" halign="%(al)s" foregroundColor="%(text)s" backgroundColor="%(panel)s" transparent="1" zPosition="2" />
  <widget source="help" render="Label" position="%(cx)d,%(hy)d" size="%(fullw)d,%(hh)d" font="Regular;%(hf)d" halign="%(al)s" foregroundColor="%(dim)s" backgroundColor="%(bg)s" transparent="1" valign="center" zPosition="2" />
  <eLabel position="0,%(ly)d" size="%(w)d,%(line)d" backgroundColor="%(gold)s" zPosition="1" />
  %(buttons)s
  <widget source="copyright" render="Label" position="0,%(fy)d" size="%(w)d,%(fh)d" font="Regular;%(ff)d" halign="center" valign="center" foregroundColor="%(gold)s" backgroundColor="%(bg)s" transparent="1" zPosition="2" />
</screen>""" % dict(
        w=z(W), h=z(H), bg=C_BG, panel=C_PANEL, gold=C_GOLD, cyan=C_CYAN, text=C_TEXT, dim=C_DIM,
        header=_header(z, W), al="right" if is_arabic() else "left",
        bx=z(W - 190), by=z(22), bw=z(170), bh=z(36), bf=z(20),
        cx=z(20), cy=z(100), cw=z(620), ch=z(390),
        px=z(660), pw=z(360), stripe=max(2, z(4)),
        ptx=z(680), pty=z(110), ptw=z(330), pth=z(34), ptf=z(24),
        psy=z(150), psh=z(330), psf=z(19),
        hy=z(495), fullw=z(1000), hh=z(28), hf=z(17),
        ly=z(528), line=max(1, z(2)),
        buttons=_button_row(z, 538, 44, 20, 20, 235, 20),
        fy=z(588), fh=z(28), ff=z(17))


def log_skin():
    k = skin_scale()

    def z(v):
        return int(round(v * k))

    W, H = 1040, 620
    return """
<screen name="AutoZapLogV2" position="center,center" size="%(w)d,%(h)d" flags="wfNoBorder" backgroundColor="%(bg)s" title="AutoZap Recovery - Log">
  %(header)s
  <eLabel position="%(x)d,%(y)d" size="%(tw)d,%(th)d" backgroundColor="%(panel)s" zPosition="0" />
  <widget name="text" position="%(ix)d,%(iy)d" size="%(iw)d,%(ih)d" font="Regular;%(f)d" foregroundColor="%(text)s" backgroundColor="%(panel)s" transparent="1" zPosition="1" />
  <eLabel position="0,%(ly)d" size="%(w)d,%(line)d" backgroundColor="%(gold)s" zPosition="1" />
  %(buttons)s
  <widget source="copyright" render="Label" position="0,%(fy)d" size="%(w)d,%(fh)d" font="Regular;%(ff)d" halign="center" valign="center" foregroundColor="%(gold)s" backgroundColor="%(bg)s" transparent="1" zPosition="2" />
</screen>""" % dict(
        w=z(W), h=z(H), bg=C_BG, panel=C_PANEL, gold=C_GOLD, text=C_TEXT,
        header=_header(z, W),
        x=z(20), y=z(100), tw=z(1000), th=z(420),
        ix=z(35), iy=z(110), iw=z(970), ih=z(400), f=z(18),
        ly=z(528), line=max(1, z(2)),
        buttons=_button_row(z, 538, 44, 20, 20, 235, 20),
        fy=z(588), fh=z(28), ff=z(17))


# ------------------------------------------------------------------------
# Screens
# ------------------------------------------------------------------------
class AutoZapLog(Screen):
    def __init__(self, session):
        self.skin = log_skin()
        Screen.__init__(self, session)
        self["title"] = StaticText("AutoZap Recovery")
        self["subtitle"] = StaticText(T("سجل الأحداث (الأحدث أولاً)", "Event log (newest first)"))
        self["copyright"] = StaticText("Designed & Developed by %s  |  %s" % (AUTHOR, COPYRIGHT))
        self["key_red"] = StaticText(T("مسح السجل", "Clear log"))
        self["key_green"] = StaticText(T("تحديث", "Refresh"))
        self["key_yellow"] = StaticText("")
        self["key_blue"] = StaticText(T("رجوع", "Back"))
        self["text"] = ScrollLabel("")
        self["actions"] = ActionMap(["OkCancelActions", "DirectionActions", "ColorActions"], {
            "ok": self.close,
            "cancel": self.close,
            "blue": self.close,
            "red": self.clear,
            "green": self.load,
            "up": self["text"].pageUp,
            "down": self["text"].pageDown,
            "left": self["text"].pageUp,
            "right": self["text"].pageDown,
        }, -1)
        self.onLayoutFinish.append(self.load)

    def load(self):
        text = read_log_tail()
        self["text"].setText(text or T("السجل فارغ. تُسجَّل هنا كل عمليات الإنعاش، "
                                        "وفعّل (سجل التشخيص) لعرض أسباب التخطي.",
                                        "Log is empty. Every recovery is written here; enable "
                                        "'Debug log' to also see skip reasons."))

    def clear(self):
        for path in (LOG_FILE, LOG_FILE + ".1"):
            try:
                os.remove(path)
            except Exception:
                pass
        self.load()


class AutoZapSetup(ConfigListScreen, Screen):
    def __init__(self, session):
        self.skin = setup_skin()
        Screen.__init__(self, session)
        self.session = session
        self.list = []
        ConfigListScreen.__init__(self, self.list, session=session)
        self._conns = []

        self["title"] = StaticText("AutoZap Recovery")
        self["subtitle"] = StaticText(T("الإنعاش الذكي للقنوات المتجمدة  |  الإصدار %s",
                                        "Smart freeze recovery for Enigma2  |  v%s") % VERSION)
        self["badge_on"] = Label(T("يعمل", "ACTIVE"))
        self["badge_off"] = Label(T("متوقف", "OFF"))
        self["status_title"] = StaticText(T("الحالة المباشرة", "Live status"))
        self["status"] = StaticText("")
        self["help"] = StaticText("")
        self["copyright"] = StaticText("Designed & Developed by %s  |  %s" % (AUTHOR, COPYRIGHT))
        self["key_red"] = StaticText(T("إلغاء", "Cancel"))
        self["key_green"] = StaticText(T("حفظ", "Save"))
        self["key_yellow"] = StaticText(T("السجل", "Log"))
        self["key_blue"] = StaticText(T("حول", "About"))
        self["actions"] = ActionMap(["SetupActions", "ColorActions"], {
            "green": self.save,
            "ok": self.save,
            "red": self.cancel,
            "cancel": self.cancel,
            "yellow": self.open_log,
            "blue": self.about,
        }, -2)

        self.status_timer = eTimer()
        connect_timer(self.status_timer, self._update_status, self._conns)
        self.onLayoutFinish.append(self._layout_finished)
        self.onClose.append(self.status_timer.stop)
        self._build()
        try:
            self["config"].onSelectionChanged.append(self._update_help)
        except Exception:
            pass

    # --- ui ------------------------------------------------------------
    def _layout_finished(self):
        self.setTitle("AutoZap Recovery v%s | %s" % (VERSION, AUTHOR))
        self._update_badge()
        self._update_help()
        self._update_status()
        self.status_timer.start(2000, False)

    def _update_badge(self):
        if cfg.enabled.value:
            self["badge_on"].show()
            self["badge_off"].hide()
        else:
            self["badge_on"].hide()
            self["badge_off"].show()

    def _update_status(self):
        if core is None:
            text = T("المراقبة غير نشطة - أعد تشغيل الواجهة", "Monitor not running - restart the GUI")
        elif not cfg.enabled.value:
            text = T("الإنعاش التلقائي متوقف.\nفعّله من القائمة أو من\nزر الإضافات (الأزرق).",
                     "Auto recovery is disabled.\nEnable it here or from the\nExtensions (blue) menu.")
        else:
            text = core.status_text()
        self["status"].setText(text)

    HELP = {
        "enabled": ("تشغيل أو إيقاف المراقبة بالكامل.", "Turn monitoring on or off."),
        "scope": ("المشفرة فقط = الأنسب لمشاكل الشيرنج والكروت.", "Encrypted only = best for sharing/card issues."),
        "iptv": ("مراقبة روابط IPTV داخل قائمة القنوات.", "Watch IPTV streams in your bouquets."),
        "freeze_time": ("مدة توقف الصورة الفعلي قبل الإنعاش.", "How long the picture must be frozen."),
        "grace": ("وقت يُترك للقناة لتبدأ بعد التقليب.", "Time given to a channel to start after zapping."),
        "max_retries": ("عدد محاولات الإنعاش قبل التوقف المؤقت.", "Attempts before pausing recovery."),
        "cooldown": ("متى يعيد المحاولة بعد فشل كل المحاولات.", "When to try again after all attempts fail."),
        "check_net": ("لا ينعش إذا كانت الشبكة مفصولة.", "Skip recovery while the network is down."),
        "notify": ("رسالة صغيرة على الشاشة عند كل إنعاش.", "Small on-screen popup on every recovery."),
        "debug": ("يسجل أسباب التخطي في /tmp/autozap.log", "Writes skip reasons to /tmp/autozap.log"),
        "language": ("لغة البلجن - تطبق بعد إعادة تشغيل الواجهة.", "Plugin language - applies after GUI restart."),
    }

    def _update_help(self):
        try:
            cur = self["config"].getCurrent()
        except Exception:
            cur = None
        text = ""
        if cur:
            for key, pair in self.HELP.items():
                if getattr(cfg, key, None) is cur[1]:
                    text = T(pair[0], pair[1])
                    break
        self["help"].setText(text)

    def _build(self):
        lst = [getConfigListEntry(T("تفعيل الإنعاش التلقائي", "Enable auto recovery"), cfg.enabled)]
        if cfg.enabled.value:
            lst += [
                getConfigListEntry(T("نطاق المراقبة", "Monitor scope"), cfg.scope),
                getConfigListEntry(T("مراقبة قنوات IPTV", "Monitor IPTV streams"), cfg.iptv),
                getConfigListEntry(T("مدة التجمد قبل الإنعاش", "Freeze time before recovery"), cfg.freeze_time),
                getConfigListEntry(T("مهلة بدء القناة بعد التقليب", "Start-up grace after zap"), cfg.grace),
                getConfigListEntry(T("أقصى عدد محاولات", "Max attempts"), cfg.max_retries),
                getConfigListEntry(T("إعادة المحاولة بعد", "Retry again after"), cfg.cooldown),
                getConfigListEntry(T("فحص الشبكة قبل الإنعاش", "Check network first"), cfg.check_net),
                getConfigListEntry(T("إظهار إشعار عند الإنعاش", "Show notification"), cfg.notify),
                getConfigListEntry(T("سجل التشخيص", "Debug log"), cfg.debug),
            ]
        lst.append(getConfigListEntry(T("لغة البلجن", "Plugin language"), cfg.language))
        self.list = lst
        widget = self["config"]
        try:
            widget.list = lst
        except Exception:
            pass
        try:
            widget.l.setList(lst)
        except Exception:
            pass

    def _after_key(self):
        cur = self["config"].getCurrent()
        if cur and cur[1] is cfg.enabled:
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

    # --- actions -------------------------------------------------------
    def save(self):
        cfg.save()
        configfile.save()
        if core:
            core.reset()
        self.close()

    def cancel(self):
        try:
            for item in cfg.dict().values():
                item.cancel()
        except Exception:
            for item in self.list:
                item[1].cancel()
        self.close()

    def open_log(self):
        self.session.open(AutoZapLog)

    def about(self):
        text = "\n".join([
            "AutoZap Recovery  v%s" % VERSION,
            "",
            "Designed & Developed by: %s" % AUTHOR,
            COPYRIGHT,
            "",
            T("إنعاش ذكي للقنوات المتجمدة يعمل فقط عند حدوث تجمد فعلي،",
              "Smart recovery that acts only on a real, confirmed freeze"),
            T("ولا يتدخل في القنوات السليمة أو الراديو أو التسجيلات.",
              "and never touches healthy channels, radio or recordings."),
            "",
            T("استثناء قناة: من زر الإضافات (الأزرق) أثناء المشاهدة.",
              "Exclude a channel: Extensions (blue) menu while watching."),
            "",
            "Enigma2 Pro Community",
        ])
        self.session.open(MessageBox, text, MessageBox.TYPE_INFO)


# ------------------------------------------------------------------------
# Entry points
# ------------------------------------------------------------------------
def main(session, **kwargs):
    session.open(AutoZapSetup)


def toggle(session, **kwargs):
    cfg.enabled.value = not cfg.enabled.value
    cfg.enabled.save()
    configfile.save()
    if core:
        core.reset()
    text = (T("AutoZap Recovery: تم التفعيل", "AutoZap Recovery: enabled") if cfg.enabled.value
            else T("AutoZap Recovery: تم الإيقاف", "AutoZap Recovery: disabled"))
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
    name = core.channel if (core and core.channel) else key
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
    name = "AutoZap Recovery"
    icon = "plugin.png" if os.path.exists(os.path.join(PLUGIN_PATH, "plugin.png")) else None
    return [
        PluginDescriptor(name=name, where=PluginDescriptor.WHERE_SESSIONSTART, fnc=sessionstart),
        PluginDescriptor(name=name,
                         description=T("إنعاش القنوات المتجمدة تلقائياً", "Auto-recovery for frozen channels")
                         + " | " + AUTHOR,
                         where=PluginDescriptor.WHERE_PLUGINMENU, icon=icon, fnc=main),
        PluginDescriptor(name=T("AutoZap: تشغيل / إيقاف", "AutoZap: On / Off"),
                         description=name, where=PluginDescriptor.WHERE_EXTENSIONSMENU, fnc=toggle),
        PluginDescriptor(name=T("AutoZap: استثناء / إرجاع القناة الحالية", "AutoZap: Exclude / include this channel"),
                         description=name, where=PluginDescriptor.WHERE_EXTENSIONSMENU, fnc=toggle_exclude),
    ]
AZ_EOF

cat > /tmp/az_plugin.b64 << 'AZ_EOF'
iVBORw0KGgoAAAANSUhEUgAAAGQAAAAoCAYAAAAIeF9DAAAQ0ElEQVR4nO2be3xVxbXHvzN7n3Ny
Ts5JcvLgFR4KITwEkYfKQ4SgxKpwFS1VigrXtlC5+qleW20tryhVfN+2FBXRYoBCC4itIhZaBCkF
ioggUoLKIxAiIe/neew90z/2SSDmBLUXW++F3+cz2Z+cPbP27PXbs9aaNTMCQINgFkLkoU7k089t
iikSPcqU9NAaARD7ex7/LLRzEQJtKQoUYkPE0gva3sFuPQtJHlqAFhoE2qlYuZQZHpMfJyThIwRH
yw20drjQ/9a3+b+PRh0KAZ1SbUiAUDX1YYu5KRN5RGsEAsyNszBGgl2ez4vJaXy3tkIwf23QXvVu
UB4oSRCWcoScZ+R/CQFagykhu01I3zyoQt0xpMKXnKYfLs+nMzBl4ywMAVCaz/S0tjxyvMiI3PLC
ha6/7E8SmAqP6zwLXwXCUQGW5Iqe1fq3Uw9FO2Ta7rITzEi/gzmiLJ8+Lhc7EcK49tlucktBkkgJ
RFEalG7NcehTl8bhI+CUo9GxKrHPoknMeUcEIIVGCqiscTGsR7Vee98nCq3taJSB0tZiWiAF9+It
QbbsD4iUQJSoLbCVQGs+U7RTYveEAClBSIHSBkpJp2gDIYVzL8aJ0ybWvoXcc6vYShC1BSmBKFv2
B8TiLUECKbhtLaZJQ+pcqwG9YmdQSpdGtWqlNMRGjDQ0whDYyoNlebGVF6/fIJgqCaZKvH4DW3lj
9zwIQyCNxlF13iE1QmmQLs2KnUFpNaANqXPNBDfdiisMPi7x4DJ1fDPVNBxAGgI76gFTcmnPWkZm
V3FJh1q6pYfwu20AaiMGn5Qm8P5xPxsPJLPjYz/YCsMVRtk4pDTKPIehtMBlaj4u8YjiCoM0v93N
jFkRYalWlBPzAUJqtDCwIwkM71PDD3KKGJFVhc+jwQDU6Y2i9O0c4sZ+ldSPKmLTx8n8/O1MNu8N
IFwhhLbRii9EihCCD7etpXPH9gAMHDmOgo8Ong19nBE3Xj+aJQueavV+etfLCIXDZ+VZ1in3oE0+
446bw1GYkKC0iWm6mDXuCNOGf0qCqdE2lFRJ9p8IsK8kkaJKLwCZKQ30blNHz7Y1ZCQqru1dSU52
FfM3tyPvD52xolGktBxSnMig1c4OGzywiQyACTePYfbcX3ypF968dhn9L+7N+En3sPZP73yhNq+t
WY8/s1/T/z2zu7J57XK8CR6qa2qxbOtL9eFMOO3thdl6NUdRQgLaJCVJsvTOvzMiqxrLgkOlbl7Z
0Ynf723HRycTaYhKVGyUSanxuhTdM+q4oc+nTLr0KB1TItyXU8yATnVMfDmb6moTIS20apoyxe3F
rTddD8Duvfvp16cn3xp3HXmP/xKtNclJAYr+/hcA2nYfTF19A0/kPcC0707kmV+9zMxHf86ud35P
924XALDilV8CMOuxn/P0vJfplNmeOdPvY9jggfi8CXzwYQGzH/8lW/+2q1kfEjweXnnuCbwJHgDu
/lEeluWY54Pvb6BNRhoAJSfL2LbjfX6c9ySFx4oBqCrchWHIJlnVNbW8+vo6fjh9LuFIyxEmW/zS
jA+NEBLpdrHkzgJGZlUTjgjWF6Rx9XNDyHsrm4KSRNymIuiLku6PkO6PEPRFcZuKgpJE8t7K5urn
hrC+II1wRDAyq5oldxYg3S6kkBiGbrUTHrebcWNGA/CTvKeorKqmc8f2DBs8sGV3dfxAof+VN7Br
zz4Axk+6B39mP56e9zLeBA9vrniRm8bmMvXe6QzN/RbdunZhze9epFePbs1kPDbrfi7q2R2ARb95
lVdfX9d0r+slo/Bn9iPYZSD3T5/Lf1x3FQt/8WiLfixb+QYdew9nzR83MvnbN/HTH94Vt7+t6MLx
G9IQ2FYCM8YUkpNVQygiWPxuB2546VJO1LjJCETwuuymUM6KlcaQ2euyyQhEOFHj5oaXLmXxux0I
RwU5WTXMHFOIZSVgWy4UEpdULXrxjdFXkpwU4GRpOX/ZtpO16x1z0zhqTodqPTyMi9GjruDCLp34
YN8B/rxpK4cLi1j9+jrcLhffuW18U70x1+TwvUm3AFDw0UEemPl4XHlRy2L1G+sIhcMMvXwAiT5v
s/sLFi2nsqqaBYuWA/Dtb46NKycOIc6kTkqwox4u71XNPcOLsSzBho+CTFvZF7/HwmMqorZAaYGU
8XlV2om3PabC77GYtrIv6/an0hCRTLuimDGXlnPToAqWTD1E97Yth2+j4t9cvwmlFK+/9WcAbhqb
i8ftjvvML4ouHTsAcLK0vOm3ktIyADrFfFaHdm2Y//RsAELhMJPuepD6hlBTfcOQzJl+Hx9uW0vZ
oR3UFu0mweOYtXZtM5o972RZebNr2zbpmKbRol/xNSlAI3F7BDOuKcRtCo5WuLjn1b54TBspnPBY
AEopauvqMQyJbCViUlpgSI0hNbP/2AOtFQ0RwcJbD5D/3UOMzKrmWKWrWZuU5CSuuWo4AJMmjKO2
aDe/WfgsAEkBP9eOHoHSp0aVEXu59LRgi+fHM2dHjh0HICM9tem3NumOLzh6rBgpJS/Ne4zUYAoA
Dz38DHv/fqCZjPE3Xsu9d02msqqa7gNGk9y5P1HLcfaG0VzZGWmpza4nSkqb/NDpaEmIBiFBK4OO
GRGSvRrbhCU7MzlYmojPZTtkCLBsRXKSn1HDBlFeUU04Eo3LOjgmLdFtceBkIst3tSc1WdMQkTSE
BXuOeqkPu5y0cww3j83F7XKxeeu7+DP7NZXpcxxSJnxzDDU1dZSWVQBw1ZWD6dWjWxOJp6OsvBKA
Lp0zm37709tbOHTkGH17Z3PViCFc0DmTcWNziVoWLy9dybe/OZbhQwYBsGbdxiZTczrcLucjikSj
CAF33TkRlxk/Tpoy+VZSkpOYMvlWAJateiNuvZaECMcM4YLD1X5G/vpKxi8ayIrdmfg8FpZqbCJQ
SuEyTVYtfIylv8qjXZtUSsucl//sF9IIrQXT3+zF85s74vNoXKamsDIBSzmplkbcEjNX69/e0qz9
uredqCp31BWkBlO4+0d5HDl6nKUvPsOODa+SnBRo8cxn5/+ag4cLeXz2A9QW7WZ0zjDqG0KMueV7
vLZmPQv+Zw5b163g0OGjjL11Kvv2f0xaakpT++tzR1JbtLtZyc66kOWr1rBs5Rv0zu7GkQ82MXf2
D+O+Mzgf0LF9mxlzTQ75y1/jZ0/Nj1tP1C5Hl9UaDH60J+X1Ji5DoZAItwvh9YE/QEOZjc+wMQ0n
D+XwJohGLVKDSby/fjHB5ACl5ZXMnbeYBUteo74hRDAlgG2rZiZDCseEVTUk8J2RR3lxwvvkrWzP
k29mYBga2/7/NXtvDHt7DMqlqPhEs3tCQNQWpPostj20nzS/3ZoPEQgkWhpIpUnxWM3IaF5VIIXA
tm3SU1N4auY9bFgxj9wRl1F6soKGUBhxmm9RGoTQpPsbWLL9Qu5fkc3+T32gXXHln2toQYhGIIR2
coCGgWOaxOcqyzAMlFLYtmJQv168ueRZVr40l17dLyAatZqRojVYtiAhEOb5v3bhDx+mgWk1TSzP
ZbQ6Uxdao8MhcCd8cWlCwGmRz8W9sggmB1CtsKm0wHDbqLOTEvpaIrlz/y9VvyUhUoJlYwwZiszs
hPXGavAkgW1xpmFi2wopBdIwKC4pI++Zl1i66i3CkQgBv6/5xE0IJ5QDlK0RscUwgeJcX8RqSYgQ
IARGpwvwTb2XukgY+/evIf3Jp1abToMzS1cYhiQStXh2wTLmL1pFYdGnpCQH8LgTsZVqLt+2UVYI
7U9CaIVGnZHscwktCdEa0Mj2majaWhIm3InVrRfWklfQ1ZXgcjcpT2uNlIKA38fqtzbxyLMvs2tv
AX6fj/S0FCzLbkmGFUWmZaAzM1EH96EjEcfTf07W91xBC0KE0mAYyIw26EgYIhFcudchbJvIguax
s5QSy7K58c4H+dM7fwMgPTUF21ZxZ6FIA11fjRyXg/v2/8Tau5uGJ2dhn/jUIUs1bnE5dxE/l+Xx
YnTNRngTwe1Bl53EGDYC2SETwmGQEq01hiGprqlj/abt+BO9+BN9WJYdP/MqJYRDyPYdMHOugqgF
kTCqvAwhBUKpZgNkQJd6ip7cw9En9rD5gQL6ZDZ8dVr4GiHuPERmtMHau4u6xx6ift5chMcLUuCa
cLvzFStF47TaMVmJKKVRqmXGNlbJaRON4p4yDZGWDtEooeW/RodDTsIkDoeL/ppGlwcvZtV7KYzu
XX2WXvnrjbhhrzpWSP0jP3HWFNGEsy8iYdwE6D8Q99T/IvL8PHC5wOMBpVononFbSjjskPH9u5H9
LkG6PIRWL8PatQPhdoNlxV23nDy0jMlDyzhc6mbsvCySvDbP31bI5RfWcbjMzZT8LpTWmjx3WyFD
utZS1WBwycO9SUu0WDjpCH07NrD1k0QKy938bkcqu495uTunhH3FXt494mshq0NKlG8NKueyC+v5
oMjL/I0ZvHfExw+uLmH3US8bC1qmZc424o4QbdvO3lLTRLhMQvkvEN2zE+n2YuRcjfunsxEpQXRV
JUQipxRvGE5p3P8TiaCrKhEpQdw/nY2RczXS7SO6Zyeh/BcQLhda2af2cH0Gi/6aRo/pfdhT5OOi
DiFuu7ycEdk1JLgUPduFuP7iKm4fXMa2g4lkT+/DJQ/3BmDi4HLe3JvMRTMv4sCJBIoq3Nw2uAwh
4MrsWjYWBOLKAvB7FCOfzGbGax2YPLQM09AM7VrLpgNfPRlwhokhWiFshZYSYUepf2IG3gfn4O47
AC7pj3xkLvaG9djbt6KOF8WipdhIkRLhdiMzO2JcPgRj1GhEWhrSlUDkg500PDEDolG0iAURZ/Dj
tWHJ3LXteOSG42w/lMjjb7Xj+U0ZRCyn0d05JWeMmJWGkhqTwV3rGHtxJe8c8MfSN7SQNbx7LdsP
OcvRDVUSW8H3rzzJ63uS/2VR+RnW1J21bqE0WkqorKR+5n+j7piKZ8zNiHaZyFsmYl43FlV4FF1U
iCorBUCmpSMyOyM7d0IEksBwQTRCaPUyQvkvQDSCFtJx5E3Pah1HytwIodmwP8BD1xVz79Un8Jia
KYu7sHhbGs/fdoT7c09QWe+YrKXbUnlp8hEe/ManbP0kkafXtSUUlcy9+Rgjn+wBQP7WVOZPLGwm
q7qheYZ64eZ0lk85xGU/6/nP6vdLQ9QuR5XVGuLyR3tSUW/i+mwSMbYNSEvpzAujFubAwXjG3YLr
ov4IXyIYRsz0NKWCEdIA20bX1xH9cBfh1b/F2rkN4TIdkUqdthX164mcHjUMy6plzpr2n1/5n0Bj
tjfos9juZHu1KYST9zNlK2MyNjt3RopAuN1Y723Hfn8HRp/+mP0GYFyQhWzfEZHgrCPrUAOq+Bj2
4Y+xdr+HvXcXWimE2+1clf7ak3HzgApmji1mzC+yvvJnmVI3JkiEGYrwSfug3TWrTZjjlW7hMRX2
Z3cvxjZUCxtQFsIwQYC1ZyfWnp3OveSgEzEBOhJBV1XQaIqEaSKEBMtCaAHi679rcdV7QVa913I5
+GxCCk3UkmS1Cev2QZvqOg5KW4l1phcxfmCFUlGBbFVPMUUC2ApsGwwDYboQpgtdXYU6WYI6WYKu
rmr6HcMxXdgxfyHOp0gaIQWoqGD8wAplehG2EuvO2nEELQSnH0cQOqb488cRWuBMxxHOH9j5N+CM
B3benoU5cjZ2xWIWBNs4R9ryt54/0nbWEf9Im+EPaipKWBi8nSkbZ2OcP/T5L8IXPfQpgPPHov8V
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
    grep -E '^config\.plugins\.autozap_alamri\.(enabled|scope|iptv|freeze_time|grace|max_retries|cooldown|check_net|notify|debug|language|excluded)=' "$S" >> /tmp/az_settings.new
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
echo ">>> AutoZap Recovery v2.1 installed successfully."
echo ">>> Plugins menu  : AutoZap Recovery"
echo ">>> Blue button   : AutoZap On/Off  -  Exclude/include channel"
echo ">>> Restarting Enigma2 GUI in 2 seconds..."
echo "=============================================="
az_restart_gui /tmp/autozap_clean.sh
exit 0
