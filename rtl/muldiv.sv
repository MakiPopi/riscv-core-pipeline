// Multiply/divide unit for the M extension: iterative, MUL_BITS / DIV_BITS result bits per cycle.
//
// Protocol: `start` is accepted only while idle (the core may hold it high while the instruction waits). The operands
// are latched. After 32/MUL_BITS (multiply) or 32/DIV_BITS (divide) iterations, `done` is high for exactly one cycle
// with `result` valid, and the unit is idle again in the cycle after. From start to done: iterations + 1 clock edges.
//
// funct3: 000 mul, 001 mulh, 010 mulhsu, 011 mulhu, 100 div, 101 divu, 110 rem, 111 remu.
// Signed operations work on magnitudes and negate at the end. Division by zero gives all ones (div, divu) or the
// dividend (rem, remu); INT_MIN / -1 gives INT_MIN with remainder 0. MUL_BITS and DIV_BITS must divide 32.
module muldiv #(
  parameter int MUL_BITS = 4,
  parameter int DIV_BITS = 2
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        start,
  input  logic [2:0]  funct3,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,       // not idle: working, or holding the result
  output logic        done,       // the result is valid in this cycle
  output logic [31:0] result
);

  localparam int ITER_MUL = 32 / MUL_BITS;
  localparam int ITER_DIV = 32 / DIV_BITS;

  typedef enum logic [1:0] {IDLE = 2'd0, RUN = 2'd1, FIN = 2'd2} state_e;
  state_e     state;
  logic [5:0] count;

  // Latched when the operation starts
  logic [2:0]  op3;
  logic        neg_a, neg_b, div0;
  logic [31:0] a_q;

  // Working registers
  logic [63:0] mcand, acc;                 // multiply: shifting multiplicand, running sum
  logic [31:0] mplier;                     // multiply: multiplier, shifting right
  logic [31:0] divisor, dq, rem;           // divide: dq holds the dividend shifting out and the quotient shifting in

  // ---- Which operands are signed, and their magnitudes ----
  logic        signed_a, signed_b, neg_a_in, neg_b_in;
  logic [31:0] ua, ub;

  always_comb begin
    if (funct3[2]) begin                   // div, divu, rem, remu: bit 0 set means unsigned
      signed_a = ~funct3[0];
      signed_b = ~funct3[0];
    end else begin                         // mul and mulhu are unsigned; mulh is signed x signed; mulhsu is signed x unsigned
      signed_a = (funct3[1:0] == 2'b01) || (funct3[1:0] == 2'b10);
      signed_b = (funct3[1:0] == 2'b01);
    end
  end

  assign neg_a_in = signed_a && a[31];
  assign neg_b_in = signed_b && b[31];
  assign ua = neg_a_in ? (~a + 32'd1) : a;
  assign ub = neg_b_in ? (~b + 32'd1) : b;

  // ---- One cycle of work: MUL_BITS multiplier bits, DIV_BITS quotient bits ----
  logic [63:0] acc_n, mc_n;
  logic [31:0] mp_n, dq_n;
  logic [32:0] rem_n;

  always_comb begin
    acc_n = acc;
    mc_n  = mcand;
    mp_n  = mplier;
    for (int j = 0; j < MUL_BITS; j++) begin
      if (mp_n[0]) acc_n = acc_n + mc_n;
      mc_n = mc_n << 1;
      mp_n = mp_n >> 1;
    end

    rem_n = {1'b0, rem};
    dq_n  = dq;
    for (int j = 0; j < DIV_BITS; j++) begin
      rem_n = {rem_n[31:0], dq_n[31]};     // bring down the next dividend bit
      dq_n  = {dq_n[30:0], 1'b0};          // make room for the quotient bit
      if (rem_n >= {1'b0, divisor}) begin
        rem_n   = rem_n - {1'b0, divisor};
        dq_n[0] = 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;
    end else begin
      case (state)
        IDLE: if (start) begin
          op3     <= funct3;
          neg_a   <= neg_a_in;
          neg_b   <= neg_b_in;
          div0    <= (b == 32'd0);
          a_q     <= a;
          mcand   <= {32'd0, ua};
          mplier  <= ub;
          acc     <= 64'd0;
          divisor <= ub;
          dq      <= ua;
          rem     <= 32'd0;
          count   <= 6'd0;
          state   <= RUN;
        end

        RUN: begin
          acc    <= acc_n;
          mcand  <= mc_n;
          mplier <= mp_n;
          dq     <= dq_n;
          rem    <= rem_n[31:0];
          count  <= count + 6'd1;
          if (count == (op3[2] ? 6'(ITER_DIV - 1) : 6'(ITER_MUL - 1))) state <= FIN;
        end

        default: state <= IDLE;            // FIN lasts one cycle; start is ignored in it
      endcase
    end
  end

  assign busy = (state != IDLE);
  assign done = (state == FIN);

  // ---- Result: undo the sign handling ----
  logic [63:0] prod;
  logic [31:0] q_out, r_out;

  assign prod  = (neg_a ^ neg_b) ? (~acc + 64'd1) : acc;
  assign q_out = (neg_a ^ neg_b) ? (~dq + 32'd1)  : dq;
  assign r_out = neg_a           ? (~rem + 32'd1) : rem;

  always_comb begin
    case (op3)
      3'b000:                  result = prod[31:0];
      3'b001, 3'b010, 3'b011:  result = prod[63:32];
      3'b100, 3'b101:          result = div0 ? 32'hFFFF_FFFF : q_out;
      default:                 result = div0 ? a_q : r_out;      // rem, remu
    endcase
  end

endmodule
