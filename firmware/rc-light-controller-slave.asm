;******************************************************************************
;
;   rc-light-controller-slave.asm
;
;******************************************************************************
;
;   Author:         Werner Lane
;   E-mail:         laneboysrc@gmail.com
;
;******************************************************************************
    TITLE       RC Light Controller
    LIST        p=pic16f628a, r=dec
    RADIX       dec

    #include    <p16f628a.inc>

    __CONFIG _CP_OFF & _DATA_CP_OFF & _LVP_OFF & _BOREN_OFF & _MCLRE_OFF & _PWRTE_ON & _WDT_OFF & _INTRC_OSC_NOCLKOUT

;#define DEBUG

;******************************************************************************
;   Port usage:
;   ===========
;   RB6, RB1:   IN  Slave in  (UART RX, PGC double-usage)
;   RB7:        OUT Servo out (PGD double-usage) 
;   RA5:        IN  N/A       (Vpp double-usage)
;   RB2, RB5:   OUT Slave out (UART TX) 
;
;   RA3:        OUT CLK TLC5916
;   RA0, RA4:   OUT SDI TLC5916
;   RA2:        OUT LE TLC5916
;   RB0:        OUT OE TLC5916
;
;   RA4         IN  Tied to RA0 for routing convenience. Note that RA4 is open
;                   drain so not good to use as SDI!
;   RA7, RB3:   IN  Tied to +Vdd for routing convenience!
;   RB5         IN  RB5 is tied to RB2 for routing convenience!
;   RA6, RA0, RA1, RB4:     OUT NC pins, switch to output

#define PORT_SERVO      PORTB, 7

; TLC5916 LED driver serial communication ports
#define PORT_CLK        PORTA, 3
#define PORT_SDI        PORTA, 0
#define PORT_LE         PORTA, 2
#define PORT_OE         PORTB, 0


#define SLAVE_MAGIC_BYTE    0x87

;******************************************************************************
;* VARIABLE DEFINITIONS
;******************************************************************************
    
    CBLOCK  0x70    ; 16 Bytes that are accessible via any bank!

    savew	        ; Interrupt save registers
    savestatus	
    savepclath
    savefsr

	ENDC

    CBLOCK  0x20    ; Bank 0

    servo_sync_flag
    pwm_counter
    int_temp
    int_d0

    uart_light_mode
    uart_light_mode_half
    uart_servo

    light_mode
    light_mode_half

	xl
	xh
	yl
	yh
    temp
    d0

	ENDC



;******************************************************************************
; Reset vector 
;******************************************************************************
    ORG     0x000           
    goto    Init


;******************************************************************************
; Interrupt vector
;******************************************************************************
    ORG     0x004           
Interrupt_handler
	movwf	savew           ; Save W register
	movf	STATUS, w       ; W now has copy of status
	clrf	STATUS          ; Ensure we are in bank 0 now!
	movwf	savestatus	    ; Save status
;	movf	PCLATH, w       ; Save pclath
;	movwf	savepclath	
;	clrf	PCLATH		    ; Explicitly select Page 0
;	movf	FSR, w
;	movwf	savefsr		    ; Save FSR (just in case)

;	btfss	INTCON, T0IF
;	goto	int_clean   

    movf    light_mode, w
    decfsz  pwm_counter, f
    goto    int_no_reload

    movlw   5
    movwf   pwm_counter
    movf    light_mode_half, w

int_no_reload
    movwf   int_temp
    movlw   8
    movwf   int_d0

int_tlc5916_send_loop
    rlf     int_temp, f
    skpc    
    bcf     PORT_SDI
    skpnc    
    bsf     PORT_SDI
    bsf     PORT_CLK
    bcf     PORT_CLK
    decfsz  int_d0, f
    goto    int_tlc5916_send_loop

    bsf     PORT_LE
    bcf     PORT_LE
    bcf     PORT_OE

int_lights_done
    clrf    servo_sync_flag

int_t0if_done
	bcf	    INTCON, T0IF    ; Clear interrupt flag that caused interrupt

int_clean
;		movf	savefsr, w
;		movwf	FSR		    ; Restore FSR
;		movf	savepclath, w
;		movwf	PCLATH      ; Restore PCLATH (Page=original)
		movf	savestatus, w
		movwf	STATUS      ; Restore status! (bank=original)
		swapf	savew, f    ; Restore W from *original* bank! 
		swapf	savew, w    ; Swapf does not affect any flags!
		retfie              


;******************************************************************************
; Initialization
;******************************************************************************
Init
    BANKSEL CMCON
    movlw   0x07
    movwf   CMCON       ; Disable the comparators

    clrf    PORTA       ; Set all (output) ports to GND
    clrf    PORTB


    BANKSEL OPTION_REG
    movlw   b'10000011'
            ; |||||||+ PS0  (Set pre-scaler to 1:8)
            ; ||||||+- PS1
            ; |||||+-- PS2
            ; ||||+--- PSA  (Use pre-scaler for Timer 0)
            ; |||+---- T0SE (not used when Timer 0 uses internal osc)
            ; ||+----- T0CS (Timer 0 to use internal oscillator)
            ; |+------ INTEDG (not used in this application)
            ; +------- RBPU (Disable Port B pull-ups)
    movwf   OPTION_REG


    ;-----------------------------
    ; Port direction
    movlw   b'10110000' ; Make all ports A exceot RA7, RA5 and RA4 output
    movwf   TRISA

    ; FIXME: RB2 needs to be output for slave!
    movlw   b'01101110' ; Make RB6, RB5, RB3, RB2 and RB1 inputs (for SLAVE!)
    movwf   TRISB


    BANKSEL xl
    ;-----------------------------
    ; Clear all memory locations between 0x20 and 0x7f
    movlw   0x7f
	movwf	FSR
	movwf	0x20		; Store a non-zero value in the last RAM address we
                        ;  like to clear
clear_ram	
    decf	FSR, f		
	clrf	INDF		; Clear Indirect memory location
	movfw	0x20		; If we reached the first RAM location it will be 0 now,
    skpz                ;  so we are done!
	goto	clear_ram   


    BANKSEL TXSTA
    ;-----------------------------
    ; UART specific initialization
OSC = d'4000000'        ; Osc frequency in Hz
BAUDRATE = d'38400'     ; Desired baudrate
BRGH_VALUE = 1          ; Either 0 or 1
SPBRG_VALUE = (((d'10'*OSC/((d'64'-(d'48'*BRGH_VALUE))*BAUDRATE))+d'5')/d'10')-1

    movlw   b'00100000'
            ; |||||||+ TX9D (not used)
            ; ||||||+- TRMT (read only)
            ; |||||+-- BRGH (high baud rate generator)
            ; ||||+---      (not implemented)
            ; |||+---- SYNC (cleared to select async mode)
            ; ||+----- TXEN (enable transmit function)
            ; |+------ TX9  (cleared to use 8 bit mode = no parity)
            ; +------- CSRC (not used in async mode)
    movwf   TXSTA

    IF (BRGH_VALUE == 1)
        bsf TXSTA, BRGH
    ELSE
        bcf TXSTA, BRGH
    ENDIF
    movlw	SPBRG_VALUE
    movwf	SPBRG

    BANKSEL RCSTA
    movlw   b'10010000'
            ; |||||||+ RX9D (not used)
            ; ||||||+- OERR (overrun error, read only)
            ; |||||+-- FERR (framing error)
            ; ||||+---      (not implemented)
            ; |||+---- CREN (enable reception for SLAVE)
            ; ||+----- SREN (not used in async mode)
            ; |+------ RX9  (cleared to use 8 bit mode = no parity)
            ; +------- SPEN (set to enable USART)
    movwf   RCSTA

    movf	RCREG, w    ; Clear uart receiver including FIFO
    movf	RCREG, w
    movf	RCREG, w

    movlw	0           ; Send dummy character to get a valid transmit flag
    movwf	TXREG


    movlw   b'00001010'
            ; |||||||+ CCPM0 (Compare mode, generate software interrupt on 
            ; ||||||+- CCPM1  match (CCP1IF bit is set, CCP1 pin is unaffected)
            ; |||||+-- CCPM2 
            ; ||||+--- CCPM3 
            ; |||+---- CCP1Y (not used)
            ; ||+----- CCP1X (not used)
            ; |+------ 
            ; +------- 
    movwf   CCP1CON

    movlw   1
    movwf   pwm_counter

    bcf     INTCON, T0IF    ; Clear Timer0 Interrupt Flag    
    bcf     PIR1, CCP1IF    ; Clear Timer1 Compare Interrupt Flag

	bsf	    INTCON, T0IE    ; Enable Timer0 interrupt
	bsf	    INTCON, GIE     ; Enable interrupts

;   goto    Main_loop    


;******************************************************************************
; Main program
;******************************************************************************
Main_loop
    call    Read_UART
    call    Set_light_mode
    call    Make_servo_pulse    
    goto    Main_loop


;******************************************************************************
; Read_UART
;
; This function returns after having successfully received a complete
; protocol frame via the UART.
;******************************************************************************
Read_UART
    IFDEF   DEBUG
    bsf     servo_sync_flag, 0
    btfsc   servo_sync_flag, 0
    goto    $ - 1   

    bsf     servo_sync_flag, 0
    btfsc   servo_sync_flag, 0
    goto    $ - 1   

    bsf     servo_sync_flag, 0
    btfsc   servo_sync_flag, 0
    goto    $ - 1   

    bsf     servo_sync_flag, 0
    btfsc   servo_sync_flag, 0
    goto    $ - 1   

    bsf     servo_sync_flag, 0
    btfsc   servo_sync_flag, 0
    goto    $ - 1   

    bsf     servo_sync_flag, 0
    btfsc   servo_sync_flag, 0
    goto    $ - 1   

    bsf     servo_sync_flag, 0
    btfsc   servo_sync_flag, 0
    goto    $ - 1   

    bsf     servo_sync_flag, 0
    btfsc   servo_sync_flag, 0
    goto    $ - 1   

    bsf     servo_sync_flag, 0
    btfsc   servo_sync_flag, 0
    goto    $ - 1   

    bsf     servo_sync_flag, 0
    btfsc   servo_sync_flag, 0
    goto    $ - 1   

    movlw   b'00000001'
    movwf   uart_light_mode 
    movlw   b'00000010'
    movwf   uart_light_mode_half
    movlw   50
    movwf   uart_servo

    return
    ENDIF


    call    read_UART_byte
    sublw   SLAVE_MAGIC_BYTE        ; First byte the magic byte?
    bnz     Read_UART               ; No: wait for 0x8f to appear

read_UART_byte_2
    call    read_UART_byte
    movwf   uart_light_mode         ; Store 2nd byte
    sublw   SLAVE_MAGIC_BYTE        ; Is it the magic byte?
    bz      read_UART_byte_2        ; Yes: we must be out of sync...

read_UART_byte_3
    call    read_UART_byte
    movwf   uart_light_mode_half
    sublw   SLAVE_MAGIC_BYTE
    bz      read_UART_byte_2

read_UART_byte_4
    call    read_UART_byte
    movwf   uart_servo
    sublw   SLAVE_MAGIC_BYTE
    bz      read_UART_byte_2
    return


;******************************************************************************
; read_UART_byte
;
; Recieve one byte from the UART in W.
;
; To enable reception of a byte, CREN must be 1. 
;
; On any error, recover by pulsing CREN low then back to high. 
;
; When a byte has been received the RCIF flag will be set. RCIF is 
; automatically cleared when RCREG is read and empty. RCREG is double buffered, 
; so it is a two byte deep FIFO. If a third byte comes in, then OERR is set. 
; You can still recover the two bytes in the FIFO, but the third (newest) is 
; lost. CREN must be pulsed negative to clear the OERR flag. 
;
; On a framing error FERR is set. FERR is automatically reset when RCREG is 
; read, so errors must be tested for *before* RCREG is read. It is *NOT* 
; recommended that you ignore the error flags. Eventually an error will cause 
; the receiver to hang up if you don't clear the error condition.
;******************************************************************************
read_UART_byte
	btfsc   RCSTA, OERR
	goto    overerror       ; if overflow error...
	btfsc   RCSTA, FERR
	goto	frameerror      ; if framing error...
uart_ready
	btfss	PIR1, RCIF
	goto	read_UART_byte  ; if not ready, wait...	

uart_gotit
	bcf     INTCON, GIE     ; Turn GIE off. This is IMPORTANT!
	btfsc	INTCON, GIE     ; MicroChip recommends this check!
	goto 	uart_gotit      ; !!! GOTCHA !!! without this check
                            ;   you are not sure gie is cleared!
	movf	RCREG, w        ; Read UART data
	bsf     INTCON, GIE     ; Re-enable interrupts
	return

overerror	   		
    ; Over-run errors are usually caused by the incoming data building up in 
    ; the fifo. This is often the case when the program has not read the UART
    ; in a while. Flushing the FIFO will allow normal input to resume.
    ; Note that flushing the FIFO also automatically clears the FERR flag.
    ; Pulsing CREN resets the OERR flag.

	bcf     INTCON, GIE
	btfsc	INTCON, GIE
	goto 	overerror

	bcf     RCSTA, CREN     ; Pulse CREN off...
	movf	RCREG, w        ; Flush the FIFO, all 3 elements
	movf	RCREG, w		
	movf	RCREG, w
	bsf     RCSTA, CREN     ; Turn CREN back on. This pulsing clears OERR
	bsf     INTCON, GIE
	goto	read_UART_byte  ; Try again...

frameerror			
    ; Framing errors are usually due to wrong baud rate coming in.

	bcf     INTCON, GIE
	btfsc	INTCON, GIE
	goto 	frameerror

	movf	RCREG,w		;reading rcreg clears ferr flag.
	bsf     INTCON, GIE
	goto	read_UART_byte  ; Try again...


;******************************************************************************
Set_light_mode
    movf    uart_light_mode, w
    movwf   light_mode
    movf    uart_light_mode_half, w
    iorwf   light_mode, w
    movwf   light_mode_half
    return    

    
;******************************************************************************
Make_servo_pulse    
    movf    uart_servo, w
    addlw   120
    movwf   xl
    call    Mul_x_by_6
    call    Add_x_and_780

    clrf    T1CON           ; Stop timer 1, runs at 1us per tick, internal osc
    clrf    TMR1H           ; Reset the timer to 0
    clrf    TMR1L
    movlw   LOW(1800)       ; Load Timer1 compare register with the wait time
    movwf   CCPR1L
    movlw   HIGH(1800)      
    movwf   CCPR1H
    bcf     PIR1, CCP1IF    ; Clear Timer1 compare interrupt flag

    ; Synchronize with the interrupt to ensure the servo pulse is not
    ; interrupted and stays precise (i.e. no servo chatter)
    bsf     servo_sync_flag, 0
    btfsc   servo_sync_flag, 0
    goto    $ - 1
   
    bsf     T1CON, 0        ; Start timer 1

    btfss   PIR1, CCP1IF    ; Wait for compare value reached
    goto    $ - 1

    clrf    T1CON           ; Stop timer 1, runs at 1us per tick, internal osc
    clrf    TMR1H           ; Reset the timer to 0
    clrf    TMR1L
    movf    xl, w           ; Load Timer1 compare register with the servo time
    movwf   CCPR1L
    movf    xh, w
    movwf   CCPR1H
    bcf     PIR1, CCP1IF    ; Clear Timer1 compare interrupt flag
   
    bsf     T1CON, 0        ; Start timer 1
    bsf     PORT_SERVO      ; Set servo port to high pulse

    btfss   PIR1, CCP1IF    ; Wait for compare value reached
    goto    $ - 1

    bcf     PORT_SERVO      ; Turn off servo pulse
    clrf    T1CON           ; Stop timer 1
    bcf     PIR1, CCP1IF

    return


;******************************************************************************
; TLC5916_send
;
; Sends the value in the temp register to the TLC5916 LED driver.
;******************************************************************************
TLC5916_send
    movlw   8
    movwf   d0

tlc5916_send_loop
    rlf     temp, f
    skpc    
    bcf     PORT_SDI
    skpnc    
    bsf     PORT_SDI
    bsf     PORT_CLK
    bcf     PORT_CLK
    decfsz  d0, f
    goto    tlc5916_send_loop

    bsf     PORT_LE
    bcf     PORT_LE
    bcf     PORT_OE
    return


;******************************************************************************
; Mul_x_by_6
;
; Calculates xh/xl = xl * 6
;
; Generated by www.piclist.com/cgi-bin/constdivmul.exe (1-May-2002 version)
;******************************************************************************
Mul_x_by_6
    ; Shift accumulator left 1 times: xh/xl = xl * 2
	clrc
	rlf	    xl, f
	clrf	xh
	rlf	    xh, f

    ; Copy accumulator to temporary location
	movf	xh, w
	movwf	yh
	movf	xl, w
	movwf	yl

    ; Shift temporary value left 1 times: yh/yl = xl * 4
	clrc
	rlf	    yl, f
	rlf	    yh, f

    ; xh/xl  =  xh/xl + yh/yl  =  xl * 6
	movf	yl, w
	addwf	xl, f
	movf	yh, w
	skpnc
	incfsz	yh, w
	addwf	xh, f
    return


;******************************************************************************
; Add_x_and_780
;
; Calculates xh/xl = xh/xl + 780
;******************************************************************************
Add_x_and_780
	movlw	LOW(780)
	addwf	xl, f
	movlw	HIGH(780)
    movwf   yh
	skpnc
	incfsz	yh, w
	addwf	xh, f
    return



    END


;******************************************************************************
; Timing architecture:
; ====================
; Timer0 will be used to provide a periodic interrupt of 2048 us.
; This will require a pre-scaler value of 8.
;
; The original design used 4096 us, as to allow to send a servo pulse of 2500 
; us without being disturbed by an interrupt by means of synchronization.
; However, 4096 us causes visible flicker on the PWM of the LEDs for anything
; other than 50%. 
;
; To ensure we output a precise pulse for the servo we must not have the
; interrupt interfere with the pulse generation. Ideally we would use the 
; CCP1/RB3 pin to let the timer hardware pull the pin low, but the pin is tied
; up and we need the other 4 already assigned pins on the servo ports anyway.
;
; The pulse we create is between 780 and 2220 us. The difference is 1440 us, 
; which is significantly shorter than the interrupt. We do not care if there
; is an interrupt occuring between 0 and 780 us (as long as the interrupt is
; done before 780 us), so all we need to do is ensure that the interrupt falls
; within the first 780 us. If we give ourself a bit of buffer at the end, we 
; would like to have the interrupt occur 2048 - 1440 - 100 (buffer) = 508 us
; before the 780 us time. So we need to start the servo pulse 780 - 508 - 2048
; = ~1800 us before we start the servo pulse.
; So the algorithm is as follows: 
; - wait for the interrup sync flag
; - wait precisely 1800 us
; - load the timer with the servo pulse time, set the pulse high and start the 
;   timer
;
; The servo pulse is generated using Timer1 in "Compare mode, generate software 
; interrupt on match" mode. The servo pulse is sent after each UART command.
; Since the master sends the UART based on reading the RC receiver, the repeat 
; timing should relatively match the normal 20 ms interval between pulses.
;******************************************************************************

