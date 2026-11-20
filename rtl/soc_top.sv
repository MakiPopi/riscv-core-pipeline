module soc_top #(
  parameter int PIPELINED = 0,         // 0: single-cycle core, 1: 5-stage pipeline
  // Branch handling of the pipeline (ignored by the single-cycle core)
  /* verilator lint_off UNUSEDPARAM */
  parameter int BP_ENABLE      = 1,
  parameter int BP_INDEX_BITS  = 10,
  parameter int BP_HIST_BITS   = 10,
  parameter int BTB_INDEX_BITS = 6
  /* verilator lint_on UNUSEDPARAM */
) (
  input  logic        clk,
  input  logic        rst,

  // Retirement trace and trap, passed straight through from the core
  output logic        ret_valid,
  output logic [31:0] ret_pc,
  output logic [31:0] ret_inst,
  output logic [4:0]  ret_rd,
  output logic [31:0] ret_rd_data,
  output logic        ret_mem_re,
  output logic        ret_mem_we,
  output logic [31:0] ret_mem_addr,
  output logic [31:0] ret_mem_data,
  output logic        trap,
  output logic        perf_stall,
  output logic        perf_flush
);

  // Memory starts here, and so does the PC after reset (Spike's default layout)
  localparam logic [31:0] BASE = 32'h8000_0000;

  logic [31:2] imem_addr, dmem_addr;
  logic [31:0] imem_rdata, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_be;

  if (PIPELINED != 0) begin : g_pipe
    core_pipe #(
      .RESET_PC(BASE), .BP_ENABLE(BP_ENABLE), .BP_INDEX_BITS(BP_INDEX_BITS),
      .BP_HIST_BITS(BP_HIST_BITS), .BTB_INDEX_BITS(BTB_INDEX_BITS)
    ) u_core (
      .clk(clk), .rst(rst),
      .imem_addr(imem_addr), .imem_rdata(imem_rdata),
      .dmem_addr(dmem_addr), .dmem_be(dmem_be),
      .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
      .ret_valid(ret_valid), .ret_pc(ret_pc), .ret_inst(ret_inst),
      .ret_rd(ret_rd), .ret_rd_data(ret_rd_data),
      .ret_mem_re(ret_mem_re), .ret_mem_we(ret_mem_we),
      .ret_mem_addr(ret_mem_addr), .ret_mem_data(ret_mem_data),
      .trap(trap),
      .perf_stall(perf_stall), .perf_flush(perf_flush)
    );
  end else begin : g_single
    core #(.RESET_PC(BASE)) u_core (
      .clk(clk), .rst(rst),
      .imem_addr(imem_addr), .imem_rdata(imem_rdata),
      .dmem_addr(dmem_addr), .dmem_be(dmem_be),
      .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
      .ret_valid(ret_valid), .ret_pc(ret_pc), .ret_inst(ret_inst),
      .ret_rd(ret_rd), .ret_rd_data(ret_rd_data),
      .ret_mem_re(ret_mem_re), .ret_mem_we(ret_mem_we),
      .ret_mem_addr(ret_mem_addr), .ret_mem_data(ret_mem_data),
      .trap(trap),
      .perf_stall(perf_stall), .perf_flush(perf_flush)
    );
  end

  mem #(.BASE(BASE)) u_mem (
    .clk(clk),
    .iaddr(imem_addr), .irdata(imem_rdata),
    .daddr(dmem_addr), .dbe(dmem_be), .dwdata(dmem_wdata), .drdata(dmem_rdata)
  );

endmodule
