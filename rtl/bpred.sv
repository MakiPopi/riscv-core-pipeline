// Branch direction predictor: a table of 2-bit saturating counters.
// index = PC bits XOR global history. HIST_BITS = 0 is bimodal; HIST_BITS = INDEX_BITS is gshare.
// (HIST_BITS must not exceed INDEX_BITS.)
module bpred #(
  parameter int INDEX_BITS = 8,                     // log2(number of counters)
  parameter int HIST_BITS  = 0,                     // global history length
  localparam int HW = (HIST_BITS == 0) ? 1 : HIST_BITS
) (
  input  logic          clk,
  input  logic          rst,

  // Lookup (combinational). pc is the word address (byte address >> 2).
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:2]   pc,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic          taken,
  output logic [HW-1:0] hist,        // the history this lookup used: carry it with the branch

  // Speculative history: shift in a predicted outcome, or restore it after a misprediction
  input  logic          spec_en,
  input  logic          spec_taken,
  input  logic          fix_en,      // wins over spec_en
  input  logic [HW-1:0] fix_hist,    // the complete history to restore (the core computes it)

  // Training, when a branch resolves
  input  logic          upd_en,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:2]   upd_pc,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [HW-1:0] upd_hist,    // the history that branch was predicted with
  input  logic          upd_taken
);

  localparam int ENTRIES = 1 << INDEX_BITS;

  logic [1:0]            ctr [ENTRIES];    // 0,1: predict not taken; 2,3: predict taken
  logic [HW-1:0]         hist_q;
  logic [HW-1:0]         upd_h;
  logic [INDEX_BITS-1:0] idx_look, idx_upd;
  logic [1:0]            upd_old;

  // With HIST_BITS = 0 the history is forced to zero, so the index is just the PC bits.
  assign hist  = (HIST_BITS == 0) ? '0 : hist_q;
  assign upd_h = (HIST_BITS == 0) ? '0 : upd_hist;

  assign idx_look = pc[INDEX_BITS+1:2]     ^ INDEX_BITS'(hist);
  assign idx_upd  = upd_pc[INDEX_BITS+1:2] ^ INDEX_BITS'(upd_h);

  assign taken   = ctr[idx_look][1];
  assign upd_old = ctr[idx_upd];

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < ENTRIES; i++) ctr[i] <= 2'd1;     // weakly not taken
    end else if (upd_en) begin
      if (upd_taken) ctr[idx_upd] <= (upd_old == 2'd3) ? 2'd3 : upd_old + 2'd1;
      else           ctr[idx_upd] <= (upd_old == 2'd0) ? 2'd0 : upd_old - 2'd1;
    end
  end

  always_ff @(posedge clk) begin
    if (rst)          hist_q <= '0;
    else if (fix_en)  hist_q <= fix_hist;
    else if (spec_en) hist_q <= (hist_q << 1) | HW'(spec_taken);
  end

endmodule
