# Impostazioni di dmgbuild per la finestra di installazione.
# Lancio: dmgbuild -s dmg-settings.py -D app=<.app> -D background=<png> -D icon=<icns> "BatteryGuard" <out.dmg>
# Le posizioni coincidono con quelle disegnate in tools/make-dmg-background.swift.
import os.path

application = defines["app"]
appname = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
# Nome inglese, come la didascalia dello sfondo (il dmg è uno solo per tutte le lingue):
# Finder mostra il nome del link così com'è, non lo traduce
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]

# Altezza = sfondo (400) + barra del titolo, così lo sfondo si vede intero
window_rect = ((200, 160), (640, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
include_icon_view_settings = True

arrange_by = None
grid_spacing = 100
label_pos = "bottom"
text_size = 13
icon_size = 128
icon_locations = {
    appname: (170, 190),
    "Applications": (470, 190),
}
hide_extension = [appname]
