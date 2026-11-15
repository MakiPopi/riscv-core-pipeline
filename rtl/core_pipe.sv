// 5-stage in-order pipeline: IF, ID, EX, MEM, WB.
// Same ports as core.sv, so the SoC can use either.
//
// Step 1: structure only. A taken branch/jump flushes the two wrong-path
// instructions behind it, but there is NO data forwarding and NO load-use
// stall yet, so programs with back-to-back dependencies give wrong results.
module core_pipe
  import alu_pkg::*;
  import decode_pkg::*;
  import pipe_pkg::*;
#(
  parameter logic [31:0] RESET_PC = 32'h8000_0000
) (
  input  logic        clk,
  input  logic        rst,            // synchronous, active high

  output logic [31:2] imem_addr,
  input  logic [31:0] imem_rdata,

  output logic [31:2] dmem_addr,
  output logic [3:0]  dmem_be,
  output logic [31:0] dmem_wdata,
  input  logic [31:0] dmem_rdata,

  output logic        ret_valid,
  output logic [31:0] ret_pc,
  output logic [31:0] ret_inst,
  output logic [4:0]  ret_rd,
  output logic [31:0] ret_rd_data,
  output logic        ret_mem_re,
  output logic        ret_mem_we,
  output logic [31:0] ret_mem_addr,
  output logic [31:0] ret_mem_data,

  output logic        trap            // a trapping instruction reached write-back
);

  // ---- Pipeline registers ----
  logic [31:0] pc;
  if_id_t      if_id;
  // The rs1/rs2 numbers and uses_rs1/uses_rs2 flags are only needed once forwarding exists.
  /* verilator lint_off UNUSEDSIGNAL */
  id_ex_t      id_ex;
  /* verilator lint_on UNUSEDSIGNAL */
  ex_mem_t     ex_mem;
  mem_wb_t     mem_wb;

  // Signals that cross stage boundaries
  logic        redirect;              // EX: a taken branch/jump changes the PC
  logic [31:0] redirect_target;
  logic        rf_we;                 // WB: register file write
  logic [31:0] wb_data;

  // ===================== IF: fetch =====================
  assign imem_addr = pc[31:2];

  always_ff @(posedge clk) begin
    if (rst)           pc <= RESET_PC;
    else if (redirect) pc <= redirect_target;
    else               pc <= pc + 32'd4;
  end

  always_ff @(posedge clk) begin
    if (rst || redirect) if_id <= '0;      // flush: the instruction fetched now is wrong-path
    else                 if_id <= '{valid: 1'b1, pc: pc, inst: imem_rdata};
  end

  // ===================== ID: decode and register read =====================
  logic [4:0]  d_rs1, d_rs2, d_rd;
  logic [2:0]  d_funct3;
  logic [31:0] d_imm;
  alu_op_e     d_alu_op;
  a_sel_e      d_a_sel;
  b_sel_e      d_b_sel;
  wb_sel_e     d_wb_sel;
  logic        d_reg_write, d_mem_read, d_mem_write;
  logic        d_is_branch, d_is_jal, d_is_jalr, d_uses_rs1, d_uses_rs2, d_illegal;

  decoder u_decoder (
    .inst(if_id.inst),
    .rs1(d_rs1), .rs2(d_rs2), .rd(d_rd), .funct3(d_funct3), .imm(d_imm),
    .alu_op(d_alu_op), .a_sel(d_a_sel), .b_sel(d_b_sel),
    .reg_write(d_reg_write), .wb_sel(d_wb_sel),
    .mem_read(d_mem_read), .mem_write(d_mem_write),
    .is_branch(d_is_branch), .is_jal(d_is_jal), .is_jalr(d_is_jalr),
    .uses_rs1(d_uses_rs1), .uses_rs2(d_uses_rs2),
    .illegal(d_illegal)
  );

  // The register file is written in WB and read here. BYPASS=1: a read of the register
  // that WB writes in the same cycle returns the new value (producer 3 instructions ahead).
  logic [31:0] rf_rdata1, rf_rdata2;

  regfile #(.BYPASS(1'b1)) u_regfile (
    .clk(clk), .we(rf_we), .waddr(mem_wb.rd), .wdata(wb_data),
    .raddr1(d_rs1), .raddr2(d_rs2), .rdata1(rf_rdata1), .rdata2(rf_rdata2)
  );

  id_ex_t id_next;

  always_comb begin
    id_next = '0;                          // an empty IF/ID slot becomes a bubble
    if (if_id.valid) begin
      id_next.valid     = 1'b1;
      id_next.pc        = if_id.pc;
      id_next.inst      = if_id.inst;
      id_next.rs1       = d_rs1;
      id_next.rs2       = d_rs2;
      id_next.rd        = d_rd;
      id_next.funct3    = d_funct3;
      id_next.imm       = d_imm;
      id_next.rs1_val   = rf_rdata1;
      id_next.rs2_val   = rf_rdata2;
      id_next.alu_op    = d_alu_op;
      id_next.a_sel     = d_a_sel;
      id_next.b_sel     = d_b_sel;
      id_next.reg_write = d_reg_write;
      id_next.wb_sel    = d_wb_sel;
      id_next.mem_read  = d_mem_read;
      id_next.mem_write = d_mem_write;
      id_next.is_branch = d_is_branch;
      id_next.is_jal    = d_is_jal;
      id_next.is_jalr   = d_is_jalr;
      id_next.uses_rs1  = d_uses_rs1;
      id_next.uses_rs2  = d_uses_rs2;
      id_next.illegal   = d_illegal;
    end
  end

  always_ff @(posedge clk) begin
    if (rst || redirect) id_ex <= '0;      // flush: the instruction decoded now is wrong-path
    else                 id_ex <= id_next;
  end

  // ===================== EX: execute and resolve branches =====================
  logic [31:0] alu_a, alu_b, alu_result;

  always_comb begin
    case (id_ex.a_sel)
      A_RS1:   alu_a = id_ex.rs1_val;
      A_PC:    alu_a = id_ex.pc;
      default: alu_a = 32'b0;              // A_ZERO (lui)
    endcase
  end

  assign alu_b = (id_ex.b_sel == B_IMM) ? id_ex.imm : id_ex.rs2_val;

  alu u_alu (.a(alu_a), .b(alu_b), .op(id_ex.alu_op), .result(alu_result));

  logic cmp_taken;
  branch_cmp u_branch_cmp (
    .a(id_ex.rs1_val), .b(id_ex.rs2_val), .funct3(id_ex.funct3), .taken(cmp_taken)
  );

  logic take_jump, jump_misaligned;

  assign take_jump       = id_ex.valid &&
                           (id_ex.is_jal || id_ex.is_jalr || (id_ex.is_branch && cmp_taken));
  // jalr: target = (rs1 + imm) with bit 0 forced to zero
  assign redirect_target = id_ex.is_jalr ? {alu_result[31:1], 1'b0} : alu_result;
  assign redirect        = take_jump;
  assign jump_misaligned = take_jump && (redirect_target[1:0] != 2'b00);

  ex_mem_t ex_next;

  always_comb begin
    ex_next = '0;
    if (id_ex.valid) begin
      ex_next.valid      = 1'b1;
      ex_next.trap       = id_ex.illegal || jump_misaligned;
      ex_next.pc         = id_ex.pc;
      ex_next.inst       = id_ex.inst;
      ex_next.rd         = id_ex.rd;
      ex_next.funct3     = id_ex.funct3;
      ex_next.alu_result = alu_result;
      ex_next.store_data = id_ex.rs2_val;
      ex_next.reg_write  = id_ex.reg_write;
      ex_next.wb_sel     = id_ex.wb_sel;
      ex_next.mem_read   = id_ex.mem_read;
      ex_next.mem_write  = id_ex.mem_write;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) ex_mem <= '0;
    else     ex_mem <= ex_next;
  end

  // ===================== MEM: data memory access =====================
  logic [3:0]  lsu_be;
  logic [31:0] load_data;
  logic        lsu_misaligned, mem_misaligned;

  lsu u_lsu (
    .addr_lo(ex_mem.alu_result[1:0]), .funct3(ex_mem.funct3),
    .store_data(ex_mem.store_data), .load_raw(dmem_rdata),
    .store_be(lsu_be), .store_wdata(dmem_wdata),
    .load_data(load_data), .misaligned(lsu_misaligned)
  );

  assign dmem_addr      = ex_mem.alu_result[31:2];
  // No store happens for a bubble, or when an older instruction is trapping in WB.
  // (lsu already zeroes the byte enable for a misaligned store.)
  assign dmem_be        = (ex_mem.valid && ex_mem.mem_write && !trap) ? lsu_be : 4'b0000;
  assign mem_misaligned = ex_mem.valid && (ex_mem.mem_read || ex_mem.mem_write) && lsu_misaligned;

  mem_wb_t mem_next;

  always_comb begin
    mem_next = '0;
    if (ex_mem.valid) begin
      mem_next.valid      = 1'b1;
      mem_next.trap       = ex_mem.trap || mem_misaligned;
      mem_next.pc         = ex_mem.pc;
      mem_next.inst       = ex_mem.inst;
      mem_next.rd         = ex_mem.rd;
      mem_next.reg_write  = ex_mem.reg_write;
      mem_next.wb_sel     = ex_mem.wb_sel;
      mem_next.alu_result = ex_mem.alu_result;
      mem_next.mem_data   = ex_mem.mem_write ? ex_mem.store_data : load_data;
      mem_next.mem_read   = ex_mem.mem_read;
      mem_next.mem_write  = ex_mem.mem_write;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) mem_wb <= '0;
    else     mem_wb <= mem_next;
  end

  // ===================== WB: write back and retire =====================
  always_comb begin
    case (mem_wb.wb_sel)
      WB_MEM:  wb_data = mem_wb.mem_data;
      WB_PC4:  wb_data = mem_wb.pc + 32'd4;
      default: wb_data = mem_wb.alu_result;  // WB_ALU
    endcase
  end

  // A trapped instruction has no side effects
  assign rf_we = mem_wb.valid && mem_wb.reg_write && !mem_wb.trap;
  assign trap  = mem_wb.valid && mem_wb.trap;

  // Retirement trace: one record per completed instruction
  assign ret_valid    = mem_wb.valid && !mem_wb.trap;
  assign ret_pc       = mem_wb.pc;
  assign ret_inst     = mem_wb.inst;
  assign ret_rd       = (mem_wb.reg_write && mem_wb.rd != 5'd0) ? mem_wb.rd : 5'd0;
  assign ret_rd_data  = (ret_rd != 5'd0) ? wb_data : 32'b0;
  assign ret_mem_re   = mem_wb.mem_read;
  assign ret_mem_we   = mem_wb.mem_write;
  assign ret_mem_addr = mem_wb.alu_result;
  assign ret_mem_data = mem_wb.mem_data;

endmodule
