; ==================================================================================================
; dlextra.asm - datalogging: every channel
;> feature: FEAT_DLEXTRA
;> name: Datalogging: every channel
;> category: Diagnostics
;> requires: FEAT_DLSTREAM
;> pages: dlextra
;> ram: none
;> about: Everything worth logging, on top of the channel stream's own list: why the fuel is cut (the
;>        rev limiter, overrun, which limiter module), the fuel map's value before the corrections and
;>        each correction after it (warm-up, intake air, baro, acceleration, tip-in, post-start, dead
;>        time, knock), each ignition correction and the knock retard, dwell, the idle target and its
;>        corrections, VTEC's state, the map indexes, the engine's flag bytes, and eight RAM addresses of
;>        your own. Pick them in Datalogging > Channels; "Everything" logs the lot (each slow one comes
;>        round in turn).
;
; Channels 53-131 of dlstream.asm's table are this module's (DL_NCHANNELS goes to 132). Entries 1000h-1007h
; there are the addresses below, read by datalog.asm's dl_fetch.
; ==================================================================================================
ifdef FEAT_DLEXTRA

if XP == XP_CAL
;@ DatalogUserAddress type=u16 count=8 formula=raw min=0 max=1151 category="Datalog" slot=dlextra.user desc="Eight RAM addresses of your own to log, as channels 'RAM address 1-8' (80h-47Fh; 0 for none). The memory map names what each RAM byte holds."
dlx_user:               DW  0, 0, 0, 0, 0, 0, 0, 0
endif

endif
