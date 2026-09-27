; ==================================================================================================
; watermark.asm - a 16-character mark in the ROM, stored scrambled with a check word
;> feature: FEAT_WATERMARK
;> name: Watermark
;> category: Options
;> pages: watermark
;> ram: none
;> about: Up to 16 characters of your own (a name, a tune number, a date) stored in the ROM scrambled, so they
;>        do not show in a hex view, with a check word worked out from them. The app shows the text and
;>        whether it is intact: an edit made any other way than through the app (a hex editor, another tool)
;>        shows as modified. It also holds an open password: OkiRomSim asks for it before it opens the ROM
;>        (a salted hash is kept, not the password). Neither changes how the ROM runs. 46 bytes.
; ==================================================================================================
ifdef FEAT_WATERMARK

if XP == XP_CAL
;@ Watermark type=u8 count=18 text=watermark category="Watermark" slot=watermark.text desc="Up to 16 characters, stored scrambled with a check word (edit it here: the app keeps the check word right)."
watermark_data:
ifdef WATERMARK_SET
                        org $ + 18              ; set from the app: the ROM's build file holds these bytes (see its end)
else
                        DB  07Ah, 0B2h, 0FEh, 03Eh, 07Ah, 082h, 0B6h, 0E6h, 02Ah, 072h, 0CEh, 08Eh, 06Ah, 022h, 0D6h, 086h, 0D9h, 0DEh
endif
; the open password block straight after the watermark (RomPassword): "OKPW", version, reserved, salt, hash - none set
;@ RomPassword type=u8 count=28 text=password category="Watermark" slot=watermark.password desc="The open password: OkiRomSim asks for it before opening this ROM. Only a salted hash of it is kept."
rompassword_data:
ifdef WATERMARK_SET
                        org $ + 28
else
                        DB  04Fh, 04Bh, 050h, 057h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
                        DB  000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h, 000h
endif
endif

endif
