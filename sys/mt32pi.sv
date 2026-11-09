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
reg  [7:0] lcd_text_cgram[64]; // captured, not yet rendered (TODO)
reg  [7:0] lcd_text_mode;      // 0 = SC-55 (2 rows), 1 = MU50 (4 rows)
reg  [7:0] lcd_text_flags;     // bit0: LCD enable; bits 4:0: MU50 LEDs (TODO)
reg         lcd_text_valid;

// 5x7 font, transcribed from Nuked-SC55 lcd_font.h (rows 0..6, bit4=left).
// Covers ASCII 0x20..0x7E only. Packed MSB-first: glyph (ch-0x20), row.
localparam [3324:0] LCD_TEXT_FONT_ROM = 3325'h000000000084210002294a0000052beafa9447d1c5f1319111131b2544564d611000000222108209041084440095754800109f210000000c2200007c00000000018c004444400e8ceb98b88c2108473a211111ff88820c5c232a5f10bf0f043171910f462ef84444210e8c5d18b9d18bc226018c0318003180611022220820800f83e00208208888744222008e885b5ab9d18c7f18fa31f463e74610845dc94631973f087a10ffe10f4210746178c5f18c7f18c5c42108471c4210a4c8ca98a4a308421087e3bad6318c639ace31746318c5de8c7d0841d18c6b26fa31f52517c20e087df21084212318c631746318c5448c635ad5518a88a8c6318a88427c222221f72108421d157c9f211c210842711510000000000003e82080000000705f17c216cc63e001d0845c10b6718bc00747f071928e210803e31785d085b318c480610847080610a4c84254c524c2108423800d56b188016cc631001d18c5c007a3e840006cde108016cc210001d0707c847108498008c633680118c54400231ad54004544544008c5e17001f1111f110882104421084211042088440082f8880;
function [4:0] lcd_text_font_row(input [7:0] ch, input [2:0] row);
	if (ch < 8'h10) lcd_text_font_row = 5'h1f;               // CGRAM: solid block (PROTOTYPE)
	else if (ch < 8'h20 || ch > 8'h7e) lcd_text_font_row = 5'h00;
	else lcd_text_font_row = LCD_TEXT_FONT_ROM[3324 - ((ch - 8'h20)*7 + row)*5 -: 5];
endfunction
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
	reg [6:0] txt_idx;  // PROTOTYPE text expansion
	reg [7:0] txt_char;
	reg [4:0] txt_glyph;
	reg       txt_pix;

	if(CE_PIXEL) begin
		old_de <= VGA_DE;
		old_vs <= VGA_VS;

		if(~&hcnt) hcnt <= hcnt + 1'd1;
		sh <= (sh << 1) | (~old_de & VGA_DE);
		if(sh[7]) hcnt <= 0;

		if(old_de & ~VGA_DE & ~&vcnt) vcnt <= vcnt + 1'd1;
		if(~old_vs & VGA_VS) vcnt <= 0;

		// PROTOTYPE (option C): expand text RAM to pixels. 6 px/char, 8 px/row.
		// MU50: DDRAM rows are 20 chars. SC-55: HD44780 2-line addressing.
		// Out-of-window pixels read DDRAM[0] harmlessly and are forced to 0.
		if (lcd_text_valid && (hcnt[6:0] / 6) < 20 && vcnt[5:3] < ((lcd_text_mode == 8'd1) ? 3'd4 : 3'd2)) begin
			if (lcd_text_mode == 8'd1) txt_idx = vcnt[5:3]*20 + (hcnt[6:0] / 6);
			else txt_idx = (vcnt[5:3] == 3'd0) ? (hcnt[6:0] / 6) : (7'd40 + (hcnt[6:0] / 6));
			txt_char = lcd_text_ddram[txt_idx[6:0]];
			txt_glyph = lcd_text_font_row(txt_char, vcnt[2:0]);
			txt_pix = ((hcnt[6:0] % 6) < 6'd5) && ((txt_glyph >> (4 - (hcnt[6:0] % 6))) & 5'd1);
		end else begin
			txt_pix = 1'b0;
		end

		mt32_lcd_en  <= mt32_available & ~hcnt[7] && (lcd_sz ? !vcnt[6] : !vcnt[6:5]);
		mt32_lcd_pix <= lcd_text_valid ? txt_pix : lcd_data[{vcnt[5:3],hcnt[6:0]}][vcnt[2:0]];
	end
end

endmodule
