/*
Author: Neil Chulani
Date: April 28, 2025
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
  input  logic [15:0] x, y, z,                // three half‑precision FP16 operands
  input  logic        mul, add, negp, negz,   // control signals
  input  logic [1:0]  roundmode,              // 00 = RZ, 01 = RNE, 10 = RD, 11 = RU
  output logic [15:0] result,                 // FP16 result
  output logic [3:0]  flags                   // output flags: {Invalid, Overflow, Underflow, Inexact}
);

  /* ----------------------------------------------------------------
   * 1. Build “real” inputs after considering the top‑level control
   * ----------------------------------------------------------------*/
  logic [15:0] x2, y2, z3;
  handle_control_signals hcs_i(.x(x), .y(y), .z(z), .mul(mul), .add(add), .negp(negp), .negz(negz), .real_x(x2), .real_y(y2), .real_z(z3));

  /* ----------------------------------------------------------------
   * 2. Split into sign, exponent, mantissa (+ sub‑norm helpers)
   * ----------------------------------------------------------------*/
  logic [10:0] Xm, Ym, Zm;
  logic [4:0]  Xe, Ye, Ze;
  logic [4:0] Xe_eff, Ye_eff, Ze_eff;
  logic        Xs, Ys, Zs;

  assign Xm = (x2[14:10]==5'd0) ? {1'b0,x2[9:0]} : {1'b1,x2[9:0]};
  assign Ym = (y2[14:10]==5'd0) ? {1'b0,y2[9:0]} : {1'b1,y2[9:0]};
  assign Zm = (z3[14:10]==5'd0) ? {1'b0,z3[9:0]} : {1'b1,z3[9:0]};

  assign Xe = x2[14:10]; 
  assign Ye = y2[14:10]; 
  assign Ze = z3[14:10];
  
  assign Xe_eff = (Xe==5'd0) ? 5'd1 : Xe;
  assign Ye_eff = (Ye==5'd0) ? 5'd1 : Ye;
  assign Ze_eff = (Ze==5'd0) ? 5'd1 : Ze;

  assign Xs = x2[15];     
  assign Ys = y2[15];     
  assign Zs = z3[15];

  /* ----------------------------------------------------------------
   * 3. Multiply (X*Y)
   * ----------------------------------------------------------------*/
  logic [68:0] PBigm;
  logic [5:0]  Pe_val;
  logic        Ps;

  compute_product multiply(.Xe_eff(Xe_eff), .Ye_eff(Ye_eff),.Xm(Xm), .Ym(Ym),.Xs(Xs), .Ys(Ys),.PBigm(PBigm), .Pe_val(Pe_val), .Ps(Ps));

  /* ----------------------------------------------------------------
   * 4. Align Z to the product
   * ----------------------------------------------------------------*/
  logic [68:0] Am;
  align_z align(.Zm(Zm), .Ze_eff(Ze_eff), .Pe_val(Pe_val),.Am(Am));

  /* ----------------------------------------------------------------
   * 5. Add (P+Z)
   * ----------------------------------------------------------------*/
  logic [69:0] Sm;
  logic        Fs;

  add_product_and_aligned_z add_p_z(.z3_bits(z3[14:0]),.Ps(Ps), .Zs(Zs),.Am(Am), .PBigm(PBigm),.Sm(Sm), .Fs(Fs));

  /* ----------------------------------------------------------------
   * 6. Normalize
   * ----------------------------------------------------------------*/
  logic  l,g,r,t;
  logic [9:0] final_frac;
  logic [5:0] finale;

  normalize norm_shift(.Sm(Sm), .Pe_val(Pe_val),.l(l), .g(g), .r(r), .t(t),.final_frac(final_frac),.finale(finale));

  /* ----------------------------------------------------------------
   * 7. Detect specials cases
   * ----------------------------------------------------------------*/
  logic is_nan_x,  is_nan_y,  is_nan_z;
  logic is_sig_nan_x, is_sig_nan_y, is_sig_nan_z;
  logic inf_x, inf_y, inf_z;
  logic zero_x, zero_y;

  assign is_nan_x = (Xe==5'h1F) && (x2[9:0]!=0);
  assign is_nan_y = (Ye==5'h1F) && (y2[9:0]!=0);
  assign is_nan_z = (Ze==5'h1F) && (z3[9:0]!=0);

  assign is_sig_nan_x = is_nan_x && ~x2[9];
  assign is_sig_nan_y = is_nan_y && ~y2[9];
  assign is_sig_nan_z = is_nan_z && ~z3[9];

  assign inf_x   = (Xe==5'h1F) && (x2[9:0]==0);
  assign inf_y   = (Ye==5'h1F) && (y2[9:0]==0);
  assign inf_z   = (Ze==5'h1F) && (z3[9:0]==0);

  assign zero_x  = (Xe==5'd0)  && (x2[9:0]==0);
  assign zero_y  = (Ye==5'd0)  && (y2[9:0]==0);

  logic [15:0] unrounded_result;
  logic        sc_overflow, sc_special, sc_invalid;

  special_cases specialcases(.zero_x(zero_x), .zero_y(zero_y),.is_nan_x(is_nan_x), .is_nan_y(is_nan_y), .is_nan_z(is_nan_z),.is_sig_nan_x(is_sig_nan_x), .is_sig_nan_y(is_sig_nan_y), .is_sig_nan_z(is_sig_nan_z),.inf_x(inf_x), .inf_y(inf_y), .inf_z(inf_z),.finale(finale), .final_frac(final_frac),.Fs(Fs), .Ps(Ps), .Zs(Zs), .z3(z3),.unrounded_result(unrounded_result),.overflow(sc_overflow),.special_flag(sc_special),.invalid(sc_invalid));

  /* ----------------------------------------------------------------
   * 8. Handle rounding
   * ----------------------------------------------------------------*/
  logic r_overflow;   // overflow introduced *by* rounding
  logic inexact_flag;

  rounding_unit round(.unrounded_result(unrounded_result),.special(sc_special),.overflow_in(sc_overflow),.roundmode(roundmode),.l(l), .g(g), .r(r), .t(t),.final_result(result),.rounded_overflow(r_overflow),.inexact(inexact_flag));

  /* ----------------------------------------------------------------
   * 9. Compute flags
   * ----------------------------------------------------------------*/
  flag_unit compute_flags(.invalid(sc_invalid),.overflow(sc_overflow),.rounded_overflow(r_overflow),.inexact(inexact_flag),.special(sc_special),.flags(flags));

endmodule 

module handle_control_signals (
  input logic [15:0]  x, y, z,                // three FMA inputs
  input logic         mul, add, negp, negz,   // control signals
  output logic [15:0] real_x, real_y, real_z  // 
);

  logic [15:0] int_z;
  // Assign 
  always_comb begin : control_mul_add
    if (!mul) 
      real_y = 16'h3C00;
    else      
      real_y = y;
    if (!add) 
      int_z = 16'h0000;
    else      
      int_z = z;
  end

  // Flip signs of x and/or z for negp and negz
  always_comb begin : control_neg
    if (negp) 
      real_x = x ^ 16'h8000; 
    else      
      real_x = x;
    if (negz) 
      real_z = int_z ^ 16'h8000;
    else      
      real_z = int_z;
  end
endmodule

module compute_product (
  input logic [4:0] Xe_eff, Ye_eff,
  input logic [10:0] Xm, Ym, 
  input logic Xs, Ys,
  output logic [68:0] PBigm,
  output logic [5:0] Pe_val,
  output logic Ps
);

  logic [21:0] Pm;
  assign Pm = Xm * Ym;

  logic [5:0] Pe_temp;
  assign Pe_temp = Xe_eff + Ye_eff;

  logic [4:0] shiftamt;
  always_comb begin : fix_Pe
    if (Pe_temp < 15) begin
      shiftamt = 5'(15-Pe_temp);
      Pe_val = 6'b0;
      PBigm = {31'b0, Pm, 16'b0} >> shiftamt;
    end else begin
      shiftamt = 0;
      Pe_val = Pe_temp - 6'd15;
      PBigm = {31'b0, Pm, 16'b0}; 
    end
  end

  assign Ps = Xs ^ Ys;
endmodule

module align_z (
  input logic [10:0] Zm,
  input logic [4:0] Ze_eff,
  input logic [5:0] Pe_val,
  output logic [68:0] Am
);

  logic [68:0] TempAm;
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
endmodule

module add_product_and_aligned_z (
  input logic [14:0] z3_bits,
  input logic Ps,
  input logic Zs,
  input logic [68:0] Am, PBigm, 
  output logic [69:0] Sm,
  output logic Fs
);
  always_comb begin
    // If z is zero, the sum is just PBigm
    if (~| z3_bits) begin
      Sm = {1'b0, PBigm};
      Fs = Ps;
    end 
    else begin
      if (Zs == Ps) begin
        Sm = PBigm + Am;
        Fs = Zs;
      end 
      else begin
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
endmodule

module normalize (
  input logic [69:0] Sm,
  input logic [5:0] Pe_val,
  output logic l,g,r,t,
  output logic [9:0] final_frac,
  output logic [5:0] finale
);
  logic [6:0] zero_cnt, shift_base;
  logic zero_sm;
  assign zero_sm = ~|Sm;
  logic [69:0] mask;
  lzc priority_enc(Sm, zero_cnt);

  always_comb begin
    if (zero_sm) begin
      final_frac = 10'b0;
      finale     = 6'd0;
      shift_base = 0;
      mask = 0;
      l = 1'b0;    g = 1'b0;    r = 1'b0;    t = 1'b0;
    end else begin
      final_frac = Sm[68-zero_cnt -: 10];
      finale = Pe_val + 6'(33 - zero_cnt);
      l = final_frac[0];
      shift_base = 68-zero_cnt;
      g = (shift_base >= 10) ? Sm[shift_base - 10] : 1'b0;
      r = (shift_base >= 11) ? Sm[shift_base - 11] : 1'b0;
      if (shift_base >= 12) begin
        mask = {70{1'b1}} >> (70 - (shift_base - 11));
        t = |(Sm & mask);
      end else begin 
        mask = 0;
        t = 1'b0;
      end
    end
  end
endmodule

module lzc (
  input  logic [69:0] num,
  output logic [6:0]  ZeroCnt
);
  integer i;
  always_comb begin
    i = 0;
    while ((i < 70) & ~num[69-i]) i = i+1;
    ZeroCnt = i[6:0];
  end
endmodule

module special_cases(
  input  logic zero_x, zero_y,
  input  logic is_nan_x, is_nan_y, is_nan_z,
  input  logic is_sig_nan_x, is_sig_nan_y, is_sig_nan_z,
  input  logic inf_x, inf_y, inf_z,
  input  logic [5:0] finale,
  input  logic [9:0] final_frac,
  input  logic Fs, Ps, Zs,
  input  logic [15:0] z3,

  output logic [15:0] unrounded_result,
  output logic        overflow,
  output logic        special_flag,
  output logic        invalid
);
  always_comb begin
    overflow      = 1'b0;
    special_flag  = 1'b1;
    invalid       = 1'b0;
    unrounded_result = 16'h0;

    /* 0 × Inf or Inf × 0 ---------------------------------------*/
    if ( (zero_x && inf_y) || (zero_y && inf_x) ) begin
      unrounded_result = 16'h7E00;   // qNaN
      invalid          = 1'b1;
    end
    /* Any NaN input --------------------------------------------*/
    else if ( is_nan_x || is_nan_y || is_nan_z ) begin
      unrounded_result = 16'h7E00;   // qNaN
      if ( is_sig_nan_x || is_sig_nan_y || is_sig_nan_z )
        invalid = 1'b1;
    end
    /* X*Y is Inf -----------------------------------------------*/
    else if ( inf_x || inf_y ) begin
      if ( inf_z && (Zs != Ps) ) begin
        unrounded_result = 16'h7E00; // inf – inf  → NaN
        invalid = 1'b1;
      end else begin
        unrounded_result = {Ps,5'h1F,10'd0}; // ±Inf
      end
    end
    /* Z is Inf --------------------------------------------------*/
    else if ( inf_z ) begin
      unrounded_result = z3;          // propagate ±Inf
    end
    /* Exponent overflow prior to rounding ----------------------*/
    else if ( finale > 6'd30 ) begin
      overflow = 1'b1;
      unrounded_result = Fs ? 16'hFBFF : 16'h7BFF; // ±MAX
    end
    /* Exactly zero result --------------------------------------*/
    else if ( (finale==0) && (final_frac==0) ) begin
      unrounded_result = 16'h0000;  // always +0
    end
    /* Normal number path ---------------------------------------*/
    else begin
      unrounded_result = {Fs, finale[4:0], final_frac};
      special_flag     = 1'b0;
    end
  end
endmodule

//---------------------------------------------------------------
module rounding_unit(
  input  logic [15:0] unrounded_result,
  input  logic        special,
  input  logic        overflow_in,
  input  logic [1:0]  roundmode,
  input  logic l,g,r,t,

  output logic [15:0] final_result,
  output logic        rounded_overflow,
  output logic        inexact
);

  /* Split unrounded result */
  logic sign;
  logic [4:0] unrounded_exp;
  logic [9:0] unrounded_frac;

  assign sign          = unrounded_result[15];
  assign unrounded_exp = unrounded_result[14:10];
  assign unrounded_frac= unrounded_result[9:0];

  /* Control flags inside rounding unit */
  logic do_trunc, do_round, do_maxnum, do_infinity;

  /*-----------------------------------------------------------------*/
  always_comb begin
    /* Default assignments */
    do_trunc    = 1'b0; do_round  = 1'b0;
    do_maxnum   = 1'b0; do_infinity = 1'b0;

    if (overflow_in) begin
      /* Pre‑round overflow – choose between MAXNUM / INFINITY */
      case (roundmode)
        2'b00 : do_maxnum   = 1'b1;                           // RZ
        2'b01 : do_infinity = 1'b1;                           // RNE
        2'b10 : 
          if (sign) do_infinity = 1;
          else      do_maxnum = 1;      // RD
        2'b11: // RU: toward +inf
          if (!sign)   do_infinity = 1'b1;
          else         do_maxnum  = 1'b1;
      endcase
    end else begin
      /* Normalised value : choose between TRUNC / ROUND */
      case (roundmode)
        2'b00 : do_trunc = 1'b1; // RZ
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

  /* Increment mantissa/exponent when rounding‑up */
  logic [9:0] incr_frac;
  logic [4:0] incr_exp;

  always_comb begin
    incr_frac = unrounded_frac;
    incr_exp  = unrounded_exp;
    if (do_round && !special) begin
      incr_frac = unrounded_frac + 10'd1;
      if (incr_frac == 10'd0)  // carry‑out into exponent
        incr_exp = unrounded_exp + 5'd1;
    end
  end

  /* Final result assembly */
  always_comb begin
    final_result = unrounded_result;      // default fall‑through

    if (do_infinity) begin
      final_result = {sign, 5'h1F, 10'd0};
    end
    else if (do_maxnum) begin
      final_result = {sign, 5'h1E, 10'h3FF}; // Max finite
    end
    else if (do_round) begin
      final_result = {sign, incr_exp, incr_frac};
    end
  end

  /* Overflow produced *by* rounding‑up */
  assign rounded_overflow = (!special && do_round && (incr_exp==5'h1F));

  /* IEEE‑754 “inexact” flag */
  assign inexact = (t | g | r | overflow_in);
endmodule

//---------------------------------------------------------------
module flag_unit(
  input  logic invalid,
  input  logic overflow,
  input  logic rounded_overflow,
  input  logic inexact,
  input  logic special,

  output logic [3:0] flags   // {Invalid, Overflow, Underflow(‑‑), Inexact}
);
  /* Underflow is not generated in this design (sub‑norm outputs unsupported) */
  always_comb begin
    if (invalid)                 flags = 4'b1000;
    else if (overflow|rounded_overflow) flags = 4'b0101; // sets both OVF + INX
    else if (inexact && !special) flags = 4'b0001;
    else                          flags = 4'b0000;
  end
endmodule