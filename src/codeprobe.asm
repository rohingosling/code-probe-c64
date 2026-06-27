//*******************************************************************************
//
// Project:      Code Probe
// Version:      2.1 (C64 Version)
// Release Date: 1990
// Last Updated: 2026-04-29 (Prepared for Kick Assembler)
// Author:       Rohin Gosling
//
// DESCRIPTION:
//
//   A lightweight machine language monitor for the Commodore 64.
//
//   Code Probe provides a software-based alternative to hardware cartridge
//   based monitors, allowing users to inspect and modify memory, manage CPU
//   registers, load and save files, and execute machine language programs.
//
//   Code Probe was originally written for the Commodore VIC-20, and was later
//   ported to the C64 with some updates and improvements.
//
// USAGE:
//
//   Load Code Probe into memory at $C000.
//
//     LOAD "CODEPROBE", 8, 1
//     SYS 49152 or SYS 12*4096 (Which ever you prefer)
//
//
// COMMAND SUMMARY:
//
//   D <start> <end>                - Hex dump memory range.
//   A <address>                    - Enter alter mode to write bytes to memory.
//   R                              - Display registers.
//   R <reg> <value>                - Set register to value and display.
//   RF                             - Display registers and flag bit-view.
//   RF <flag> <bit>                - Set flag to bit value and display.
//   F <address> <count> <value>    - Fill memory range with byte value.
//   T <source> <count> <dest>      - Transfer memory range to new location.
//   S <device> <filename>          - Save memory range to file.
//   L <device> <filename>          - Load file into memory.
//   G <address>                    - Execute machine language program at address.
//   CLS                            - Clear screen.
//   EXIT                           - Exit Code Probe and return to BASIC.
//
// CHANGE LOG:
//
//   Code Probe 1.0 (VIC-20, 1988)
//
//     - Initial release.
//
//   Code Probe 2.0 (C64, 1990)
//
//     - Ported to C64.
//     - Multiple bug fixes. 
//     - Added error checking and messages.
//     - Added support for disk drive. 
//     - Updated register and flag display to be more readable on a 40 column screen.
//     - Added ability to set registers and flags.
//
//   Code Probe 2.1 (C64, 2026)
//
//     - Restoration project to recover assembly language listing from
//       disassembled machine code on the original disk image, and prepare it 
//       for use with Kick Assembler and VS Code. Original assembly listing 
//       existed as hand-assembled handwritten pages, long lost to time. Much 
//       of the original Code Probe was written using a combination of BASIC 
//       machine language loaders, and older versions of itself. 
//     - Since it's 2026, I used Claude Code to analyze and format the 
//       disassembled code, identify and fix old bugs, and aid in the 
//       reconstruction of comments. 
//
// GYMNASTICS:
//
//   The original VIC-20 version of Code-Probe was super minimal and served 
//   its purpose well enough. Porting Code-Probe to the C64 opened up 
//   opportunities to significantly expand its feature set. However, in spite 
//   of the larger memory budget available on the C64, it was still quite a 
//   challenge to get everything to fit in the C000–CFFF (4KB) memory range. 
//   For the sake of academic interest and/or entertainment, here are some of 
//   the things I did to make it all fit. All together, the combined savings 
//   of the tricks below free up around 450 to 550 bytes.
//
//   - Code structure and algorithmic tricks 
//
//     - Tail-call optimization:
//       print_hex_word falls through into print_hex_byte, which jmps to 
//       print_nibble instead of jsr+rts. Saves 2–3 bytes per call site.
//
//     - Fall-through print chains:
//       print_indent falls through to print_spaces; print_newline tail-calls 
//       KERNAL_CHROUT rather than wrapping it.
//
//     - Table-driven command dispatch:
//       dispatch_command walks a 4-byte-per-entry command_table 
//       (name pointer + handler pointer) and invokes handlers via an indirect 
//       jmp through ZP_PTR_1, replacing a long chain of inline compares.
//
//     - Inverted-branch + jmp pattern:
//       Large handlers (e.g. cmd_s) use bcs skip/jmp error to reach error 
//       labels that exceed the ±127 byte relative branch range, instead of 
//       duplicating error code closer to each check.
//
//   - Shared subroutines and handlers:
//
//     - Single error handler (cmd_s_error):
//       Every command's parse-error path jumps to one handler instead of 
//       carrying its own.
//
//     - Unified hex tokenizer:
//       One parse_hex_byte / parse_hex_word pair, writing to a common 
//       hex_parse_result buffer, serves the D, A, R, RF, F, T, G, L, 
//       and S commands.
//
//     - Shared 16-bit arithmetic:
//       compare_16, add_16, subtract_16 (each <10 bytes) are reused by the 
//       D, F, and T commands, instead of inline math.
//
//   - Data layout tricks:
//
//     - Contiguous shadow-register block:
//       The A, X, Y, SP, PCL, PCH, P, and IO registers are stored as one 
//       8-byte array, so print_registers and cmd_r iterate with indexed 
//       addressing instead of eight separate code paths.
//
//     - Parallel register metadata table:
//       register_name_table packs name-pointer + shadow offset + width 
//       flag per entry, so cmd_r pulls all three via a single indexed read 
//       pair rather than a switch.
//
//     - Precomputed flag bit table:
//       flag_bit_table holds the 8 status-flag bitmasks so RF can mask via 
//       lda flag_bit_table,x instead of per-flag logic.
//
//     - Multiplexed I/O buffers:
//       filename_buffer, drive_filename, file_io_device, file_io_name_length 
//       are shared between S and L (only one runs at a time). Saves ~50 bytes.
//
//     - Shared I/O label strings:
//       the S and L commands both print through io_label_address rather than 
//       each carrying its own copy.
//
//     - Shared overflow flag byte:
//       The F and T commands both use a single byte to signal clamped ranges 
//       instead of separate booleans plus branches.
//
//   - Zero page and KERNAL:
//
//     - Two global ZP pointers:
//       ZP_PTR_1 ($FB/$FC) and ZP_PTR_2 ($FD/$FE) serve every command's 
//       parsing/string/copy needs instead of per-feature pointer pairs.
//
//     - Leaning on KERNAL:
//       CHROUT, CHRIN, GETIN, SETLFS, SETNAM, OPEN, CLOSE, CHKOUT, CLRCHN, 
//       and LOAD are all borrowed rather than reimplemented;
//       KERNAL is left banked in precisely so $C000 has the whole 4 KB free.
//
//     - Implicit register preservation across KERNAL calls:
//       For example, KERNAL_LOAD is entered with A=0 already left behind 
//       by SETLFS, avoiding a redundant lda #$00.
// 
//*******************************************************************************

//==============================================================================
// Constants
//==============================================================================

// KERNAL routines.

.const KERNAL_CHROUT            = $FFD2     // Output character to current device
.const KERNAL_CHRIN             = $FFCF     // Input character from current device
.const KERNAL_GETIN             = $FFE4     // Get character from keyboard buffer
.const KERNAL_SETLFS            = $FFBA     // Set logical file parameters
.const KERNAL_SETNAM            = $FFBD     // Set file name
.const KERNAL_OPEN              = $FFC0     // Open logical file
.const KERNAL_CLOSE             = $FFC3     // Close logical file
.const KERNAL_CHKOUT            = $FFC9     // Open output channel
.const KERNAL_CHKIN             = $FFC6     // Open input channel
.const KERNAL_CLRCHN            = $FFCC     // Clear I/O channels
.const KERNAL_LOAD              = $FFD5     // Load file into memory

// VIC-II registers.

.const VIC_BORDER_COLOR         = $D020     // Border color register
.const VIC_BACKGROUND_COLOR     = $D021     // Background color register

// System addresses.

.const CURRENT_TEXT_COLOR       = $0286     // Current cursor color
.const KEYBOARD_BUFFER_COUNT    = $C6       // Number of characters in keyboard buffer
.const CURSOR_BLINK_ENABLE      = $CC       // Cursor blink: 0 = enabled, non-zero = disabled
.const CURSOR_CHAR_UNDER        = $CE       // Character stored under cursor (screen code)
.const CURSOR_BLINK_PHASE       = $CF       // Cursor phase: 0 = not displayed, non-zero = displayed
.const CURSOR_LINE_POINTER      = $D1       // Pointer to current screen line (lo/hi)
.const CURSOR_COLUMN            = $D3       // Current cursor column position
.const BRK_VECTOR               = $0316     // BRK interrupt vector (low/high)
.const BASIC_WARM_START         = $A002     // BASIC ROM warm start vector (indirect)

// Zero page pointers.

.const ZP_PTR_1                 = $FB       // General 16-bit pointer
.const ZP_PTR_2                 = $FD       // Secondary 16-bit pointer
.const ZP_SCRATCH               = $02       // Temporary scratch byte
.const ZP_PR_INDEX              = $22       // print_registers loop index (avoids
                                            // conflict with ZP_SCRATCH used by
                                            // print_hex_word)
.const ZP_START_ADDR            = $23       // L command: file start address (lo/hi,
                                            // 2 bytes: $23/$24)

// Color codes.

.const COLOR_BLACK              = $00       // Black
.const COLOR_GREEN              = $05       // Green

// Character codes.

.const CLEAR_SCREEN             = $93       // Clear screen control code
.const CARRIAGE_RETURN          = $0D       // Carriage return
.const SPACE                    = $20       // Space character
.const CURSOR_LEFT              = $9D       // Cursor left
.const CURSOR_RIGHT             = $1D       // Cursor right
.const DELETE                   = $14       // DEL key (INST/DEL without SHIFT)
.const COMMA                    = $2C       // Comma character
.const DOUBLE_QUOTE             = $22       // Double quote character

// Buffer sizes.

.const INPUT_BUFFER_SIZE        = 40        // Input buffer size in bytes

// Tokenizer limits.

.const MAX_TOKENS               = 12        // Maximum tokens per command line

// Display formatting.

.const ECHO_INDENT              = 2         // Spaces before output

// Data entry limits.

.const A_MAX_BYTES_PER_LINE     = 10        // Max bytes per A command line
.const A_MAX_NIBBLES_PER_LINE   = 20        // Max nibbles per line (10 * 2)

//==============================================================================
// Program Entry Point
//==============================================================================

*= $C000 "Code Probe"

entry:

    // Set border and background colors to black.

    lda #COLOR_BLACK
    sta VIC_BORDER_COLOR
    sta VIC_BACKGROUND_COLOR

    // Set text color to green.

    lda #COLOR_GREEN
    sta CURRENT_TEXT_COLOR

    // Clear the screen.

    lda #CLEAR_SCREEN
    jsr KERNAL_CHROUT

    // Print title banner.

    lda #<title_string
    ldx #>title_string
    jsr print_string
    jsr print_blank_line

    // Initialize shadow registers to default values.
    // A, X, Y, SP, PC default to zero. P defaults to $20
    // (unused bit 5 set). IO reads the current processor
    // port value from address $01.

    lda #$00
    sta shadow_a
    sta shadow_x
    sta shadow_y
    sta shadow_sp
    sta shadow_pc
    sta shadow_pc + 1
    lda #$20
    sta shadow_p
    lda $01
    sta shadow_io

    // Save original BRK vector and install Code Probe's
    // BRK handler for G command return.

    lda BRK_VECTOR
    sta original_brk_vector
    lda BRK_VECTOR + 1
    sta original_brk_vector + 1

    sei
    lda #<brk_handler
    sta BRK_VECTOR
    lda #>brk_handler
    sta BRK_VECTOR + 1
    cli

    // Fall through to the monitor prompt loop.

//==============================================================================
// Monitor Prompt Loop
//==============================================================================

main_loop:

    jsr print_prompt
    jsr read_line
    jsr print_newline
    jsr tokenize
    jsr dispatch_command
    jmp main_loop

//==============================================================================
// Command Handlers
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: cmd_d
//
// Description:
//
//   Hex dump command. Displays memory contents from start_address to
//   end_address (inclusive) in rows of 8 bytes, with hex values and
//   character glyphs.
//
//   Syntax: D <start_address> <end_address>
//
//------------------------------------------------------------------------------

cmd_d:

    // Validate argument count.

    lda token_count
    cmp #$03
    bcs cmd_d_parse_start
    jmp cmd_s_error

cmd_d_parse_start:

    // Parse start address (token 1).

    ldx #$01
    jsr get_token_address
    jsr parse_hex_word
    bcc cmd_d_error

    lda hex_parse_result
    sta d_current_address
    lda hex_parse_result + 1
    sta d_current_address + 1

    // Parse end address (token 2).

    ldx #$02
    jsr get_token_address
    jsr parse_hex_word
    bcc cmd_d_error

    lda hex_parse_result
    sta d_end_address
    lda hex_parse_result + 1
    sta d_end_address + 1

    // Calculate byte count: end - start + 1.

    lda d_end_address
    sta ZP_PTR_1
    lda d_end_address + 1
    sta ZP_PTR_1 + 1
    lda d_current_address
    ldx d_current_address + 1
    jsr subtract_16
    lda #$01
    ldx #$00
    jsr add_16
    lda ZP_PTR_1
    sta d_byte_count
    lda ZP_PTR_1 + 1
    sta d_byte_count + 1

    // Row loop.

cmd_d_row_loop:

    jsr print_dump_row
    bcs cmd_d_summary               // Carry set = address wrapped past $FFFF

    // Check if d_current_address > d_end_address.

    lda d_current_address
    sta ZP_PTR_1
    lda d_current_address + 1
    sta ZP_PTR_1 + 1
    lda d_end_address
    sta ZP_PTR_2
    lda d_end_address + 1
    sta ZP_PTR_2 + 1
    jsr compare_16
    bcc cmd_d_row_loop              // current < end: more rows
    beq cmd_d_row_loop              // current == end: more rows

cmd_d_summary:

    lda d_byte_count
    sta ZP_PTR_1
    lda d_byte_count + 1
    sta ZP_PTR_1 + 1
    jmp print_byte_count_summary

cmd_d_error:

    jmp cmd_s_error

//------------------------------------------------------------------------------
//
// Subroutine: cmd_a
//
// Description:
//
//   Alter mode command. Enters alter mode for writing hex bytes
//   directly to RAM starting at the specified address.
//
//   - The user types hex digits one at a time via GETIN.
//
//   - After each byte (two nibbles), the cursor auto-advances past the space 
//     separator.
//
//   - Return commits the current line.
//
//   - Return on an empty line exits.
//
//   - A full line of 10 bytes auto-commits.
//
//   Syntax: A <address>
//
//------------------------------------------------------------------------------

cmd_a:

    // Validate argument count.

    lda token_count
    cmp #$02
    bcs cmd_a_parse
    jmp cmd_s_error

cmd_a_parse:

    // Parse start address (token 1).

    ldx #$01
    jsr get_token_address
    jsr parse_hex_word
    bcc cmd_a_error

    // Initialize state.

    lda hex_parse_result
    sta a_line_address
    lda hex_parse_result + 1
    sta a_line_address + 1

    lda #$00
    sta a_nibble_count
    sta a_cursor_pos
    sta a_total_bytes
    sta a_total_bytes + 1

    // Clear keyboard buffer to prevent leftover characters from the
    // monitor prompt input being processed as alter mode data.

    lda #$00
    sta KEYBOARD_BUFFER_COUNT

    // Print first line prompt.

    jsr a_print_line_prompt

    // Key input loop. CHROUT disables the cursor blink flag ($CC)
    // during character output. Re-enable it each time we return to
    // the polling loop so the cursor is visible while waiting for
    // the next keypress.

cmd_a_enable_cursor:

    lda #$00
    sta CURSOR_BLINK_ENABLE

cmd_a_key_loop:

    jsr KERNAL_GETIN
    beq cmd_a_key_loop                      // No key pressed

    // Dispatch key.

    cmp #CARRIAGE_RETURN
    bne cmd_a_not_return

    // Return pressed — remove cursor from screen, then commit or exit.

    jsr a_cursor_off
    lda a_nibble_count
    beq cmd_a_exit
    jsr a_commit_line
    jsr print_newline
    jsr a_print_line_prompt
    jmp cmd_a_enable_cursor

cmd_a_not_return:

    cmp #CURSOR_LEFT
    beq cmd_a_do_left
    cmp #CURSOR_RIGHT
    beq cmd_a_do_right
    cmp #DELETE
    beq cmd_a_do_delete

    // Check if hex digit.

    jsr is_hex_digit
    bcc cmd_a_enable_cursor                 // Not hex, re-enable cursor and poll

    // Handle hex digit entry.

    jsr a_handle_hex_digit
    jmp cmd_a_enable_cursor

cmd_a_do_left:

    jsr a_handle_cursor_left
    jmp cmd_a_enable_cursor

cmd_a_do_right:

    jsr a_handle_cursor_right
    jmp cmd_a_enable_cursor

cmd_a_do_delete:

    jsr a_handle_delete
    jmp cmd_a_enable_cursor

cmd_a_exit:

    // Exit alter mode with byte count summary.

    jsr print_newline
    lda a_total_bytes
    sta ZP_PTR_1
    lda a_total_bytes + 1
    sta ZP_PTR_1 + 1
    jmp print_byte_count_summary

cmd_a_error:

    jmp cmd_s_error

//------------------------------------------------------------------------------
//
// Subroutine: cmd_r
//
// Description:
//
//   Register display and set command.
//
//   R          — Display all shadow register values.
//   R <r> <v>  — Set register <r> to value <v> and display.
//
//   8-bit registers (A, X, Y, SP, P, IO) require exactly 2 hex digits.
//   The 16-bit register (PC) requires exactly 4 hex digits.
//
//------------------------------------------------------------------------------

cmd_r:

    // Dispatch: R alone → display, R <reg> <val> → set.

    lda token_count
    cmp #$01
    beq cmd_r_display
    cmp #$03
    bcs cmd_r_set
    jmp cmd_r_error

cmd_r_display:

    jmp print_registers

cmd_r_set:

    // Look up register name (token 1) in the register table.

    ldx #$01
    jsr get_token_address

cmd_r_find_loop:

    lda register_name_table, y
    sta ZP_PTR_2
    lda register_name_table + 1, y
    sta ZP_PTR_2 + 1

    // Check for end sentinel ($0000).

    ora ZP_PTR_2
    beq cmd_r_error

    sty r_table_index
    jsr compare_string
    beq cmd_r_matched

    // Advance to next entry (4 bytes).

    ldy r_table_index
    iny
    iny
    iny
    iny
    jmp cmd_r_find_loop

cmd_r_matched:

    // Retrieve shadow offset and expected width from table.

    ldy r_table_index
    lda register_name_table + 2, y
    sta r_shadow_offset
    lda register_name_table + 3, y

    // Get value token (token 2).

    pha
    ldx #$02
    jsr get_token_address
    pla

    // Dispatch by width: 0 = byte, 1 = word.

    bne cmd_r_parse_word

    // Parse 8-bit value (2 hex digits).

    jsr parse_hex_byte
    bcc cmd_r_error

    // Validate exact length: next character must be null.

    pha
    lda ( ZP_PTR_1 ), y
    bne cmd_r_error_pop
    pla

    // Store value in shadow register.

    ldx r_shadow_offset
    sta shadow_registers, x
    jmp cmd_r_show

cmd_r_parse_word:

    // Parse 16-bit value (4 hex digits).

    jsr parse_hex_word
    bcc cmd_r_error

    // Validate exact length.

    lda ( ZP_PTR_1 ), y
    bne cmd_r_error

    // Store value in shadow register (low byte, then high byte).

    ldx r_shadow_offset
    lda hex_parse_result
    sta shadow_registers, x
    lda hex_parse_result + 1
    sta shadow_registers + 1, x
    jmp cmd_r_show

cmd_r_show:

    jmp print_registers

cmd_r_error_pop:

    pla

cmd_r_error:

    jmp cmd_s_error

//------------------------------------------------------------------------------
//
// Subroutine: cmd_rf
//
// Description:
//
//   Register and flag display/set command.
//
//   RF             — Display registers and expanded flag bit-view.
//   RF <flag> <b>  — Set flag <flag> to bit value <b> (0 or 1) and display.
//
//   Flags: N (bit 7), V (6), - (5), B (4), D (3), I (2), Z (1), C (0).
//
//------------------------------------------------------------------------------

cmd_rf:

    // Dispatch: RF alone → display, RF <flag> <bit> → set.

    lda token_count
    cmp #$01
    beq cmd_rf_display
    cmp #$03
    bcs cmd_rf_set
    jmp cmd_rf_error

cmd_rf_display:

    jmp cmd_rf_show

cmd_rf_set:

    // Look up flag name (token 1) in the flag name table.

    ldx #$01
    jsr get_token_address

cmd_rf_find_loop:

    lda flag_name_table, y
    sta ZP_PTR_2
    lda flag_name_table + 1, y
    sta ZP_PTR_2 + 1

    // Check for end sentinel.

    ora ZP_PTR_2
    beq cmd_rf_error

    sty rf_table_index
    jsr compare_string
    beq cmd_rf_matched

    // Advance to next entry (2 bytes).

    ldy rf_table_index
    iny
    iny
    jmp cmd_rf_find_loop

cmd_rf_matched:

    // Convert byte offset to flag index and get bit mask.

    lda rf_table_index
    lsr
    tax
    lda flag_bit_table, x
    sta rf_bit_mask

    // Get bit value token (token 2).

    ldx #$02
    jsr get_token_address

    // Validate: exactly 1 character, must be '0' or '1'.

    lda ( ZP_PTR_1 ), y
    sta ZP_SCRATCH
    iny
    lda ( ZP_PTR_1 ), y
    bne cmd_rf_error

    lda ZP_SCRATCH
    cmp #$30                                // '0'
    beq cmd_rf_clear_bit
    cmp #$31                                // '1'
    beq cmd_rf_set_bit
    jmp cmd_rf_error

cmd_rf_clear_bit:

    lda rf_bit_mask
    eor #$FF
    and shadow_p
    sta shadow_p
    jmp cmd_rf_show

cmd_rf_set_bit:

    lda rf_bit_mask
    ora shadow_p
    sta shadow_p

cmd_rf_show:

    jsr print_registers
    jmp print_flags

cmd_rf_error:

    jmp cmd_s_error

//------------------------------------------------------------------------------
//
// Subroutine: cmd_f
//
// Description:
//
//   Fill memory command. Fills a range of memory with a specified byte
//   value. If the fill range would exceed $FFFF, the operation is
//   truncated to the boundary and an overflow error is printed.
//
//   Syntax: F <address> <byte_count> <byte_value>
//
//------------------------------------------------------------------------------

cmd_f:

    // Validate argument count (need 4 tokens: F, address, count, value).

    lda token_count
    cmp #$04
    bcs cmd_f_parse_address
    jmp cmd_s_error

cmd_f_parse_address:

    // Parse address (token 1).

    ldx #$01
    jsr get_token_address
    jsr parse_hex_word
    bcc cmd_f_error

    lda hex_parse_result
    sta f_address
    lda hex_parse_result + 1
    sta f_address + 1

    // Parse byte count (token 2).

    ldx #$02
    jsr get_token_address
    jsr parse_hex_word
    bcc cmd_f_error

    lda hex_parse_result
    sta f_byte_count
    lda hex_parse_result + 1
    sta f_byte_count + 1

    // Parse byte value (token 3).

    ldx #$03
    jsr get_token_address
    jsr parse_hex_byte
    bcc cmd_f_error
    sta f_byte_value
    lda ( ZP_PTR_1 ), y
    bne cmd_f_error

    // If byte count is zero, nothing to fill.

    lda f_byte_count
    ora f_byte_count + 1
    bne cmd_f_check_overflow
    rts

cmd_f_check_overflow:

    // Check for RAM overflow.
    // Compute end_address = address + (byte_count - 1).
    // If the addition carries past $FFFF, the range overflows.

    lda f_address
    sta ZP_PTR_1
    lda f_address + 1
    sta ZP_PTR_1 + 1

    lda f_byte_count
    sec
    sbc #$01
    pha
    lda f_byte_count + 1
    sbc #$00
    tax
    pla                                         // A = low, X = high of (count - 1)
    jsr add_16
    bcs cmd_f_overflow

    // No overflow.

    lda #$00
    sta f_overflow_flag
    jmp cmd_f_fill

cmd_f_error:

    jmp cmd_s_error

cmd_f_overflow:

    // Overflow detected. Clamp byte_count so fill reaches $FFFF.
    // Adjusted count = $10000 - address = $0000 - address (16-bit).

    lda #$00
    sec
    sbc f_address
    sta f_byte_count
    lda #$00
    sbc f_address + 1
    sta f_byte_count + 1

    lda #$01
    sta f_overflow_flag

cmd_f_fill:

    // Save the effective byte count for the summary. The fill loop
    // decrements f_byte_count to zero, so preserve it here.

    lda f_byte_count
    sta f_filled_count
    lda f_byte_count + 1
    sta f_filled_count + 1

    // Set up pointer.

    lda f_address
    sta ZP_PTR_1
    lda f_address + 1
    sta ZP_PTR_1 + 1
    ldy #$00

cmd_f_fill_loop:

    lda f_byte_value
    sta ( ZP_PTR_1 ), y

    // Decrement byte_count (16-bit).

    lda f_byte_count
    bne cmd_f_dec_low
    dec f_byte_count + 1

cmd_f_dec_low:

    dec f_byte_count

    // Check if byte_count reached zero.

    lda f_byte_count
    ora f_byte_count + 1
    beq cmd_f_fill_done

    // Increment pointer (16-bit).

    inc ZP_PTR_1
    bne cmd_f_fill_loop
    inc ZP_PTR_1 + 1
    jmp cmd_f_fill_loop

cmd_f_fill_done:

    // Print byte count summary.

    lda f_filled_count
    sta ZP_PTR_1
    lda f_filled_count + 1
    sta ZP_PTR_1 + 1
    jsr print_byte_count_summary

    // If overflow was detected, print error.

    lda f_overflow_flag
    beq cmd_f_done

    lda #<error_ram_overflow
    ldx #>error_ram_overflow
    jmp print_error

cmd_f_done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: cmd_t
//
// Description:
//
//   Transfer memory command. Copies a range of bytes from a source
//   address to a destination address.
//
//   - If either the source or destination range would exceed $FFFF, the byte 
//     count is clamped and an overflow error is printed.
//
//   - Uses forward copy when source >= destination, and backward copy when 
//     source < destination, to handle overlapping regions.
//
//   Syntax: T <source_address> <byte_count> <destination_address>
//
//------------------------------------------------------------------------------

cmd_t:

    // Validate argument count (need 4 tokens: T, source, count, dest).

    lda token_count
    cmp #$04
    bcs cmd_t_parse_source
    jmp cmd_s_error

cmd_t_parse_source:

    // Parse source address (token 1).

    ldx #$01
    jsr get_token_address
    jsr parse_hex_word
    bcc cmd_t_error

    lda hex_parse_result
    sta t_source_address
    lda hex_parse_result + 1
    sta t_source_address + 1

    // Parse byte count (token 2).

    ldx #$02
    jsr get_token_address
    jsr parse_hex_word
    bcc cmd_t_error

    lda hex_parse_result
    sta t_byte_count
    lda hex_parse_result + 1
    sta t_byte_count + 1

    // Parse destination address (token 3).

    ldx #$03
    jsr get_token_address
    jsr parse_hex_word
    bcc cmd_t_error

    lda hex_parse_result
    sta t_destination_address
    lda hex_parse_result + 1
    sta t_destination_address + 1

    // Verify no trailing characters after destination token.

    lda ( ZP_PTR_1 ), y
    bne cmd_t_error

    // If byte count is zero, nothing to copy.

    lda t_byte_count
    ora t_byte_count + 1
    bne cmd_t_check_source_overflow
    rts

cmd_t_error:

    jmp cmd_s_error

cmd_t_check_source_overflow:

    // Check source range for overflow.
    // Compute source + (byte_count - 1). If carry, clamp.

    lda #$00
    sta t_overflow_flag

    lda t_source_address
    sta ZP_PTR_1
    lda t_source_address + 1
    sta ZP_PTR_1 + 1

    lda t_byte_count
    sec
    sbc #$01
    pha
    lda t_byte_count + 1
    sbc #$00
    tax
    pla                                     // A = low, X = high of (count - 1)
    jsr add_16
    bcc cmd_t_check_dest_overflow

    // Source overflow. Clamp: count = $0000 - source.

    lda #$00
    sec
    sbc t_source_address
    sta t_byte_count
    lda #$00
    sbc t_source_address + 1
    sta t_byte_count + 1

    lda #$01
    sta t_overflow_flag

cmd_t_check_dest_overflow:

    // Check destination range for overflow (using possibly clamped count).
    // Compute dest + (byte_count - 1). If carry, clamp.

    lda t_destination_address
    sta ZP_PTR_1
    lda t_destination_address + 1
    sta ZP_PTR_1 + 1

    lda t_byte_count
    sec
    sbc #$01
    pha
    lda t_byte_count + 1
    sbc #$00
    tax
    pla                                     // A = low, X = high of (count - 1)
    jsr add_16
    bcc cmd_t_copy_setup

    // Destination overflow. Clamp: count = $0000 - dest.

    lda #$00
    sec
    sbc t_destination_address
    sta t_byte_count
    lda #$00
    sbc t_destination_address + 1
    sta t_byte_count + 1

    lda #$01
    sta t_overflow_flag

cmd_t_copy_setup:

    // Save effective byte count for summary.

    lda t_byte_count
    sta t_copied_count
    lda t_byte_count + 1
    sta t_copied_count + 1

    // Determine copy direction.
    // If source < destination, copy backward to handle overlap.

    lda t_source_address + 1
    cmp t_destination_address + 1
    bcc cmd_t_backward                      // source high < dest high
    bne cmd_t_forward                       // source high > dest high
    lda t_source_address
    cmp t_destination_address
    bcc cmd_t_backward                      // source low < dest low

    // Fall through: source >= destination → forward copy.

cmd_t_forward:

    // Set up source pointer in ZP_PTR_1.

    lda t_source_address
    sta ZP_PTR_1
    lda t_source_address + 1
    sta ZP_PTR_1 + 1

    // Set up destination pointer in ZP_PTR_2.

    lda t_destination_address
    sta ZP_PTR_2
    lda t_destination_address + 1
    sta ZP_PTR_2 + 1

    ldy #$00

cmd_t_forward_loop:

    lda ( ZP_PTR_1 ), y
    sta ( ZP_PTR_2 ), y

    // Decrement byte count (16-bit).

    lda t_byte_count
    bne cmd_t_fwd_dec_low
    dec t_byte_count + 1

cmd_t_fwd_dec_low:

    dec t_byte_count

    // Check if byte count reached zero.

    lda t_byte_count
    ora t_byte_count + 1
    beq cmd_t_forward_done

    // Increment source pointer (16-bit).

    inc ZP_PTR_1
    bne cmd_t_fwd_inc_dest
    inc ZP_PTR_1 + 1

cmd_t_fwd_inc_dest:

    // Increment destination pointer (16-bit).

    inc ZP_PTR_2
    bne cmd_t_forward_loop
    inc ZP_PTR_2 + 1
    jmp cmd_t_forward_loop

cmd_t_forward_done:

    jmp cmd_t_copy_done

cmd_t_backward:

    // Set up pointers at end of ranges for backward copy.
    // Compute (count - 1) into X (low) and Y (high).

    lda t_byte_count
    sec
    sbc #$01
    tax
    lda t_byte_count + 1
    sbc #$00
    tay

    // ZP_PTR_1 = source + (count - 1).

    txa
    clc
    adc t_source_address
    sta ZP_PTR_1
    tya
    adc t_source_address + 1
    sta ZP_PTR_1 + 1

    // ZP_PTR_2 = destination + (count - 1).

    txa
    clc
    adc t_destination_address
    sta ZP_PTR_2
    tya
    adc t_destination_address + 1
    sta ZP_PTR_2 + 1

    ldy #$00

cmd_t_backward_loop:

    lda ( ZP_PTR_1 ), y
    sta ( ZP_PTR_2 ), y

    // Decrement byte count (16-bit).

    lda t_byte_count
    bne cmd_t_bwd_dec_low
    dec t_byte_count + 1

cmd_t_bwd_dec_low:

    dec t_byte_count

    // Check if byte count reached zero.

    lda t_byte_count
    ora t_byte_count + 1
    beq cmd_t_copy_done

    // Decrement source pointer (ZP_PTR_1, 16-bit).

    lda ZP_PTR_1
    bne cmd_t_bwd_dec_src_low
    dec ZP_PTR_1 + 1

cmd_t_bwd_dec_src_low:

    dec ZP_PTR_1

    // Decrement destination pointer (ZP_PTR_2, 16-bit).

    lda ZP_PTR_2
    bne cmd_t_bwd_dec_dest_low
    dec ZP_PTR_2 + 1

cmd_t_bwd_dec_dest_low:

    dec ZP_PTR_2
    jmp cmd_t_backward_loop

cmd_t_copy_done:

    // Print byte count summary.

    lda t_copied_count
    sta ZP_PTR_1
    lda t_copied_count + 1
    sta ZP_PTR_1 + 1
    jsr print_byte_count_summary

    // If overflow was detected, print error.

    lda t_overflow_flag
    beq cmd_t_done

    lda #<error_ram_overflow
    ldx #>error_ram_overflow
    jmp print_error

cmd_t_done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: cmd_g
//
// Description:
//
//   Execute program command. Loads the shadow registers into the real
//   CPU registers and transfers control to the specified address via
//   RTI. The user program may return to the monitor by executing a
//   BRK instruction ($00).
//
//   Syntax: G <address>
//
//------------------------------------------------------------------------------

cmd_g:

    // Validate argument count.

    lda token_count
    cmp #$02
    bcs cmd_g_parse
    jmp cmd_s_error

cmd_g_parse:

    // Parse target address (token 1).

    ldx #$01
    jsr get_token_address
    jsr parse_hex_word
    bcc cmd_g_error

    // Validate no trailing characters.

    lda ( ZP_PTR_1 ), y
    bne cmd_g_error

    // Store target address in shadow_pc.

    lda hex_parse_result
    sta shadow_pc
    lda hex_parse_result + 1
    sta shadow_pc + 1

    // Disable interrupts during register load.

    sei

    // Set I/O configuration.

    lda shadow_io
    sta $01

    // Set stack pointer to user's value.

    ldx shadow_sp
    txs

    // Push PC and P for RTI. RTI pulls P first, then PCL, then
    // PCH, so push in reverse order: PCH deepest, P on top.

    lda shadow_pc + 1
    pha
    lda shadow_pc
    pha
    lda shadow_p
    pha

    // Load user registers.

    lda shadow_a
    ldx shadow_x
    ldy shadow_y

    // Transfer control to user program. RTI pulls P and PC
    // from the stack, restoring the user's processor state and
    // jumping to the target address.

    rti

cmd_g_error:

    jmp cmd_s_error

//------------------------------------------------------------------------------
//
// Subroutine: cmd_cls
//
// Description:
//
//   Clear screen command. Clears the terminal display and returns to the
//   monitor prompt at the top of the screen.
//
//   Syntax: CLS
//
//------------------------------------------------------------------------------

cmd_cls:

    lda #CLEAR_SCREEN
    jmp KERNAL_CHROUT

//------------------------------------------------------------------------------
//
// Subroutine: cmd_exit
//
// Description:
//
//   Exit command. Restores the original BRK vector and returns to BASIC
//   via the BASIC ROM warm start vector. Code Probe remains in memory
//   and can be re-entered with SYS 49152.
//
//   Syntax: EXIT
//
//------------------------------------------------------------------------------

cmd_exit:

    // Restore the original BRK vector.

    sei
    lda original_brk_vector
    sta BRK_VECTOR
    lda original_brk_vector + 1
    sta BRK_VECTOR + 1
    cli

    // Return to BASIC via the warm start vector.

    jmp ( BASIC_WARM_START )

//------------------------------------------------------------------------------
//
// Subroutine: cmd_s
//
// Description:
//
//   Save file command. Saves a range of memory to a file on the
//   specified device. If a load address is specified, the file is
//   saved as a PRG with a 2-byte header. Otherwise, it is saved as
//   a SEQ file (raw data, no header).
//
//   Syntax: S "<filename>" <device> <start> <end> [<load_address>]
//
//   Tokens: 0=S, 1=filename, 2=device, 3=start, 4=end, 5=load_address
//
//------------------------------------------------------------------------------

cmd_s:

    // Validate minimum argument count (need at least 5 tokens).

    lda token_count
    cmp #$05
    bcs cmd_s_parse_args
    jmp cmd_s_error

cmd_s_parse_args:

    // Parse filename and device (shared with L command).

    jsr parse_filename_device
    bcs cmd_s_parse_start
    jmp cmd_s_error

cmd_s_parse_start:

    // Parse start address (token 3).

    ldx #$03
    jsr get_token_address
    jsr parse_hex_word
    bcs cmd_s_start_ok
    jmp cmd_s_error

cmd_s_start_ok:

    lda hex_parse_result
    sta s_start_address
    lda hex_parse_result + 1
    sta s_start_address + 1

    // Parse end address (token 4).

    ldx #$04
    jsr get_token_address
    jsr parse_hex_word
    bcs cmd_s_end_ok
    jmp cmd_s_error

cmd_s_end_ok:

    lda hex_parse_result
    sta s_end_address
    lda hex_parse_result + 1
    sta s_end_address + 1

    // Check for optional load address (token 5).

    lda #$00
    sta s_has_load_address

    lda token_count
    cmp #$06
    bcc cmd_s_compute_count

    // Parse load address (token 5).

    ldx #$05
    jsr get_token_address
    jsr parse_hex_word
    bcs cmd_s_load_ok
    jmp cmd_s_error

cmd_s_load_ok:

    lda hex_parse_result
    sta s_load_address
    lda hex_parse_result + 1
    sta s_load_address + 1

    lda #$01
    sta s_has_load_address

cmd_s_compute_count:

    // Compute byte count: end - start + 1.

    lda s_end_address
    sta ZP_PTR_1
    lda s_end_address + 1
    sta ZP_PTR_1 + 1
    lda s_start_address
    ldx s_start_address + 1
    jsr subtract_16
    lda #$01
    ldx #$00
    jsr add_16

    lda ZP_PTR_1
    sta s_byte_count
    lda ZP_PTR_1 + 1
    sta s_byte_count + 1

    // Build the drive filename with type suffix.

    jsr s_build_drive_filename

    // Perform the file save.

    jsr s_save_file
    bcs cmd_s_done                              // Error already printed

    // Print "  BYTES SAVED: XXXX (Y)".

    jsr print_indent
    lda #<s_label_bytes_saved
    ldx #>s_label_bytes_saved
    jsr print_string

    lda s_byte_count
    sta ZP_PTR_1
    lda s_byte_count + 1
    sta ZP_PTR_1 + 1
    jsr print_value_hex_decimal

    // If load address was specified, print "  ADDRESS:     XXXX (Y)".

    lda s_has_load_address
    beq cmd_s_final_newline

    jsr print_indent
    lda #<io_label_address
    ldx #>io_label_address
    jsr print_string

    lda s_load_address
    sta ZP_PTR_1
    lda s_load_address + 1
    sta ZP_PTR_1 + 1
    jsr print_value_hex_decimal

cmd_s_final_newline:

    jsr print_newline

cmd_s_done:

    rts

cmd_s_error:

    lda #<error_illegal_value
    ldx #>error_illegal_value
    jmp print_error

//------------------------------------------------------------------------------
//
// Subroutine: cmd_l
//
// Description:
//
//   L command handler — load a file from disk using KERNAL LOAD.
//
//   Syntax: L "<filename>" <device>
//
//   Parses the quoted filename and device number, then uses KERNAL
//   SETNAM, SETLFS, and LOAD to load the file into memory at the
//   address specified in the file's 2-byte PRG header.
//
//   On success, prints the byte count and load address.
//   On failure, prints "ERROR: FILE NOT FOUND."
//
//------------------------------------------------------------------------------

cmd_l:

    // Dispatch: 2 tokens → directory, 3 → PRG load, 4+ → SEQ load.

    lda token_count
    cmp #$02
    bne cmd_l_file_check
    jmp cmd_l_directory

cmd_l_file_check:

    bcc cmd_l_err                               // Token count < 2
    jsr parse_filename_device
    bcs cmd_l_shared_setnam

cmd_l_err:

    jmp cmd_s_error

cmd_l_shared_setnam:

    // SETNAM — shared by PRG and SEQ paths.

    lda file_io_name_length
    ldx #<filename_buffer
    ldy #>filename_buffer
    jsr KERNAL_SETNAM

    // Branch: 4+ tokens → SEQ load with address.

    lda token_count
    cmp #$04
    bcs cmd_l_seq_mode

    // PRG load — pre-read file header to get start address.
    // KERNAL LOAD does not preserve the start address in any
    // accessible location, so we open the file first, read the
    // 2-byte PRG header, close, then perform the actual LOAD.
    // SETNAM values persist across CLOSE, so no re-call needed.

    lda #$02
    tay                                         // SA = 2 (sequential read)
    ldx file_io_device
    jsr KERNAL_SETLFS
    jsr KERNAL_OPEN
    bcs cmd_l_prg_load                          // OPEN failed — skip pre-read
    ldx #$02
    jsr KERNAL_CHKIN
    jsr KERNAL_CHRIN
    sta ZP_START_ADDR
    jsr KERNAL_CHRIN
    sta ZP_START_ADDR + 1
    jsr cmd_l_close_channel

cmd_l_prg_load:

    // SETLFS for KERNAL LOAD (LF=0, SA=1).
    // SETLFS preserves A, so A=0 is shared with LOAD.

    lda #$00
    ldx file_io_device
    ldy #$01
    jsr KERNAL_SETLFS

    // LOAD — A=0 (still set from SETLFS).

    jsr KERNAL_LOAD
    bcc cmd_l_success
    jmp cmd_l_dir_error                         // Shared error handler

cmd_l_success:

    // LOAD returns end address in X (low) / Y (high).
    // Compute byte count: end - start (from pre-read).

    txa
    sec
    sbc ZP_START_ADDR
    sta ZP_PTR_2
    tya
    sbc ZP_START_ADDR + 1
    sta ZP_PTR_2 + 1

cmd_l_print_result:

    // Print "  BYTES LOADED: XXXX (Y)".

    jsr print_indent
    lda #<l_label_bytes_loaded
    ldx #>l_label_bytes_loaded
    jsr print_string

    lda ZP_PTR_2
    sta ZP_PTR_1
    lda ZP_PTR_2 + 1
    sta ZP_PTR_1 + 1
    jsr print_value_hex_decimal

    // Print "  ADDRESS:      XXXX (Y)".
    // Uses shared label (13 chars) plus one extra space to align
    // with "BYTES LOADED: " (14 chars).

    jsr print_indent
    lda #<io_label_address
    ldx #>io_label_address
    jsr print_string
    lda #SPACE
    jsr KERNAL_CHROUT

    lda ZP_START_ADDR
    sta ZP_PTR_1
    lda ZP_START_ADDR + 1
    sta ZP_PTR_1 + 1
    jsr print_value_hex_decimal

    jmp print_newline

//------------------------------------------------------------------------------
//
// Subroutine: cmd_l_seq_mode
//
// Description:
//
//   Sequential file load mode for the L command.
//
//   Syntax: L "<filename>" <device> <address>
//
//   Opens the file using OPEN/CHKIN and reads all bytes via CHRIN,
//   storing them starting at the specified address. Used for loading
//   SEQ files (raw data with no PRG header).
//
//------------------------------------------------------------------------------

cmd_l_seq_mode:

    // Parse load address from token 3.

    ldx #$03
    jsr get_token_address
    jsr parse_hex_word
    bcs cmd_l_seq_addr_ok
    jmp cmd_s_error

cmd_l_seq_addr_ok:

    lda hex_parse_result
    sta ZP_START_ADDR
    sta ZP_PTR_1
    lda hex_parse_result + 1
    sta ZP_START_ADDR + 1
    sta ZP_PTR_1 + 1

    // Initialize byte count.

    lda #$00
    sta ZP_PTR_2
    sta ZP_PTR_2 + 1

    // SETLFS — logical file 2, device, SA 2 (sequential read).

    lda #$02
    tay                                         // Y = 2 (SA for SETLFS)
    ldx file_io_device
    jsr KERNAL_SETLFS

    // Open file and redirect input.

    jsr cmd_l_open_input

    // Read loop — read bytes via CHRIN until end of file.

cmd_l_seq_read:

    jsr KERNAL_CHRIN
    ldy #$00
    sta ( ZP_PTR_1 ), y

    // Increment byte count.

    inc ZP_PTR_2
    bne cmd_l_seq_no_carry
    inc ZP_PTR_2 + 1

cmd_l_seq_no_carry:

    // Check KERNAL status ($90) for end of file.

    lda $90
    bne cmd_l_seq_done

    // Advance pointer.

    inc ZP_PTR_1
    bne cmd_l_seq_read
    inc ZP_PTR_1 + 1
    bne cmd_l_seq_read                          // Always taken

cmd_l_seq_done:

    jsr cmd_l_close_channel
    jmp cmd_l_print_result

//------------------------------------------------------------------------------
//
// Subroutine: cmd_l_directory
//
// Description:
//
//   Directory listing mode for the L command.
//
//   Syntax: L <device>
//
//   Opens the directory channel ("$") on the specified device, reads
//   and parses each directory entry, and prints the filename (padded
//   to 16 characters) and file type (prefixed with "."). Prints a
//   file count summary at the end.
//
//------------------------------------------------------------------------------

cmd_l_directory:

    // Parse device number from token 1.

    ldx #$01
    jsr get_token_address
    jsr parse_hex_byte
    bcs cmd_l_dir_device_ok
    jmp cmd_s_error

cmd_l_dir_device_ok:

    sta file_io_device

    // Validate no trailing characters after device.

    lda ( ZP_PTR_1 ), y
    beq cmd_l_dir_open
    jmp cmd_s_error

cmd_l_dir_open:

    // SETNAM — directory filename "$".

    lda #$01
    ldx #<l_dir_name
    ldy #>l_dir_name
    jsr KERNAL_SETNAM

    // SETLFS — logical file 2, user-specified device, SA 0.

    lda #$02
    ldx file_io_device
    ldy #$00
    jsr KERNAL_SETLFS

    // OPEN the directory.

    jsr cmd_l_open_input

    // Skip load address (2 bytes).

    jsr KERNAL_CHRIN
    jsr KERNAL_CHRIN

    // Initialize file count in ZP_PTR_2.

    lda #$00
    sta ZP_PTR_2
    sta ZP_PTR_2 + 1

    //------------------------------------------------------------------
    // Main loop — read one directory line per iteration.
    //------------------------------------------------------------------

cmd_l_dir_read_line:

    // Read link pointer (2 bytes). Zero = end of directory.

    jsr KERNAL_CHRIN
    sta ZP_SCRATCH
    jsr KERNAL_CHRIN
    ora ZP_SCRATCH
    beq cmd_l_dir_close

    // Read line number / block count (2 bytes, discarded).

    jsr KERNAL_CHRIN
    jsr KERNAL_CHRIN

    // Scan for opening quote. Lines without a quote (disk header,
    // "BLOCKS FREE.") are skipped.

cmd_l_dir_find_quote:

    jsr KERNAL_CHRIN
    beq cmd_l_dir_read_line                     // No quote → skip line
    cmp #DOUBLE_QUOTE
    bne cmd_l_dir_find_quote

    // Print indent.

    jsr print_indent

    // Read and print filename until closing quote.

    ldx #$00

cmd_l_dir_print_name:

    jsr KERNAL_CHRIN
    cmp #DOUBLE_QUOTE
    beq cmd_l_dir_pad_name
    jsr KERNAL_CHROUT
    inx
    bne cmd_l_dir_print_name                    // Always taken

cmd_l_dir_pad_name:

    // Pad filename to 16 characters with spaces.

    lda #$10
    stx ZP_SCRATCH
    sec
    sbc ZP_SCRATCH
    beq cmd_l_dir_find_type
    jsr print_spaces

    // Skip spaces between filename and file type.

cmd_l_dir_find_type:

    jsr KERNAL_CHRIN
    beq cmd_l_dir_end_line                      // End of line, no type
    cmp #SPACE
    beq cmd_l_dir_find_type

    // Print file type with "." prefix.

    pha
    lda #$2E                                    // '.'
    jsr KERNAL_CHROUT
    pla
    jsr KERNAL_CHROUT

cmd_l_dir_print_type:

    jsr KERNAL_CHRIN
    beq cmd_l_dir_end_line
    cmp #SPACE
    beq cmd_l_dir_skip_rest
    jsr KERNAL_CHROUT
    jmp cmd_l_dir_print_type

    // Consume trailing characters after the type.

cmd_l_dir_skip_rest:

    jsr KERNAL_CHRIN
    bne cmd_l_dir_skip_rest

cmd_l_dir_end_line:

    jsr print_newline

    // Increment file count (16-bit).

    inc ZP_PTR_2
    bne cmd_l_dir_read_line
    inc ZP_PTR_2 + 1
    bne cmd_l_dir_read_line                     // Always taken (< 256 files)

    //------------------------------------------------------------------
    // Close directory and print file count.
    //------------------------------------------------------------------

cmd_l_dir_close:

    jsr cmd_l_close_channel

    lda ZP_PTR_2
    sta ZP_PTR_1
    lda ZP_PTR_2 + 1
    sta ZP_PTR_1 + 1
    jmp print_byte_count_summary                // Tail call

cmd_l_dir_error:

    jsr cmd_l_close_channel
    lda #<error_file_not_found
    ldx #>error_file_not_found
    jmp print_error

//------------------------------------------------------------------------------
//
// Subroutine: cmd_l_open_input
//
// Description:
//
//   Opens a file (via KERNAL OPEN) and redirects input to logical
//   file 2 (via KERNAL CHKIN). SETNAM and SETLFS must be called
//   before this subroutine. On OPEN failure, jumps to cmd_l_dir_error.
//
//   Shared by the directory listing and sequential file load paths.
//
//------------------------------------------------------------------------------

cmd_l_open_input:

    jsr KERNAL_OPEN
    bcc cmd_l_open_ok
    jmp cmd_l_dir_error

cmd_l_open_ok:

    ldx #$02
    jmp KERNAL_CHKIN                            // Tail call

//------------------------------------------------------------------------------
//
// Subroutine: cmd_l_close_channel
//
// Description:
//
//   Restores default I/O and closes logical file 2. Shared by the
//   directory listing and sequential file load paths.
//
//------------------------------------------------------------------------------

cmd_l_close_channel:

    jsr KERNAL_CLRCHN
    lda #$02
    jmp KERNAL_CLOSE                            // Tail call

//==============================================================================
// Subroutines — BRK Handler
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: brk_handler
//
// Description:
//
//   Entry point for BRK-based return from user programs executed via
//   the G command. The KERNAL IRQ handler at $FF48 detects the BRK
//   condition (B flag set in stacked P) and jumps here via the BRK
//   vector at $0316/$0317.
//
//   On entry, the KERNAL has pushed A, X, Y onto the stack (in that
//   order), and the CPU pushed P and PC+2 during the BRK sequence.
//   Stack layout (top to bottom): Y, X, A, P, PCL, PCH.
//
//   This handler saves all user registers into the shadow register
//   block, restores the monitor's screen state, and returns to the
//   monitor prompt loop.
//
//------------------------------------------------------------------------------

brk_handler:

    // Pull user registers from stack (pushed by KERNAL and CPU).

    pla
    sta shadow_y
    pla
    sta shadow_x
    pla
    sta shadow_a
    pla
    sta shadow_p
    pla
    sta shadow_pc
    pla
    sta shadow_pc + 1

    // Adjust PC: subtract 2 to point at the BRK instruction.
    // The CPU pushes PC+2 during BRK (past the opcode and the
    // signature byte).

    lda shadow_pc
    sec
    sbc #$02
    sta shadow_pc
    lda shadow_pc + 1
    sbc #$00
    sta shadow_pc + 1

    // Save stack pointer.

    tsx
    stx shadow_sp

    // Save I/O register.

    lda $01
    sta shadow_io

    // Restore default memory configuration (BASIC + KERNAL + I/O).

    lda #$37
    sta $01

    // Reset stack pointer for monitor use.

    ldx #$FF
    txs

    // Restore screen colors.

    lda #COLOR_BLACK
    sta VIC_BORDER_COLOR
    sta VIC_BACKGROUND_COLOR
    lda #COLOR_GREEN
    sta CURRENT_TEXT_COLOR

    // Re-enable interrupts.

    cli

    // Print blank line separator and return to monitor prompt.

    jsr print_blank_line
    jmp main_loop

//==============================================================================
// Subroutines — Hex Dump
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: print_dump_row
//
// Description:
//
//   Prints a single row of the hex dump. Each row contains an address,
//   8 hex byte values (with '-' separator between bytes 3 and 4), and
//   character glyphs for valid bytes. Invalid positions show "..".
//
//   Updates d_current_address by advancing it by 8.
//
// Returns:
//
//   Carry - Set if d_current_address wrapped past $FFFF.
//
//------------------------------------------------------------------------------

print_dump_row:

    // Calculate valid byte count for this row: min(8, end - current + 1).

    lda d_end_address
    sta ZP_PTR_1
    lda d_end_address + 1
    sta ZP_PTR_1 + 1
    lda d_current_address
    ldx d_current_address + 1
    jsr subtract_16                         // ZP_PTR_1 = end - current
    lda #$01
    ldx #$00
    jsr add_16                              // ZP_PTR_1 = end - current + 1

    lda ZP_PTR_1 + 1
    bne print_dump_row_full                 // High byte != 0: >= 256 remaining
    lda ZP_PTR_1
    cmp #$08
    bcs print_dump_row_full                 // >= 8 remaining
    sta d_row_valid_count                   // 1-7 valid bytes
    jmp print_dump_row_read

print_dump_row_full:

    lda #$08
    sta d_row_valid_count

print_dump_row_read:

    // Read valid bytes into d_row_buffer.

    lda d_current_address
    sta ZP_PTR_1
    lda d_current_address + 1
    sta ZP_PTR_1 + 1
    ldy #$00

print_dump_row_read_loop:

    cpy d_row_valid_count
    beq print_dump_row_read_done
    lda ( ZP_PTR_1 ), y
    sta d_row_buffer, y
    iny
    bne print_dump_row_read_loop            // Always branches (Y < 8)

print_dump_row_read_done:

    // Print indent.

    jsr print_indent

    // Print address.

    lda d_current_address + 1
    ldx d_current_address
    jsr print_hex_word

    // Print ": ".

    lda #$3A                                // ':'
    jsr KERNAL_CHROUT
    lda #SPACE
    jsr KERNAL_CHROUT

    // Print 8 hex byte positions.

    ldx #$00

print_dump_row_hex_loop:

    cpx d_row_valid_count
    bcs print_dump_row_hex_invalid

    // Valid byte.

    lda d_row_buffer, x
    jsr print_hex_byte
    jmp print_dump_row_hex_separator

print_dump_row_hex_invalid:

    // Invalid position — print "..".

    lda #$2E                                // '.'
    jsr KERNAL_CHROUT
    lda #$2E
    jsr KERNAL_CHROUT

print_dump_row_hex_separator:

    // Separator: '-' after byte 3, space after all others.

    cpx #$03
    beq print_dump_row_hex_dash

    lda #SPACE
    jsr KERNAL_CHROUT
    jmp print_dump_row_hex_next

print_dump_row_hex_dash:

    lda #$2D                                // '-'
    jsr KERNAL_CHROUT

print_dump_row_hex_next:

    inx
    cpx #$08
    bne print_dump_row_hex_loop

    // Print character glyphs for valid bytes only.

    ldx #$00

print_dump_row_glyph_loop:

    cpx d_row_valid_count
    beq print_dump_row_glyph_done
    lda d_row_buffer, x
    jsr print_safe_petscii
    inx
    bne print_dump_row_glyph_loop           // Always branches (X <= 8)

print_dump_row_glyph_done:

    // Print newline only for partial rows. Full rows (8 glyphs) are
    // exactly 40 characters wide, so the C64 screen auto-wraps the
    // cursor to the next line. An explicit newline would create an
    // unwanted blank line.

    lda d_row_valid_count
    cmp #$08
    beq print_dump_row_no_newline
    jsr print_newline

print_dump_row_no_newline:

    // Advance d_current_address by 8.

    lda d_current_address
    sta ZP_PTR_1
    lda d_current_address + 1
    sta ZP_PTR_1 + 1
    lda #$08
    ldx #$00
    jsr add_16                              // Carry set = wrapped past $FFFF
    php
    lda ZP_PTR_1
    sta d_current_address
    lda ZP_PTR_1 + 1
    sta d_current_address + 1
    plp                                     // Restore carry for caller
    rts

//------------------------------------------------------------------------------
//
// Subroutine: print_safe_petscii
//
// Description:
//
//   Prints a byte value as a printable PETSCII character via CHROUT.
//   Non-printable values (control codes) are replaced with a space.
//
//   Printable ranges: $20-$7E, $A0-$FE.
//   Non-printable:    $00-$1F, $7F, $80-$9F, $FF.
//
// Parameters:
//
//   A - Byte value to print.
//
//------------------------------------------------------------------------------

print_safe_petscii:

    cmp #$20
    bcc print_safe_petscii_space              // < $20: control code
    cmp #$7F
    bcc print_safe_petscii_ok               // $20-$7E: printable
    cmp #$A0
    bcc print_safe_petscii_space              // $7F-$9F: control code
    cmp #$FF
    bcc print_safe_petscii_ok               // $A0-$FE: printable

print_safe_petscii_space:

    lda #SPACE                              // Non-printable → blank space

print_safe_petscii_ok:

    jmp KERNAL_CHROUT

//==============================================================================
// Subroutines — Alter Mode
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: a_cursor_off
//
// Description:
//
//   Disables the cursor blink and restores the original character at the
//   cursor position if the blink is currently in the visible (reversed)
//   phase. Must be called before any CHROUT that moves or overwrites the
//   cursor position, to prevent the reversed character from being left
//   behind as a screen artifact.
//
//   Clobbers: A, Y.
//
//------------------------------------------------------------------------------

a_cursor_off:

    // Prevent the IRQ cursor routine from toggling while we work.

    inc CURSOR_BLINK_ENABLE

    // If cursor is currently displayed (reversed phase), restore the
    // original character from $CE to screen memory.

    lda CURSOR_BLINK_PHASE
    beq a_cursor_off_done

    ldy CURSOR_COLUMN
    lda CURSOR_CHAR_UNDER
    sta ( CURSOR_LINE_POINTER ), y

    lda #$00
    sta CURSOR_BLINK_PHASE

a_cursor_off_done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: a_print_line_prompt
//
// Description:
//
//   Prints the alter mode line prompt: "  AAAA: " (2-space indent, 4-digit
//   hex address, colon, space). Does not print a leading newline; the
//   caller is responsible for line positioning.
//
//------------------------------------------------------------------------------

a_print_line_prompt:

    jsr print_indent

    lda a_line_address + 1
    ldx a_line_address
    jsr print_hex_word

    lda #$3A                                // ':'
    jsr KERNAL_CHROUT
    lda #SPACE
    jmp KERNAL_CHROUT

//------------------------------------------------------------------------------
//
// Subroutine: a_handle_hex_digit
//
// Description:
//
//   Processes a hex digit keypress in alter mode. Stores
//   the nibble value in the nibble buffer, prints the character to screen,
//   and handles auto-advance past byte separators. Auto-commits when the
//   line reaches 10 bytes (20 nibbles).
//
// Parameters:
//
//   A - PETSCII hex character (validated by caller via is_hex_digit).
//
//------------------------------------------------------------------------------

a_handle_hex_digit:

    // Remove cursor from screen before output.

    pha
    jsr a_cursor_off
    pla

    // Print the character to screen.

    pha
    jsr KERNAL_CHROUT
    pla

    // Convert to nibble value.

    jsr char_to_nibble

    // Store in nibble buffer at cursor position.

    ldx a_cursor_pos
    sta a_nibble_buffer, x

    // Advance cursor.

    inc a_cursor_pos

    // Extend frontier if cursor passed it.

    lda a_cursor_pos
    cmp a_nibble_count
    bcc a_hex_byte_check                    // Within existing data
    beq a_hex_byte_check                    // At boundary (overwrite of last)
    sta a_nibble_count                      // Frontier extended

a_hex_byte_check:

    // Check if byte complete (cursor_pos even after entering low nibble).

    lda a_cursor_pos
    and #$01
    bne a_hex_done                          // Odd → high nibble only, not complete

    // Byte complete. Auto-commit only at frontier when line is full.

    lda a_cursor_pos
    cmp a_nibble_count
    bne a_hex_advance                       // Not at frontier → no auto-commit
    lda a_nibble_count
    cmp #A_MAX_NIBBLES_PER_LINE
    beq a_hex_auto_commit

a_hex_advance:

    // Print space to advance past byte separator.

    lda #SPACE
    jmp KERNAL_CHROUT

a_hex_auto_commit:

    // Line full — commit and start new line.

    jsr a_commit_line
    jsr print_newline
    jmp a_print_line_prompt

a_hex_done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: a_handle_cursor_left
//
// Description:
//
//   Moves the cursor one hex digit to the left in alter mode.
//   Skips the space separator when crossing a byte boundary. Does
//   nothing if already at the first digit.
//
//------------------------------------------------------------------------------

a_handle_cursor_left:

    lda a_cursor_pos
    beq a_cursor_left_done                  // Already at position 0

    // Remove cursor from screen before moving.

    jsr a_cursor_off

    dec a_cursor_pos

    // Move screen cursor left one position.

    lda #CURSOR_LEFT
    jsr KERNAL_CHROUT

    // If new position is odd (low nibble of previous byte), we crossed
    // a byte boundary and need to skip the space separator.

    lda a_cursor_pos
    and #$01
    beq a_cursor_left_done                  // Even → within same byte

    lda #CURSOR_LEFT
    jsr KERNAL_CHROUT

a_cursor_left_done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: a_handle_cursor_right
//
// Description:
//
//   Moves the cursor one hex digit to the right in alter mode.
//   Skips the space separator when crossing a byte boundary. Does
//   not advance past the current entry point.
//
//------------------------------------------------------------------------------

a_handle_cursor_right:

    lda a_cursor_pos
    cmp a_nibble_count
    bcs a_cursor_right_done                 // At or past entry point

    // Remove cursor from screen before moving.

    jsr a_cursor_off

    inc a_cursor_pos

    // Move screen cursor right one position.

    lda #CURSOR_RIGHT
    jsr KERNAL_CHROUT

    // If new position is even (high nibble of next byte), we crossed
    // a byte boundary and need to skip the space separator.

    lda a_cursor_pos
    and #$01
    bne a_cursor_right_done                 // Odd → within same byte

    lda #CURSOR_RIGHT
    jsr KERNAL_CHROUT

a_cursor_right_done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: a_handle_delete
//
// Description:
//
//   Deletes the last nibble entered in alter mode.
//   Only operates at the frontier (cursor_pos == nibble_count). If the
//   cursor has been moved back into existing data, the key is ignored.
//
//   When deleting a low nibble (nibble_count was even), the trailing
//   space separator is also erased (2 characters). When deleting a
//   high nibble (nibble_count was odd), only the digit is erased
//   (1 character).
//
//------------------------------------------------------------------------------

a_handle_delete:

    // Guard: nothing to delete, or not at frontier.

    lda a_cursor_pos
    beq a_delete_done
    cmp a_nibble_count
    bne a_delete_done

    // Remove cursor from screen before erasing.

    jsr a_cursor_off

    // Decrement nibble count and cursor position.

    dec a_nibble_count
    dec a_cursor_pos

    // If new nibble_count is odd, we deleted a low nibble that had a
    // trailing space — erase 2 characters. If even, we deleted a high
    // nibble — erase 1 character.

    lda a_nibble_count
    and #$01
    bne a_delete_two

    // Erase 1 character (high nibble).

    lda #CURSOR_LEFT
    jsr KERNAL_CHROUT
    lda #SPACE
    jsr KERNAL_CHROUT
    lda #CURSOR_LEFT
    jmp KERNAL_CHROUT

a_delete_two:

    // Erase 2 characters (low nibble + trailing space).

    lda #CURSOR_LEFT
    jsr KERNAL_CHROUT
    lda #CURSOR_LEFT
    jsr KERNAL_CHROUT
    lda #SPACE
    jsr KERNAL_CHROUT
    lda #SPACE
    jsr KERNAL_CHROUT
    lda #CURSOR_LEFT
    jsr KERNAL_CHROUT
    lda #CURSOR_LEFT
    jmp KERNAL_CHROUT

a_delete_done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: a_commit_line
//
// Description:
//
//   Writes the complete bytes from the nibble buffer to RAM at the
//   current line address. Updates the running total and advances the
//   line address for the next line. Resets nibble state.
//
//   Incomplete bytes (a single high nibble without its low nibble)
//   are discarded.
//
//------------------------------------------------------------------------------

a_commit_line:

    // Calculate number of complete bytes.

    lda a_nibble_count
    lsr                                     // Divide by 2
    beq a_commit_reset                      // No complete bytes
    sta a_commit_byte_count

    // Set up destination pointer.

    lda a_line_address
    sta ZP_PTR_1
    lda a_line_address + 1
    sta ZP_PTR_1 + 1

    // Convert nibble pairs to bytes and write to RAM.

    ldx #$00                                // Nibble buffer index
    ldy #$00                                // Destination offset

a_commit_write_loop:

    cpy a_commit_byte_count
    beq a_commit_update

    lda a_nibble_buffer, x                  // High nibble
    asl
    asl
    asl
    asl
    sta ZP_SCRATCH
    inx
    lda a_nibble_buffer, x                  // Low nibble
    ora ZP_SCRATCH                          // Combine into byte
    sta ( ZP_PTR_1 ), y                     // Write to RAM
    inx
    iny
    jmp a_commit_write_loop

a_commit_update:

    // Add byte count to running total.

    lda a_commit_byte_count
    clc
    adc a_total_bytes
    sta a_total_bytes
    lda #$00
    adc a_total_bytes + 1
    sta a_total_bytes + 1

    // Advance line address by byte count.

    lda a_commit_byte_count
    clc
    adc a_line_address
    sta a_line_address
    lda #$00
    adc a_line_address + 1
    sta a_line_address + 1

a_commit_reset:

    // Reset nibble state for next line.

    lda #$00
    sta a_nibble_count
    sta a_cursor_pos
    rts

//==============================================================================
// Subroutines — Registers
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: print_registers
//
// Description:
//
//   Prints all shadow register values on one line:
//   "A:XX X:XX Y:XX SP:XX PC:XXXX P:XX IO:XX"
//
//   No leading indent — the line is 39 characters wide to fit within the
//   40-column screen.
//
//------------------------------------------------------------------------------

print_registers:

    ldx #$00                                    // Table index

pr_loop:

    // Load register name string address from table.

    lda register_name_table, x
    sta ZP_PTR_2
    lda register_name_table + 1, x
    sta ZP_PTR_2 + 1

    // Check for end sentinel ($0000).

    ora ZP_PTR_2
    beq pr_done

    stx ZP_PR_INDEX                             // Save table index

    // Print space separator (skip for first register).

    cpx #$00
    beq pr_no_space
    lda #SPACE
    jsr KERNAL_CHROUT

pr_no_space:

    // Print register name string.

    lda ZP_PTR_2
    ldx ZP_PTR_2 + 1
    jsr print_string

    // Print ":".

    lda #$3A
    jsr KERNAL_CHROUT

    // Load shadow offset and width flag from table.

    ldx ZP_PR_INDEX
    ldy register_name_table + 2, x
    lda register_name_table + 3, x
    bne pr_word

    // Byte register — print 2 hex digits.

    lda shadow_registers, y
    jsr print_hex_byte
    jmp pr_advance

pr_word:

    // Word register — print 4 hex digits (A=high, X=low).

    lda shadow_registers + 1, y
    ldx shadow_registers, y
    jsr print_hex_word

pr_advance:

    ldx ZP_PR_INDEX
    inx
    inx
    inx
    inx
    jmp pr_loop

pr_done:

    jmp print_blank_line

//------------------------------------------------------------------------------
//
// Subroutine: print_flags
//
// Description:
//
//   Prints the processor status flag bit-view:
//
//       NV-BDIZC
//     P:XXXXXXXX
//
//   Each flag is printed as '0' or '1', from bit 7 (N) to bit 0 (C).
//
//------------------------------------------------------------------------------

print_flags:

    // Print flag header: "    NV-BDIZC"

    lda #$04
    jsr print_spaces
    lda #<flag_header_string
    ldx #>flag_header_string
    jsr print_string
    jsr print_newline

    // Print flag values: "  P:XXXXXXXX"

    jsr print_indent
    lda #$50                                // 'P'
    jsr KERNAL_CHROUT
    lda #$3A                                // ':'
    jsr KERNAL_CHROUT

    // Print 8 flag bits from bit 7 to bit 0.

    lda shadow_p
    sta ZP_SCRATCH
    ldx #$08

print_flags_bit_loop:

    asl ZP_SCRATCH
    lda #$30                                // '0'
    bcc print_flags_print_bit
    lda #$31                                // '1'

print_flags_print_bit:

    jsr KERNAL_CHROUT
    dex
    bne print_flags_bit_loop

    jmp print_blank_line

//==============================================================================
// Subroutines — Hex Output
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: print_nibble
//
// Description:
//
//   Prints a 4-bit value (0-15) as a single hex ASCII character via
//   CHROUT. Internal helper for print_hex_byte.
//
// Parameters:
//
//   A - Nibble value (0-15).
//
//------------------------------------------------------------------------------

print_nibble:

    cmp #$0A
    bcc print_nibble_digit

    // A >= 10: carry is set from cmp.
    // ADC #$36 = A + $36 + 1 (carry) = A + $37.
    // Maps 10 → $41 ('A'), 15 → $46 ('F').

    adc #$36
    jmp KERNAL_CHROUT

print_nibble_digit:

    // A < 10: carry is clear from cmp.
    // ADC #$30 = A + $30 + 0 = A + $30.
    // Maps 0 → $30 ('0'), 9 → $39 ('9').

    adc #$30
    jmp KERNAL_CHROUT

//------------------------------------------------------------------------------
//
// Subroutine: print_hex_byte
//
// Description:
//
//   Prints an 8-bit value as exactly two hex ASCII characters via CHROUT.
//
// Parameters:
//
//   A - Byte value to print.
//
//------------------------------------------------------------------------------

print_hex_byte:

    pha                                     // Save original byte
    lsr                                     // Shift high nibble to low
    lsr
    lsr
    lsr
    jsr print_nibble                        // Print high nibble
    pla                                     // Restore original byte
    and #$0F                                // Isolate low nibble
    jmp print_nibble                        // Print low nibble (tail call)

//------------------------------------------------------------------------------
//
// Subroutine: print_hex_word
//
// Description:
//
//   Prints a 16-bit value as exactly four hex ASCII characters (high byte
//   first) via CHROUT.
//
// Parameters:
//
//   A - High byte.
//   X - Low byte.
//
//------------------------------------------------------------------------------

print_hex_word:

    stx ZP_SCRATCH                          // Save low byte
    jsr print_hex_byte                      // Print high byte (already in A)
    lda ZP_SCRATCH                          // Load low byte
    jmp print_hex_byte                      // Print low byte (tail call)

//==============================================================================
// Subroutines — Hex Input and Validation
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: is_hex_digit
//
// Description:
//
//   Tests whether a PETSCII character is a valid hexadecimal digit
//   (0-9 or A-F).
//
// Parameters:
//
//   A - PETSCII character to test.
//
// Returns:
//
//   Carry flag: set = valid hex digit, clear = invalid.
//   A is preserved.
//
//------------------------------------------------------------------------------

is_hex_digit:

    cmp #$30                                // Below '0'?
    bcc is_hex_digit_no
    cmp #$3A                                // Above '9'?
    bcc is_hex_digit_yes
    cmp #$41                                // Below 'A'?
    bcc is_hex_digit_no
    cmp #$47                                // Above 'F'?
    bcc is_hex_digit_yes

is_hex_digit_no:

    clc
    rts

is_hex_digit_yes:

    sec
    rts

//------------------------------------------------------------------------------
//
// Subroutine: char_to_nibble
//
// Description:
//
//   Converts a PETSCII hex character to its 4-bit numeric value (0-15).
//
// Parameters:
//
//   A - PETSCII hex character ('0'-'9' or 'A'-'F').
//
// Returns:
//
//   A     - Nibble value (0-15).
//   Carry - Set = success, clear = invalid character.
//
//------------------------------------------------------------------------------

char_to_nibble:

    sec
    sbc #$30                                // Subtract '0'
    bcc char_to_nibble_bad                  // Below '0'
    cmp #$0A                                // Result < 10?
    bcc char_to_nibble_ok                   // Yes, it's 0-9

    // Might be A-F. Carry is set from cmp (A >= $0A).
    // SBC #$07 = A - $07 - 0 = A - $07.
    // Maps $11 ('A'-$30) to $0A, $16 ('F'-$30) to $0F.

    sbc #$07
    cmp #$0A                                // Below 'A' equivalent?
    bcc char_to_nibble_bad
    cmp #$10                                // Above 'F' equivalent?
    bcc char_to_nibble_ok

char_to_nibble_bad:

    clc
    rts

char_to_nibble_ok:

    sec
    rts

//------------------------------------------------------------------------------
//
// Subroutine: parse_hex_byte
//
// Description:
//
//   Parses two hex characters from a string into an 8-bit value.
//
// Parameters:
//
//   ZP_PTR_1 - Address of the string.
//   Y         - Offset to the first character.
//
// Returns:
//
//   A     - Parsed byte value.
//   Y     - Advanced by 2 (past the two characters).
//   Carry - Set = success, clear = parse error.
//
//------------------------------------------------------------------------------

parse_hex_byte:

    lda ( ZP_PTR_1 ), y                    // First hex character
    jsr char_to_nibble
    bcc parse_hex_byte_fail

    asl                                     // Shift to high nibble
    asl
    asl
    asl
    sta ZP_SCRATCH                          // Save high nibble
    iny

    lda ( ZP_PTR_1 ), y                    // Second hex character
    jsr char_to_nibble
    bcc parse_hex_byte_fail

    ora ZP_SCRATCH                          // Combine nibbles
    iny
    sec                                     // Success
    rts

parse_hex_byte_fail:

    clc
    rts

//------------------------------------------------------------------------------
//
// Subroutine: parse_hex_word
//
// Description:
//
//   Parses four hex characters from a string into a 16-bit value.
//   The result is stored in hex_parse_result (low byte) and
//   hex_parse_result+1 (high byte).
//
// Parameters:
//
//   ZP_PTR_1 - Address of the string.
//   Y         - Offset to the first character.
//
// Returns:
//
//   hex_parse_result   - Low byte of the parsed value.
//   hex_parse_result+1 - High byte of the parsed value.
//   A                   - Low byte (convenience).
//   Y                   - Advanced by 4.
//   Carry               - Set = success, clear = parse error.
//
//------------------------------------------------------------------------------

parse_hex_word:

    jsr parse_hex_byte                      // Parse high byte (first 2 chars)
    bcc parse_hex_word_fail
    sta hex_parse_result + 1                // Store high byte

    jsr parse_hex_byte                      // Parse low byte (next 2 chars)
    bcc parse_hex_word_fail
    sta hex_parse_result                    // Store low byte

    sec                                     // Success
    rts

parse_hex_word_fail:

    clc
    rts

//==============================================================================
// Subroutines — Tokenizer
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: tokenize
//
// Description:
//
//   Scans the input buffer and records the starting offset of each
//   space-separated token. Tokens are null-terminated in-place (the first
//   space after each token is replaced with $00).
//
// Returns:
//
//   token_count   - Number of tokens found (0 to MAX_TOKENS).
//   token_offsets - Byte offsets into input_buffer for each token start.
//   Carry         - Set = at least one token, clear = empty input.
//
//------------------------------------------------------------------------------

tokenize:

    ldx #$00                                // Token count
    ldy #$00                                // Buffer index

tokenize_skip_spaces:

    lda input_buffer, y
    beq tokenize_done                       // Null terminator
    cmp #SPACE
    bne tokenize_record_token
    iny
    bne tokenize_skip_spaces                // Always branches (40-byte buffer)

tokenize_record_token:

    tya                                     // A = buffer offset
    sta token_offsets, x                    // Record token start
    inx

tokenize_scan_token:

    lda input_buffer, y
    beq tokenize_done                       // Null = end of last token
    cmp #SPACE
    beq tokenize_terminate
    iny
    bne tokenize_scan_token                 // Always branches

tokenize_terminate:

    lda #$00
    sta input_buffer, y                     // Null-terminate this token
    iny
    cpx #MAX_TOKENS                         // Max tokens reached?
    bcc tokenize_skip_spaces                // No — continue

tokenize_done:

    stx token_count
    cpx #$00
    beq tokenize_empty
    sec                                     // At least one token
    rts

tokenize_empty:

    clc                                     // No tokens
    rts

//------------------------------------------------------------------------------
//
// Subroutine: get_token_address
//
// Description:
//
//   Loads the address of a specific token (within input_buffer) into
//   ZP_PTR_1 for use by parse_hex_byte, print_string, etc.
//
// Parameters:
//
//   X - Token index (0-based).
//
// Returns:
//
//   ZP_PTR_1 - Points to the start of the token.
//   Y         - Set to 0 (ready for indexed access).
//
//------------------------------------------------------------------------------

get_token_address:

    lda token_offsets, x
    clc
    adc #<input_buffer
    sta ZP_PTR_1
    lda #>input_buffer
    adc #$00
    sta ZP_PTR_1 + 1
    ldy #$00
    rts

//==============================================================================
// Subroutines — 16-Bit Arithmetic
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: compare_16
//
// Description:
//
//   Compares two 16-bit values. Flags are set as if a subtraction
//   (first - second) was performed.
//
// Parameters:
//
//   ZP_PTR_1 - First value (low byte / high byte).
//   ZP_PTR_2 - Second value (low byte / high byte).
//
// Returns:
//
//   Carry set and zero set   = first == second.
//   Carry set and zero clear = first > second.
//   Carry clear               = first < second.
//
//------------------------------------------------------------------------------

compare_16:

    lda ZP_PTR_1 + 1                       // Compare high bytes
    cmp ZP_PTR_2 + 1
    bne compare_16_done                     // Not equal — flags are set
    lda ZP_PTR_1                            // High bytes equal — compare low
    cmp ZP_PTR_2

compare_16_done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: add_16
//
// Description:
//
//   Adds a 16-bit value to ZP_PTR_1.
//
// Parameters:
//
//   ZP_PTR_1 - Base value (modified in place).
//   A         - Low byte of addend.
//   X         - High byte of addend.
//
// Returns:
//
//   ZP_PTR_1 - Sum.
//   Carry     - Set = overflow past $FFFF.
//
//------------------------------------------------------------------------------

add_16:

    clc
    adc ZP_PTR_1
    sta ZP_PTR_1
    txa
    adc ZP_PTR_1 + 1
    sta ZP_PTR_1 + 1
    rts

//------------------------------------------------------------------------------
//
// Subroutine: subtract_16
//
// Description:
//
//   Subtracts a 16-bit value from ZP_PTR_1.
//
// Parameters:
//
//   ZP_PTR_1 - Minuend (modified in place).
//   A         - Low byte of subtrahend.
//   X         - High byte of subtrahend.
//
// Returns:
//
//   ZP_PTR_1 - Difference.
//   Carry     - Clear = underflow (borrow occurred).
//
//------------------------------------------------------------------------------

subtract_16:

    sta ZP_SCRATCH                          // Save low byte of subtrahend
    lda ZP_PTR_1
    sec
    sbc ZP_SCRATCH
    sta ZP_PTR_1
    txa
    sta ZP_SCRATCH                          // Save high byte of subtrahend
    lda ZP_PTR_1 + 1
    sbc ZP_SCRATCH
    sta ZP_PTR_1 + 1
    rts

//==============================================================================
// Subroutines — Decimal Output
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: print_decimal_word
//
// Description:
//
//   Prints a 16-bit value as a decimal number (1 to 5 digits). Leading
//   zeros are suppressed; the value 0 prints as "0".
//
// Parameters:
//
//   ZP_PTR_1 - Value to print (low byte / high byte). Modified.
//
//------------------------------------------------------------------------------

print_decimal_word:

    lda #$00
    sta ZP_SCRATCH                          // 0 = suppress leading zeros

    ldx #$00                                // Table index (0, 2, 4, 6, 8)

print_decimal_next_power:

    ldy #$00                                // Digit counter

print_decimal_subtract:

    // Try subtracting the current power of 10 from the value.

    lda ZP_PTR_1
    sec
    sbc decimal_powers, x
    pha                                     // Save tentative low byte
    lda ZP_PTR_1 + 1
    sbc decimal_powers + 1, x
    bcc print_decimal_too_far               // Borrow — went negative

    // Subtraction succeeded.

    sta ZP_PTR_1 + 1
    pla
    sta ZP_PTR_1
    iny                                     // Increment digit
    bne print_decimal_subtract              // Always branches (digit < 256)

print_decimal_too_far:

    pla                                     // Discard tentative low byte

    // Check if this digit should be printed.

    cpy #$00
    bne print_decimal_print                 // Non-zero digit — always print
    lda ZP_SCRATCH
    beq print_decimal_skip                  // Still suppressing leading zeros

print_decimal_print:

    lda #$01
    sta ZP_SCRATCH                          // No longer suppressing
    tya
    clc
    adc #$30                                // Convert digit to PETSCII
    jsr KERNAL_CHROUT

print_decimal_skip:

    inx                                     // Advance to next power (2 bytes)
    inx
    cpx #$0A                                // Past last entry? (5 x 2 = 10)
    bcc print_decimal_next_power

    // If nothing was printed, the value was 0.

    lda ZP_SCRATCH
    bne print_decimal_done
    lda #$30                                // '0'
    jsr KERNAL_CHROUT

print_decimal_done:

    rts

//==============================================================================
// Subroutines — String Comparison and Command Dispatch
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: compare_string
//
// Description:
//
//   Compares two null-terminated strings for equality.
//
// Parameters:
//
//   ZP_PTR_1 - Address of string 1.
//   ZP_PTR_2 - Address of string 2.
//
// Returns:
//
//   Zero flag: set = strings are equal, clear = strings differ.
//
//------------------------------------------------------------------------------

compare_string:

    ldy #$00

compare_string_loop:

    lda ( ZP_PTR_1 ), y
    cmp ( ZP_PTR_2 ), y
    bne compare_string_done                 // Mismatch
    cmp #$00                                // Both bytes equal — null?
    beq compare_string_done                 // Both null — strings equal
    iny
    bne compare_string_loop                 // Max 256 characters

compare_string_done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: dispatch_command
//
// Description:
//
//   Matches the first token of user input against the command table and
//   jumps to the corresponding handler. If no match is found, prints
//   "ERROR: UNKNOWN COMMAND". If input is empty, returns immediately.
//
//   The handler is entered via JMP, so the handler's RTS returns to the
//   caller of dispatch_command (the monitor prompt loop).
//
//------------------------------------------------------------------------------

dispatch_command:

    lda token_count
    beq dispatch_command_empty

    // Load token 0 address into ZP_PTR_1.

    ldx #$00
    jsr get_token_address

    // Walk the command table using Y as a byte offset.

dispatch_command_loop:

    // Load command string address into ZP_PTR_2.

    lda command_table, y
    sta ZP_PTR_2
    lda command_table + 1, y
    sta ZP_PTR_2 + 1

    // Check for end sentinel ($0000).

    ora ZP_PTR_2
    beq dispatch_command_unknown

    // Save table offset. compare_string clobbers Y but preserves
    // ZP_PTR_1 and ZP_PTR_2.

    sty ZP_SCRATCH
    jsr compare_string
    beq dispatch_command_found

    // No match — restore offset and advance to next entry (4 bytes).

    ldy ZP_SCRATCH
    iny
    iny
    iny
    iny
    jmp dispatch_command_loop

dispatch_command_found:

    ldy ZP_SCRATCH

    // Load handler address from table (offset +2 and +3).

    lda command_table + 2, y
    sta ZP_PTR_1
    lda command_table + 3, y
    sta ZP_PTR_1 + 1
    jmp ( ZP_PTR_1 )                       // Jump to handler

dispatch_command_unknown:

    lda #<error_unknown_cmd
    ldx #>error_unknown_cmd
    jmp print_error

dispatch_command_empty:

    jmp print_newline                       // Blank separator for empty input

//==============================================================================
// Subroutines — Error Reporting
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: print_error
//
// Description:
//
//   Prints a formatted error message: "  ERROR: <message>" followed by
//   a blank line separator.
//
// Parameters:
//
//   A - Error message string address low byte.
//   X - Error message string address high byte.
//
//------------------------------------------------------------------------------

print_error:

    // Save the message address.

    pha
    txa
    pha

    // Print indent.

    jsr print_indent

    // Print "ERROR: " prefix.

    lda #<error_prefix_string
    ldx #>error_prefix_string
    jsr print_string

    // Restore and print the specific error message.

    pla
    tax
    pla
    jsr print_string

    // Blank line separator.

    jmp print_blank_line

//==============================================================================
// Subroutines — Character I/O
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: print_byte_count_summary
//
// Description:
//
//   Prints a byte count summary line used by multiple commands (D, A, F).
//   Format: "  XXXX (Y)" where XXXX is the 4-digit hex count and Y is
//   the decimal count, followed by a blank line separator.
//
// Parameters:
//
//   ZP_PTR_1 - Byte count (low byte / high byte). Modified.
//
//------------------------------------------------------------------------------

print_byte_count_summary:

    // Print indent.

    jsr print_indent

    // Print hex byte count.

    lda ZP_PTR_1 + 1
    ldx ZP_PTR_1
    jsr print_hex_word

    // Print " (".

    lda #SPACE
    jsr KERNAL_CHROUT
    lda #$28                                // '('
    jsr KERNAL_CHROUT

    // Print decimal byte count.

    jsr print_decimal_word

    // Print ")".

    lda #$29                                // ')'
    jsr KERNAL_CHROUT

    jmp print_blank_line

//------------------------------------------------------------------------------
//
// Subroutine: print_value_hex_decimal
//
// Description:
//
//   Prints a 16-bit value as both hex and decimal in the format
//   "HHHH (DDD)" followed by a newline. Used by the S and L command
//   output formatting.
//
// Parameters:
//
//   ZP_PTR_1 - Value to print (low byte / high byte). Modified.
//
//------------------------------------------------------------------------------

print_value_hex_decimal:

    lda ZP_PTR_1 + 1
    ldx ZP_PTR_1
    jsr print_hex_word

    lda #SPACE
    jsr KERNAL_CHROUT
    lda #$28                                    // '('
    jsr KERNAL_CHROUT

    jsr print_decimal_word

    lda #$29                                    // ')'
    jsr KERNAL_CHROUT

    jmp print_newline                           // Tail call

//------------------------------------------------------------------------------
//
// Subroutine: print_prompt
//
// Description:
//
//   Prints the monitor prompt string ": " to the screen.
//
//------------------------------------------------------------------------------

print_prompt:

    lda #<prompt_string
    ldx #>prompt_string
    jmp print_string

//------------------------------------------------------------------------------
//
// Subroutine: read_line
//
// Description:
//
//   Reads a line of input from the keyboard into the input buffer using
//   CHRIN ($FFCF). The buffer is null-terminated.
//
//   CHRIN returns characters starting from the cursor position where input
//   began (after the prompt), not from column 0 of the screen line. Prompt
//   characters are not included and must not be skipped.
//
//------------------------------------------------------------------------------

read_line:

    ldx #$00                            // Buffer index

read_line_loop:

    jsr KERNAL_CHRIN
    cmp #CARRIAGE_RETURN                // End of input?
    beq read_line_done
    sta input_buffer, x
    inx
    cpx #INPUT_BUFFER_SIZE - 1          // Buffer full?
    bcc read_line_loop

read_line_done:

    // Null-terminate the buffer.

    lda #$00
    sta input_buffer, x
    rts

//------------------------------------------------------------------------------
//
// Subroutine: print_string
//
// Description:
//
//   Prints a null-terminated string via CHROUT.
//
// Parameters:
//
//   A - String address low byte.
//   X - String address high byte.
//
//------------------------------------------------------------------------------

print_string:

    sta ZP_PTR_1
    stx ZP_PTR_1 + 1
    ldy #$00

print_string_loop:

    lda ( ZP_PTR_1 ), y
    beq print_string_done
    jsr KERNAL_CHROUT
    iny
    bne print_string_loop               // Max 256 characters

print_string_done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: print_spaces
//
// Description:
//
//   Prints A space characters to the screen.
//
// Parameters:
//
//   A - Number of spaces to print (0-255).
//
//------------------------------------------------------------------------------

print_indent:

    lda #ECHO_INDENT                            // Fall through to print_spaces

print_spaces:

    tax
    beq print_spaces_done
    lda #SPACE

print_spaces_loop:

    jsr KERNAL_CHROUT
    dex
    bne print_spaces_loop

print_spaces_done:

    rts

//------------------------------------------------------------------------------
//
// Subroutine: print_newline
//
// Description:
//
//   Prints a carriage return to move the cursor to the next line.
//
//------------------------------------------------------------------------------

print_blank_line:

    jsr print_newline
    jmp print_newline

print_newline:

    lda #CARRIAGE_RETURN
    jmp KERNAL_CHROUT

//==============================================================================
// Subroutines — File I/O Common
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: parse_filename_device
//
// Description:
//
//   Parses a quoted filename from token 1 and a device number from
//   token 2. The filename is extracted (quotes stripped) into
//   filename_buffer and its length stored in file_io_name_length.
//   The device number is stored in file_io_device.
//
//   Shared by the S and L command handlers.
//
// Returns:
//
//   Carry - Set = success, clear = parse error.
//
//------------------------------------------------------------------------------

parse_filename_device:

    // Extract filename from token 1, stripping surrounding quotes.

    ldx #$01
    jsr get_token_address

    lda ( ZP_PTR_1 ), y
    cmp #DOUBLE_QUOTE
    bne parse_fd_error
    iny

    ldx #$00

parse_fd_name_loop:

    lda ( ZP_PTR_1 ), y
    beq parse_fd_error                          // Null before closing quote
    cmp #DOUBLE_QUOTE
    beq parse_fd_name_done
    sta filename_buffer, x
    iny
    inx
    cpx #$10                                    // Max 16 characters
    bcc parse_fd_name_loop
    bcs parse_fd_error                          // Filename too long

parse_fd_name_done:

    stx file_io_name_length

    // Parse device number (token 2, 2 hex digits).

    ldx #$02
    jsr get_token_address
    jsr parse_hex_byte
    bcc parse_fd_error

    // Validate no trailing characters after device.

    sta file_io_device
    lda ( ZP_PTR_1 ), y
    bne parse_fd_error

    sec
    rts

parse_fd_error:

    clc
    rts

//==============================================================================
// Subroutines — File Save
//==============================================================================

//------------------------------------------------------------------------------
//
// Subroutine: s_build_drive_filename
//
// Description:
//
//   Copies the user filename from filename_buffer into drive_filename
//   and appends the appropriate type suffix: ",P,W" for PRG files
//   (when load address is specified) or ",S,W" for SEQ files.
//
//   Sets drive_filename_length for use with SETNAM.
//
//------------------------------------------------------------------------------

s_build_drive_filename:

    // Copy user filename to drive_filename.

    ldx #$00
    ldy #$00

s_build_copy_loop:

    cpx file_io_name_length
    beq s_build_append_suffix
    lda filename_buffer, x
    sta drive_filename, y
    inx
    iny
    jmp s_build_copy_loop

s_build_append_suffix:

    // Append comma separator.

    lda #COMMA
    sta drive_filename, y
    iny

    // Append file type: 'P' for PRG, 'S' for SEQ.

    lda s_has_load_address
    bne s_build_prg_type

    lda #$53                                    // 'S'
    jmp s_build_write_type

s_build_prg_type:

    lda #$50                                    // 'P'

s_build_write_type:

    sta drive_filename, y
    iny

    // Append ",W" (write mode).

    lda #COMMA
    sta drive_filename, y
    iny

    lda #$57                                    // 'W'
    sta drive_filename, y
    iny

    sty drive_filename_length
    rts

//------------------------------------------------------------------------------
//
// Subroutine: s_save_file
//
// Description:
//
//   Performs the file save operation using KERNAL OPEN, CHKOUT, and
//   CHROUT. Opens the file on the target device, writes the optional
//   PRG load address header and then all data bytes from the specified
//   memory range, and closes the file.
//
// Returns:
//
//   Carry - Clear = success, set = error (error message printed).
//
//------------------------------------------------------------------------------

s_save_file:

    // SETNAM — set the drive filename.

    lda drive_filename_length
    ldx #<drive_filename
    ldy #>drive_filename
    jsr KERNAL_SETNAM

    // SETLFS — logical file 1, device, secondary address 2.

    lda #$01
    ldx file_io_device
    ldy #$02
    jsr KERNAL_SETLFS

    // OPEN the file for writing.

    jsr KERNAL_OPEN
    bcs s_save_file_error

    // CHKOUT — redirect output to the file.

    ldx #$01
    jsr KERNAL_CHKOUT
    bcs s_save_file_close_error

    // If PRG mode, write the 2-byte load address header.

    lda s_has_load_address
    beq s_save_file_write_data

    lda s_load_address
    jsr KERNAL_CHROUT
    lda s_load_address + 1
    jsr KERNAL_CHROUT

s_save_file_write_data:

    // Set up source pointer.

    lda s_start_address
    sta ZP_PTR_1
    lda s_start_address + 1
    sta ZP_PTR_1 + 1

    // Copy byte count for the write loop.

    lda s_byte_count
    sta s_write_count
    lda s_byte_count + 1
    sta s_write_count + 1

s_save_file_write_loop:

    // Read and write one byte.

    ldy #$00
    lda ( ZP_PTR_1 ), y
    jsr KERNAL_CHROUT

    // Decrement write count (16-bit).

    lda s_write_count
    bne s_save_dec_low
    dec s_write_count + 1

s_save_dec_low:

    dec s_write_count

    // Check if done.

    lda s_write_count
    ora s_write_count + 1
    beq s_save_file_done

    // Increment source pointer (16-bit).

    inc ZP_PTR_1
    bne s_save_file_write_loop
    inc ZP_PTR_1 + 1
    jmp s_save_file_write_loop

s_save_file_done:

    // Restore default I/O and close the file.

    jsr KERNAL_CLRCHN

    lda #$01
    jsr KERNAL_CLOSE

    clc                                         // Success
    rts

s_save_file_close_error:

    // CHKOUT failed — close the file before reporting error.

    jsr KERNAL_CLRCHN

    lda #$01
    jsr KERNAL_CLOSE

s_save_file_error:

    lda #<error_save_failed
    ldx #>error_save_failed
    jsr print_error

    sec                                         // Error
    rts

//==============================================================================
// Data
//==============================================================================

// Text encoding for string data.

.encoding "petscii_upper"

// Title banner string.

title_string:

    .text "CODE PROBE (2.1) - ROHIN GOSLING"
    .byte $00

// Prompt string.

prompt_string:

    .byte $3A, $20, $00                 // ": " null-terminated (PETSCII)

// Input buffer.

input_buffer:

    .fill INPUT_BUFFER_SIZE, $00

// Tokenizer state.

token_count:

    .byte $00

token_offsets:

    .fill MAX_TOKENS, $00

// Hex parser output.

hex_parse_result:

    .word $0000

// Decimal powers-of-10 table (low byte / high byte).

decimal_powers:

    .word 10000, 1000, 100, 10, 1

// Error strings.

error_prefix_string:

    .text "ERROR: "
    .byte $00

error_unknown_cmd:

    .text "UNKNOWN COMMAND"
    .byte $00

error_illegal_value:

    .text "ILLEGAL VALUE"
    .byte $00

error_ram_overflow:

    .text "RAM OVERFLOW"
    .byte $00

error_save_failed:

    .text "SAVE FAILED"
    .byte $00

error_file_not_found:

    .text "FILE NOT FOUND."
    .byte $00

// D command working storage.

d_current_address:

    .word $0000

d_end_address:

    .word $0000

d_byte_count:

    .word $0000

d_row_valid_count:

    .byte $00

d_row_buffer:

    .fill 8, $00

// A command working storage.

a_line_address:

    .word $0000

a_nibble_count:

    .byte $00

a_cursor_pos:

    .byte $00

a_total_bytes:

    .word $0000

a_nibble_buffer:

    .fill A_MAX_NIBBLES_PER_LINE, $00

a_commit_byte_count:

    .byte $00

// F command working storage.

f_address:

    .word $0000

f_byte_count:

    .word $0000

f_byte_value:

    .byte $00

f_overflow_flag:

    .byte $00

f_filled_count:

    .word $0000

// T command working storage.

t_source_address:

    .word $0000

t_byte_count:

    .word $0000

t_destination_address:

    .word $0000

t_overflow_flag:

    .byte $00

t_copied_count:

    .word $0000

// File I/O shared working storage (S and L commands).

file_io_device:

    .byte $00

file_io_name_length:

    .byte $00

// S command working storage.

s_start_address:

    .word $0000

s_end_address:

    .word $0000

s_load_address:

    .word $0000

s_has_load_address:

    .byte $00

s_byte_count:

    .word $0000

s_write_count:

    .word $0000

// File name buffer (shared by S and L commands).

filename_buffer:

    .fill 16, $00

// Drive filename buffer (user name + type suffix).

drive_filename:

    .fill 21, $00

drive_filename_length:

    .byte $00

// File I/O output labels (shared by S and L commands).

s_label_bytes_saved:

    .text "BYTES SAVED: "
    .byte $00

io_label_address:

    .text "ADDRESS:     "
    .byte $00

// L command working storage.

// L command output labels.

l_label_bytes_loaded:

    .text "BYTES LOADED: "
    .byte $00

// L command directory listing data.

l_dir_name:

    .text "$"

// Command table — pairs of (command string address, handler address).
// Terminated by a $0000 sentinel.

command_table:

    .word flag_str_d, cmd_d
    .word reg_str_a, cmd_a
    .word cmd_str_r, cmd_r
    .word cmd_str_rf, cmd_rf
    .word cmd_str_f, cmd_f
    .word cmd_str_t, cmd_t
    .word cmd_str_g, cmd_g
    .word cmd_str_s, cmd_s
    .word cmd_str_l, cmd_l
    .word cmd_str_cls, cmd_cls
    .word cmd_str_exit, cmd_exit
    .word $0000

// Command name strings.

cmd_str_r:

    .text "R"
    .byte $00

cmd_str_rf:

    .text "RF"
    .byte $00

cmd_str_f:

    .text "F"
    .byte $00

cmd_str_t:

    .text "T"
    .byte $00

cmd_str_g:

    .text "G"
    .byte $00

cmd_str_s:

    .text "S"
    .byte $00

cmd_str_l:

    .text "L"
    .byte $00

cmd_str_cls:

    .text "CLS"
    .byte $00

cmd_str_exit:

    .text "EXIT"
    .byte $00

// Shadow registers.
//
// Contiguous 8-byte block for indexed access via shadow_registers base.
// Layout: A(0) X(1) Y(2) SP(3) PC_lo(4) PC_hi(5) P(6) IO(7).

shadow_registers:

shadow_a:

    .byte $00

shadow_x:

    .byte $00

shadow_y:

    .byte $00

shadow_sp:

    .byte $00

shadow_pc:

    .word $0000

shadow_p:

    .byte $20

shadow_io:

    .byte $00

// Original BRK vector backup (saved at startup).

original_brk_vector:

    .word $0000

// R command working storage.

r_table_index:

    .byte $00

r_shadow_offset:

    .byte $00

// RF command working storage.

rf_table_index:

    .byte $00

rf_bit_mask:

    .byte $00

// Register name table — entries of (name string address, shadow offset,
// width flag). Width: 0 = byte (2 hex digits), 1 = word (4 hex digits).
// Terminated by $0000 sentinel.

register_name_table:

    .word reg_str_a
    .byte 0, 0

    .word reg_str_x
    .byte 1, 0

    .word reg_str_y
    .byte 2, 0

    .word reg_str_sp
    .byte 3, 0

    .word reg_str_pc
    .byte 4, 1

    .word reg_str_p
    .byte 6, 0

    .word reg_str_io
    .byte 7, 0

    .word $0000

// Register name strings.

reg_str_a:

    .text "A"
    .byte $00

reg_str_x:

    .text "X"
    .byte $00

reg_str_y:

    .text "Y"
    .byte $00

reg_str_sp:

    .text "SP"
    .byte $00

reg_str_pc:

    .text "PC"
    .byte $00

reg_str_p:

    .text "P"
    .byte $00

reg_str_io:

    .text "IO"
    .byte $00

// Flag name table — word addresses of flag name strings.
// Order: bit 7 (N) to bit 0 (C). Terminated by $0000 sentinel.

flag_name_table:

    .word flag_str_n
    .word flag_str_v
    .word flag_str_dash
    .word flag_str_b
    .word flag_str_d
    .word flag_str_i
    .word flag_str_z
    .word flag_str_c
    .word $0000

// Flag bit mask table — parallel to flag_name_table (before sentinel).

flag_bit_table:

    .byte $80, $40, $20, $10, $08, $04, $02, $01

// Flag header string.

flag_header_string:

    .text "NV-BDIZC"
    .byte $00

// Flag name strings.

flag_str_n:

    .text "N"
    .byte $00

flag_str_v:

    .text "V"
    .byte $00

flag_str_dash:

    .text "-"
    .byte $00

flag_str_b:

    .text "B"
    .byte $00

flag_str_d:

    .text "D"
    .byte $00

flag_str_i:

    .text "I"
    .byte $00

flag_str_z:

    .text "Z"
    .byte $00

flag_str_c:

    .text "C"
    .byte $00
