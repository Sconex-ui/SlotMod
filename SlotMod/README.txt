SlotMod - mod menu for Slotbound (no game files are changed)

Start:   SlotMod\SlotMod.exe  (starts the game through Steam, or attaches if it is already running;
         a different launcher can be set with launch= in SlotMod.ini)
Menu:    F1 or Insert in game
Keys:    Tab / PageUp / PageDown switch tabs, Up/Down select, Enter/Space toggle/apply,
         Left/Right change value (Shift = 10x step, Ctrl = 100x step), type digits for an exact value, Esc close
Mouse:   click switches, -/+ and APPLY; wheel over a value changes it; drag the title bar to move

Toggles are saved in slotmod_settings.txt. Errors go to slotmod_log.txt.
Unlock toggles keep a backup in slotmod_unlock_backup.txt; switching them OFF restores it.
Rebuild: slotmod_src\build.bat (Visual Studio 2022 with C++).
