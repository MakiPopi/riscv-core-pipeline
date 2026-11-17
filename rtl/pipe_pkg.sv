// Pipeline registers: one struct per stage boundary.
// A bubble is the all-zeros value: valid = 0 and every control signal = 0, so it does nothing.
package pipe_pkg;
  import alu_pkg::*;
  import decode_pkg::*;

  // IF/ID: the fetched instruction
  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] inst;
  } if_id_t;

  // ID/EX: decoded instruction, with the register values read in ID
  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] inst;
    logic [4:0]  rs1;
    logic [4:0]  rs2;
    logic [4:0]  rd;
    logic [2:0]  funct3;
    logic [31:0] imm;
    logic [31:0] rs1_val;
    logic [31:0] rs2_val;
    alu_op_e     alu_op;
    a_sel_e      a_sel;
    b_sel_e      b_sel;
    logic        reg_write;
    wb_sel_e     wb_sel;
    logic        mem_read;
    logic        mem_write;
    logic        is_branch;
    logic        is_jal;
    logic        is_jalr;
    logic        uses_rs1;
    logic        uses_rs2;
    logic        illegal;
  } id_ex_t;

  // EX/MEM: ALU result (also the memory address) and what MEM and WB still need
  typedef struct packed {
    logic        valid;
    logic        trap;
    logic [31:0] pc;
    logic [31:0] inst;
    logic [4:0]  rd;
    logic [2:0]  funct3;
    logic [31:0] alu_result;
    logic [31:0] store_data;
    logic        reg_write;
    wb_sel_e     wb_sel;
    logic        mem_read;
    logic        mem_write;
  } ex_mem_t;

  // MEM/WB: everything the write-back stage and the retirement trace need
  typedef struct packed {
    logic        valid;
    logic        trap;
    logic [31:0] pc;
    logic [31:0] inst;
    logic [4:0]  rd;
    logic        reg_write;
    wb_sel_e     wb_sel;
    logic [31:0] alu_result;
    logic [31:0] mem_data;      // load: the loaded value; store: the raw rs2 (for the trace)
    logic        mem_read;
    logic        mem_write;
  } mem_wb_t;

endpackage
