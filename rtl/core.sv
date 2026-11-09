module core
  import alu_pkg::*;
  import decode_pkg::*;
#(
  parameter logic [31:0] RESET_PC = 32'h8000_0000
) (
  input  logic        clk,
  input  logic        rst,            // synchronous, active high

  // Instruction memory: combinational read. Word address.
  output logic [31:2] imem_addr,
  input  logic [31:0] imem_rdata,

  // Data memory: combinational read, synchronous write. Word address + byte enables.
  output logic [31:2] dmem_addr,
  output logic [3:0]  dmem_be,
  output logic [31:0] dmem_wdata,
  input  logic [31:0] dmem_rdata,

  // Retirement trace: one record per completed instruction (valid when ret_valid=1)
  output logic        ret_valid,
  output logic [31:0] ret_pc,
  output logic [31:0] ret_inst,
  output logic [4:0]  ret_rd,         // 0 if no register was written
  output logic [31:0] ret_rd_data,
  output logic        ret_mem_re,     // a load
  output logic        ret_mem_we,     // a store
  output logic [31:0] ret_mem_addr,   // full byte address
  output logic [31:0] ret_mem_data,   // load: value loaded; store: raw rs2

  // Illegal instruction or misaligned jump/access: the core stops
  output logic        trap
);

  // ===================== Fetch =====================
  logic [31:0] pc, pc_plus4, next_pc, inst;

  assign imem_addr = pc[31:2];
  assign inst      = imem_rdata;
  assign pc_plus4  = pc + 32'd4;

  // ===================== Decode =====================
  logic [4:0]  rs1, rs2, rd;
  logic [2:0]  funct3;
  logic [31:0] imm;
  alu_op_e     alu_op;
  a_sel_e      a_sel;
  b_sel_e      b_sel;
  wb_sel_e     wb_sel;
  logic        reg_write, mem_read, mem_write;
  logic        is_branch, is_jal, is_jalr, illegal;

  // Only a pipelined core needs these (hazard detection), so nothing reads them here.
  /* verilator lint_off UNUSEDSIGNAL */
  logic        uses_rs1, uses_rs2;
  /* verilator lint_on UNUSEDSIGNAL */

  decoder u_decoder (
    .inst(inst),
    .rs1(rs1), .rs2(rs2), .rd(rd), .funct3(funct3), .imm(imm),
    .alu_op(alu_op), .a_sel(a_sel), .b_sel(b_sel),
    .reg_write(reg_write), .wb_sel(wb_sel),
    .mem_read(mem_read), .mem_write(mem_write),
    .is_branch(is_branch), .is_jal(is_jal), .is_jalr(is_jalr),
    .uses_rs1(uses_rs1), .uses_rs2(uses_rs2),
    .illegal(illegal)
  );

  // ===================== Register file =====================
  logic [31:0] rs1_val, rs2_val, wb_data;
  logic        rf_we;

  // No bypass: an instruction must read the OLD value of a register it also writes.
  regfile #(.BYPASS(1'b0)) u_regfile (
    .clk(clk), .we(rf_we), .waddr(rd), .wdata(wb_data),
    .raddr1(rs1), .raddr2(rs2), .rdata1(rs1_val), .rdata2(rs2_val)
  );

  // ===================== Execute =====================
  logic [31:0] alu_a, alu_b, alu_result;

  always_comb begin
    case (a_sel)
      A_RS1:   alu_a = rs1_val;
      A_PC:    alu_a = pc;
      default: alu_a = 32'b0;           // A_ZERO (lui)
    endcase
  end

  assign alu_b = (b_sel == B_IMM) ? imm : rs2_val;

  alu u_alu (.a(alu_a), .b(alu_b), .op(alu_op), .result(alu_result));

  // The branch condition is decided on the raw register values.
  logic cmp_taken;
  branch_cmp u_branch_cmp (.a(rs1_val), .b(rs2_val), .funct3(funct3), .taken(cmp_taken));

  // ===================== Next PC =====================
  logic        take_jump;
  logic [31:0] jump_target;

  assign take_jump   = is_jal | is_jalr | (is_branch & cmp_taken);
  // jalr: target = (rs1 + imm) with bit 0 forced to zero. Branch/jal targets are already even.
  assign jump_target = is_jalr ? {alu_result[31:1], 1'b0} : alu_result;
  assign next_pc     = take_jump ? jump_target : pc_plus4;

  // ===================== Memory =====================
  logic [3:0]  lsu_be;
  logic [31:0] load_data;
  logic        lsu_misaligned;

  lsu u_lsu (
    .addr_lo(alu_result[1:0]), .funct3(funct3),
    .store_data(rs2_val), .load_raw(dmem_rdata),
    .store_be(lsu_be), .store_wdata(dmem_wdata),
    .load_data(load_data), .misaligned(lsu_misaligned)
  );

  assign dmem_addr = alu_result[31:2];
  // lsu already forces its byte enable to 0 for a misaligned store
  assign dmem_be   = (mem_write && !rst) ? lsu_be : 4'b0000;

  // ===================== Write-back =====================
  always_comb begin
    case (wb_sel)
      WB_MEM:  wb_data = load_data;
      WB_PC4:  wb_data = pc_plus4;
      default: wb_data = alu_result;    // WB_ALU
    endcase
  end

  // ===================== Traps and state update =====================
  logic jump_misaligned, mem_misaligned, run;

  assign jump_misaligned = take_jump && (jump_target[1:0] != 2'b00);
  assign mem_misaligned  = (mem_read || mem_write) && lsu_misaligned;
  assign trap            = !rst && (illegal || jump_misaligned || mem_misaligned);
  assign run             = !rst && !trap;      // this cycle completes an instruction

  assign rf_we = reg_write && run;

  always_ff @(posedge clk) begin
    if (rst)        pc <= RESET_PC;
    else if (!trap) pc <= next_pc;
  end

  // ===================== Retirement trace =====================
  assign ret_valid    = run;
  assign ret_pc       = pc;
  assign ret_inst     = inst;
  assign ret_rd       = (reg_write && rd != 5'd0) ? rd : 5'd0;
  assign ret_rd_data  = (ret_rd != 5'd0) ? wb_data : 32'b0;
  assign ret_mem_re   = mem_read;
  assign ret_mem_we   = mem_write;
  assign ret_mem_addr = alu_result;
  assign ret_mem_data = mem_write ? rs2_val : load_data;

endmodule
