{{

 bluetooth-host  ver 0.1
──────────────────────────────────────────────────────────────────

High-level Bluetooth Host driver for the Parallax Propeller.
Using the bluetooth-hciusb and usb-fs-host objects, this
directly supports USB Bluetooth adapters. This module implements
application-level protocols: L2CAP, RFCOMM, and SDP.

The latest version of this file should always be at:
http://svn.navi.cx/misc/trunk/propeller/usb-host/bluetooth-host.spin

 ┌────────────────────────────────────────────────┐
 │ Copyright (c) 2010 Micah Dowty <micah@navi.cx> │               
 │ See end of file for terms of use.              │
 └────────────────────────────────────────────────┘

}}

OBJ
  hci : "bluetooth-hciusb"
  sdp : "bluetooth-sdp"

CON
  ' Standard Bluetooth "Class of Device" constants

  COD_Misc               = $000000
  COD_Computer           = $000100
  COD_Computer_Desktop   = $000104
  COD_Computer_Server    = $000108
  COD_Computer_Laptop    = $00010C
  COD_Computer_Handheld  = $000110
  COD_Computer_Palm      = $000114  
  COD_Phone              = $000200
  COD_Phone_Cellular     = $000204
  COD_Phone_Cordless     = $000208
  COD_Phone_Smart        = $00020C
  COD_Phone_Modem        = $000210  
  COD_LAN                = $000300
  COD_Audio              = $000400
  COD_Audio_Headset      = $000404
  COD_Peripheral         = $000500

  ' Standard Bluetooth Protocol Service Multiplexor (PSM) constants

  PSM_ServiceDiscovery   = $0001
  PSM_RFCOMM             = $0003
  PSM_TelephonyControl   = $0005
  PSM_TCSCordless        = $0007
  PSM_BNEP               = $000F
  PSM_HIDControl         = $0011
  PSM_HIDInterrupt       = $0013
  PSM_UPnP               = $0015
  PSM_AVCTP              = $0017
  PSM_AVDTP              = $0019
  PSM_DynamicBase        = $1001
  
  ' Other Bluetooth constants

  BDADDR_LEN = hci#BDADDR_LEN

  ' Commands for the server cog.
  ' Command IDs are the upper byte, parameters are the low 24 bits.

  C_HCI_Reset           = 1
  C_HCI_WrPageScanType  = 2
  C_HCI_WrScanEnable    = 3
  C_HCI_WrLocalName     = 4
  C_HCI_RdLocalAddr     = 5
  C_HCI_SetEvtFilter24  = 6
  C_HCI_WrLocalClass    = 7
  C_HCI_Inquiry         = 8
  C_HCI_WrInqScanType   = 9
  C_HCI_SetEventMask    = 10

  ' Various timeouts

  ENUM_TIMEOUT_MS    = 2000
  HCI_TIMEOUT_MS     = 250
  HCI_RETRIES        = 10
  
  ' L2CAP Local Channel ID (LCID) Table: Stored information
  ' about each active L2CAP connection. To save memory, we have a
  ' single global table of L2CAP channels, and we hand out unique
  ' channel numbers to each device that's connected.
  '
  ' The table is indexed according to destination CID. We
  ' support up to LCID_TABLE_SIZE simultaneous L2CAP connections,
  ' using CIDs starting at LCID_FIRST.

  LCI_CONN_ID       = 0      ' Connection ID, or zero if unused
  LCI_REMOTE_CID    = 2      ' Remote channel ID that we're connected to
  LCI_PSM           = 4      ' Protocol Service Multiplexor
  LCI_LEN           = 6      ' Must be a multiple of 2 
  LCI_TABLE_SIZE    = 8
  CID_FIRST         = $0080
  CID_LAST          = CID_FIRST + LCI_TABLE_SIZE

  ' Connection info table: Stored information about each active ACL
  ' connection. We begin the table with the bluetooth address, so
  ' that the public ConnectionAddress routine can also be easily
  ' used internally for other table entries.
  '
  ' The table size here determines the maximum number of devices we
  ' can maintain connections with simultaneously.
  '
  ' Table entries with CID=0 are unused.

  CI_BDADDR          = 0
  CI_CID             = 6
  CI_LEN             = 8      ' Must be a multiple of 4
  CI_TABLE_SIZE      = 8      ' Max number of open device connections
  
  ' Inquiry table: Stored information about discoverable Bluetooth
  ' devices nearby, which we've discovered as the result of an Inquiry
  ' command.

  IT_BDADDR          = 0
  IT_CLASS           = 6
  IT_LEN             = 9
  IT_TABLE_SIZE      = 8      ' Max number of devices we can discover

  ' L2CAP: Basic header

  L2CAP_SIZE         = hci#ACL_HEADER_LEN
  L2CAP_CHANNEL      = L2CAP_SIZE + 2

  ' L2CAP: Connectionless data (G-frame)
  
  L2CAP_G_CHANNEL    = $0002
  L2CAP_G_PSM        = L2CAP_CHANNEL + 2
  L2CAP_G_DATA       = L2CAP_G_PSM + 2
  L2CAP_G_DATA_MAX   = hci#ACL_PACKET_SIZE - L2CAP_G_DATA
  
  ' L2CAP: Connection-oriented data (S-frame and I-frame)

  L2CAP_SI_DATA      = L2CAP_CHANNEL + 2
  L2CAP_SI_DATA_MAX  = hci#ACL_PACKET_SIZE - L2CAP_SI_DATA

  ' L2CAP: Signalling packets

  L2CAP_SIG_CHANNEL  = $0001
  L2CAP_SIG_CODE     = L2CAP_CHANNEL + 2
  L2CAP_SIG_ID       = L2CAP_SIG_CODE + 1
  L2CAP_SIG_LEN      = L2CAP_SIG_ID + 1
  L2CAP_SIG_DATA     = L2CAP_SIG_LEN + 2
  L2CAP_SIG_DATA_MAX = hci#ACL_PACKET_SIZE - L2CAP_SIG_DATA

  L2SIG_CmdReject       = $01
  L2SIG_ConnRequest     = $02
  L2SIG_ConnResponse    = $03
  L2SIG_CfgRequest      = $04
  L2SIG_CfgResponse     = $05
  L2SIG_DisconnRequest  = $06
  L2SIG_DisconnResponse = $07
  L2SIG_EchoRequest     = $08
  L2SIG_EchoResponse    = $09
  L2SIG_InfoRequest     = $0A
  L2SIG_InfoResponse    = $0B
  
DAT

serverCmd     long  -1
serverStack   long  0[256]
connTable     long  0[CI_TABLE_SIZE * CI_LEN / 4]
aclBuffer     long  0[hci#ACL_PACKET_SIZE / 4]

serverError   word  0           ' Last error from the server cog
hciCommand    word  0           ' In-progress HCI command (0 when done)
lciTable      word  0[LCI_TABLE_SIZE * LCI_LEN / 2]

hciStatus     byte  0           ' Status code from last HCI command
addrStringBuf byte  0[18]       ' Buffer for AddressToString 
localAddr     byte  0[BDADDR_LEN]
inqCount      byte  0           ' Number of devices found so far
inqInProgress byte  0           ' Inquiry in progress?
inqTable      byte  0[IT_TABLE_SIZE * IT_LEN]

DAT
''
''
''==============================================================================
'' Initialization
''==============================================================================

PUB Start | deadline
  '' Get this whole Rube Goldberg machine going...
  ''   - Starts the USB Host Controller (3 cogs)
  ''   - Enumerates the attached USB devices
  ''   - Configures the Bluetooth USB device
  ''   - Starts the Bluetooth host controller (1 cog)
  ''
  '' So, this uses a total of 4 cogs. Our Bluetooth host cog runs
  '' an SDP server and handles incoming connections, so your application
  '' is free to do other things without compromising Bluetooth connectivity.
  ''
  '' By default, we accept incoming connections but this device is not
  '' discoverable. To make it discoverable, call SetName and SetClass
  '' (both optional but recommended) then SetDiscoverable.

  ' Initialize the hardware, retrying if it doesn't succeed right away.

  deadline := cnt + clkfreq/1000 * ENUM_TIMEOUT_MS
  result~~
  repeat while result and (cnt - deadline) < 0
    result := \HardwareInit
  if result
    abort

  ' Start the server cog
  if cognew(Server, @serverStack) < 0
    abort hci#E_OUT_OF_COGS

  HCIWait(constant(C_HCI_Reset << 24))
  HCIWait(constant(C_HCI_RdLocalAddr << 24))

  ' Set up interlaced page scan mode. This will continuously listen
  ' for incoming connections- we need to do this in order to notice
  ' other device's attempts to connect to us.
  HCIWait(constant(C_HCI_WrPageScanType << 24 | 1))

  ' Use interlaced scan for Inquiry too
  HCIWait(constant(C_HCI_WrInqScanType << 24 | 1))

  ' Use CB_SetEventFilter to auto-accept incoming commands:
  '    $02 - Connection setup filter
  '    $00 - Allow connections from any device
  '    $02 - Auto-accept with role switch disabled
  HCIWait(constant(C_HCI_SetEvtFilter24 << 24 | $020002))

  ' Mask out unwanted/unsupported events
  HCIWait(constant(C_HCI_SetEventMask << 24))
  
PUB SetDiscoverable
  '' Make this Bluetooth device discoverable by other devices

  HCIWait(constant(C_HCI_WrScanEnable << 24 | $03))

PUB SetName(str)
  '' Set the human-readable name of this Bluetooth device

  HCIWait(constant(C_HCI_WrLocalName << 24) | str)

PUB SetClass(class)
  '' Set the local device's class, as a packed 24-bit constant.
  '' You can use the standard COD_* constants from this object,
  '' or you can follow the Bluetooth spec in creating a custom
  '' COD for your device. 

  HCIWait(constant(C_HCI_WrLocalClass << 24) | class)

PUB LocalAddress
  '' Return a pointer to the local Bluetooth adapter's address

  return @localAddr

DAT
''
''
''==============================================================================
'' Device Discovery
''==============================================================================

PUB DiscoverDevices(duration)
  '' Begin looking for nearby discoverable Bluetooth devices.
  ''
  '' Device discovery is asynchronous. After you start discovery,
  '' the Bluetooth host cog will begin storing data about each
  '' device we find.
  ''
  '' Device discovery has a pre-set duration, specified here in
  '' units of 1.28 seconds. Valid durations are 1.28 to 61.44 seconds,
  '' or 1 through 48.
  ''
  '' Discovery results and status can be obtained using the other
  '' functions in this section.

  inqCount~
  longfill(@inqTable, 0, constant(IT_TABLE_SIZE * IT_LEN / 4))
  
  HCIWait(constant(C_HCI_Inquiry << 24) | duration)
  inqInProgress~~
  
PUB DiscoveryInProgress
  '' Returns nonzero as long as an asynchronous device discovery
  '' is in progress. If the discovery has finished because it has
  '' reached the end of its duration, returns zero.

  return inqInProgress

PUB NumDiscoveredDevices
  '' Returns the number of devices we've discovered so far.

  return inqCount

PUB DiscoveredAddr(id)
  '' Returns a pointer to the address of the discovered device
  '' with zero-based index "id".

  return @inqTable + IT_LEN * id

PUB DiscoveredClass(id) | ptr
  '' Returns the 24-bit class of a discovered device with
  '' zero-based index "id".

  ptr := DiscoveredAddr(id) + IT_CLASS
  result := BYTE[ptr++]
  result |= BYTE[ptr++] << 8
  result |= BYTE[ptr] << 16


DAT
''
''
''==============================================================================
'' Connection Management
''==============================================================================

PUB ConnectionAddress(cid) | ptr
  '' Return a pointer to the Bluetooth address for a particular connection ID.
  ''
  '' If the connection doesn't exist, aborts with E_NO_CONNECTION.
  '' Note that connections can be torn down at any time, so the caller
  '' must always handle this error somehow. 

  ptr := @connTable
  repeat CI_TABLE_SIZE
    if cid == WORD[ptr + CI_CID]
      return ptr
    ptr += CI_LEN
  abort hci#E_NO_CONNECTION

DAT
''
''
''==============================================================================
'' Utilities
''==============================================================================

PUB AddressToString(addr) | pIn, pOut, octet
  '' Convert a 6-byte Bluetooth Device Address
  '' to a human-readable string in the standard format.
  ''
  '' Returns a pointer to a zero-terminated string.
  '' This buffer is valid until the next call to AddressToString.
  ''
  '' For convenience, this function returns "--:--:--:--:--:--" if
  '' addr =< 0, so you can directly pass either pointers or error
  '' codes in and see something human-readable.

  pIn := addr + constant(BDADDR_LEN - 1)
  pOut := @addrStringBuf
  repeat BDADDR_LEN
    octet := BYTE[pIn--] << 24
    repeat 2
      if addr > 0
        BYTE[pOut++] := lookupz((octet <-= 4) & $F : "0".."9", "A".."F")
      else
        BYTE[pOut++] := "-" 
    BYTE[pOut++] := ":"
  BYTE[--pOut] := 0
  return @addrStringBuf

DAT
'
'
'==============================================================================
' Private Implementation
'==============================================================================

PRI HardwareInit
  ' Internal function to initialize the host controller hardware.
  ' We'll retry this until it succeeds, in case the Bluetooth adapter
  ' needs time to wake up, or there's noise on the USB connection.

  hci.Enumerate
  hci.Init

PRI Command(c)
  ' Send a command to the server cog

  repeat while serverCmd
  serverCmd := c

PRI HCIWait(c) | deadline
  ' Tell the server cog to issue an HCI command,
  ' and wait for the response. We'll automatically
  ' retry the command several times, but if it ultimately
  ' fails, we abort with an error code.
  '
  ' This is an indirect way to issue an HCI command via the server
  ' cog. We have to do this for two main reasons: (1) The server
  ' cog owns the USB controller and all HCI buffers, so we can't
  ' send commands without synchronizing with it anyway, and (2)
  ' we may need to process unrelated events and ACL packets while
  ' we're waiting on this command.
  '
  ' Note that we currently never have more than one pending
  ' command at a time, for simplicity's sake.

  repeat HCI_RETRIES

    hciCommand~~
    Command(c)

    deadline := cnt + clkfreq/1000 * HCI_TIMEOUT_MS
    repeat while (cnt - deadline) < 0 and hciCommand

    if not (hciCommand or hciStatus) 
      return 0  ' Success

  if hciCommand
    abort hci#E_NO_RESPONSE
  abort hci#E_CMD_FAIL

PRI Server | err
  ' Main loop for the server cog.

  serverCmd~
  repeat
    err := \ServerPoll
    if err < 0
      serverError := err
    
PRI ServerPoll | tmp
  ' Poll all event sources:
  '    - Server Commands
  '    - HCI Events
  '    - ACL Packets

  if serverCmd
    case serverCmd >> 24
  
      C_HCI_Reset:
        hci.CmdBegin(hciCommand := hci#CB_Reset)
        hci.CmdSend

      C_HCI_RdLocalAddr:
        hci.CmdBegin(hciCommand := hci#IP_ReadBDAddr)
        hci.CmdSend
      
      C_HCI_WrPageScanType:
        hci.CmdBegin(hciCommand := hci#CB_WritePageScanType)
        hci.Cmd8(serverCmd)
        hci.CmdSend

      C_HCI_WrInqScanType:
        hci.CmdBegin(hciCommand := hci#CB_WriteInquiryScanType)
        hci.Cmd8(serverCmd)
        hci.CmdSend

      C_HCI_WrScanEnable:
        hci.CmdBegin(hciCommand := hci#CB_WriteScanEnable)
        hci.Cmd8(serverCmd)
        hci.CmdSend

      C_HCI_WrLocalName:
        hci.CmdBegin(hciCommand := hci#CB_WriteLocalName)
        hci.CmdString(serverCmd)
        hci.CmdSend

      C_HCI_SetEvtFilter24:
        hci.CmdBegin(hciCommand := hci#CB_SetEventFilter)
        hci.Cmd24(serverCmd)
        hci.CmdSend

      C_HCI_SetEventMask:
        ' This should roughly match the events we actually support.
        ' It is especially important to mask out the PIN events until
        ' we actually support PINs, so peers know we have no way of
        ' collecting a PIN code.
        hci.CmdBegin(hciCommand := hci#CB_SetEventMask)
        hci.Cmd32($00000c5f)
        hci.Cmd32($00000000)
        hci.CmdSend      

      C_HCI_WrLocalClass:
        hci.CmdBegin(hciCommand := hci#CB_WriteClassOfDevice)
        hci.Cmd24(serverCmd)
        hci.CmdSend

      C_HCI_Inquiry:
        hci.CmdBegin(hciCommand := hci#LC_Inquiry)
        hci.Cmd24($9E8B00)       ' LAP
        hci.Cmd8(serverCmd)      ' Duration
        hci.Cmd8(IT_TABLE_SIZE)  ' Max # of responses
        hci.CmdSend

    serverCmd~  ' Server command is now complete

  case \hci.EvtPoll

    hci#EV_CommandComplete:
      hci.Evt8                    ' Number of commands we can send
      if hci.Evt16 == hciCommand  ' Command type 
        hciStatus := hci.Evt8     ' Command status

        ' Store response data for this command
        case hciCommand

          hci#IP_ReadBDAddr:
            bytemove(@localAddr, hci.EvtBuffer(BDADDR_LEN), BDADDR_LEN)
        
        hciCommand~  ' HCIWait is now complete

    hci#EV_CommandStatus:
      tmp := hci.Evt8             ' Command status
      hci.Evt8                    ' Number of commands we can send
      if hci.Evt16 == hciCommand  ' Command type
        hciStatus := tmp
        hciCommand~  ' HCIWait is now complete

    hci#EV_ConnComplete:
      if hci.Evt8 == 0            ' Connection status (0=success)
        tmp := hci.Evt16          ' Connection handle, BDADDR
        NewConnection(tmp, hci.EvtBuffer(BDADDR_LEN)) 

    hci#EV_DisconnectionComplete:
      if hci.Evt8 == 0            ' Disconnection status (0=success)
        EndConnection(hci.Evt16)  ' Connection handle

    hci#EV_InquiryComplete:
      inqInProgress~

    hci#EV_InquiryResult:
      StoreInquiryResult

  repeat while tmp := hci.ACLPoll(@aclBuffer) => hci#ACL_HEADER_LEN
    ACLReceive
        
PRI NewConnection(cid, bdAddr) | ptr
  ' A new incoming connection was established.
  ' Find an unused connection table entry, and initialize it.
  ' If our connection table is full, aborts with E_NO_CONNECTION.

  ptr := ConnectionAddress(0)
  bytemove(ptr, bdAddr, BDADDR_LEN)
  WORD[ptr + CI_CID] := cid

PRI EndConnection(cid) | lcid, ptr
  ' An connection has terminated, and the corresponding CID
  ' is no longer in use.

  bytefill(ConnectionAddress(cid), 0, CI_LEN)
  
  ' Free all L2CAP channels associated with this connection
  repeat lcid from CID_FIRST to CID_LAST
    ptr := L2ChannelPtr(lcid)
    if WORD[ptr] == cid
      L2ChannelFree(lcid)

PRI StoreInquiryResult | numResults, i, ptr
  ' Store the payload of an EV_InquiryResult in the inquiry table.

  ' There can be multiple responses in one event
  numResults := hci.Evt8

  if numResults
    ' Array of BDADDRs
    repeat i from 0 to numResults-1
      bytemove(ptr := DiscoveredAddr(inqCount + i), hci.EvtBuffer(BDADDR_LEN), BDADDR_LEN)

    ' Ignore the Page_Scan_Repetition_Mode and the two Reserved arrays.
    hci.EvtBuffer(numResults * 3)
  
    ' Class array
    repeat i from 0 to numResults-1
      bytemove(DiscoveredAddr(inqCount + i) + IT_CLASS, hci.EvtBuffer(3), 3)

    inqCount += numResults

DAT
'
'
'==============================================================================
' ACL Layer Implementation
'==============================================================================

PRI ACLReceive | cid, len, lcid
  ' Handle a single received ACL packet from the HCI.

  ' First word of the ACL header has the connection ID and the ACL flags.
  ' Currently we only handle point-to-point non-fragmented packets.
  
  cid := WORD[@aclBuffer + hci#ACL_HANDLE]  
  if cid & hci#ACL_BC_MASK
    abort hci#E_BROADCAST
  if (cid & hci#ACL_PB_MASK) <> hci#ACL_PB_FIRST
    abort hci#E_FRAGMENTED
  cid &= hci#ACL_HANDLE_MASK

  ' Next word is the total length. If it's longer than the
  ' size of one ACL packet's payload, it's fragmented and we
  ' don't support it.

  len := WORD[@aclBuffer + hci#ACL_TOTAL_LEN]
  if len > hci#ACL_DATA_LEN
    abort hci#E_FRAGMENTED

  ' Now check the L2CAP length. This should be consistent too.

  len -= hci#ACL_HEADER_LEN
  if len <> WORD[@aclBuffer + L2CAP_SIZE]
    abort hci#E_FRAGMENTED

  ' Dispatch to a channel-specific L2CAP packet handler

  case lcid := WORD[@aclBuffer + L2CAP_CHANNEL]

    L2CAP_SIG_CHANNEL:
      ' Signalling packet
      L2SignalReceive

    L2CAP_G_CHANNEL:
      ' Connectionless data (Currently unsupported)
      abort hci#E_BAD_CHANNEL

    other:
      ' Connection-oriented channel
      L2ChannelReceive(lcid)

PRI ACLTransmit(aclLen)
  ' Transmit the currently buffered ACL packet.
  ' Only handles point-to-point non-fragmented packets.
  '
  ' Uses the connection ID that's already in the ACL buffer,
  ' but we do set the rest of the ACL header.

  if aclLen > hci#ACL_DATA_LEN
    abort hci#E_FRAGMENTED

  WORD[@aclbuffer + hci#ACL_HANDLE] := ACLGetConnection | hci#ACL_PB_FIRST
  WORD[@aclBuffer + hci#ACL_TOTAL_LEN] := aclLen

  ' Retry if there's a transmit failure
  repeat HCI_RETRIES
    result := \hci.ACLWrite(@aclBuffer, aclLen + hci#ACL_HEADER_LEN)
    if result => 0
      return

PRI ACLGetConnection
  ' Return the connection ID for the current ACL packet

  return WORD[@aclBuffer + hci#ACL_HANDLE] & hci#ACL_HANDLE_MASK

DAT
'
'
'==============================================================================
' L2CAP Layer Implementation
'==============================================================================

PRI L2ChannelPtr(lcid)
  ' Return a pointer to the Local Channel Info table row
  ' for a channel with ID "lcid". Validates the range of lcid only.
  
  lcid -= CID_FIRST
  if lcid => LCI_TABLE_SIZE
    abort hci#E_BAD_CHANNEL

  return @lciTable + lcid * LCI_LEN
    
PRI L2ChannelLookupACL(lcid)
  ' Look up and validate an entry in the Local Channel Info table. 
  ' The connection ID must match the current ACL packet.

  result := L2ChannelPtr(lcid)
  if WORD[result] <> ACLGetConnection
    abort hci#E_BAD_CHANNEL

PRI L2ChannelFree(lcid)
  ' Mark an L2CAP channel as unused

  wordfill(L2ChannelPtr(lcid), 0, constant(LCI_LEN / 2))

PRI L2ChannelNewACL(psm, rcid) : lcid | ptr
  ' Allocate a new L2CAP channel,
  ' using the connection ID from the current ACL packet.

  repeat lcid from CID_FIRST to CID_LAST
    ptr := L2ChannelPtr(lcid)
    if not WORD[ptr]
      ' Channel is free.
      WORD[ptr] := ACLGetConnection
      WORD[ptr + LCI_REMOTE_CID] := rcid
      WORD[ptr + LCI_PSM] := psm
      return

  abort hci#E_NO_CHANNELS
 
PRI L2SignalReceive | psm, scid, dcid
  ' Received an L2CAP Signalling packet.
  ' Handle the packet according to its 8-bit code.
  
  case BYTE[@aclBuffer + L2CAP_SIG_CODE]

    L2SIG_EchoRequest:
      L2SignalTransmit(L2SIG_EchoResponse, WORD[@aclBuffer + L2CAP_SIG_LEN])

    L2SIG_InfoRequest:
      WORD[@aclBuffer + constant(L2CAP_SIG_DATA + 2)] := $0001   ' Not supported
      L2SignalTransmit(L2SIG_InfoResponse, 4)

    L2SIG_ConnRequest:
      ' The connection request includes PSM and Source CID for the connection.
      ' We need to respond with a Destination (local) CID. Since we only need
      ' to support one L2 connection for each PSM on a particular device
      ' connection, we derive our Destionation CID from the PSM itself.
      psm := WORD[@aclBuffer + constant(L2CAP_SIG_DATA + 0)]
      scid := WORD[@aclBuffer + constant(L2CAP_SIG_DATA + 2)]
      WORD[@aclBuffer + constant(L2CAP_SIG_DATA + 0)] := L2ChannelNewACL(psm, scid)
      LONG[@aclBuffer + constant(L2CAP_SIG_DATA + 4)] := 0 ' Connection successful
      L2SignalTransmit(L2SIG_ConnResponse, 8)                         

    L2SIG_DisconnRequest:
      dcid := WORD[@aclBuffer + constant(L2CAP_SIG_DATA + 0)]
      L2ChannelLookupACL(dcid)  ' Validate channel for this connection
      L2ChannelFree(dcid)
      L2SignalTransmit(L2SIG_DisconnResponse, 4)
    
    L2SIG_CfgRequest:
      ' Currently this just always returns success without examining the configuration
      dcid := WORD[@aclBuffer + constant(L2CAP_SIG_DATA + 0)]
      scid := WORD[L2ChannelLookupACL(dcid) + LCI_REMOTE_CID]
      WORD[@aclBuffer + constant(L2CAP_SIG_DATA + 0)] := scid
      WORD[@aclBuffer + constant(L2CAP_SIG_DATA + 4)] := $0000 ' Success
      L2SignalTransmit(L2SIG_CfgResponse, 6)
                                                        
      ' To complete configuration, both sides of the connection have to
      ' request configuration. Take this opportunity to send our request
      ' to the other side.
      L2SignalTransmit(L2SIG_CfgRequest, 4)

    L2SIG_CfgResponse:
      ' Ignore the other side's response to our CfgRequest.
     
    other:      
      WORD[@aclBuffer + L2CAP_SIG_DATA] := 0 ' Command not understood
      L2SignalTransmit(L2SIG_CmdReject, 2)       

PRI L2SignalTransmit(type, len)
  ' Send an L2CAP Signalling packet.
  '
  ' Takes the connection ID and Signal ID that are
  ' currently in the buffer, writes all other fields.

  ' Lengths, from inner to outermost
  WORD[@aclBuffer + L2CAP_SIG_LEN] := len
  WORD[@aclBuffer + L2CAP_SIZE] := len += constant(L2CAP_SIG_DATA - L2CAP_SIG_CODE)

  WORD[@aclBuffer + L2CAP_CHANNEL] := L2CAP_SIG_CHANNEL
  BYTE[@aclBuffer + L2CAP_SIG_CODE] := type

  ACLTransmit(len + constant(L2CAP_SIG_CODE - hci#ACL_HEADER_LEN))

PRI L2ChannelReceive(lcid) | channel
  ' Received an L2CAP packet on a connection-oriented channel.
  ' Dispatch it to a connection-specific handler.
  
  channel := L2ChannelLookupACL(lcid)
  case BYTE[channel + LCI_PSM]

    PSM_ServiceDiscovery:
      ' Invoke the SDP server
      sdp.FillReceiveBuffer(@aclBuffer + L2CAP_SI_DATA, WORD[@aclBuffer + L2CAP_SIZE])
      sdp.SetTransmitBuffer(@aclBuffer + L2CAP_SI_DATA, L2CAP_SI_DATA_MAX)
      sdp.HandlePDU                                   
      L2ChannelTransmit(channel, sdp.TransmitLength)  

PRI L2ChannelTransmit(channel, len)
  ' Send an L2CAP connection-oriented packet.
  ' Writes all fields in the L2CAP and ACL header.
                                      
  WORD[@aclBuffer + L2CAP_SIZE] := len
  WORD[@aclBuffer + L2CAP_CHANNEL] := WORD[channel + LCI_REMOTE_CID]

  ACLTransmit(len + constant(L2CAP_SI_DATA - hci#ACL_HEADER_LEN))
  
PUB XXX_ACLBuffer
  return @aclBuffer


DAT
{{

┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                                   TERMS OF USE: MIT License                                                  │                                                            
├──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation    │ 
│files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy,    │
│modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software│
│is furnished to do so, subject to the following conditions:                                                                   │
│                                                                                                                              │
│The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.│
│                                                                                                                              │
│THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE          │
│WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR         │
│COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,   │
│ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                         │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
}}