#!/bin/sh
echo "====================================================="
echo "   AutoZap Recovery 1.0 by Ahmad Alamri             "
echo "====================================================="
TARGET_DIR="/usr/lib/enigma2/python/Plugins/Extensions/AutoZap_AhmadAlamri"
mkdir -p "$TARGET_DIR"

cat << 'PYEOF' > "$TARGET_DIR/__init__.py"
# -*- coding: utf-8 -*-
# AutoZap Recovery by Ahmad Alamri
PYEOF

cat << 'PYEOF' > "$TARGET_DIR/plugin.py"
# -*- coding: utf-8 -*-
import base64
import os
import time

_D = base64.b64decode(b'QWhtYWQgQWxhbXJp').decode('utf-8')
_S = base64.b64decode(b'QXV0b1phcCBSZWNvdmVyeSB2MS4wIC0gRGV2ZWxvcGVkIGJ5OiBhaG1hZCBhbGFtcmk=').decode('utf-8').lower()

from Plugins.Plugin import PluginDescriptor
from Screens.Screen import Screen
from Components.ConfigList import ConfigListScreen
from Components.ActionMap import ActionMap
from Components.Sources.StaticText import StaticText
from Components.Label import Label
from Components.config import (
    config, ConfigSubsection, ConfigEnableDisable, 
    ConfigInteger, ConfigSelection, getConfigListEntry
)
from enigma import eTimer, getDesktop

def _verify_license():
    try:
        t = "AutoZap Recovery v1.0 - Developed by: Ahmad Alamri".lower()
        if _D != "Ahmad Alamri" or t != _S:
            return False
        return True
    except:
        return False

config.plugins.autozap_alamri = ConfigSubsection()
config.plugins.autozap_alamri.enabled = ConfigEnableDisable(default=True)
config.plugins.autozap_alamri.timeout = ConfigInteger(default=10, limits=(1, 100))
config.plugins.autozap_alamri.max_retries = ConfigInteger(default=3, limits=(1, 100))
config.plugins.autozap_alamri.show_alert = ConfigEnableDisable(default=True)
config.plugins.autozap_alamri.alert_pos = ConfigSelection(default="top_right", choices=[
    ("top_right", "أعلى اليمين"),
    ("top_left", "أعلى اليسار"),
    ("bottom_right", "أسفل اليمين"),
    ("bottom_left", "أسفل اليسار"),
    ("center", "وسط الشاشة")
])
config.plugins.autozap_alamri.alert_size = ConfigSelection(default="large", choices=[
    ("small", "صغير"),
    ("medium", "متوسط"),
    ("large", "كبير")
])
config.plugins.autozap_alamri.alert_color = ConfigSelection(default="#f0a500", choices=[
    ("#f0a500", "أصفر ذهبي"),
    ("#00ff00", "أخضر"),
    ("#00bfff", "أزرق سماوي"),
    ("#ff3333", "أحمر"),
    ("#ffffff", "أبيض")
])

class AutoZapToast(Screen):
    def __init__(self, session, msg, color="#f0a500", pos="top_right", size_choice="large"):
        sz = str(size_choice)
        if sz == "small":
            w, h, font_sz = 300, 55, 24
        elif sz == "large":
            w, h, font_sz = 620, 100, 46
        else:
            w, h, font_sz = 450, 75, 34

        try:
            desk = getDesktop(0).size()
            dw, dh = desk.width(), desk.height()
        except:
            dw, dh = 1920, 1080

        margin_x = 50
        margin_y = 60

        if pos == "top_right":
            x, y = dw - w - margin_x, margin_y
        elif pos == "top_left":
            x, y = margin_x, margin_y
        elif pos == "bottom_right":
            x, y = dw - w - margin_x, dh - h - margin_y
        elif pos == "bottom_left":
            x, y = margin_x, dh - h - margin_y
        else:
            x, y = (dw - w) // 2, (dh - h) // 2

        self.skin = """
        <screen name="AutoZapToast" position="%d,%d" size="%d,%d" zPosition="150" backgroundColor="#b0000000" flags="wfNoBorder">
            <widget name="msg" position="0,0" size="%d,%d" font="Regular;%d" halign="center" valign="center" foregroundColor="%s" backgroundColor="#b0000000" transparent="1" />
        </screen>""" % (x, y, w, h, w, h, font_sz, color)

        Screen.__init__(self, session)
        self.session = session
        self["msg"] = Label(msg)
        self.timer = eTimer()
        try:
            self.timer_conn = self.timer.timeout.connect(self.close)
        except:
            self.timer.callback.append(self.close)
        self.onLayoutFinish.append(self.start_timer)

    def start_timer(self):
        self.timer.start(2500, True)

class AutoZapCore:
    def __init__(self, session):
        self.session = session
        self.timer = eTimer()
        try:
            self.timer_conn = self.timer.timeout.connect(self.monitor)
        except:
            self.timer.callback.append(self.monitor)
        self.last_ref = None
        self.last_mtime = 0
        self.cooldown_until = 0
        self.retries = 0
        self.valid = _verify_license()
        self.start()

    def start(self):
        if not self.valid:
            return
        self.timer.start(2000)

    def trigger_alert(self, current, max_r):
        if not config.plugins.autozap_alamri.show_alert.value:
            return
        msg = "إنعاش القناة (%s/%s)" % (current, max_r)
        color = config.plugins.autozap_alamri.alert_color.value
        pos = config.plugins.autozap_alamri.alert_pos.value
        sz = config.plugins.autozap_alamri.alert_size.value
        try:
            from Tools.Notifications import AddNotification
            AddNotification(AutoZapToast, msg, color, pos, sz)
        except:
            try:
                self.session.open(AutoZapToast, msg, color, pos, sz)
            except:
                pass

    def monitor(self):
        if not self.valid or not config.plugins.autozap_alamri.enabled.value:
            return

        try:
            from Screens.Standby import inStandby
            if inStandby:
                self.retries = 0
                return
        except:
            pass

        try:
            ref = self.session.nav.getCurrentlyPlayingServiceReference()
            if not ref:
                self.retries = 0
                return

            ref_str = ref.toString()
            now = time.time()

            if ref_str != self.last_ref:
                self.last_ref = ref_str
                self.retries = 0
                self.cooldown_until = now + 4
                if os.path.exists("/tmp/ecm.info"):
                    self.last_mtime = os.path.getmtime("/tmp/ecm.info")
                else:
                    self.last_mtime = now
                return

            if now < self.cooldown_until:
                return

            ecm_path = "/tmp/ecm.info"
            if not os.path.exists(ecm_path):
                return

            mtime = os.path.getmtime(ecm_path)
            time_since_update = now - mtime
            timeout_limit = int(config.plugins.autozap_alamri.timeout.value)

            is_frozen = False
            if time_since_update > timeout_limit:
                is_frozen = True
            else:
                try:
                    with open(ecm_path, "r") as f:
                        data = f.read().lower()
                        if "timeout" in data or "not found" in data:
                            is_frozen = True
                except:
                    pass

            if is_frozen:
                max_r = int(config.plugins.autozap_alamri.max_retries.value)
                if self.retries < max_r:
                    self.retries += 1
                    self.cooldown_until = now + 5
                    self.trigger_alert(self.retries, max_r)
                    self.session.nav.stopService()
                    self.session.nav.playService(ref)
            else:
                if time_since_update < 4:
                    self.retries = 0
        except:
            pass

core_instance = None

def sessionstart(reason, session=None, **kwargs):
    global core_instance
    s = session if session is not None else kwargs.get("session")
    if s is not None and reason == 0:
        core_instance = AutoZapCore(s)

class AutoZapSetup(ConfigListScreen, Screen):
    skin = """
    <screen name="AutoZapSetup" position="center,center" size="720,440" title="AutoZap Recovery 1.0">
        <widget name="config" position="20,20" size="680,270" scrollbarMode="showOnDemand" font="Regular;21" itemHeight="38" />
        <widget source="author_info" render="Label" position="20,310" size="680,25" font="Regular;18" halign="center" valign="center" foregroundColor="#f0a500" transparent="1" />
        <widget source="key_red" render="Label" position="90,370" size="140,40" zPosition="1" font="Regular;20" halign="center" valign="center" backgroundColor="#9f1313" transparent="0" />
        <widget source="key_green" render="Label" position="280,370" size="140,40" zPosition="1" font="Regular;20" halign="center" valign="center" backgroundColor="#0b7e13" transparent="0" />
    </screen>"""

    def __init__(self, session):
        Screen.__init__(self, session)
        self.session = session
        self.list = []
        ConfigListScreen.__init__(self, self.list)
        
        self["author_info"] = StaticText("AutoZap Recovery v1.0 - Developed by: Ahmad Alamri")
        self["key_red"] = StaticText("إلغاء")
        self["key_green"] = StaticText("حفظ")
        self["actions"] = ActionMap(["SetupActions", "ColorActions"], {
            "green": self.save,
            "red": self.cancel,
            "cancel": self.cancel,
            "ok": self.save
        }, -2)
        
        self.create_setup()

    def create_setup(self):
        self.list = [
            getConfigListEntry("تفعيل المراقبة والإنعاش التلقائي", config.plugins.autozap_alamri.enabled),
            getConfigListEntry("مهلة انقطاع الشفرة قبل التدخل (ثواني)", config.plugins.autozap_alamri.timeout),
            getConfigListEntry("أقصى عدد محاولات قبل التوقف", config.plugins.autozap_alamri.max_retries),
            getConfigListEntry("إظهار تنبيه الإنعاش على الشاشة", config.plugins.autozap_alamri.show_alert),
            getConfigListEntry("مكان ظهور التنبيه على الشاشة", config.plugins.autozap_alamri.alert_pos),
            getConfigListEntry("حجم التنبيه على الشاشة", config.plugins.autozap_alamri.alert_size),
            getConfigListEntry("لون خط التنبيه", config.plugins.autozap_alamri.alert_color)
        ]
        self["config"].list = self.list
        self["config"].setList(self.list)

    def save(self):
        for x in self["config"].list:
            x[1].save()
        config.plugins.autozap_alamri.save()
        global core_instance
        if core_instance:
            core_instance.start()
        self.close()

    def cancel(self):
        for x in self["config"].list:
            x[1].cancel()
        self.close()

def main(session, **kwargs):
    session.open(AutoZapSetup)

def Plugins(**kwargs):
    return [
        PluginDescriptor(where=PluginDescriptor.WHERE_SESSIONSTART, fnc=sessionstart),
        PluginDescriptor(name="AutoZap Recovery 1.0", description="إعدادات إنعاش القنوات الذاتي | إعداد: Ahmad Alamri", where=PluginDescriptor.WHERE_PLUGINMENU, icon=None, fnc=main)
    ]
PYEOF

python -m compileall "$TARGET_DIR" > /dev/null 2>&1 || python3 -m compileall "$TARGET_DIR" > /dev/null 2>&1
if [ -d "$TARGET_DIR/__pycache__" ]; then
    for f in "$TARGET_DIR/__pycache__"/*.pyc; do
        [ -e "$f" ] || continue
        base=$(basename "$f" | sed -E 's/\.cpython-[0-9]+\.pyc/\.pyc/')
        cp -f "$f" "$TARGET_DIR/$base"
    done
fi

rm -f "$TARGET_DIR"/*.py
chmod 444 "$TARGET_DIR"/*.pyc 2>/dev/null
chmod 444 "$TARGET_DIR/__pycache__"/*.pyc 2>/dev/null

echo "====================================================="
echo " تم تثبيت وقفل AutoZap Recovery 1.0 بنجاح!           "
echo " مطور الإضافة: Ahmad Alamri                          "
echo " جاري إعادة تشغيل واجهة المستخدم (GUI)...            "
echo "====================================================="
killall -9 enigma2
