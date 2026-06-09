fx_version 'cerulean'
game 'gta5'

name 'exec_multichar'
author 'WickmanCapo'

version '1.0.1'
description 'Multi-character selection resource for EXEC RZ.'
dependencies {
  'ox_lib',
  'oxmysql',
  'fivem-appearance'
}

shared_scripts {
  '@ox_lib/init.lua',
  'shared/utils.lua',
  'config/studio.lua',
  'config/appearance.lua',
  'config/peds.lua',
  'config/anims.lua',
  'config/huds.lua',
  'config/ui.lua'
}

client_scripts {
  'client/main.lua'
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/main.lua'
}

server_exports {
  'GetActiveCitizenId'
}

ui_page 'html/index.html'

files {
  'html/index.html',
  'html/style.css',
  'html/app.js'
}

escrow_ignore {
  '.git',
  '.git/**',
  'config/*.lua'
}
