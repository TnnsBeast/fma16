/*
Author: Neil Chulani
Date: April 21, 2025
Email: njcf2022@mymail.pomona.edu

Purpose: Half-precision FMA optimized for low power for computer graphics.  Accepts three half-precision (16-bit) floating-point numbers X, Y, and Z, and computes XY+Z

High Level Architecture: 
1. Use the control signals to construct 'real' inputs to the FMA
2. Split the 'real' inputs into their signs, exponents, and create their mantissas
3. Multiply X and Y to get P (product)
4. Align Z with P, call this A (aligned)
5. Add P and A to get S (sum)
6. Use a priority encoder to detect leading 0s and normalize S
7. Check for special cases
8. Round
9. Set flags based on special cases and normalization
*/

module fma16(
  input  logic [15:0] x, y, z,                // three half precision 16 bit floating point input values
  input  logic        mul, add, negp, negz,   // control signals
  input  logic [1:0]  roundmode,              // 00 = RZ, 01 = RNE, 10 = RD, 11 = RU
  output logic [15:0] result,                 // half precision 16 bit floating point output
  output logic [3:0]  flags                   // output flags: {Invalid, Overflow, Underflow, Inexact}
);

  logic [15:0] y2, z2, x2, z3; // Intermediate values for control signals
  
  // Force y and/or z to 1 and/or 0 respectively to turn on/off add/mul
  always_comb begin : control_mul_add
    if (!mul) 
      y2 = 16'h3C00;
    else      
      y2 = y;
    if (!add) 
      z2 = 16'h0000;
    else      
      z2 = z;
  end

  // Flip signs of x and/or z for negp and negz
  always_comb begin : control_neg
    if (negp) 
      x2 = x ^ 16'h8000; 
    else      
      x2 = x;
    if (negz) 
      z3 = z2 ^ 16'h8000;
    else      
      z3 = z2;
  end
  
  // Handle subnorm inputs (got most of this working before realizing we didn't need to implement it)
  // While subnorms have not been rigorously tested, this module does support subnorm inputs
  // It does not support subnorm outputs
  // Split logic
  logic [10:0] Xm, Ym, Zm;
  logic [4:0] Xe, Ye, Ze;
  logic Xs, Ys, Zs;
  assign Xm = (x2[14:10] == 5'b0) ? {1'b0, x2[9:0]} : {1'b1, x2[9:0]};
  assign Ym = (y2[14:10] == 5'b0) ? {1'b0, y2[9:0]} : {1'b1, y2[9:0]};
  assign Zm = (z3[14:10] == 5'b0) ? {1'b0, z3[9:0]} : {1'b1, z3[9:0]}; 
  assign Xe = x2[14:10];
  assign Ye = y2[14:10];
  assign Ze = z3[14:10];
  assign Xs = x2[15];
  assign Ys = y2[15];
  assign Zs = z3[15];
  logic [4:0] Xe_eff, Ye_eff, Ze_eff;
  assign Xe_eff = (Xe == 5'b0) ? 5'd1 : Xe;
  assign Ye_eff = (Ye == 5'b0) ? 5'd1 : Ye;
  assign Ze_eff = (Ze == 5'b0) ? 5'd1 : Ze;

  // Get the product's exponent and mantissa, adjusting if exponent is too small (allows for subnorm inputs)
  // Store the product in a large placeholder, PBigm, which will be used for adding
  logic [21:0] Pm_temp;
  assign Pm_temp = Xm * Ym;
  logic [5:0] Pe_temp;
  logic [5:0] Pe_val;
  assign Pe_temp = Xe_eff + Ye_eff;
  logic [68:0] TempAm, Am, PBigm;
  logic [4:0] shiftamt;
  always_comb begin : fix_Pe
    if (Pe_temp < 15) begin
      shiftamt = 5'(15-Pe_temp);
      Pe_val = 6'b0;
      PBigm = {31'b0, Pm_temp, 16'b0} >> shiftamt;
    end else begin
      shiftamt = 0;
      Pe_val = Pe_temp - 6'd15;
      PBigm = {31'b0, Pm_temp, 16'b0}; 
    end
  end
  
  // Get the product's sign
  logic Ps;
  assign Ps = Xs ^ Ys;

  // The goal of this is to align both Am and PBigm as 33.36, with an exponent of Pe_val so that we can add easily
  // So for PBigm we just have to pad Pm with some zeros, but for Z we have to align based on Ze and Pe_val to get Am
  logic [5:0] Acnt;
  assign TempAm = {32'b0, Zm, 26'b0};
  logic [5:0] Ze_eff_big;
  assign Ze_eff_big = {1'b0, Ze_eff};
  always_comb begin : align
    if (Pe_val > Ze_eff_big) begin
      Acnt = Pe_val - Ze_eff; 
      Am = TempAm >> Acnt;
    end else begin
      Acnt = Ze_eff - Pe_val; 
      Am = TempAm << Acnt;
    end
  end
  // At this point both Am and PBigm are 33.36, both with exponent of Pe_val, so we can add directly

  // SM will be 34.36 after adding
  logic [69:0] Sm;
  logic Fs;
  always_comb begin : add_product_and_aligned_z
    // If z is zero, the sum is just PBigm
    // Use reduction or to check if bottom 15 bits are all 0
    if (~| z3[14:0]) begin
      Sm = {1'b0, PBigm};
      Fs = Ps;
    end 
    else begin
      // If z and the product have the same sign, add their magnitudes and keep the shared sign
      if (Zs == Ps) begin
        Sm = PBigm + Am;
        Fs = Zs;
      end 
      else begin
        // When the signs differ, subtract the smaller magnitude from the larger, and use the larger magnitude's sign
        if (Am > PBigm) begin
          Sm = Am - PBigm;
          Fs = Zs;
        end 
        else begin
          Sm = PBigm - Am;
          Fs = Ps;
        end
      end
    end
  end

  // Now, Sm and Fs are our sum's mantissa and sum's sign respectively. 
  // Next we find the leading one to normalize and shift
  // The best way to do this is to use a priority encoder. I use a slightly modified lzc from Wally that doesn't take variable width as input
  logic [9:0] final_frac;
  logic [5:0] finale;
  logic [6:0] zero_cnt, shift_base; // zero_cnt is the number of leading zeros, shift_base helps find the rounding bits
  logic zero_sm;
  assign zero_sm = ~|Sm;
  logic l,g,r,t;
  logic [69:0] mask;
  lzc priority_enc(Sm, zero_cnt);

  always_comb begin
    if (zero_sm) begin
      final_frac = 10'b0;
      finale     = 6'd0;
      shift_base = 0;
      mask = 0;
      l = 1'b0;    // LSB
      g = 1'b0;    // guard
      r = 1'b0;    // round
      t = 1'b0;    // sticky
    end else begin
      final_frac = Sm[68-zero_cnt -: 10];
      finale = Pe_val + 6'(33 - zero_cnt);
      l = final_frac[0];
      shift_base = 68-zero_cnt;
      g = (shift_base >= 10) ? Sm[shift_base - 10] : 1'b0;
      r = (shift_base >= 11) ? Sm[shift_base - 11] : 1'b0;
      if (shift_base >= 12) begin
        mask = {70{1'b1}} >> (70 - (shift_base - 11)); // Create a mask to extract all of the bits to the left of the rounding bit. Use this to determine the sticky bit
        t = |(Sm & mask);
      end else begin 
        mask = 0;
        t = 1'b0;
      end
    end
  end
  /* 
  This was my original approach to shifting SM using a for loop, which 
  is the same logic that Wally uses: a leading zero counter
  It implies a lot of hardware (70 different comparators and muxes).

  always_comb begin : normshift
    final_frac = 10'b0;
    finale = 6'b0;
    for (int i = 69; i >= 1; i--) begin
      if (Sm[i]) begin
        // Extract 10 bits of fraction starting just after the leading 1
        final_frac = Sm[i-1 -: 10];
        // Adjust the exponent based on the location of the leading one
        finale = Pe_val + 6'(i - 36);
        break;
      end
    end
  end
  */

  /* 
  Instead, I use a similar approach to binary search, which checks for a one in 
  the top half, then the top quarter, then the top eigth, etc, until we find the
  index of the leading 1. 

  The priority encoder which is used should be faster than this, but I spent a good amount of time designing this and don't want to just delete it :)
  Plus, I'd like to see what each synthesizes to
  */
  // logic [127:0] SM_padded;
  // assign SM_padded = {58'b0, Sm};     // pad Sm to make it a power of 2
  // logic [6:0]   leading_index;        // will hold the 0–69 index
  // logic [127:0] rem;                  // working remainder
  // logic l,g,r,t;                      // used for rounding
  // logic [69:0] mask;                  // will be used for calculating sticky bit

  // always_comb begin : normshift_binarysearch
  //   final_frac = 10'b0;
  //   finale     = 6'b0;
  //   rem        = SM_padded;
  //   {l,g,r,t} = 4'b0;
  //   mask = 0;
  //   // test bits [127:64] vs [63:0]. 
  //   // If there is a 1 in the top half, then we will keep it in the remaining bits and mark that our msb of leading_index is 1. 
  //   // If not, we will use the bottom half as our remaining bits to check
  //   if (|rem[127:64]) begin
  //     leading_index[6] = 1;
  //     rem = {64'b0, rem[127:64]};
  //   end else begin
  //     leading_index[6] = 0;
  //     rem = {64'b0, rem[63:0]};
  //   end

  //   // test rem[63:32] vs rem[31:0]
  //   if (|rem[63:32]) begin
  //     leading_index[5] = 1;
  //     rem = {96'b0, rem[63:32]};
  //   end else begin
  //     leading_index[5] = 0;
  //     rem = {96'b0, rem[31:0]};
  //   end

  //   // 32→16
  //   if (|rem[31:16]) begin
  //     leading_index[4] = 1;
  //     rem = {112'b0, rem[31:16]};
  //   end else begin
  //     leading_index[4] = 0;
  //     rem = {112'b0, rem[15:0]};
  //   end

  //   // ...
  //   if (|rem[15:8]) begin
  //     leading_index[3] = 1;
  //     rem = {120'b0, rem[15:8]};
  //   end else begin
  //     leading_index[3] = 0;
  //     rem = {120'b0, rem[7:0]};
  //   end

  //   if (|rem[7:4]) begin
  //     leading_index[2] = 1;
  //     rem = {124'b0, rem[7:4]};
  //   end else begin
  //     leading_index[2] = 0;
  //     rem = {124'b0, rem[3:0]};
  //   end

  //   if (|rem[3:2]) begin
  //     leading_index[1] = 1;
  //     rem = {126'b0, rem[3:2]};
  //   end else begin
  //     leading_index[1] = 0;
  //     rem = {126'b0, rem[1:0]};
  //   end

  //   leading_index[0] = rem[1] ? 1'b1 : 1'b0;

  //   // Now leading_index is the index of the leading 1 in SM. Use this index to get the 10 bits we need, calculate the exponent, and keep track of rounding bits
  //   if (|Sm) begin
  //     final_frac = Sm[leading_index-1 -: 10];
  //     finale = Pe_val + 6'(leading_index - 36);
  //     l = final_frac[0];
  //     g = (leading_index > 11) ? Sm[leading_index - 11] : 1'b0;
  //     r = (leading_index > 12) ? Sm[leading_index - 12] : 1'b0;
  //     // For the sticky bit, we need to or all of the bits to the right of the rounding bit
  //     // To do this, we build a 70 bit mask, which has 1's in all positions from [leading_index-13:0]
  //     // We can then or all of the bits of (Sm & mask), which would be or-ing all of the bits to the right of the rounding bit
  //     if (leading_index >= 13) begin
  //       mask = {70{1'b1}} >> (70 - (leading_index - 12));
  //       t = |(Sm & mask);
  //     end else begin
  //       t = 1'b0;
  //     end
  //   end
  // end

  // Handle all special cases, keeping track of overflow, special, and invalid cases for flags and rounding
  logic overflow, special, invalid, inexact;
  logic [15:0] unrounded_result;
  logic is_nan_x, is_nan_y, is_nan_z;
  logic is_sig_nan_x, is_sig_nan_y, is_sig_nan_z;
  logic inf_x, inf_y, inf_z;
  logic zero_x, zero_y;

  // Create registers for checking special cases to avoid re-checking the same bits
  assign is_nan_x = (Xe == 5'b11111) && (x2[9:0] != 10'b0);
  assign is_nan_y = (Ye == 5'b11111) && (y2[9:0] != 10'b0);
  assign is_nan_z = (Ze == 5'b11111) && (z3[9:0] != 10'b0); 

  assign is_sig_nan_x = is_nan_x && ~x2[9];
  assign is_sig_nan_y = is_nan_y && ~y2[9];
  assign is_sig_nan_z = is_nan_z && ~z3[9];

  assign inf_x   = (Xe == 5'b11111) && (x2[9:0] == 10'b0);
  assign inf_y   = (Ye == 5'b11111) && (y2[9:0] == 10'b0);
  assign inf_z   = (Ze == 5'b11111) && (z3[9:0] == 10'b0);

  assign zero_x  = (Xe == 5'b00000) && (x2[9:0] == 10'b0);
  assign zero_y  = (Ye == 5'b00000) && (y2[9:0] == 10'b0);
  // assign neg_zero_z  = z3 == 16'h8000;

  always_comb begin : specialcases
    overflow        = 0;
    special         = 1;
    invalid = 0;
    if ((zero_x && inf_y) || (zero_y && inf_x)) begin
      unrounded_result = 16'h7E00;
      invalid = 1; // 0 * inf or inf * 0
    end else if (is_nan_x || is_nan_y || is_nan_z) begin
      unrounded_result = 16'h7E00;
      if (is_sig_nan_x || is_sig_nan_y || is_sig_nan_z) invalid = 1; // at least one signaling nan
    end else if (inf_x || inf_y) begin
      if (inf_z && (Zs != Ps)) begin
        unrounded_result = 16'h7E00;
        invalid = 1; // x or y is inf, and z has opposite sign of product inf
      end else begin
        unrounded_result = {Ps, 5'b11111, 10'b0};
      end
    end else if (inf_z) begin
      unrounded_result = z3;
    end else if (finale > 6'd30) begin
      overflow = 1'b1; // overflow
      unrounded_result = Fs ? 16'hFBFF : 16'h7BFF;
    end else if ((finale == 6'b0) && (final_frac == 10'b0)) begin
      unrounded_result = 16'h0000; // when 0, always return +0
    // end else if ((zero_x || zero_y) && (neg_zero_z)) begin
    //   unrounded_result = neg_zero_z;  
    end else begin
      unrounded_result = {Fs, finale[4:0], final_frac};
      special          = 1'b0;
    end
  end

  // Figure out what we need to do for rounding
  logic do_trunc, do_round, do_maxnum, do_infinity, sign;
  assign sign = unrounded_result[15];
  always_comb begin
    do_trunc    = 1'b0;
    do_round    = 1'b0;
    do_maxnum   = 1'b0;
    do_infinity = 1'b0;

    if (overflow) begin
      // overflow: choose MAXNUM or INFINITY
      case (roundmode)
        2'b00: // RZ: toward zero
          do_maxnum = 1'b1;
        2'b01: // RNE: nearest
          do_infinity = 1'b1;
        2'b10: // RD: toward -inf
          if (sign)    do_infinity = 1'b1;
          else         do_maxnum  = 1'b1;
        2'b11: // RU: toward +inf
          if (!sign)   do_infinity = 1'b1;
          else         do_maxnum  = 1'b1;
      endcase
    end
    else begin
      // no overflow: choose TRUNC or RND
      case (roundmode)
        2'b00: // RZ
          do_trunc = 1'b1;
        2'b01: // RNE
          if (g && (r || t || l)) do_round = 1'b1;
          else                    do_trunc = 1'b1;
        2'b10: // RD
          if (sign && (g || r || t)) do_round = 1'b1;
          else                       do_trunc = 1'b1;
        2'b11: // RU
          if (!sign && (g || r || t)) do_round = 1'b1;
          else                        do_trunc = 1'b1;
      endcase
    end
  end

  logic [4:0] unrounded_exp;
  logic [9:0] unrounded_frac;
  assign unrounded_exp  = unrounded_result[14:10];
  assign unrounded_frac = unrounded_result[9:0];

  // compute rounded‑up fraction & exponent
  logic [9:0] incr_frac;
  logic [4:0] incr_exp;
  always_comb begin
    incr_frac = unrounded_frac;
    incr_exp  = unrounded_exp;
    if (do_round && !special) begin
      // add 1 to smallest place
      incr_frac = unrounded_frac + 10'd1;
      // if mantissa overflowed, carry into exponent
      if (incr_frac == 10'd0)  
        incr_exp = unrounded_exp + 5'd1;
    end
  end

  // Check if we had overflow that resulted from rounding, which is different than the overflow from earlier
  logic rounded_overflow;
  always_comb begin
    if (!special && do_round && (incr_exp == 5'b11111)) rounded_overflow = 1'b1;
    else rounded_overflow = 0;
  end

  // Put everything together based on rounding
  always_comb begin
    result = unrounded_result;
    if (do_infinity) begin
      result = {sign, 5'b11111, 10'b0};
    end
    else if (do_maxnum) begin
      result = {sign, 5'b11110, 10'b1111111111};
    end
    else if (do_round) begin
      result = {sign, incr_exp, incr_frac};
    end
    else begin
      result = unrounded_result;
    end
  end
  
  // Determine flags
  assign inexact = t | g | r | overflow;
  always_comb begin : calc_flags
    if (invalid) flags = 4'd8;
    else if (overflow | rounded_overflow) flags = 4'd5;
    else if (inexact & ~special) flags = 4'd1;
    else flags = 4'd0;
  end

endmodule


module lzc (
  input  logic [69:0] num,    // number to count the leading zeroes of
  output logic [6:0]  ZeroCnt // the number of leading zeroes
);

  integer i;
  
  always_comb begin
    i = 0;
    while ((i < 70) & ~num[70-1-i]) i = i+1;  // search for leading one
    ZeroCnt = i[6:0];
  end
endmodule