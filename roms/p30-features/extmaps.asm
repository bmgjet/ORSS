; ==================================================================================================
; extmaps.asm - extended maps: 20 load columns (as the larger CromeGold / HTS tables)
;> feature: FEAT_EXTMAPS
;> name: Extended maps (20 load columns)
;> category: Fuel
;> ram: none
;> about: Widens the fuel, ignition and VE maps from 10 load columns to 20, with a 20-point load axis, for
;>        finer steps where the engine needs them. The new maps are made from the stock ones, so the engine
;>        runs exactly as before until they are changed. Every map grows by 10 bytes a row (about 1,000
;>        bytes with the stock functions left out); the modules that switch maps use the same size.
; ==================================================================================================
; Nothing to assemble here: the skeleton builds its maps and lookups with MAP_COLS = 20 when this is
; defined (see p30-skeleton.asm).
