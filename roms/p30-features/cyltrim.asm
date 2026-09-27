; ==================================================================================================
; cyltrim.asm - a fuel trim for each cylinder (HTS "Cylinder corrections" page)
;> feature: FEAT_CYLTRIM
;> name: Individual cylinder fuel trims
;> category: Fuel
;> pages: cyltrim
;> ram: none
;> about: A fuel trim for each cylinder, applied all the time. The skeleton already has the per-cylinder
;>        table (stock P30 uses it only in closed loop); this takes that condition out, as HTS120 does,
;>        so the trims hold at full throttle too. The trims (CylinderFuelTrim, in the skeleton
;>        calibration) default to 0 %, so building it in changes nothing until they are set.
; ==================================================================================================
ifdef FEAT_CYLTRIM

if XP == XP_DEFS

endif

if XP == XP_CAL

endif

endif
