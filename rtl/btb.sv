// Branch target buffer: direct-mapped, full tags. Remembers the target of conditional branches, jal and jalr,
// and whether the instruction is a call (push the return stack) or a return (target comes from the return
// stack). A hit means "there is a branch or jump at this PC". Lookup is combinational, writes happen on the edge.
module btb #(
  parameter int INDEX_BITS = 6
) (
  input  logic        clk,
  input  logic        rst,

  // Lookup. pc is the word address (byte address >> 2).
  input  logic [31:2] pc,
  output logic        hit,
  output logic [31:2] target,       // 0 on a miss
  output logic        uncond,       // jal/jalr: always taken (0 on a miss; conditional branches use the predictor)
  output logic        is_call,      // 0 on a miss
  output logic        is_ret,       // 0 on a miss

  // Allocate or refresh, when a branch or jump resolves
  input  logic        upd_en,
  input  logic [31:2] upd_pc,
  input  logic [31:2] upd_target,
  input  logic        upd_uncond,
  input  logic        upd_call,
  input  logic        upd_ret
);

  localparam int ENTRIES  = 1 << INDEX_BITS;
  localparam int TAG_BITS = 30 - INDEX_BITS;

  logic                valid [ENTRIES];
  logic [TAG_BITS-1:0] tag   [ENTRIES];
  logic [31:2]         tgt   [ENTRIES];
  logic                unc   [ENTRIES];
  logic                cal   [ENTRIES];
  logic                rtn   [ENTRIES];

  logic [INDEX_BITS-1:0] idx_look, idx_upd;
  logic [TAG_BITS-1:0]   tag_look, tag_upd;

  assign idx_look = pc[INDEX_BITS+1:2];
  assign tag_look = pc[31:INDEX_BITS+2];
  assign idx_upd  = upd_pc[INDEX_BITS+1:2];
  assign tag_upd  = upd_pc[31:INDEX_BITS+2];

  assign hit     = valid[idx_look] && (tag[idx_look] == tag_look);
  assign target  = hit ? tgt[idx_look] : '0;
  assign uncond  = hit && unc[idx_look];
  assign is_call = hit && cal[idx_look];
  assign is_ret  = hit && rtn[idx_look];

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < ENTRIES; i++) valid[i] <= 1'b0;
    end else if (upd_en) begin
      valid[idx_upd] <= 1'b1;
      tag[idx_upd]   <= tag_upd;
      tgt[idx_upd]   <= upd_target;
      unc[idx_upd]   <= upd_uncond;
      cal[idx_upd]   <= upd_call;
      rtn[idx_upd]   <= upd_ret;
    end
  end

endmodule
