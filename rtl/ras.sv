// Return-address stack with two copies. IF pushes and pops the speculative copy as it predicts calls and
// returns. EX applies the calls and returns that really execute to the committed copy (an instruction in EX is
// always on the correct path). On a redirect the speculative copy is replaced by the committed one, which
// undoes every wrong-path push and pop exactly. Circular: after DEPTH nested calls the oldest entry is lost.
module ras #(
  parameter int DEPTH_LOG2 = 3                 // log2 of the number of entries
) (
  input  logic        clk,
  input  logic        rst,

  // Speculative side (IF). Word addresses (byte address >> 2).
  output logic [31:2] top_addr,                // predicted return address
  input  logic        push,
  input  logic [31:2] push_val,
  input  logic        pop,

  // Committed side (EX): the call or return that is really executing (never both at once)
  input  logic        c_push,
  input  logic [31:2] c_push_val,
  input  logic        c_pop,

  // Redirect: the speculative copy becomes the committed copy (after this cycle's commit operation)
  input  logic        restore
);

  localparam int DEPTH = 1 << DEPTH_LOG2;
  localparam logic [DEPTH_LOG2-1:0] ONE = DEPTH_LOG2'(1);

  logic [31:2]           s_ent   [DEPTH];      // speculative entries
  logic [31:2]           c_ent   [DEPTH];      // committed entries
  logic [31:2]           c_ent_n [DEPTH];      // committed entries after this cycle's commit operation
  logic [DEPTH_LOG2-1:0] s_ptr, c_ptr, c_ptr_n;   // each points at the top entry
  logic [DEPTH_LOG2-1:0] s_inc, s_dec, c_inc, c_dec;

  assign s_inc = s_ptr + ONE;
  assign s_dec = s_ptr - ONE;
  assign c_inc = c_ptr + ONE;
  assign c_dec = c_ptr - ONE;

  assign top_addr = s_ent[s_ptr];

  always_comb begin
    for (int i = 0; i < DEPTH; i++) c_ent_n[i] = c_ent[i];
    c_ptr_n = c_ptr;
    if (c_push) begin
      c_ptr_n        = c_inc;
      c_ent_n[c_inc] = c_push_val;
    end else if (c_pop) begin
      c_ptr_n = c_dec;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < DEPTH; i++) begin
        s_ent[i] <= '0;
        c_ent[i] <= '0;
      end
      s_ptr <= '0;
      c_ptr <= '0;
    end else begin
      for (int i = 0; i < DEPTH; i++) c_ent[i] <= c_ent_n[i];
      c_ptr <= c_ptr_n;
      if (restore) begin
        for (int i = 0; i < DEPTH; i++) s_ent[i] <= c_ent_n[i];
        s_ptr <= c_ptr_n;
      end else if (push) begin
        s_ptr        <= s_inc;
        s_ent[s_inc] <= push_val;
      end else if (pop) begin
        s_ptr <= s_dec;
      end
    end
  end

endmodule
