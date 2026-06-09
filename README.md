# exec_multichar

Character selection and creation UI for EXEC resources with built-in `fivem-appearance` support, optional HUD suppression, and optional hand-off into `exec_framework`.

## Dependencies

- Required: `ox_lib`
- Required: `oxmysql`
- Required: `fivem-appearance`
- Optional: `exec_hud`
- Optional: `exec_framework`

## Installation

1. Copy the `exec_multichar` folder into your server `resources` directory.
2. Ensure the required dependencies start first.
3. Start `exec_hud` before `exec_multichar` if you want the menu to hide the HUD automatically.
4. Start `exec_framework` after `exec_multichar` if you want the framework hand-off.

```cfg
ensure ox_lib
ensure oxmysql
ensure fivem-appearance
ensure exec_hud
ensure exec_multichar
ensure exec_framework
```

## Database Behavior

- No manual SQL import is required.
- On first start, the resource creates `characters` and `character_appearance` automatically.

## Commands And Exports

- `/logout`
- Server export: `GetActiveCitizenId`

## Main Config Files

- `config/studio.lua`
- `config/appearance.lua`
- `config/peds.lua`
- `config/anims.lua`
- `config/huds.lua`
