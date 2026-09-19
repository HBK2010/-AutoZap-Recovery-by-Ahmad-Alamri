cat << 'EOF' > /tmp/install_autozap_ultimate_pro.sh
#!/bin/sh
echo "====================================================="
echo "   AutoZap Recovery 1.0 (Ultimate Pro Edition)       "
echo "   Developed by: Ahmad Alamri                        "
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
import re
import socket
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
from enigma import eTimer, getDesktop, iServiceInformation

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
config.plugins.autozap_alamri.sports_mode = ConfigEnableDisable(default=False)
config.plugins.autozap_alamri.boost_system = ConfigEnableDisable(default=True)
config.plugins.autozap_alamri.check_net = ConfigEnableDisable(default=True)
config.plugins.autozap_alamri.cam_restart = ConfigEnableDisable(default=True)
config.plugins.autozap_alamri.lock_caid = ConfigEnableDisable(default=True)
config.plugins.autozap_alamri.mode = ConfigSelection(default="zap", choices=[
    ("zap", "تقليب مرئي لقناة مجاورة والعودة"),
    ("restart", "إعادة تشغيل القناة مكانها دون تقليب")
])
config.plugins.autozap_alamri.timeout = ConfigInteger(default=10, limits=(1, 100))
config.plugins.autozap_alamri.max_retries = ConfigInteger(default=3, limits=(1, 100))
config.plugins.autozap_alamri.silent_mode = ConfigEnableDisable(default=False)
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
config.plugins.autozap_alamri.alert_color = ConfigSelection(default="#00ff00", choices=[
    ("#00ff00", "أخضر"),
    ("#f0a500", "أصفر ذهبي"),
    ("#00bfff", "أزرق سماوي"),
    ("#ff3333", "أحمر"),
    ("#ffffff", "أبيض")
])

class AutoZapToast(Screen):
    def __init__(self, session, msg, color="#00ff00", pos="top_right", size_choice="large"):
        sz = str(size_choice)
        if sz == "small":
            w, h, font_sz = 340, 55, 24
        elif sz == "large":
            w, h, font_sz = 680, 100, 42
        else:
            w, h, font_sz = 500, 75, 32

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

        self.return_timer = eTimer()
        try:
            self.return_timer_conn = self.return_timer.timeout.connect(self.finish_recovery)
        except:
            self.return_timer.callback.append(self.finish_recovery)

        self.last_ref = None
        self.target_ref = None
        self.recovery_action = None
        self.recovering = False
        self.channel_tune_time = 0
        self.cooldown_until = 0
        self.last_boost_time = 0
        self.recovery_count = 0
        self.locked_srvid = set()
        self.retries = 0
        self.valid = _verify_license()
        self.start()

    def start(self):
        if not self.valid:
            return
        self.apply_hardware_boost()
        self.timer.start(2000)

    def apply_hardware_boost(self):
        if not config.plugins.autozap_alamri.boost_system.value:
            return
        try:
            cmd = (
                "renice -n -19 $(pidof oscam ncam 2>/dev/null) >/dev/null 2>&1; "
                "ionice -c 1 -n 0 -p $(pidof oscam ncam 2>/dev/null) >/dev/null 2>&1; "
                "sysctl -w net.core.rmem_max=8388608 >/dev/null 2>&1; "
                "sysctl -w net.core.wmem_max=8388608 >/dev/null 2>&1; "
                "sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1; "
                "echo 1 > /proc/sys/vm/drop_caches 2>/dev/null"
            )
            os.system(cmd + " &")
        except:
            pass

    def check_network(self):
        if not config.plugins.autozap_alamri.check_net.value:
            return True
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(0.6)
            s.connect(("1.1.1.1", 53))
            s.close()
            return True
        except:
            return False

    def restart_softcam(self):
        try:
            cmd = (
                "killall -9 oscam ncam 2>/dev/null; sleep 1; "
                "for bin in /usr/bin/oscam* /usr/bin/ncam*; do "
                "if [ -x \"$bin\" ]; then \"$bin\" -b & break; fi; done"
            )
            os.system(cmd + " &")
            self.trigger_alert("تم إنعاش الأوسكام تلقائياً بنجاح")
        except:
            pass

    def trigger_alert(self, msg_text, force_color=None):
        if config.plugins.autozap_alamri.silent_mode.value:
            return
        if not config.plugins.autozap_alamri.show_alert.value:
            return
        color = force_color if force_color else config.plugins.autozap_alamri.alert_color.value
        pos = config.plugins.autozap_alamri.alert_pos.value
        sz = config.plugins.autozap_alamri.alert_size.value
        try:
            from Tools.Notifications import AddNotification
            AddNotification(AutoZapToast, msg_text, color, pos, sz)
        except:
            try:
                self.session.open(AutoZapToast, msg_text, color, pos, sz)
            except:
                pass

    def get_dvbapi_files(self):
        found = []
        dirs = [
            "/etc/tuxbox/config/oscam",
            "/etc/tuxbox/config/ncam",
            "/etc/tuxbox/config/oscam-emu",
            "/etc/tuxbox/config/oscam-trunk",
            "/etc/tuxbox/config",
            "/var/tuxbox/config"
        ]
        for d in dirs:
            for name in ["oscam.dvbapi", "ncam.dvbapi"]:
                p = os.path.join(d, name)
                if os.path.exists(p) and p not in found:
                    found.append(p)
        return found

    def lock_best_caid(self, ecm_path):
        if not config.plugins.autozap_alamri.lock_caid.value:
            return
        try:
            with open(ecm_path, "r") as f:
                content = f.read().lower()

            if "timeout" in content or "not found" in content or "cannot decode" in content:
                return

            caid_m = re.search(r'caid:\s*0x([0-9a-f]+)', content)
            prov_m = re.search(r'prov:\s*0x([0-9a-f]+)', content)
            srv_m = re.search(r'srvid:\s*0x([0-9a-f]+)', content)

            if caid_m and srv_m:
                caid = caid_m.group(1).zfill(4)
                srvid = srv_m.group(1).zfill(4)
                prov = prov_m.group(1).zfill(6) if prov_m else "000000"

                if srvid in self.locked_srvid:
                    return

                rule = "P: %s:%s:%s 1" % (caid, prov, srvid)
                target_files = self.get_dvbapi_files()

                for dvbapi in target_files:
                    existing = []
                    if os.path.exists(dvbapi):
                        with open(dvbapi, "r") as f_in:
                            existing = [l.strip() for l in f_in.readlines() if l.strip()]

                    cleaned = [l for l in existing if not l.startswith("P: %s:" % caid) and srvid not in l]
                    new_content = [rule] + cleaned
                    with open(dvbapi, "w") as f_out:
                        f_out.write("\n".join(new_content) + "\n")

                os.system("killall -1 oscam ncam 2>/dev/null &")
                self.locked_srvid.add(srvid)
        except:
            pass

    def is_channel_crypted(self):
        try:
            service = self.session.nav.getCurrentService()
            if service:
                info = service.info()
                if info:
                    c1 = (info.getInfo(iServiceInformation.sIsCrypted) == 1)
                    try:
                        c2 = bool(info.getInfoFlag(iServiceInformation.sIsCrypted))
                    except:
                        c2 = False
                    return c1 or c2
        except:
            pass
        return False

    def finish_recovery(self):
        try:
            if self.recovery_action == "zap":
                from Screens.InfoBar import InfoBar
                if InfoBar.instance and hasattr(InfoBar.instance, "zapUp"):
                    InfoBar.instance.zapUp()
                elif self.target_ref:
                    self.session.nav.playService(self.target_ref)
            elif self.recovery_action == "restart":
                if self.target_ref:
                    self.session.nav.playService(self.target_ref)
        except:
            pass

        self.recovering = False
        self.target_ref = None
        self.recovery_action = None
        self.channel_tune_time = time.time()

    def check_preemptive_boost(self, ecm_path, now):
        if not config.plugins.autozap_alamri.boost_system.value:
            return
        if (now - self.last_boost_time) < 15:
            return

        try:
            if os.path.exists(ecm_path):
                with open(ecm_path, "r") as f:
                    content = f.read().lower()
                    m = re.search(r'([0-9\.]+)\s*(ms|s)', content)
                    if m:
                        val = float(m.group(1))
                        unit = m.group(2)
                        t_ms = val * 1000 if unit == "s" else val
                        if t_ms > 1300:
                            self.apply_hardware_boost()
                            self.last_boost_time = now
        except:
            pass

    def monitor(self):
        if not self.valid or not config.plugins.autozap_alamri.enabled.value:
            return

        if self.recovering:
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
                self.channel_tune_time = now
                self.apply_hardware_boost()
                return

            if now < self.cooldown_until:
                return

            ecm_path = "/tmp/ecm.info"
            ecm_exists = os.path.exists(ecm_path)
            is_crypted = self.is_channel_crypted()

            if not is_crypted and not ecm_exists:
                return

            if ecm_exists:
                self.lock_best_caid(ecm_path)

            self.check_preemptive_boost(ecm_path, now)

            # مهلة الانتظار الذكية (وضع المباريات يقلل المهلة إلى 3 ثوانٍ)
            timeout_limit = 3 if config.plugins.autozap_alamri.sports_mode.value else int(config.plugins.autozap_alamri.timeout.value)
            is_frozen = False

            if not ecm_exists:
                if (now - self.channel_tune_time) > timeout_limit:
                    is_frozen = True
            else:
                mtime = os.path.getmtime(ecm_path)
                if mtime < self.channel_tune_time:
                    if (now - self.channel_tune_time) > timeout_limit:
                        is_frozen = True
                elif (now - mtime) > timeout_limit:
                    is_frozen = True
                else:
                    try:
                        with open(ecm_path, "r") as f:
                            data = f.read().lower()
                            if "timeout" in data or "not found" in data or "cannot decode" in data:
                                is_frozen = True
                    except:
                        pass

            if is_frozen:
                # التحقق أولاً من سلامة الإنترنت
                if not self.check_network():
                    self.trigger_alert("تنبيه: تعذر الإنعاش بسبب انقطاع الإنترنت", force_color="#ff3333")
                    self.cooldown_until = now + 10
                    return

                max_r = int(config.plugins.autozap_alamri.max_retries.value)
                if self.retries < max_r:
                    self.retries += 1
                    self.recovery_count += 1
                    self.cooldown_until = now + 7
                    self.recovering = True
                    self.target_ref = ref

                    try:
                        if os.path.exists(ecm_path):
                            os.remove(ecm_path)
                    except:
                        pass

                    mode = config.plugins.autozap_alamri.mode.value
                    if mode == "zap":
                        self.recovery_action = "zap"
                        zapped = False
                        try:
                            from Screens.InfoBar import InfoBar
                            if InfoBar.instance and hasattr(InfoBar.instance, "zapDown"):
                                InfoBar.instance.zapDown()
                                zapped = True
                        except:
                            zapped = False

                        if zapped:
                            msg = "إنعاش القناة: تقليب مؤقت (%s/%s)" % (self.retries, max_r)
                            self.trigger_alert(msg)
                            self.return_timer.start(2500, True)
                        else:
                            self.recovery_action = "restart"
                            self.session.nav.stopService()
                            self.session.nav.playService(ref)
                            self.recovering = False
                            self.channel_tune_time = now
                    else:
                        self.recovery_action = "restart"
                        msg = "إنعاش القناة بنفس مكانها (%s/%s)" % (self.retries, max_r)
                        self.trigger_alert(msg)
                        self.session.nav.stopService()
                        self.session.nav.playService(ref)
                        self.recovering = False
                        self.channel_tune_time = now
                else:
                    # عند استنفاد كافة المحاولات وظلت القناة سوداء: إعادة تشغيل الإيمو
                    if config.plugins.autozap_alamri.cam_restart.value:
                        self.retries = 0
                        self.cooldown_until = now + 8
                        self.restart_softcam()
            else:
                if ecm_exists and (now - os.path.getmtime(ecm_path)) < 4:
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
    <screen name="AutoZapSetup" position="center,center" size="820,620" title="AutoZap Recovery 1.0 - لوحة التحكم الاحترافية">
        <widget name="config" position="20,20" size="780,420" scrollbarMode="showOnDemand" font="Regular;21" itemHeight="38" />
        <widget source="status_info" render="Label" position="20,455" size="780,30" font="Regular;19" halign="center" valign="center" foregroundColor="#00ff00" transparent="1" />
        <widget source="author_info" render="Label" position="20,490" size="780,25" font="Regular;17" halign="center" valign="center" foregroundColor="#f0a500" transparent="1" />
        <widget source="key_red" render="Label" position="90,540" size="160,45" zPosition="1" font="Regular;20" halign="center" valign="center" backgroundColor="#9f1313" transparent="0" />
        <widget source="key_green" render="Label" position="330,540" size="160,45" zPosition="1" font="Regular;20" halign="center" valign="center" backgroundColor="#0b7e13" transparent="0" />
        <widget source="key_yellow" render="Label" position="570,540" size="160,45" zPosition="1" font="Regular;19" halign="center" valign="center" backgroundColor="#a08000" transparent="0" />
    </screen>"""

    def __init__(self, session):
        Screen.__init__(self, session)
        self.session = session
        self.list = []
        ConfigListScreen.__init__(self, self.list)
        
        rescues = core_instance.recovery_count if core_instance else 0
        self["status_info"] = StaticText("حالة النظام: التيونر والأوسكام في القمة (Turbo Boost) | عمليات الإنعاش اليوم: %s" % rescues)
        self["author_info"] = StaticText("AutoZap Recovery v1.0 - Developed by: Ahmad Alamri")
        self["key_red"] = StaticText("إلغاء")
        self["key_green"] = StaticText("حفظ")
        self["key_yellow"] = StaticText("إنعاش الإيمو الآن")

        self["actions"] = ActionMap(["SetupActions", "ColorActions"], {
            "green": self.save,
            "red": self.cancel,
            "yellow": self.manual_cam_restart,
            "cancel": self.cancel,
            "ok": self.save
        }, -2)
        
        self.create_setup()

    def create_setup(self):
        self.list = [
            getConfigListEntry("تفعيل المراقبة والإنعاش التلقائي", config.plugins.autozap_alamri.enabled),
            getConfigListEntry("وضع المباريات فائق السرعة (استجابة فورية 3 ثواني)", config.plugins.autozap_alamri.sports_mode),
            getConfigListEntry("تسريع التيونر والأوسكام ورفع الأولوية للقصوى", config.plugins.autozap_alamri.boost_system),
            getConfigListEntry("فحص اتصال الإنترنت قبل التقليب", config.plugins.autozap_alamri.check_net),
            getConfigListEntry("إعادة تشغيل الأوسكام تلقائياً عند فشل المحاولات", config.plugins.autozap_alamri.cam_restart),
            getConfigListEntry("تثبيت أسرع شفرة ومنع التنقل العشوائي", config.plugins.autozap_alamri.lock_caid),
            getConfigListEntry("طريقة الإنعاش عند تجمد القناة", config.plugins.autozap_alamri.mode),
            getConfigListEntry("وضع الإنعاش الصامت (بدون رسائل على الشاشة)", config.plugins.autozap_alamri.silent_mode),
            getConfigListEntry("مهلة انقطاع الشفرة قبل التدخل (ثواني)", config.plugins.autozap_alamri.timeout),
            getConfigListEntry("أقصى عدد محاولات قبل إعادة تشغيل الإيمو", config.plugins.autozap_alamri.max_retries),
            getConfigListEntry("إظهار تنبيه الإنعاش على الشاشة", config.plugins.autozap_alamri.show_alert),
            getConfigListEntry("مكان ظهور التنبيه على الشاشة", config.plugins.autozap_alamri.alert_pos),
            getConfigListEntry("حجم التنبيه على الشاشة", config.plugins.autozap_alamri.alert_size),
            getConfigListEntry("لون خط التنبيه", config.plugins.autozap_alamri.alert_color)
        ]
        self["config"].list = self.list
        self["config"].setList(self.list)

    def manual_cam_restart(self):
        global core_instance
        if core_instance:
            core_instance.restart_softcam()
            self["status_info"].setText("تم إرسال أمر تنشيط وإعادة تشغيل الإيمو بنجاح!")

    def save(self):
        for x in self["config"].list:
            x[1].save()
        config.plugins.autozap_alamri.save()
        global core_instance
        if core_instance:
            core_instance.apply_hardware_boost()
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
echo " تم تثبيت AutoZap Recovery Ultimate Pro بنجاح تام!   "
echo " مطور الإضافة: Ahmad Alamri                          "
echo " جاري إعادة تشغيل واجهة المستخدم (GUI)...            "
echo "====================================================="
killall -9 enigma2
EOF
sh /tmp/install_autozap_ultimate_pro.sh
