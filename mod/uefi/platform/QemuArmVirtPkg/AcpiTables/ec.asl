/** @file
  Contains root level name space objects for the platform

  Copyright (c) 2024, MediaTek Inc. All rights reserved.<BR>
  SPDX-License-Identifier: BSD-2-Clause-Patent

**/

DefinitionBlock ("SsdtEc.aml", "SSDT", 2, "QEMUAR", "EC      ", 1) {

  Scope(\_SB)
  {
    #include "ffa.asl"
    #include "ucsi.asl"
    #include "hid.asl"
    #include "battery.asl"
    #include "thermal.asl"
    #include "rtc.asl"

  //
  // EC Test interface to load KMDF driver and map methods
  //
  Device (ECT0) {
    Name (_HID, "ETST0001")
    Name (_UID, 0x0)
    Name (_CCA, 0x0)

    /*********************** General Methods **********************************/
    Name (NEVT, 0x1234)

    Method(ECHO, 0x1, NotSerialized) {
      Return(Arg0) // Echo back input
    }

    Method (_STA) {
      Return (0xf)
    }

    /******************* Battery Test Methods **********************************/
    Method (TBIX, 0x0, NotSerialized) {
      Return (\_SB.BAT0._BIX ())
    }

    Method (TBST, 0x0, NotSerialized) {
      Return (\_SB.BAT0._BST ())
    }

    Method (TPSR, 0x0, NotSerialized) {
      Return (\_SB.PSU0._PSR ())
    }

    Method (TPIF, 0x0, NotSerialized) {
      Return (\_SB.PSU0._PIF ())
    }

    Method (TBPS, 0x0, NotSerialized) {
      Return (\_SB.BAT0._BPS ())
    }

    Method (TBTP, 0x1, NotSerialized) {
      Return (\_SB.BAT0._BTP (Arg0))
    }

    Method (TBPT, 0x0, NotSerialized) {
      Return (\_SB.BAT0._BPT (1, 20, 100))
    }

    Method (TBPC, 0x0, NotSerialized) {
      Return (\_SB.BAT0._BPC ())
    }

    Method (TBMC, 0x0, NotSerialized) {
      Return (\_SB.BAT0._BMC (0x1))
    }

    Method (TBMD, 0x0, NotSerialized) {
      Return (\_SB.BAT0._BMD ())
    }

    Method (TBCT, 0x0, NotSerialized) {
      Return (\_SB.BAT0._BCT (5000))
    }

    Method (TBTM, 0x0, NotSerialized) {
      Return (\_SB.BAT0._BTM (500))
    }

    Method (TBMS, 0x0, NotSerialized) {
      Return (\_SB.BAT0._BMS (1000))
    }

    Method (TBMA, 0x0, NotSerialized) {
      Return (\_SB.BAT0._BMA (5000))
    }

    Method (BNFY, 0x0, NotSerialized) {
      Return (\_SB.BAT0.TNFY ())
    }

    /******************* Thermal Test Methods **********************************/
    Method (RFAN, 0x0, NotSerialized) {
      Return (\_SB.CIO1._DSM (ToUuid ("07ff6382-e29a-47c9-ac87-e79dad71dd82"), 1, 3, 0))
    }

    Method (WFAN, 0x0, NotSerialized) {
      Return (\_SB.CIO1._DSM (ToUuid ("d9b9b7f3-2a3e-4064-8841-cb13d317669e"), 1, 3, 1500))
    }

    Method (RTMP, 0x0, NotSerialized) {
      Return (\_SB.SKIN._TMP ())
    }

    Method (TDSM, 0x4, NotSerialized) {
      Return (\_SB.CIO1._DSM (Arg0, Arg1, Arg2, Arg3))
    }

    Method (TSVR, 0x3, NotSerialized) {
      Return (\_SB.CIO1.SVAR (Arg0, Arg1, Arg2))
    }

    Method (TGVR, 0x2, NotSerialized) {
      Return (\_SB.CIO1.GVAR (Arg0, Arg1))
    }

    /******************* Time/Alarm Test Methods *******************************/
    Method (_GCP, 0, Serialized) {
      Return (\_SB.RTC._GCP ())
    }

    Method (_GRT, 0, Serialized) {
      Return (\_SB.RTC._GRT ())
    }

    Method (_SRT, 1, Serialized) {
      Return (\_SB.RTC._SRT (Arg0))
    }

    Method (_GWS, 1, Serialized) {
      Return (\_SB.RTC._GWS (Arg0))
    }

    Method (_CWS, 1, Serialized) {
      Return (\_SB.RTC._CWS (Arg0))
    }

    Method (_STV, 2, NotSerialized) {
      Return (\_SB.RTC._STV (Arg0, Arg1))
    }

    Method (_TIV, 1, Serialized) {
      Return (\_SB.RTC._TIV (Arg0))
    }

    Method (_STP, 2, NotSerialized) {
      Return (\_SB.RTC._STP (Arg0, Arg1))
    }

    Method (_TIP, 1, Serialized) {
      Return (\_SB.RTC._TIP (Arg0))
    }

    /********************* UCSI Test Methods **********************************/
    // USND — forward an 8-byte UCSI CONTROL buffer to the reusable FF-A
    // backend at \_SB.FFA0.UCMD. NotSerialized: the backend owns serialization.
    Method(USND, 1, NotSerialized) {
      Return(\_SB.FFA0.UCMD(Arg0))
    }

  } // Device (ECT0)

  }

}
