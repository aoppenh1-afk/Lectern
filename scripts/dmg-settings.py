# Finder layout for the drag-to-Applications installer.
import os

application = os.path.abspath(defines['app'])
files = [application]
symlinks = {'Applications': '/Applications'}
format = 'UDZO'
filesystem = 'HFS+'
background = 'builtin-arrow'
window_rect = ((200, 160), (640, 280))
icon_locations = {'Lectern.app': (140, 120), 'Applications': (500, 120)}
icon_size = 96
text_size = 14
show_status_bar = False
show_toolbar = False
show_tab_view = False
show_pathbar = False
show_sidebar = False
default_view = 'icon-view'
include_icon_view_settings = True
