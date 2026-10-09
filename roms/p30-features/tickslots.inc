; ==================================================================================================
; p30-features/tickslots.inc - the modules' slotted tick code, from the timer 1 interrupt.
;
; A module's tick runs on one tick in 16, its slot (features.inc hands them out: the first 16 modules built
; take slots 0..15 in turn). The tick counter is looked at once - its low four bits, by bit tests (off(): the
; timer 1 interrupt runs on page 0) - and the jump goes to that slot's list, built here by including the
; modules once per slot (XP_TICKSLOT, with TICK_SLOT set): a list holds only the calls of the modules on that
; slot, so a tick no longer pays for every module asking whether it is its turn. Only the branches and lists
; of slots that hold a module are built (TICKSLOT_N, the number of slotted modules): with few modules the
; dispatch is a few bytes, with none it is nothing. The every-tick code (XP_TICK) runs after it.
; ==================================================================================================
if TICKSLOT_N > 0
tick_slots:
if TICKSLOT_N > 8
                JBS     off(000feh).3, tick_n8_16
else
                JBS     off(000feh).3, tick_none
endif
if TICKSLOT_N > 4
                JBS     off(000feh).2, tick_n4_8
else
                JBS     off(000feh).2, tick_none
endif
if TICKSLOT_N > 2
                JBS     off(000feh).1, tick_n2_4
else
                JBS     off(000feh).1, tick_none
endif
if TICKSLOT_N > 1
                JBS     off(000feh).0, tick_n1_2
else
                JBS     off(000feh).0, tick_none
endif
                J       tick_slot_0
if TICKSLOT_N > 1
tick_n1_2:
                J       tick_slot_1
endif
if TICKSLOT_N > 2
tick_n2_4:
if TICKSLOT_N > 3
                JBS     off(000feh).0, tick_n3_2
else
                JBS     off(000feh).0, tick_none
endif
                J       tick_slot_2
if TICKSLOT_N > 3
tick_n3_2:
                J       tick_slot_3
endif
endif
if TICKSLOT_N > 4
tick_n4_8:
if TICKSLOT_N > 6
                JBS     off(000feh).1, tick_n6_4
else
                JBS     off(000feh).1, tick_none
endif
if TICKSLOT_N > 5
                JBS     off(000feh).0, tick_n5_2
else
                JBS     off(000feh).0, tick_none
endif
                J       tick_slot_4
if TICKSLOT_N > 5
tick_n5_2:
                J       tick_slot_5
endif
if TICKSLOT_N > 6
tick_n6_4:
if TICKSLOT_N > 7
                JBS     off(000feh).0, tick_n7_2
else
                JBS     off(000feh).0, tick_none
endif
                J       tick_slot_6
if TICKSLOT_N > 7
tick_n7_2:
                J       tick_slot_7
endif
endif
endif
if TICKSLOT_N > 8
tick_n8_16:
if TICKSLOT_N > 12
                JBS     off(000feh).2, tick_n12_8
else
                JBS     off(000feh).2, tick_none
endif
if TICKSLOT_N > 10
                JBS     off(000feh).1, tick_n10_4
else
                JBS     off(000feh).1, tick_none
endif
if TICKSLOT_N > 9
                JBS     off(000feh).0, tick_n9_2
else
                JBS     off(000feh).0, tick_none
endif
                J       tick_slot_8
if TICKSLOT_N > 9
tick_n9_2:
                J       tick_slot_9
endif
if TICKSLOT_N > 10
tick_n10_4:
if TICKSLOT_N > 11
                JBS     off(000feh).0, tick_n11_2
else
                JBS     off(000feh).0, tick_none
endif
                J       tick_slot_10
if TICKSLOT_N > 11
tick_n11_2:
                J       tick_slot_11
endif
endif
if TICKSLOT_N > 12
tick_n12_8:
if TICKSLOT_N > 14
                JBS     off(000feh).1, tick_n14_4
else
                JBS     off(000feh).1, tick_none
endif
if TICKSLOT_N > 13
                JBS     off(000feh).0, tick_n13_2
else
                JBS     off(000feh).0, tick_none
endif
                J       tick_slot_12
if TICKSLOT_N > 13
tick_n13_2:
                J       tick_slot_13
endif
if TICKSLOT_N > 14
tick_n14_4:
if TICKSLOT_N > 15
                JBS     off(000feh).0, tick_n15_2
else
                JBS     off(000feh).0, tick_none
endif
                J       tick_slot_14
if TICKSLOT_N > 15
tick_n15_2:
                J       tick_slot_15
endif
endif
endif
endif
tick_none:      J       tick_slots_done
if TICKSLOT_N > 0
tick_slot_0:
undef TICK_SLOT
define TICK_SLOT 0
undef XP
define XP XP_TICKSLOT
include "features.inc"
                J       tick_slots_done
endif
if TICKSLOT_N > 1
tick_slot_1:
undef TICK_SLOT
define TICK_SLOT 1
undef XP
define XP XP_TICKSLOT
include "features.inc"
                J       tick_slots_done
endif
if TICKSLOT_N > 2
tick_slot_2:
undef TICK_SLOT
define TICK_SLOT 2
undef XP
define XP XP_TICKSLOT
include "features.inc"
                J       tick_slots_done
endif
if TICKSLOT_N > 3
tick_slot_3:
undef TICK_SLOT
define TICK_SLOT 3
undef XP
define XP XP_TICKSLOT
include "features.inc"
                J       tick_slots_done
endif
if TICKSLOT_N > 4
tick_slot_4:
undef TICK_SLOT
define TICK_SLOT 4
undef XP
define XP XP_TICKSLOT
include "features.inc"
                J       tick_slots_done
endif
if TICKSLOT_N > 5
tick_slot_5:
undef TICK_SLOT
define TICK_SLOT 5
undef XP
define XP XP_TICKSLOT
include "features.inc"
                J       tick_slots_done
endif
if TICKSLOT_N > 6
tick_slot_6:
undef TICK_SLOT
define TICK_SLOT 6
undef XP
define XP XP_TICKSLOT
include "features.inc"
                J       tick_slots_done
endif
if TICKSLOT_N > 7
tick_slot_7:
undef TICK_SLOT
define TICK_SLOT 7
undef XP
define XP XP_TICKSLOT
include "features.inc"
                J       tick_slots_done
endif
if TICKSLOT_N > 8
tick_slot_8:
undef TICK_SLOT
define TICK_SLOT 8
undef XP
define XP XP_TICKSLOT
include "features.inc"
                J       tick_slots_done
endif
if TICKSLOT_N > 9
tick_slot_9:
undef TICK_SLOT
define TICK_SLOT 9
undef XP
define XP XP_TICKSLOT
include "features.inc"
                J       tick_slots_done
endif
if TICKSLOT_N > 10
tick_slot_10:
undef TICK_SLOT
define TICK_SLOT 10
undef XP
define XP XP_TICKSLOT
include "features.inc"
                J       tick_slots_done
endif
if TICKSLOT_N > 11
tick_slot_11:
undef TICK_SLOT
define TICK_SLOT 11
undef XP
define XP XP_TICKSLOT
include "features.inc"
                J       tick_slots_done
endif
if TICKSLOT_N > 12
tick_slot_12:
undef TICK_SLOT
define TICK_SLOT 12
undef XP
define XP XP_TICKSLOT
include "features.inc"
                J       tick_slots_done
endif
if TICKSLOT_N > 13
tick_slot_13:
undef TICK_SLOT
define TICK_SLOT 13
undef XP
define XP XP_TICKSLOT
include "features.inc"
                J       tick_slots_done
endif
if TICKSLOT_N > 14
tick_slot_14:
undef TICK_SLOT
define TICK_SLOT 14
undef XP
define XP XP_TICKSLOT
include "features.inc"
                J       tick_slots_done
endif
if TICKSLOT_N > 15
tick_slot_15:
undef TICK_SLOT
define TICK_SLOT 15
undef XP
define XP XP_TICKSLOT
include "features.inc"
                J       tick_slots_done
endif
tick_slots_done:
endif
