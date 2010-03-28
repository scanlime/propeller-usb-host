{{                                              

 usb-fs-host
──────────────────────────────────────────────────────────────────

This is a software implementation of a simple full-speed (12 MB/s)
USB 1.1 host controller for the Parallax Propeller.

XXX: Work-in-progress! Not actually usable yet.


Limitations
───────────

 - Doesn't even pretend to adhere to the USB spec
 - Maximum average speed is much less than line rate,
   due to time spent pre-encoding and post-decoding.
 - Maximum transmitted packet size is approx. 384 bytes
 - Maximum received packet size is approx. 1024 bytes
 - Clock speed and pin assignments are fixed
 - SOF packets do not have an incrementing frame number
 - SOF packets may not be sent on-time due to other traffic
 - Could use its cogs more efficiently. We need a peak
   of 3 cogs during receive, but the two RX cogs are
   idle at other times. The decode/encode work could
   be split up between multiple cogs in the future.
 - We don't detect TX/RX buffer overruns. If it hurts,
   don't do it. (Also, do not use this HC with untrusted
   devices- a babble condition can overwrite cog memory.)
 
Hardware Requirements
─────────────────────

 - 96 MHz (overclocked) Propeller
 - USB D- attached to P0 with a 47Ω series resistor
 - USB D+ attached to P1 with a 47Ω series resistor
 - Pull-down resistor (~4.7kΩ) from USB D- to ground


 ┌───────────────────────────────────┐
 │ Copyright (c) 2008 Micah Dowty    │               
 │ See end of file for terms of use. │
 └───────────────────────────────────┘

}}

CON
  ' Overclock to 96 MHz (8 cycles per full-speed bit)
  _clkmode = xtal1 + pll16x
  _xinfreq = 6_000_000

CON
  NUM_COGS = 3

  ' Transmit / Receive Size limits.
  '
  ' Transmit size limit is based on free Cog RAM. It can be increased if we save space
  ' in the cog by optimizing the code or removing other data. Receive size is limited only
  ' by available hub ram.

  TX_BUFFER_WORDS = 192
  RX_BUFFER_WORDS = 256
            
  ' USB data pins. We make a couple assumptions about these, so if you want to change these
  ' it isn't as straightforward as just changing these constants:
  '
  '   - Both DMINUS and DPLUS must be <= 8, since we use pin masks in instruction literals.
  '   - The vcfg and palette values we use in the transmitter hardcode these values,
  '     but they could be changed without too much trouble.
  
  DMINUS = 0
  DPLUS = 1

  ' Output bus states
  STATE_J   = |< DPLUS
  STATE_K   = |< DMINUS
  STATE_SE0 = 0
  BUS_MASK  = (|< DPLUS) | (|< DMINUS)

  ' How long we should wait, in bit periods, for a USB device to respond to a token we sent.
  RX_START_TIMEOUT = 64

  ' Maximum number of times to retry a single command list. We try to space the retries
  ' out in intervals of one frame, so this is roughly the number of milliseconds we'll
  ' spend on a single portion of a transfer.
  MAX_CL_RETRIES   = 512

  ' Cog parameter block
  PARAM_COMMAND    = 0          ' Trigger for TX cog
  PARAM_RX_BUFFER  = 1          ' RX data, not yet decoded
  PARAM_RX1_TIME   = 2          ' Trigger for RX1
  PARAM_RX2_TIME   = 3          ' Trigger for RX2
  PARAM_RX_LONGS   = 4          ' Number of raw longs received, MSB=done
  PARAM_RESULT     = 5          ' Result buffer for commands
  NUM_PARAMS       = 6

  ' Command opcodes for the controller cog.
  
  OP_RESET         = 1 << 24           ' Send a USB Reset signal   ' 
  OP_TX_BEGIN      = 2 << 24           ' Start a TX packet. Includes 8-bit PID
  OP_TX_END        = 3 << 24           ' End a TX packet
  OP_TX_FLUSH      = 4 << 24           ' Transmit a batch of TX packets (no receive)
  OP_TXRX          = OP_TX_FLUSH | 1   ' Transmit a batch and immediately start receiving                                
  OP_TX_DATA_16    = 5 << 24           ' Encode and store a 16-bit word
  OP_TX_DATA_PTR   = 6 << 24           ' Encode data from hub memory.
                                       '   [23:16] = # of bytes, [15:0] = pointer
  OP_TX_CRC16      = 7 << 24           ' Encode  a 16-bit CRC of all data since the PID   
  OP_TX_IDLE       = 8 << 24           ' Idle the bus for N bit periods
  OP_RX_PID        = 9 << 24           ' Decode and return a 16-bit PID word, reset CRC-16
  OP_RX_DATA_PTR   = 10 << 24          ' Decode data to hub memory.
                                       '   [23:16] = max # of bytes, [15:0] = pointer
                                       '   Return value is actual # of bytes (including CRC-16)
  OP_RX_CRC16      = 11 << 24          ' Decode and check CRC. Returns (actual XOR expected)
  OP_SOF_WAIT      = 12 << 24          ' Wait for one SOF to be sent
  
  OP_EOL           = $8000_0000        ' End-of-list. Last command in a CommandList().
  
  ' USB PID values / commands

  PID_OUT    = %1110_0001
  PID_IN     = %0110_1001
  PID_SOF    = %1010_0101
  PID_SETUP  = %0010_1101
  PID_DATA0  = %1100_0011
  PID_DATA1  = %0100_1011
  PID_ACK    = %1101_0010
  PID_NAK    = %0101_1010
  PID_STALL  = %0001_1110
  PID_PRE    = %0011_1100

  ' NRZI-decoded representation of a SYNC field, and PIDs which include the SYNC.
  ' These are the form of values returned by OP_RX_PID.

  SYNC_FIELD      = %10000000
  SYNC_PID_ACK    = SYNC_FIELD | (PID_ACK << 8)
  SYNC_PID_NAK    = SYNC_FIELD | (PID_NAK << 8)
  SYNC_PID_STALL  = SYNC_FIELD | (PID_STALL << 8)
  SYNC_PID_DATA0  = SYNC_FIELD | (PID_DATA0 << 8)
  SYNC_PID_DATA1  = SYNC_FIELD | (PID_DATA1 << 8)    

  ' USB Tokens (Device ID + Endpoint) with pre-calculated CRC5 values.
  ' Since we only support a single USB device, we only need tokens for
  ' device 0 (the default address) and device 1 (our arbitrary device ID).
  ' For device 0, we only need endpoint zero. For device 1, we include
  ' tokens for every possible endpoint.
  '
  '                  CRC5  EP#  DEV#
  TOKEN_DEV0_EP0  = %00010_0000_0000000
  TOKEN_DEV1_EP0  = %11101_0000_0000001
  TOKEN_DEV1_EP1  = %01011_0001_0000001
  TOKEN_DEV1_EP2  = %11000_0010_0000001
  TOKEN_DEV1_EP3  = %01110_0011_0000001
  TOKEN_DEV1_EP4  = %10111_0100_0000001
  TOKEN_DEV1_EP5  = %00001_0101_0000001
  TOKEN_DEV1_EP6  = %10010_0110_0000001
  TOKEN_DEV1_EP7  = %00100_0111_0000001
  TOKEN_DEV1_EP8  = %01001_1000_0000001
  TOKEN_DEV1_EP9  = %11111_1001_0000001
  TOKEN_DEV1_EP10 = %01100_1010_0000001
  TOKEN_DEV1_EP11 = %11010_1011_0000001
  TOKEN_DEV1_EP12 = %00011_1100_0000001
  TOKEN_DEV1_EP13 = %10101_1101_0000001
  TOKEN_DEV1_EP14 = %00110_1110_0000001
  TOKEN_DEV1_EP15 = %10000_1111_0000001

  ' Standard device requests.
  '
  ' This encodes the first two bytes of the SETUP packet into
  ' one word-sized command. The low byte is bmRequestType,
  ' the high byte is bRequest.

  REQ_CLEAR_DEVICE_FEATURE     = $0100
  REQ_CLEAR_INTERFACE_FEATURE  = $0101
  REQ_CLEAR_ENDPOINT_FEATURE   = $0102
  REQ_GET_CONFIGURATION        = $0880
  REQ_GET_DESCRIPTOR           = $0680
  REQ_GET_INTERFACE            = $0a81
  REQ_GET_DEVICE_STATUS        = $0000
  REQ_GET_INTERFACE_STATUS     = $0001
  REQ_GET_ENDPOINT_STATUS      = $0002
  REQ_SET_ADDRESS              = $0500
  REQ_SET_CONFIGURATION        = $0900
  REQ_SET_DESCRIPTOR           = $0700
  REQ_SET_DEVICE_FEATURE       = $0300
  REQ_SET_INTERFACE_FEATURE    = $0301
  REQ_SET_ENDPOINT_FEATURE     = $0302
  REQ_SET_INTERFACE            = $0b01
  REQ_SYNCH_FRAME              = $0c82

  ' Standard descriptor types.
  '
  ' These identify a descriptor in REQ_GET_DESCRIPTOR,
  ' via the high byte of wValue. (wIndex is the language ID.)

  DESC_DEVICE        = $0100
  DESC_CONFIGURATION = $0200
  DESC_STRING        = $0300
  DESC_INTERFACE     = $0400
  DESC_ENDPOINT      = $0500

  ' Descriptor Formats

  DEVDESC_bLength             = 0
  DEVDESC_bDescriptorType     = 1
  DEVDESC_bcdUSB              = 2
  DEVDESC_bDeviceClass        = 4
  DEVDESC_bDeviceSubClass     = 5
  DEVDESC_bDeviceProtocol     = 6
  DEVDESC_bMaxPacketSize0     = 7
  DEVDESC_idVendor            = 8
  DEVDESC_idProduct           = 10
  DEVDESC_bcdDevice           = 12
  DEVDESC_iManufacturer       = 14
  DEVDESC_iProduct            = 15
  DEVDESC_iSerialNumber       = 16
  DEVDESC_bNumConfigurations  = 17
  DEVDESC_LEN                 = 18
                
  ' Negative error codes for functions that return them.

  E_TRANSFER      = -1          ' Generic low-level transfer error
  E_CRC           = -2          ' CRC-16 mismatch

  E_ADDR_FAIL     = -10         ' Failed to put device in Addressed state
  E_DESC_PARSE    = -11         ' Can't parse a USB descriptor
  
VAR
  BYTE cogs[NUM_COGS]
  LONG params[NUM_PARAMS]
  LONG rx_buffer[RX_BUFFER_WORDS]

  ' Device state
  WORD devdesc[DEVDESC_LEN/2]   ' Full device descriptor  
  
DAT
''
''
''==============================================================================
'' Host Controller Setup
''==============================================================================

  
PUB Start

  '' Starts the software USB host controller.
  '' Requires 3 free cogs.                             
  
  params[PARAM_COMMAND]~~                    ' Controller will clear COMMAND when it's ready
  params[PARAM_RX1_TIME]~                    ' Don't trigger receivers yet
  params[PARAM_RX2_TIME]~
  params[PARAM_RX_BUFFER] := @rx_buffer      ' Global buffer for not-yet-decoded rx data

  ' Runtime address patching
  Setup_DataPtr |= @Setup_Request
 
  cogs[0] := cognew(@controller_cog, @params)
  cogs[1] := cognew(@rx_cog_1, @params)
  cogs[2] := cognew(@rx_cog_2, @params)

PUB Stop | i

  '' Wait for the USB host controller to become idle, and shut it down.
  '' Frees all allocated cogs.

  Sync
  repeat i from 0 to constant(NUM_COGS - 1)
    cogstop(cogs[i])

PUB Sync

  '' Wait for the host controller to finish any pending operations.

  Command(0)

DAT
''
''==============================================================================
'' High-level Device Framework
''==============================================================================

PUB Enumerate : error

  '' Initialize a device and read its device descriptor.

  DeviceReset

  if DeviceAddress
    return E_ADDR_FAIL

  ' Assume a max packet size of 8 until we get the device descriptor
  BYTE[@devdesc + DEVDESC_bMaxPacketSize0] := 8
    
  error := ControlRead(REQ_GET_DESCRIPTOR, DESC_DEVICE, $0, @devdesc, DEVDESC_LEN)

  return 'xxx
  
  ' XXX: Abort on transfer errors, but not CRC errors.
  '      Some devices seem to give bad CRCs for their device descriptor.. it could be a subtle
  '      timing error, but it doesn't seem like something we can fix on this end. It doesn't happen
  '      with all devices, and much longer packets can be received flawlessly with the same code.
  '      Weird.

  if error == E_TRANSFER
    return

  ' Validate bLength and bDescriptorType in one step
  if WORD[@devdesc] <> constant(DESC_DEVICE | DEVDESC_LEN)
    return E_DESC_PARSE

  return 0

PUB GetDeviceDescriptor : ptr
  '' Get a pointer to the enumerated device's Device Descriptor
  return @devdesc

PUB GetVendorID : devID
  '' Get the enumerated device's 16-bit Vendor ID
  return WORD[@devdesc + DEVDESC_idVendor]
  
PUB GetProductID : devID
  '' Get the enumerated device's 16-bit Product ID
  return WORD[@devdesc + DEVDESC_idProduct]


DAT
''
''==============================================================================
'' Device Setup
''==============================================================================

PUB DeviceReset
  '' Asynchronously send a USB bus reset signal.

  Command(OP_RESET) 

PUB DeviceAddress : error

  '' Send a SET_ADDRESS(1) to device 0.
  ''
  '' This should be sent after DeviceReset to transition the
  '' device from the Default state to the Addressed state. All
  '' other transfers here assume the device address is 1.

  Setup_Token := Setup_IN_ACK_Token := constant(OP_TX_DATA_16 | TOKEN_DEV0_EP0)

  error := Control(REQ_SET_ADDRESS, 1, 0)

  Setup_Token := Setup_IN_ACK_Token := constant(OP_TX_DATA_16 | TOKEN_DEV1_EP0)

DAT

''==============================================================================
'' Control Transfers
''==============================================================================

PUB Control(req, value, index) : error

  '' Issue a no-data control transfer to an addressed device.

  Setup_Request := req
  Setup_Value := value
  Setup_Index := index
  Setup_Length~
  
  if SCLRetry(@Setup_Commands, SYNC_PID_ACK)
    return E_TRANSFER

  CommandList(@Setup_IN_ACK_Commands)
  return 0

  
PUB ControlRead(req, value, index, bufferPtr, length) : error | toggle

  '' Issue a control IN transfer to an addressed device.
  ''
  '' Returns the number of bytes read. Zero is a successful zero-length
  '' transfer, negative numbers indicate errors.

  Setup_Request := req
  Setup_Value := value
  Setup_Index := index
  Setup_Length := length

  if SCLRetry(@Setup_Commands, SYNC_PID_ACK)
    return E_TRANSFER

  toggle := PID_DATA1
  error := DataIN(TOKEN_DEV1_EP0, bufferPtr, length, BYTE[@devdesc + DEVDESC_bMaxPacketSize0], @toggle)
  
  if SyncCommand(OP_RX_CRC16)
    return E_CRC

DAT

'==============================================================================
' Low-level Transfer Utilities
'==============================================================================

PRI DataIN(token, buffer, length, maxPacketLen, togglePtr) : actual | packet

  '' Issue IN tokens and read the resulting data packets until
  '' a packet smaller than maxPacketLen arrives. On success,
  '' returns the actual number of bytes read. On failure, returns
  '' a negative error code.
  ''
  '' 'togglePtr' is a pointer to a byte with either PID_DATA0 or
  '' PID_DATA1, depending on which DATA PID we expect next. Every
  '' time we receive a packet, we toggle this byte from DATA0 to
  '' DATA1 or vice versa.

  actual~
  IN_DATA_Token := OP_TX_DATA_16 | token
  
  repeat
    if SCLRetry(@IN_DATA_Commands, SYNC_FIELD | (BYTE[togglePtr] << 8))
      return E_TRANSFER

    packet := SyncCommand(OP_RX_DATA_PTR | (length << 16) | buffer)
    if packet < 0
      return packet

    actual += packet
    buffer += packet
    length -= packet
    BYTE[togglePtr] ^= constant(PID_DATA0 ^ PID_DATA1)
      
    if packet < maxPacketLen
      ' Short packet or zero-length packet
      return actual 
    

DAT

'==============================================================================
' Low-level Command Interface
'==============================================================================

PRI Command(c)
  '' Asynchronously execute a low-level driver cog command
  
  repeat while params[PARAM_COMMAND]
  params[PARAM_COMMAND] := c

PRI SyncCommand(c) : r
  '' Synchronously execute a low-level driver cog command, and return the result

  Command(c)
  Sync
  r := params[PARAM_RESULT]

PRI CommandList(ptr) | c
  '' Execute several commands from a list in hub memory.
  '' The last command has the OP_EOL bit set.

  repeat
    c := LONG[ptr]
    Command(c & $7FFF_FFFF)
    ptr += 4
    if c & OP_EOL
      return

PRI SyncCommandList(ptr) : r
  '' Execute a command list synchronously, and return the result of the
  '' last command in the list which wrote to the result buffer.

  CommandList(ptr)
  Sync
  r := params[PARAM_RESULT]

PRI SCLRetry(ptr, expected) : error

  '' Run a command list synchronously, retrying it if it returns
  '' a value other than 'expected'. If it doesn't work even after
  '' the maximum number of retries, returns nonzero.

  repeat MAX_CL_RETRIES
    if SyncCommandList(ptr) == expected
      return 0

    ' Wait a frame between retries
    Command(OP_SOF_WAIT)

  return E_TRANSFER


DAT

'==============================================================================
' Command List Templates
'==============================================================================

        ' Shared buffer for SETUP packets on any control transfer.

Setup_Request           word  0
Setup_Value             word  0
Setup_Index             word  0
Setup_Length            word  0

        ' Setup Data out
        '
        '   Host:  SETUP DATA0 [data]         
        ' Device:                     [ACK]
        '
        ' Return value: ACK pid
        
Setup_Commands          long  OP_TX_BEGIN | PID_SETUP
Setup_Token             long  OP_TX_DATA_16 | TOKEN_DEV1_EP0
                        long  OP_TX_END        
        
                        long  OP_TX_BEGIN | PID_DATA0
Setup_DataPtr           long  OP_TX_DATA_PTR | (8 << 16)
                        long  OP_TX_CRC16
                        long  OP_TX_END

                        long  OP_TXRX
                        long  OP_RX_PID | OP_EOL

        ' Acknowledge an OUT or no-data control transfer, with an IN / DATA1 ACK handshake
        '
        '   Host:  IN         ACK          
        ' Device:     (DATA1)
        '
        ' No return value.

Setup_IN_ACK_Commands   long  OP_TX_BEGIN | PID_IN      ' Start IN / DATA1 / ACK handshake
Setup_IN_ACK_Token      long  OP_TX_DATA_16 | TOKEN_DEV1_EP0
                        long  OP_TX_END

                        long  OP_TX_IDLE | 40           ' Ignore DATA1. Not enough time to
                                                        ' receive it before the device expects
                                                        ' us to ACK!

                        long  OP_TX_BEGIN | PID_ACK
                        long  OP_TX_END                 ' Send ACK      
                        long  OP_TX_FLUSH | OP_EOL      ' Done

        ' IN data phase. Saves the data.
        '
        ' We do send an ACK just for completeness, but it's way too late and the
        ' device has probably already given up on waiting for it.
        '
        '   Host:  IN                 ACK  
        ' Device:     [DATA1] data...
        '
        ' Return value: DATA1 pid. RX buffer is ready to decode payload. 

IN_DATA_Commands        long  OP_TX_BEGIN | PID_IN
IN_DATA_Token           long  0
                        long  OP_TX_END

                        long  OP_TXRX

                        long  OP_TX_BEGIN | PID_ACK
                        long  OP_TX_END                 ' Send ACK      
                        long  OP_TX_FLUSH

                        long  OP_RX_PID | OP_EOL      ' Done
  
DAT

'==============================================================================
' Controller / Transmitter Cog
'==============================================================================

' This is the "main" cog in the host controller. It processes commands that arrive
' from Spin code. These commands can build encoded USB packets in a local buffer,
' and transmit them. Multiple packets can be buffered back-to-back, to reduce the
' gap between packets to an acceptable level.
'
' This cog also handles triggering our two receiver cogs. Two receiver cogs are
' interleaved, so we can receive packets larger than what will fit in a single
' cog's unrolled loop.
'
' The receiver cogs are also responsible for managing the bus ownership, and the
' handoff between a driven idle state and an undriven idle. We calculate timestamps
' at which the receiver cogs will perform this handoff.

              org
controller_cog

              '======================================================
              ' Cog Initialization
              '======================================================

              ' Initialize the PLL and video generator for 12 MB/s output.
              ' This sets up CTRA as a divide-by-8, with no PLL multiplication.
              ' Use 2bpp "VGA" mode, so we can insert SE0 states easily. Every
              ' two bits we send to waitvid will be two literal bits on D- and D+.
              
              ' To start with, we leave the pin mask in vcfg set to all zeroes.
              ' At the moment we're actually ready to transmit, we set the mask.

              mov       ctra, ctra_value
              mov       frqa, frqa_value
              mov       vcfg, vcfg_value
              mov       vscl, vscl_value

              mov       result_ptr, par
              add       result_ptr, #(PARAM_RESULT * 4)

              mov       sof_deadline, cnt

              call      #enc_reset


              '======================================================
              ' Command Processing
              '======================================================

              ' Wait until there's a command available or it's time to send a SOF.
              ' SOF is more important than a command, but we have no way of ensuring
              ' that a SOF won't need to occur during a command- so the SOF might be
              ' late.

cmdret        wrlong    c_zero, par
command_loop
              cmp       tx_count, #0 wz         ' Skip SOF if the buffer is in use
              mov       t1, cnt                 ' cnt - sof_deadline, store sign bit
              sub       t1, sof_deadline
              rcl       t1, #1 wc               ' C = deadline is in the future
  if_z_and_nc jmp       #tx_sof                 ' Send the SOF.

              rdlong    l_cmd, par wz           ' Look for an incoming command
        if_z  jmp       #command_loop

              mov       t1, l_cmd
              shr       t1, #24
              add       t1, #:cmdjmp
              movs      :cmdjmp, t1
              nop                               ' Instruction fetch delay

              ' Command jump table

:cmdjmp       jmp       #0
              jmp       #cmd_reset
              jmp       #cmd_tx_begin
              jmp       #cmd_tx_end
              jmp       #cmd_tx_flush
              jmp       #cmd_tx_data_16
              jmp       #cmd_tx_data_ptr
              jmp       #cmd_tx_crc16
              jmp       #cmd_tx_idle
              jmp       #cmd_rx_pid
              jmp       #cmd_rx_data_ptr
              jmp       #cmd_rx_crc16
              jmp       #cmd_sof_wait

              '======================================================
              ' SOF Packets
              '======================================================

              ' If we're due for a SOF and we're between packets,
              ' this routine is called to transmit the SOF packet.
              '
              ' We're allowed to use the transmit buffer, but we must
              ' not return via 'cmdret', since we don't want to clear
              ' our command buffer- if another cog wrote a command
              ' while we're processing the SOF, we would miss it.
              ' So we need to use the lower-level encoder routines
              ' instead of calling other command implementations.
 
tx_sof
              xor       cmd_sof_wait, c_condition     ' Let an SOF wait through.
                                                      ' (Swap from if_always to if_never)
                                                        
              call      #encode_sync                  ' SYNC field

              mov       codec_buf, sof_frame          ' PID and Token
              mov       codec_cnt, #24
              call      #encode

              call      #encode_eop                   ' End of packet and inter-packet delay
                                                
              mov       l_cmd, #0                     ' TX only, no receive
              call      #txrx

              add       sof_deadline, sof_period
              
              jmp       #command_loop 
              
              '======================================================
              ' OP_TX_BEGIN
              '======================================================

              ' When we begin a packet, we'll always end up generating
              ' 16 bits (8 sync, 8 pid) which will fill up the first long
              ' of the transmit buffer. So it's legal to use tx_count!=0
              ' to detect whether we're using the transmit buffer.
              
cmd_tx_begin
              call      #encode_sync

              ' Now NRZI-encode the PID field

              mov       codec_buf, l_cmd
              mov       codec_cnt, #8
              call      #encode

              ' Reset the CRC-16, it should cover only data from after the PID.

              mov       enc_crc16, crc16_mask

              jmp       #cmdret

              '======================================================
              ' OP_TX_END
              '======================================================

cmd_tx_end
              call      #encode_eop

              jmp       #cmdret

              '======================================================
              ' OP_TX_DATA_16
              '======================================================

cmd_tx_data_16
              mov       codec_buf, l_cmd
              mov       codec_cnt, #16
              call      #encode

              jmp       #cmdret

              '======================================================
              ' OP_TX_DATA_PTR
              '======================================================

              ' Byte count in l_cmd[23:16], hub pointer in [15:0].
              '
              ' This would be faster if we processed in 32-bit
              ' chunks when possible (at least 4 bytes left, pointer is
              ' long-aligned) but right now we're optimizing for simplicity. 
              
cmd_tx_data_ptr
              test      l_cmd, c_00FF0000 wz    ' At least 1 byte to send?
        if_z  jmp       #cmdret

              rdbyte    codec_buf, l_cmd
              mov       codec_cnt, #8
              add       l_cmd, c_FFFF0001       ' Count - 1, Pointer + 1
              call      #encode

              jmp       #cmd_tx_data_ptr

              '======================================================
              ' OP_TX_CRC16
              '======================================================

cmd_tx_crc16
              mov       codec_buf, enc_crc16
              xor       codec_buf, crc16_mask
              mov       codec_cnt, #16
              call      #encode

              jmp       #cmdret

              '======================================================
              ' OP_TX_IDLE
              '======================================================

              ' Send one or more bit periods worth of idle bus state.
              ' This can be used to introduce delays, or to skip responses
              ' that we don't have time to fully process.

cmd_tx_idle
              and       l_cmd, #$1FF
:loop         call      #encode_idle
              djnz      l_cmd, #:loop

              jmp       #cmdret

              '======================================================
              ' OP_TX_FLUSH and OP_TXRX
              '======================================================

cmd_tx_flush
              call      #txrx

              jmp       #cmdret

              '======================================================
              ' OP_RESET
              '======================================================
              
cmd_reset

              mov       outa, #0                ' Start driving SE0
              mov       dira, #BUS_MASK

              mov       t1, cnt
              add       t1, reset_period
              waitcnt   t1, #0
                                                    
              mov       dira, #0                ' Stop driving
              mov       sof_deadline, cnt       ' Ignore SOFs that should have occurred
              
              jmp       #cmdret

              '======================================================
              ' OP_RX_PID
              '======================================================

              ' Receive a 16-bit word, and reset the CRC-16.
              ' For use in receiving and validating a packet's SYNC/PID header.

cmd_rx_pid
              mov       codec_cnt, #16
              call      #decode
              shr       codec_buf, #16
              wrlong    codec_buf, result_ptr

              mov       dec_crc16, crc16_mask   ' Reset the CRC-16

              jmp       #cmdret
              
              '======================================================
              ' OP_RX_DATA_PTR
              '======================================================

              ' Max byte count in l_cmd[23:16], hub pointer in [15:0].
              ' Returns the actual number of bytes received.
              '
              ' This would be faster if we processed in 32-bit
              ' chunks when possible (at least 4 bytes left, pointer is
              ' long-aligned) but right now we're optimizing for simplicity. 
              '
              ' This determines actual length by looking for a pseudo-EOP.
              ' After every byte, we scan ahead in the raw buffer and look
              ' for when the bus goes idle for at least 7 bit periods.
              ' This can't happen during a packet due to bit stuffing. Once
              ' we find this, we can search backward to the nearest byte
              ' boundary, then back two bytes (for the CRC-16).
              '
              ' By keeping a look-ahead buffer in the decoder, this test
              ' can be made very efficient. See dec_nrzi and eop_mask below.
              
cmd_rx_data_ptr
              mov       t1, #0                  ' Count received bytes

:loop8        test      l_cmd, c_00FF0000 wz    ' At least 1 byte to decode?
        if_z  jmp       #:done

              mov       codec_cnt, #8
              call      #decode
              shr       codec_buf, #24          ' Right-justify result
              wrbyte    codec_buf, l_cmd
              add       l_cmd, c_FFFF0001       ' Count - 1, Pointer + 1
              add       t1, #1                  ' Result += 1

              test      dec_nrzi, eop_mask wz   ' Test for pseudo-EOP
        if_nz jmp       #:loop8                 ' Stop looping if we find it.

:done
              wrlong    t1, result_ptr
              jmp       #cmdret
    
              '======================================================
              ' OP_RX_CRC16
              '======================================================
             
cmd_rx_crc16
              xor       dec_crc16, crc16_mask   ' Save CRC of payload
              mov       t1, dec_crc16

              mov       codec_cnt, #16
              call      #decode

              shr       codec_buf, #16          ' Justify received CRC
              xor       t1, codec_buf           ' Compare
              wrlong    t1, result_ptr          ' and return
              jmp       #cmdret
              
              '======================================================
              ' OP_SOF_WAIT
              '======================================================

              ' Normally this jumps back to the command loop without
              ' completing the command. In tx_sof, this code is modified
              ' to return exactly once.
              '
              ' (The modification works by patching the condition code on the
              ' first instruction in this routine.)

cmd_sof_wait  jmp       #command_loop
              xor       cmd_sof_wait, c_condition       ' Swap from if_never to if_always
              jmp       #cmdret

        
              '======================================================
              ' Transmit / Receive Front-end
              '======================================================

txrx
              ' Save the raw transmit length, not including padding,
              ' then pad our buffer to a multiple of 16 (one video word)

              mov       tx_count_raw, tx_count
:pad          test      tx_count, #%1111 wz
        if_z  jmp       #:pad_done
              call      #encode_idle
              jmp       #:pad
:pad_done

              ' Reset the receiver state (regardless of whether we're using it.)

              mov       t1, par
              add       t1, #(PARAM_RX_LONGS * 4)
              wrlong    c_zero, t1

              ' Save bit 1 of the command. This distinguishes between
              ' OP_TX_FLUSH and OP_TXRX. If bit 1 is set, we're receiving too.

              test      l_cmd, #1 wz

              ' Transmitter startup: We need to synchronize with the video PLL,
              ' and transition from an undriven idle state to a driven idle state.
              ' To do this, we need to fill up the video generator register with
              ' idle states before setting DIRA and VCFG.
              '
              ' Since we own the bus at this point, we don't have to hurry.

              waitvid   v_palette, v_idle
              waitvid   v_palette, v_idle 
              movs      vcfg, #BUS_MASK
              mov       dira, #BUS_MASK

              ' Give the receiver cogs a synchronized timestamp to wake up at.
              ' We use the same timestamp below to figure out when we should
              ' stop driving the bus.
            
              shl       tx_count_raw, #3                ' 8 cycles per bit
              add       tx_count_raw, #$60              ' Constant offset
              add       tx_count_raw, cnt

        if_nz mov       t1, par
        if_nz add       t1, #(PARAM_RX1_TIME * 4)
        if_nz wrlong    tx_count_raw, t1                             
        if_nz add       t1, #((PARAM_RX2_TIME - PARAM_RX1_TIME) * 4)
        if_nz wrlong    tx_count_raw, t1
    
              ' Transmit our NRZI-encoded packet

              movs      :tx_loop, #tx_buffer
              shr       tx_count, #4                    ' Bits -> words
:tx_loop      waitvid   v_palette, 0
              add       :tx_loop, #1
              djnz      tx_count, #:tx_loop

              ' Stop driving the bus at the same time our RX cogs wake up.
              ' This should be as soon as possible after the idle state has been
              ' driven for one bit period. (See the constant time offset above)

              waitcnt   tx_count_raw, #0
              mov       dira, #0
              movs      vcfg, #0

              '======================================
              ' Receiver Controller
              '======================================

        if_z  jmp       #:rx_done                       ' Receiver disabled

              ' If we're receiving, now we need to babysit the receiver cogs.
              ' If they don't receive at least one raw long by the time
              ' the RX_START_TIMEOUT passes, we'll artificially trigger them
              ' (and presumably they'll receive silence for the entire duration
              ' of the receive burst.)

              mov       rx_deadline, #RX_START_TIMEOUT  ' Timeout is in bits
              shl       rx_deadline, #3                 ' 8 cycles per bit
              add       rx_deadline, tx_count_raw       ' Start at the end of our last packet

              mov       t3, par
              add       t3, #(PARAM_RX_LONGS * 4)

:rx_start_wait
              rdlong    t1, t3 wz                       ' RX_LONGS nonzero?
        if_nz jmp       #:rx_start_success

              mov       t1, rx_deadline                 ' Past deadline yet?
              sub       t1, cnt                         ' t1 = rx_deadline - cnt
              rcl       t1, #1 wc                       ' Sign bit
        if_nc jmp       #:rx_start_wait                 ' No, keep looping

              ' The RX_START_TIMEOUT expired, and we're still waiting for the
              ' packet to start. To keep our RX cogs from getting permanently
              ' stuck, we'll manually wake them up by driving a SE1 onto the bus
              ' for a few cycles.

              mov       outa, #BUS_MASK
              mov       dira, #BUS_MASK
              jmp       #:rx_se1_1
:rx_se1_1     jmp       #:rx_se1_2
:rx_se1_2     mov       dira, #0
              mov       outa, #0

:rx_start_success
        
              ' Wait for the receiver to signal that it's done.
              ' It can't detect a real EOP, but it detects a pseudo-EOP
              ' after there is a full 16-bit word of all zeroes.
              
:rx_buffer_wait
              rdlong    t1, t3
              rcl       t1, #1 nr,wc
        if_nc jmp       #:rx_buffer_wait

              ' Initialize the decoder, point it at the top of the RX buffer.
              ' The decoder will load the first long on our first invocation.
              
              mov       t1, par
              add       t1, #(PARAM_RX_BUFFER * 4)
              rdlong    dec_rxbuffer, t1
              
              mov       dec_nrzi_cnt, #1        ' Mod-32 counter
              mov       dec_nrzi_st, #0
              mov       dec_1cnt, #0
              rdlong    dec_nrzi, dec_rxbuffer
              add       dec_rxbuffer, #4
              
:rx_done
              '======================================
              ' End of Receiver Controller
              '======================================

              ' Initialize the encoder too

              call      #enc_reset

txrx_ret      ret


              '======================================================
              ' NRZI Encoding and Bit Stuffing
              '======================================================

              ' Encode (NRZI, bit stuffing, and store) up to 32 bits.
              '
              ' The data to be encoded comes from codec_buf, and codec_cnt
              ' specifies how many bits we shift out from the LSB side.
              '
              ' For both space and time efficiency, this routine is also
              ' responsible for updating a running CRC-16. This is only
              ' used for data packets- at all other times it's quietly
              ' ignored.
encode
              rcr       codec_buf, #1 wc

              ' Update the CRC16.
              '
              ' This is equivalent to:
              '
              '   condition = (input_bit ^ (enc_crc16 & 1))
              '   enc_crc16 >>= 1
              '   if condition:
              '     enc_crc16 ^= crc16_poly

              test      enc_crc16, #1 wz
              shr       enc_crc16, #1
    if_z_eq_c xor       enc_crc16, crc16_poly        
      
              ' NRZI-encode one bit.
              '
              ' For every incoming bit, we generate two outgoing bits;
              ' one for D- and one for D+. We can do all of this in three
              ' instructions with SAR and XOR. For example:
              '
              '   Original value of tx_reg:        10 10 10 10
              '   After SAR by 2 bits:          11 10 10 10 10
              '     To invert D-/D+, flip MSB:  01 10 10 10 10
              '    (or)
              '     Avoid inverting by flipping
              '     the next highest bit:       10 10 10 10 10
              '
              ' These two operations correspond
              ' to NRZI encoding 0 and 1, respectively.
  
              sar       enc_nrzi, #2
        if_nc xor       enc_nrzi, c_80000000     ' NRZI 0
        if_c  xor       enc_nrzi, c_40000000     ' NRZI 1


              ' Bit stuffing: After every six consecutive 1 bits, insert a 0.
              ' If we detect that bit stuffing is necessary, we do the branch
              ' after storing the original bit below, then we come back here to
              ' store the stuffed bit.

        if_nc mov       enc_1cnt, #6 wz
        if_c  sub       enc_1cnt, #1 wz
enc_bitstuff_ret

              ' Every time we fill up enc_nrzi, append it to tx_buffer.
              ' We use another shift register as a modulo-32 counter.
     
              ror       enc_nrzi_cnt, #1 wc
              add       tx_count, #1
encode_ptr
        if_c  mov       0, enc_nrzi
        if_c  add       encode_ptr, c_dest_1

              ' Insert the stuffed bit if necessary
              
        if_z  jmp       #enc_bitstuff

              djnz      codec_cnt, #encode
encode_ret    ret

              ' Handle the relatively uncommon case of inserting a zero bit,
              ' for bit stuffing. This duplicates some of the code from above
              ' for NRZI-encoding the extra bit. This bit is *not* included
              ' in the CRC16.

enc_bitstuff  sar       enc_nrzi, #2
              xor       enc_nrzi, c_80000000
              mov       enc_1cnt, #6 wz
              jmp       #enc_bitstuff_ret       ' Count and store this bit            

                          
              '======================================================
              ' Encoder / Transmitter Reset
              '======================================================
        
              ' (Re)initialize the encoder and transmitter registers.
              ' The transmit buffer will now be empty.

enc_reset     mov       enc_nrzi, v_idle
              mov       enc_nrzi_cnt, enc_ncnt_init
              mov       enc_1cnt, #0
              mov       tx_count, #0
              movd      encode_ptr, #tx_buffer
enc_reset_ret ret


              '======================================================
              ' Low-level Encoder
              '======================================================

              ' The main 'encode' function above is the normal case.
              ' But we need to be able to encode special bus states too,
              ' so these functions are slower but more flexible encoding
              ' entry points.
              '
              
              ' Check whether we need to store the contents of enc_nrzi
              ' after encoding another bit-period worth of data from it.
              ' This is a modified version of the tail end of 'encode' above.
              
encode_store
              mov       :ptr, encode_ptr
              ror       enc_nrzi_cnt, #1 wc
              add       tx_count, #1
:ptr    if_c  mov       0, enc_nrzi
        if_c  add       encode_ptr, c_dest_1
encode_store_ret ret

              ' Raw NRZI zeroes and ones, with no bit stuffing

encode_raw0
              sar       enc_nrzi, #2
              xor       enc_nrzi, c_80000000
              mov       enc_1cnt, #0
              call      #encode_store
encode_raw0_ret ret

encode_raw1
              sar       enc_nrzi, #2
              xor       enc_nrzi, c_40000000
              call      #encode_store
encode_raw1_ret ret

              ' One cycle of single-ended zero.

encode_se0
              shr       enc_nrzi, #2
              call      #encode_store
encode_se0_ret ret

              ' One cycle of idle bus (J state).
              
encode_idle
              shr       enc_nrzi, #2
              xor       enc_nrzi, c_80000000
              call      #encode_store
encode_idle_ret ret

              ' Append a raw SYNC field
encode_sync
              mov       t1, #7
:loop         call      #encode_raw0
              djnz      t1, #:loop
              call      #encode_raw1
encode_sync_ret ret

              ' Append a raw EOP
encode_eop    
              call      #encode_se0
              call      #encode_se0
              mov       t1, #4
:loop         call      #encode_idle
              djnz      t1, #:loop
encode_eop_ret ret


              '======================================================
              ' NRZI Decoder / Bit un-stuffer
              '======================================================

              ' Decode (retrieve, NRZI, bit un-stuff) up to 32 bits.
              '
              ' The data to decode comes from the RX buffer in hub memory.
              ' We decode 'codec_cnt' bits into the *MSBs* of 'codec_buf'.
              '
              ' As with encoding, we also run a CRC-16 here, since it's
              ' a convenient place to do so.

decode
              ' Extract the next bit from the receive buffer.
              '
              ' Our buffering scheme is a bit strange, since we need to have
              ' a 32-bit look ahead buffer at all times, for pseudo-EOP detection.
              '
              ' So, we treat 'dec_nrzi' as a 32-bit shift register which always
              ' contains valid bytes from the RX buffer. It is pre-loaded with the
              ' first word of the receive buffer.
              '
              ' Once every 32 decoded bits (starting with the first bit) we load a
              ' new long from dec_rxbuffer into dec_rxlatch. When we shift bits out
              ' of dec_nrzi, bits from dec_rxlatch replace them. 
                                                        
              ror       dec_nrzi_cnt, #1 wc
        if_c  rdlong    dec_rxlatch, dec_rxbuffer
        if_c  add       dec_rxbuffer, #4
              rcr       dec_rxlatch, #1 wc
              rcr       dec_nrzi, #1 wc

              ' Skip stuffed bits. (We don't bother validating them...)

              cmp       dec_1cnt, #6 wz
        if_z  mov       dec_1cnt, #0
        if_z  jmp       #decode
        
              ' We use a small auxiliary shift register to XOR the current bit
              ' with the last one, even across word boundaries where we might have
              ' to reload the main shift register. This auxiliary shift register
              ' ends up tracking the state ("what was the last bit?") for NRZI decoding.
              
              rcl       dec_nrzi_st, #1
              test      dec_nrzi_st, #%10 wz    ' Previous bit
              shr       codec_buf, #1
    if_c_ne_z or        codec_buf, c_80000000   ' codec_buf <= !(prev XOR current)     
    if_c_ne_z add       dec_1cnt, #1            ' Count consecutive '1' bits       
    if_c_eq_z mov       dec_1cnt, #0
    
              ' Update our CRC-16. This performs the same function as the logic
              ' in the encoder above, but it's optimized for our flag usage.

              test      codec_buf, c_80000000 wz  ' Move decoded bit to Z
              shr       dec_crc16, #1 wc          ' Shift out CRC LSB into C
    if_z_eq_c xor       dec_crc16, crc16_poly        
   
              djnz      codec_cnt, #decode
decode_ret    ret
             

              '======================================================
              ' Data
              '======================================================

c_zero        long      0
c_40000000    long      $40000000
c_80000000    long      $80000000
c_00FF0000    long      $00FF0000
c_FFFF0001    long      $FFFF0001
c_dest_1      long      1 << 9
c_condition   long      %000000_0000_1111_000000000_000000000

reset_period  long      96_000_000 / 100

frqa_value    long      $10000000                       ' 1/8
ctra_value    long      (%00001 << 26) | (%111 << 23)   ' PLL 1:1
vcfg_value    long      (%011 << 28)                    ' Unpack 2-bit -> 8-bit     
vscl_value    long      (8 << 12) | (8 * 16)
v_palette     long      $03_02_01_00
v_idle        long      %%2222_2222_2222_2222

enc_ncnt_init long      $8000_8000                      ' Shift reg as mod-16 counter

crc16_poly    long      $a001                           ' USB CRC-16 polynomial
crc16_mask    long      $ffff                           ' Init/final mask

' Mask for detecting pseudo-EOPs at a byte boundary. We have a 32-bit lookahead
' buffer for detecting them in the raw NRZI stream. We want to detect them just
' prior to the CRC-16. Due to bit stuffing, the CRC can take anywhere between
' 16 and 20 bits. The EOP itself is detected as at least 8 consecutive zeroes. 
'
' Every '1' bit in this mask is a position that must be zero for the pseudo-EOP
' test to pass, signalling that the packet is about to end.

eop_mask      long      %00011111_11100000_00000000_00000000

' We try to send SOFs every millisecond, but other traffic can preempt them.
' Since we're not even trying to support very timing-sensitive devices, we
' also send a fake (non-incrementing) frame number.

sof_frame     long      %00010_00000000000_1010_0101    ' SOF PID, Frame 0, valid CRC6
sof_period    long      96_000                          ' 96 MHz, 1ms          

result_ptr    res       1
l_cmd         res       1
t1            res       1
t3            res       1

sof_deadline  res       1

' Shared encode/decode state
codec_buf     res       1
codec_cnt     res       1

' Encoder only
enc_nrzi      res       1                               ' Encoded NRZI shift register
enc_1cnt      res       1
enc_nrzi_cnt  res       1                               ' Cyclic bit counter
enc_crc16     res       1

' Decoder only
dec_nrzi      res       1                               ' Encoded NRZI shift register
dec_nrzi_cnt  res       1                               ' Cyclic bit counter
dec_nrzi_st   res       1                               ' State of NRZI decoder
dec_1cnt      res       1
dec_rxbuffer  res       1
dec_rxlatch   res       1
dec_crc16     res       1

rx_deadline   res       1

tx_count      res       1                               ' Number of bit periods
tx_count_raw  res       1                               ' Not padded
tx_buffer     res       TX_BUFFER_WORDS

              fit

DAT

'==============================================================================
' Receiver Cog 1
'==============================================================================

' This receiver cog stores the first 16-bit half of every 32-bit word.

              org
rx_cog_1
              mov       rx1_time_p, par
              add       rx1_time_p, #(PARAM_RX1_TIME * 4)

              mov       rx1_longs_p, par
              add       rx1_longs_p, #(PARAM_RX_LONGS * 4)

              ' DEBUG: Monitoring RX1 phase
              'mov       dira, #4
              
              mov       t2, par
              add       t2, #(PARAM_RX_BUFFER * 4)
              rdlong    rx1_buffer, t2

              mov       rx1_iters, #RX_BUFFER_WORDS
              
:wait         rdlong    t2, rx1_time_p wz       ' Read trigger timestamp
        if_z  jmp       #:wait
              wrlong    rx1_zero, rx1_time_p    ' One-shot, zero it.
                                                  
              waitcnt   t2, #0                  ' Wait for trigger time          

              ' Now synchronize to the beginning of the next packet.
              ' We sample only D- in the receiver. If we time out,
              ' the controller cog will artificially send a SE1
              ' to bring us out of sleep. (We'd rather not send a SE0,
              ' since we may inadvertently reset the device.)

              waitpne   rx1_zero, rx1_pin
              
:sample_loop

{{
              ' DEBUG: Monitoring RX1 phase
              xor       outa, #4                '0
              nop
              xor       outa, #4                '1
              nop
              xor       outa, #4                '2
              nop
              xor       outa, #4                '3
              nop
              xor       outa, #4                '4
              nop
              xor       outa, #4                '5
              nop
              xor       outa, #4                '6
              nop
              xor       outa, #4                '7
              nop
              xor       outa, #4                '8
              nop
              xor       outa, #4                '9
              nop
              xor       outa, #4                '10
              nop
              xor       outa, #4                '11
              nop
              xor       outa, #4                '12
              nop
              xor       outa, #4                '13
              nop
              xor       outa, #4                '14
              nop
              xor       outa, #4                '15
              nop
}}
  
              test      rx1_pin, ina wc         '  0
              rcr       t2, #1
              test      rx1_pin, ina wc         '  1
              rcr       t2, #1
              test      rx1_pin, ina wc         '  2
              rcr       t2, #1
              test      rx1_pin, ina wc         '  3
              rcr       t2, #1
              test      rx1_pin, ina wc         '  4
              rcr       t2, #1
              test      rx1_pin, ina wc         '  5
              rcr       t2, #1
              test      rx1_pin, ina wc         '  6
              rcr       t2, #1
              test      rx1_pin, ina wc         '  7
              rcr       t2, #1
              test      rx1_pin, ina wc         '  8
              rcr       t2, #1
              test      rx1_pin, ina wc         '  9
              rcr       t2, #1
              test      rx1_pin, ina wc         ' 10
              rcr       t2, #1
              test      rx1_pin, ina wc         ' 11
              rcr       t2, #1
              test      rx1_pin, ina wc         ' 12
              rcr       t2, #1
              test      rx1_pin, ina wc         ' 13
              rcr       t2, #1
              test      rx1_pin, ina wc         ' 14
              rcr       t2, #1
              test      rx1_pin, ina wc         ' 15
              rcr       t2, #1

              ' At this exact moment, the RX2 cog takes over sampling
              ' for us. We can store these 16 bits to hub memory, but we
              ' need to use a waitcnt to resynchronize to USB after
              ' waiting on the hub.
              '
              ' This constant must be carefully adjusted so that the period
              ' of this loop is exactly 32*8 cycles. For reference, we can
              ' compare the RX1 and RX2 periods to make sure they're equal.

              mov       rx1_cnt, cnt
              add       rx1_cnt, #(16*8 - 9)

              shr       t2, #16
              wrword    t2, rx1_buffer
              add       rx1_buffer, #4

              ' Stop either when we fill up the buffer, or when RX2 signals
              ' that it's detected a pseudo-EOP and set the 'done' bit in RX_LONGS.
              
              sub       rx1_iters, #1 wz
              rdlong    t2, rx1_longs_p
              rcl       t2, #1 nr,wc
   if_z_or_c  jmp       #rx_cog_1

              waitcnt   rx1_cnt, #0       
              jmp       #:sample_loop

rx1_pin       long      |< DMINUS   
rx1_zero      long      0

rx1_longs_p   res       1
rx1_time_p    res       1
rx1_buffer    res       1                  
rx1_cnt       res       1
rx1_iters     res       1
t2            res       1

              fit

DAT

'==============================================================================
' Receiver Cog 2
'==============================================================================

' This receiver cog stores the second 16-bit half of every 32-bit word.
'
' Since this is the last receiver cog to run, we update the RX_LONGS counter
' and detect when we're "done". We don't actually detect EOP conditions (since
' we are only sampling D-) but we decide to finish receiving when an entire word
' (16 bit perods) of the bus looks idle. Due to bit stuffing, this condition never
' occurs while a packet is in progress.
'
' When we detect this pseudo-EOP condition, we'll set the "done" bit (bit 31) in
' RX_LONGS. This tells both the RX1 cog and the controller that we're finished.

              org
rx_cog_2
              mov       rx2_time_p, par
              add       rx2_time_p, #(PARAM_RX2_TIME * 4)

              ' DEBUG: Monitoring RX2 phase
              'mov       dira, #8

              mov       rx2_longs_p, par
              add       rx2_longs_p, #(PARAM_RX_LONGS * 4)
              mov       rx2_longs, #0
              
              mov       t4, par
              add       t4, #(PARAM_RX_BUFFER * 4)
              rdlong    rx2_buffer, t4

              mov       rx2_iters, #RX_BUFFER_WORDS
                            
:wait         rdlong    t4, rx2_time_p wz       ' Read trigger timestamp
        if_z  jmp       #:wait
              wrlong    rx2_zero, rx2_time_p    ' One-shot, zero it.
                                                  
              waitcnt   t4, #0                  ' Wait for trigger time
              waitpne   rx2_zero, rx2_pin       ' Sync to SOP

              ' Calculate a sample time that's 180 degrees out of phase
              ' from the RX1 cog's sampling burst. We want to sample every
              ' 8 clock cycles with no gaps.

              mov       rx2_cnt, cnt            
              add       rx2_cnt, #(16*8 - 4)

              jmp       #:first_sample
        
:sample_loop

              add       rx2_longs, #1

              ' Justify the received word. Also detect our pseudo-EOP condition,
              ' when we've been idle (0) for 16 bits.
              shr       t4, #16 wz
              
              add       rx2_buffer, #2
              wrword    t4, rx2_buffer
              
              ' Update RX_LONGS only after writing to the buffer
              ' We're done if rx2_iters runs out, or if we're idle

        if_nz sub       rx2_iters, #1 wz
        if_z  or        rx2_longs, rx2_done_bit
              wrlong    rx2_longs, rx2_longs_p

              add       rx2_buffer, #2

        if_z  jmp       #rx_cog_2

:first_sample waitcnt   rx2_cnt, #(32*8)

{{
              ' DEBUG: Monitoring RX2 phase
              xor       outa, #8                '0
              nop
              xor       outa, #8                '1
              nop
              xor       outa, #8                '2
              nop
              xor       outa, #8                '3
              nop
              xor       outa, #8                '4
              nop
              xor       outa, #8                '5
              nop
              xor       outa, #8                '6
              nop
              xor       outa, #8                '7
              nop
              xor       outa, #8                '8
              nop
              xor       outa, #8                '9
              nop
              xor       outa, #8                '10
              nop
              xor       outa, #8                '11
              nop
              xor       outa, #8                '12
              nop
              xor       outa, #8                '13
              nop
              xor       outa, #8                '14
              nop
              xor       outa, #8                '15
              nop
}}

              test      rx2_pin, ina wc         '  0
              rcr       t4, #1
              test      rx2_pin, ina wc         '  1
              rcr       t4, #1
              test      rx2_pin, ina wc         '  2
              rcr       t4, #1
              test      rx2_pin, ina wc         '  3
              rcr       t4, #1
              test      rx2_pin, ina wc         '  4
              rcr       t4, #1
              test      rx2_pin, ina wc         '  5
              rcr       t4, #1
              test      rx2_pin, ina wc         '  6
              rcr       t4, #1
              test      rx2_pin, ina wc         '  7
              rcr       t4, #1
              test      rx2_pin, ina wc         '  8
              rcr       t4, #1
              test      rx2_pin, ina wc         '  9
              rcr       t4, #1
              test      rx2_pin, ina wc         ' 10
              rcr       t4, #1
              test      rx2_pin, ina wc         ' 11
              rcr       t4, #1
              test      rx2_pin, ina wc         ' 12
              rcr       t4, #1
              test      rx2_pin, ina wc         ' 13
              rcr       t4, #1
              test      rx2_pin, ina wc         ' 14
              rcr       t4, #1
              test      rx2_pin, ina wc         ' 15
              rcr       t4, #1

              jmp       #:sample_loop

rx2_pin       long      |< DMINUS
rx2_zero      long      0
rx2_done_bit  long      $80000000

rx2_longs     res       1
rx2_longs_p   res       1
rx2_time_p    res       1
rx2_buffer    res       1
rx2_iters     res       1                  
rx2_cnt       res       1
t4            res       1

              fit
                        

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