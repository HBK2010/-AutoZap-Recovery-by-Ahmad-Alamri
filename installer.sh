#!/bin/sh
mkdir -p /usr/lib/enigma2/python/Plugins/Extensions/AutoZap_AhmadAlamri
cat << 'EOF' > /usr/lib/enigma2/python/Plugins/Extensions/AutoZap_AhmadAlamri/__init__.py
# AutoZap Recovery
# Designed and Developed by: Ahmad Alamri
# All Rights Reserved (C) 2026
EOF
cat << 'EOF' > /usr/lib/enigma2/python/Plugins/Extensions/AutoZap_AhmadAlamri/plugin.py
# ========================================================================
# Plugin Name: AutoZap Recovery
# Author & Developer: Ahmad Alamri
# Description: Smart Auto-Recovery for Frozen Channels on Enigma2
# Copyright: (C) 2026 Ahmad Alamri. All Rights Reserved.
# ========================================================================

from Plugins.Plugin import PluginDescriptor
from Screens.Screen import Screen
from Components.ConfigList import ConfigListScreen
from Components.ActionMap import ActionMap
from Components.Sources.StaticText import StaticText
from Components.config import config, ConfigSubsection, ConfigEnableDisable, ConfigInteger, getConfigListEntry
from enigma import eTimer
import os

config.plugins.autozap_alamri = ConfigSubsection()
config.plugins.autozap_alamri.enabled = ConfigEnableDisable(default=True)
config.plugins.autozap_alamri.interval = ConfigInteger(default=4, limits=(2, 15))
config.plugins.autozap_alamri.max_retries = ConfigInteger(default=2, limits=(1, 5))

class AutoZapCore:
    def __init__(self, session):
        self.session = session
        self.timer = eTimer()
        try:
            self.timer.callback.append(self.monitor)
        except:
            self.timer_conn = self.timer.timeout.connect(self.monitor)
        self.last_pts = None
        self.last_ref = None
        self.retries = 0
        self.start()

    def start(self):
        self.timer.start(int(config.plugins.autozap_alamri.interval.value) * 1000)

    def read_pts(self):
        for path in ["/proc/stb/vmpeg/0/pts", "/proc/stb/video/pts"]:
            if os.path.exists(path):
                try:
                    with open(path, "r") as f:
                        return f.read().strip()
                except:
                    pass
        return None

    def monitor(self):
        if not config.plugins.autozap_alamri.enabled.value:
            return

        try:
            from Screens.Standby import inStandby
            if inStandby:
                self.retries = 0
                return
        except:
            pass

        ref = self.session.nav.getCurrentlyPlayingServiceReference()
        if not ref:
            self.retries = 0
            return

        ref_str = ref.toString()
        if ref_str != self.last_ref:
            self.last_ref = ref_str
            self.last_pts = None
            self.retries = 0
            return

        pts = self.read_pts()
        if pts and self.last_pts:
            if pts == self.last_pts:
                max_r = int(config.plugins.autozap_alamri.max_retries.value)
                if self.retries < max_r:
                    self.retries += 1
                    self.session.nav.playService(ref)
            else:
                self.retries = 0

        self.last_pts = pts

core_instance = None

def sessionstart(reason, **kwargs):
    global core_instance
    if "session" in kwargs and reason == 0:
        core_instance = AutoZapCore(kwargs["session"])

class AutoZapSetup(ConfigListScreen, Screen):
    skin = """
    <screen name="AutoZapSetup" position="center,center" size="680,310" title="AutoZap Recovery | Developed by Ahmad Alamri">
        <widget name="config" position="20,20" size="640,140" scrollbarMode="showOnDemand" font="Regular;22" itemHeight="35" />
        <widget source="author_info" render="Label" position="20,180" size="640,30" font="Regular;18" halign="center" valign="center" foregroundColor="#f0a500" transparent="1" />
        <widget source="key_red" render="Label" position="70,240" size="140,40" zPosition="1" font="Regular;20" halign="center" valign="center" backgroundColor="#9f1313" transparent="0" />
        <widget source="key_green" render="Label" position="250,240" size="140,40" zPosition="1" font="Regular;20" halign="center" valign="center" backgroundColor="#0b7e13" transparent="0" />
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
            getConfigListEntry("تفعيل المراقبة والإنعاش التلقائي:", config.plugins.autozap_alamri.enabled),
            getConfigListEntry("مدة فحص تجمد البث (ثواني):", config.plugins.autozap_alamri.interval),
            getConfigListEntry("أقصى عدد محاولات قبل التوقف:", config.plugins.autozap_alamri.max_retries)
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
        PluginDescriptor(name="AutoZap Recovery (Ahmad Alamri)", description="Auto-Recovery for Frozen Channels by Ahmad Alamri", where=PluginDescriptor.WHERE_SESSIONSTART, fnc=sessionstart),
        PluginDescriptor(name="AutoZap Recovery - Ahmad Alamri", description="إعدادات إنعاش القنوات الذاتي | إعداد: Ahmad Alamri", where=PluginDescriptor.WHERE_PLUGINMENU, icon=None, fnc=main)
    ]
EOF

killall -9 enigma2
