//
// Communication module to MT32-pi (external MIDI emulator on RPi)
// (C) 2020 Sorgelig, Kitrinx
//
// https://github.com/dwhinham/mt32-pi
//
//
// PROTOTYPE - option C text LCD (branch prototype/mt32pi-lcd-text-x68000).
// NOT verified: no Quartus/verilator on this VM. Do not ship as-is.
// See PROTOTYPE-LCD-TEXT.md in the repo root for the wire format.

module mt32pi
(
	input             CLK_AUDIO,

	input             CLK_VIDEO,
	input             CE_PIXEL,
	input             VGA_VS,
	input             VGA_DE,

	input       [6:0] USER_IN,
	output      [6:0] USER_OUT,

	input             reset,
	input             midi_tx,
	output            midi_rx,

	output reg [15:0] mt32_i2s_r,
	output reg [15:0] mt32_i2s_l,

	output reg        mt32_available,

	input             mt32_mode_req,
	input       [1:0] mt32_rom_req,
	input       [7:0] mt32_sf_req,

	output reg  [7:0] mt32_mode,
	output reg  [7:0] mt32_rom,
	output reg  [7:0] mt32_sf,
	output reg        mt32_newmode,

	output reg        mt32_lcd_en,
	output reg        mt32_lcd_pix,
	output reg        mt32_lcd_update
);

//
// Pin | USB Name | Signal
// ----+----------+--------------
// 0   | D+       | I/O I2C_SDA / RX (midi in)
// 1   | D-       | O   TX (midi out)
// 2   | TX-      | I   I2S_WS (1 == right)
// 3   | GND_d    | I   I2C_SCL
// 4   | RX+      | I   I2S_BCLK
// 5   | RX-      | I   I2S_DAT
// 6   | TX+      | -   none
//

assign USER_OUT[0]   = sda_out;
assign USER_OUT[1]   = midi_tx;
assign USER_OUT[6:2] = '1;


//
// crossed/straight cable selection
//

generate
	genvar i;
	for(i = 0; i<2; i++) begin : clk_rate
		wire clk_in = i ? USER_IN[6] : USER_IN[4];
		reg [4:0] cnt;
		always @(posedge CLK_AUDIO) begin : clkr
			reg       clk_sr, clk, old_clk;
			reg [4:0] cnt_tmp;

			clk_sr <= clk_in;
			if (clk_sr == clk_in) clk <= clk_sr;

			if(~&cnt_tmp) cnt_tmp <= cnt_tmp + 1'd1;
			else cnt <= '1;

			old_clk <= clk;
			if(~old_clk & clk) begin
				cnt <= cnt_tmp;
				cnt_tmp <= 0;
			end
		end
	end
	
	reg crossed;
	always @(posedge CLK_AUDIO) crossed <= (clk_rate[0].cnt <= clk_rate[1].cnt);
endgenerate

wire   i2s_ws   = crossed ? USER_IN[2] : USER_IN[5];
wire   i2s_data = crossed ? USER_IN[5] : USER_IN[2];
wire   i2s_bclk = crossed ? USER_IN[4] : USER_IN[6];
assign midi_rx  = ~mt32_available ? USER_IN[0] : crossed ? USER_IN[6] : USER_IN[4];


//
// i2s receiver
//

always @(posedge CLK_AUDIO) begin : i2s_proc
	reg [15:0] i2s_buf = 0;
	reg  [4:0] i2s_cnt = 0;
	reg        clk_sr;
	reg        i2s_clk = 0;
	reg        old_clk, old_ws;
	reg        i2s_next = 0;

	// Debounce clock
	clk_sr <= i2s_bclk;
	if (clk_sr == i2s_bclk) i2s_clk <= clk_sr;

	// Latch data and ws on rising edge
	old_clk <= i2s_clk;
	if (i2s_clk && ~old_clk) begin

		if (~i2s_cnt[4]) begin
			i2s_cnt <= i2s_cnt + 1'd1;
			i2s_buf[~i2s_cnt[3:0]] <= i2s_data;
		end

		// Word Select will change 1 clock before the new word starts
		old_ws <= i2s_ws;
		if (old_ws != i2s_ws) i2s_next <= 1;
	end

	if (i2s_next) begin
		i2s_next <= 0;
		i2s_cnt <= 0;
		i2s_buf <= 0;

		if (i2s_ws) mt32_i2s_l <= i2s_buf;
		else        mt32_i2s_r <= i2s_buf;
	end
	
	if (reset) begin
		i2s_buf    <= 0;
		mt32_i2s_l <= 0;
		mt32_i2s_r <= 0;
	end
end


//
// i2c slave
//

reg        sda_out;
reg  [7:0] lcd_data[1024];
//
// PROTOTYPE (option C): text-mode LCD state. Pi sends a ~150-byte text
// packet on I2C 0x3C (control 0x00, magic 'T', mode, DDRAM 80 B, CGRAM
// 64 B, flags 1 B). Bitmap path (control 0x40) is unchanged; a bitmap
// packet clears lcd_text_valid. Text RAM is written on CLK_AUDIO and
// read on CLK_VIDEO, same cross-domain wart as the existing lcd_data.
reg  [7:0] lcd_text_ddram[80];
reg  [7:0] lcd_text_cgram[64]; // CGRAM custom chars, rendered by txt_glyph_row (FIX1)
reg  [7:0] lcd_text_mode;      // 0 = SC-55 (2 rows), 1 = MU50 (4 rows)
reg  [7:0] lcd_text_flags;     // bit0: LCD enable (gates text); bits 4:0: MU50 LEDs (FIX1)
reg         lcd_text_valid;

// 5x7 font, transcribed from Nuked-SC55 lcd_font.h (rows 0..6, bit4=left).
// Covers ASCII 0x20..0x7E only. Packed MSB-first: glyph (ch-0x20), row.
localparam [3324:0] LCD_TEXT_FONT_ROM = 3325'h000000000084210002294a0000052beafa9447d1c5f1319111131b2544564d611000000222108209041084440095754800109f210000000c2200007c00000000018c004444400e8ceb98b88c2108473a211111ff88820c5c232a5f10bf0f043171910f462ef84444210e8c5d18b9d18bc226018c0318003180611022220820800f83e00208208888744222008e885b5ab9d18c7f18fa31f463e74610845dc94631973f087a10ffe10f4210746178c5f18c7f18c5c42108471c4210a4c8ca98a4a308421087e3bad6318c639ace31746318c5de8c7d0841d18c6b26fa31f52517c20e087df21084212318c631746318c5448c635ad5518a88a8c6318a88427c222221f72108421d157c9f211c210842711510000000000003e82080000000705f17c216cc63e001d0845c10b6718bc00747f071928e210803e31785d085b318c480610847080610a4c84254c524c2108423800d56b188016cc631001d18c5c007a3e840006cde108016cc210001d0707c847108498008c633680118c54400231ad54004544544008c5e17001f1111f110882104421084211042088440082f8880;
function [4:0] lcd_text_font_row(input [7:0] ch, input [2:0] row);
	// Only called for non-custom chars (ch >= 0x10); custom chars
	// come from CGRAM via the registered read below (FIX2).
	if (ch < 8'h20 || ch > 8'h7e) lcd_text_font_row = 5'h00;
	else lcd_text_font_row = LCD_TEXT_FONT_ROM[3324 - ((ch - 8'h20)*7 + row)*5 -: 5];
endfunction
//
// FIX1 (timing): pipelined text expansion. The prototype expanded
// text combinationally in one CE_PIXEL cycle - /6 and %6 dividers,
// an asynchronous DDRAM read, and the font-ROM lookup chained into
// mt32_lcd_pix - which failed setup on video_clock (-6.933 ns).
// The pipeline splits that chain into registered stages, each a
// single short operation feeding a register, and uses a 0..5 pixel
// counter instead of division/modulo. Rendered output is
// unchanged: 6 px/char (5 px glyph + 1 px gap), 8 px/row.
//
// FIX2 (CGRAM): FIX1 read CGRAM through txt_glyph_row(), and
// Quartus 17.0's elaborator did not trace the memory read through
// the function call - warning 10036 persisted and the 64x8 CGRAM
// was optimised away entirely (mt32pi memory bits 8,832, no CGRAM
// RAM in the netlist). FIX2 reads CGRAM directly in the clocked
// block into a register, the same synchronous-read shape that
// saved DDRAM in FIX1. A sync CGRAM read needs one more stage
// than FIX1 had (the CGRAM address {char[2:0], row} only exists
// once the DDRAM byte is registered), so the fetch now starts at
// px0 instead of px3:
//   px0: register DDRAM address of the next char
//   px1: register DDRAM byte (synchronous read)
//   px2: register CGRAM address + whether the char is custom
//   px3: register CGRAM byte (synchronous read, direct)
//   px4: register glyph row (CGRAM byte, or font ROM)
//   px5: wrap to the next char (glyph already registered)
// The blanking prefetch of char 0 re-asserts the DDRAM address
// every cycle and runs the remaining four stages on a separate
// counter (txt_blank_stage 0..3), so it converges no matter what
// phase the counter is in when blanking starts; txt_px is held
// at 0 in blanking and the window always opens at px0.
reg  [6:0] txt_ddram_addr; // registered DDRAM read address (sync read)
reg  [7:0] txt_char;       // registered DDRAM byte
reg  [5:0] txt_cgram_addr; // registered CGRAM read address (sync read)
reg  [7:0] txt_cgram_data; // registered CGRAM byte
reg         txt_custom;     // next char is a CGRAM custom char (< 0x10)
reg  [4:0] txt_glyph;      // registered glyph row for the current char
reg  [4:0] txt_col;        // current char column 0..19
reg  [2:0] txt_px;         // pixel within char 0..5
reg  [2:0] txt_blank_stage; // blanking prefetch stage 0..3 (char 0)
//
// DDRAM index for (row, col). MU50: row*20+col, with row*20 built
// from shifts (row*16 + row*4) - no multiplier. SC-55: HD44780
// 2-line addressing, row 0 -> col, row 1 -> 40+col.
function [6:0] txt_ddram_idx(input [2:0] row, input [4:0] col, input [7:0] mode);
	reg [6:0] row20;
	begin
		row20 = ({4'b0000, row} << 4) + ({4'b0000, row} << 2);
		if (mode == 8'd1) txt_ddram_idx = row20 + {2'b00, col};
		else txt_ddram_idx = (row == 3'd0) ? {2'b00, col} : (7'd40 + {2'b00, col});
	end
endfunction
// Glyph row for a DDRAM char. Codes < 0x10 are CGRAM custom chars
// (8 chars x 8 rows, 5 bits/row; address {char[2:0], row} =
// char*8+row), which is how MU50 bar-graph and SC-55 level-meter
// glyphs are drawn; other codes come from the font ROM (blank
// outside 0x20..0x7E). FIX2: the CGRAM byte is read directly in
// the clocked block below (txt_cgram_data), never through a
// function - Quartus 17.0 does not trace a memory read through
// a function call and optimised the CGRAM away (warning 10036).
reg        lcd_sz;

reg        reset_r  = 0;
wire [7:0] mode_req = reset_r ? 8'hA0 : mt32_mode_req ? 8'hA2 : 8'hA1;
wire [7:0] rom_req  = {6'd0, mt32_rom_req};

always @(posedge CLK_AUDIO) begin : i2c_slave
	reg        sda_sr, scl_sr;
	reg        old_sda, old_scl;
	reg        sda, scl;
	reg  [7:0] tmp;
	reg  [3:0] cnt = 0;
	reg [10:0] bcnt = 0;
	reg        ack;
	reg        i2c_rw;
	reg        disp, dispdata;
	reg        textctl, textdata; // PROTOTYPE text-packet state
	reg  [2:0] div;
	reg        old_reset;
	
	old_reset <= reset;
	if(old_reset & ~reset) sda_out <= 1;

	div <= div + 1'd1;
	if(!div) begin
		sda_sr <= USER_IN[0];
		if(sda_sr == USER_IN[0]) sda <= sda_sr;
		old_sda <= sda;

		scl_sr <= USER_IN[3];
		if(scl_sr == USER_IN[3]) scl <= scl_sr;
		old_scl <= scl;

		//start
		if(old_scl & scl & old_sda & ~sda) begin
			cnt <= 9;
			bcnt <= 0;
			ack <= 0;
			i2c_rw <= 0;
			disp <= 0;
			dispdata <= 0;
			textctl <= 0;
			textdata <= 0;
		end

		//stop
		if(old_scl & scl & ~old_sda & sda) begin
			cnt <= 0;
			if(dispdata) begin
				lcd_sz <= ~bcnt[9];
				mt32_lcd_update <= ~mt32_lcd_update;
			end
			if(textdata) begin // PROTOTYPE: text packet complete
				lcd_text_valid <= 1;
				mt32_lcd_update <= ~mt32_lcd_update;
			end
		end

		//data latch
		if(~old_scl && scl && cnt) begin
			tmp <= {tmp[6:0], sda};
			cnt <= cnt - 1'd1;
		end

		if(!cnt) sda_out <= 1;

		//data set
		if(old_scl && ~scl) begin
			sda_out <= 1;
			if(cnt == 1) begin
				if(!bcnt) begin
					if(tmp[7:1] == 'h45 || tmp[7:1] == 'h3c) begin
						disp <= (tmp[7:1] == 'h3c);
						sda_out <= 0;
						mt32_available <= 1;
						ack <= 1;
						i2c_rw <= tmp[0];
						bcnt <= bcnt + 1'd1;
						cnt <= 10;
					end
					else begin
						// wrong address, stop
						cnt <= 0;
					end
				end
				else if(ack) begin
					if(~i2c_rw) begin
						if(disp) begin
							if(bcnt == 1) begin
								// PROTOTYPE: 0x40 = SSD1306 bitmap (existing); 0x00 = text packet.
								dispdata <= (tmp[7:6] == 2'b01);
								textctl  <= (tmp == 8'h00);
								textdata <= 1'b0;
								if(tmp[7:6] == 2'b01) lcd_text_valid <= 1'b0; // bitmap supersedes text
							end
							else if(bcnt == 2 && textctl) begin
								textdata <= (tmp == 8'h54); // 'T' magic
								textctl  <= 1'b0;
							end
							else if(dispdata) lcd_data[bcnt[9:0] - 2'd2] <= tmp;
							else if(textdata) begin
								// payload index = bcnt-3: 0 mode, 1..80 DDRAM, 81..144 CGRAM, 145 flags
								if(bcnt == 11'd3) lcd_text_mode <= tmp;
								else if(bcnt >= 11'd4 && bcnt <= 11'd83) lcd_text_ddram[bcnt[9:0] - 11'd4] <= tmp;
								else if(bcnt >= 11'd84 && bcnt <= 11'd147) lcd_text_cgram[bcnt[9:0] - 11'd84] <= tmp;
								else if(bcnt == 11'd148) lcd_text_flags <= tmp;
							end
						end
						else begin
							if(bcnt == 1) mt32_mode <= tmp;
							if(bcnt == 2) mt32_rom  <= tmp;
							if(bcnt == 3) mt32_sf   <= tmp;
							if(bcnt == 3) mt32_newmode <= ~mt32_newmode;
						end
					end
					if(~&bcnt) bcnt <= bcnt + 1'd1;
					sda_out <= 0;
					cnt <= 10;
				end
			end
			else if(i2c_rw && ack && cnt && ~disp) begin
				if(bcnt == 1) sda_out <= mode_req[cnt[2:0] - 2'd2];
				if(bcnt == 2) sda_out <= rom_req[cnt[2:0] - 2'd2];
				if(bcnt == 3) sda_out <= mt32_sf_req[cnt[2:0] - 2'd2];
				if(bcnt == 3) reset_r <= 0;
			end
		end
	end

	if(reset) begin
		reset_r <= 1;
		mt32_available <= 0;
	end
end

always @(posedge CLK_VIDEO) begin
	reg old_de, old_vs;
	reg [7:0] hcnt;
	reg [6:0] vcnt;
	reg [7:0] sh;
	// FIX1: combinational temps for the text pipeline (single-cycle
	// operations only; the long chain lives in the registered stages).
	reg       txt_in_window;
	reg       txt_pix_bit;
	reg       txt_led_pix;

	if(CE_PIXEL) begin
		old_de <= VGA_DE;
		old_vs <= VGA_VS;

		if(~&hcnt) hcnt <= hcnt + 1'd1;
		sh <= (sh << 1) | (~old_de & VGA_DE);
		if(sh[7]) hcnt <= 0;

		if(old_de & ~VGA_DE & ~&vcnt) vcnt <= vcnt + 1'd1;
		if(~old_vs & VGA_VS) vcnt <= 0;

		// Text window: first 20 chars (120 px) of the active rows.
		// MU50: 4 rows; SC-55: 2 rows. (Pre-edge hcnt/vcnt, same
		// values the bitmap path below uses.)
		txt_in_window = lcd_text_valid && (hcnt[6:0] < 7'd120) &&
			(vcnt[5:3] < ((lcd_text_mode == 8'd1) ? 3'd4 : 3'd2));

		// Pixel bit for the current position, from the registered
		// glyph and pixel counter. The shift amount wraps to 31 when
		// txt_px==5, so the 1 px inter-char gap reads 0.
		txt_pix_bit = lcd_text_flags[0] && txt_in_window &&
			((txt_glyph >> (5'd4 - {2'b00, txt_px})) & 5'd1);

		// MU50 LEDs: 5 squares, 5 px wide + 1 px gap, in the first
		// unused row below the text (page 4, y 32..37), x 0..29.
		// flags bit i = LED i. Panel indicators: shown whenever a
		// text packet is active in MU50 mode, independent of the
		// LCD-enable flag. Only visible in 128x64 mode (page 4 is
		// outside the 128x32 enable window, like MU50 rows 2..3).
		txt_led_pix = lcd_text_valid && (lcd_text_mode == 8'd1) &&
			(vcnt[5:3] == 3'd4) && (vcnt[2:0] < 3'd6) &&
			(((hcnt[6:0] < 7'd5)  && lcd_text_flags[0]) ||
			 ((hcnt[6:0] >= 7'd6  && hcnt[6:0] < 7'd11) && lcd_text_flags[1]) ||
			 ((hcnt[6:0] >= 7'd12 && hcnt[6:0] < 7'd17) && lcd_text_flags[2]) ||
			 ((hcnt[6:0] >= 7'd18 && hcnt[6:0] < 7'd23) && lcd_text_flags[3]) ||
			 ((hcnt[6:0] >= 7'd24 && hcnt[6:0] < 7'd29) && lcd_text_flags[4]));

		mt32_lcd_en  <= mt32_available & ~hcnt[7] && (lcd_sz ? !vcnt[6] : !vcnt[6:5]);
		mt32_lcd_pix <= lcd_text_valid ? (txt_pix_bit | txt_led_pix) : lcd_data[{vcnt[5:3],hcnt[6:0]}][vcnt[2:0]];

		// Text pipeline: fetch the NEXT char during the current
		// char's 6 pixels, one short operation per stage feeding a
		// register (FIX2 staging - CGRAM needs the extra stage):
		//   txt_px==0: register DDRAM address of the next char
		//   txt_px==1: register DDRAM byte (synchronous read)
		//   txt_px==2: register CGRAM address + custom flag
		//   txt_px==3: register CGRAM byte (synchronous read)
		//   txt_px==4: register glyph row (CGRAM or font ROM)
		//   txt_px==5: wrap to the next char (glyph ready)
		// The glyph is therefore ready before the next char's first
		// pixel, and the pixel output above only does a 5:1 mux.
		if(sh[7]) begin
			// New line starts (hcnt resets this edge): restart the
			// char counters. Char 0's glyph was fetched during
			// blanking (else-branch below), so it is already ready.
			txt_col <= 5'd0;
			txt_px  <= 3'd0;
		end else if(txt_in_window) begin
			if(txt_px == 3'd0 && txt_col < 5'd19)
				txt_ddram_addr <= txt_ddram_idx(vcnt[5:3], txt_col + 5'd1, lcd_text_mode);
			if(txt_px == 3'd1)
				txt_char <= lcd_text_ddram[txt_ddram_addr];
			if(txt_px == 3'd2) begin
				txt_cgram_addr <= {txt_char[2:0], vcnt[2:0]};
				txt_custom <= (txt_char < 8'h10);
			end
			if(txt_px == 3'd3)
				txt_cgram_data <= lcd_text_cgram[txt_cgram_addr];
			if(txt_px == 3'd4)
				txt_glyph <= txt_custom ? txt_cgram_data[4:0] : lcd_text_font_row(txt_char, vcnt[2:0]);
			if(txt_px == 3'd5) begin
				txt_px  <= 3'd0;
				txt_col <= txt_col + 5'd1;
			end else begin
				txt_px <= txt_px + 3'd1;
			end
		end else begin
			// Outside the text window (blanking, or past col 19):
			// prefetch char 0 of the current row. The DDRAM address
			// is re-asserted EVERY blanking cycle, so the remaining
			// stages (char -> CGRAM addr -> CGRAM byte -> glyph)
			// always read char 0 no matter what phase
			// txt_blank_stage is in when blanking starts (after a
			// window it holds the last in-window fetch state, e.g.
			// addr = idx(19) - a pass starting mid-sequence would
			// otherwise compute char 0's glyph from char 19).
			// The glyph therefore converges within a few cycles of
			// blanking (worst case ~8), well before the next line's
			// first active pixel; real blanking is >100 CE_PIXEL
			// cycles. txt_px is held at 0 here, so the window
			// always opens at px0. Only for rows this mode
			// displays: other rows would address DDRAM past entry
			// 79 (MU50 row 4 = index 80).
			if (vcnt[5:3] < ((lcd_text_mode == 8'd1) ? 3'd4 : 3'd2)) begin
				txt_ddram_addr <= txt_ddram_idx(vcnt[5:3], 5'd0, lcd_text_mode);
				if(txt_blank_stage == 3'd0)
					txt_char <= lcd_text_ddram[txt_ddram_addr];
				if(txt_blank_stage == 3'd1) begin
					txt_cgram_addr <= {txt_char[2:0], vcnt[2:0]};
					txt_custom <= (txt_char < 8'h10);
				end
				if(txt_blank_stage == 3'd2)
					txt_cgram_data <= lcd_text_cgram[txt_cgram_addr];
				if(txt_blank_stage == 3'd3)
					txt_glyph <= txt_custom ? txt_cgram_data[4:0] : lcd_text_font_row(txt_char, vcnt[2:0]);
				if(txt_blank_stage == 3'd3)
					txt_blank_stage <= 3'd0;
				else
					txt_blank_stage <= txt_blank_stage + 3'd1;
			end else begin
				txt_blank_stage <= 3'd0;
			end
			txt_col <= 5'd0;
			txt_px  <= 3'd0;
		end
	end
end

endmodule
