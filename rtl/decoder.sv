module decoder
  import alu_pkg::*;
  import decode_pkg::*;
(
  input  logic [31:0] inst,

  // Fields taken straight from the instruction bits
  output logic [4:0]  rs1,
  output logic [4:0]  rs2,
  output logic [4:0]  rd,
  output logic [2:0]  funct3,
  output logic [31:0] imm,

  // Control signals
  output alu_op_e     alu_op,
  output a_sel_e      a_sel,
  output b_sel_e      b_sel,
  output logic        reg_write,
  output wb_sel_e     wb_sel,
  output logic        mem_read,
  output logic        mem_write,
  output logic        is_branch,
  output logic        is_jal,
  output logic        is_jalr,
  output logic        uses_rs1,
  output logic        uses_rs2,
  output logic        illegal
);

  // ---- Fixed-position fields (same in every format) ----
  logic [6:0] opcode;
  logic [6:0] funct7;

  assign opcode = inst[6:0];
  assign rd     = inst[11:7];
  assign funct3 = inst[14:12];
  assign rs1    = inst[19:15];
  assign rs2    = inst[24:20];
  assign funct7 = inst[31:25];

  // ---- The five immediate formats, each sign-extended to 32 bits ----
  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;

  assign imm_i = {{20{inst[31]}}, inst[31:20]};
  assign imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
  assign imm_b = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
  assign imm_u = {inst[31:12], 12'b0};
  assign imm_j = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};

  // ---- Control logic ----
  always_comb begin
    // Defaults: do nothing. Each case below overrides only what it needs.
    imm       = 32'b0;
    alu_op    = ALU_ADD;
    a_sel     = A_RS1;
    b_sel     = B_IMM;
    reg_write = 1'b0;
    wb_sel    = WB_ALU;
    mem_read  = 1'b0;
    mem_write = 1'b0;
    is_branch = 1'b0;
    is_jal    = 1'b0;
    is_jalr   = 1'b0;
    uses_rs1  = 1'b0;
    uses_rs2  = 1'b0;
    illegal   = 1'b0;

    case (opcode)
      OPC_LUI: begin                       // rd = 0 + imm
        imm       = imm_u;
        a_sel     = A_ZERO;
        reg_write = 1'b1;
      end

      OPC_AUIPC: begin                     // rd = PC + imm
        imm       = imm_u;
        a_sel     = A_PC;
        reg_write = 1'b1;
      end

      OPC_JAL: begin                       // target = PC + imm, rd = PC + 4
        imm       = imm_j;
        a_sel     = A_PC;
        reg_write = 1'b1;
        wb_sel    = WB_PC4;
        is_jal    = 1'b1;
      end

      OPC_JALR: begin                      // target = rs1 + imm, rd = PC + 4
        imm       = imm_i;
        reg_write = 1'b1;
        wb_sel    = WB_PC4;
        is_jalr   = 1'b1;
        uses_rs1  = 1'b1;
        if (funct3 != 3'b000) illegal = 1'b1;
      end

      OPC_BRANCH: begin                    // target = PC + imm (taken is decided later)
        imm       = imm_b;
        a_sel     = A_PC;
        is_branch = 1'b1;
        uses_rs1  = 1'b1;
        uses_rs2  = 1'b1;
        if (funct3 == 3'b010 || funct3 == 3'b011) illegal = 1'b1;
      end

      OPC_LOAD: begin                      // address = rs1 + imm
        imm       = imm_i;
        reg_write = 1'b1;
        wb_sel    = WB_MEM;
        mem_read  = 1'b1;
        uses_rs1  = 1'b1;
        if (funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111) illegal = 1'b1;
      end

      OPC_STORE: begin                     // address = rs1 + imm
        imm       = imm_s;
        mem_write = 1'b1;
        uses_rs1  = 1'b1;
        uses_rs2  = 1'b1;
        if (funct3 > 3'b010) illegal = 1'b1;
      end

      OPC_OP_IMM: begin                    // rd = rs1 <op> imm
        imm       = imm_i;
        reg_write = 1'b1;
        uses_rs1  = 1'b1;
        case (funct3)
          3'b000: alu_op = ALU_ADD;        // addi (no subi exists)
          3'b010: alu_op = ALU_SLT;
          3'b011: alu_op = ALU_SLTU;
          3'b100: alu_op = ALU_XOR;
          3'b110: alu_op = ALU_OR;
          3'b111: alu_op = ALU_AND;
          3'b001: begin                    // slli
            alu_op = ALU_SLL;
            if (funct7 != 7'b0000000) illegal = 1'b1;
          end
          3'b101: begin                    // srli / srai
            alu_op = funct7[5] ? ALU_SRA : ALU_SRL;
            if (funct7 != 7'b0000000 && funct7 != 7'b0100000) illegal = 1'b1;
          end
        endcase
      end

      OPC_OP: begin                        // rd = rs1 <op> rs2
        b_sel     = B_RS2;
        reg_write = 1'b1;
        uses_rs1  = 1'b1;
        uses_rs2  = 1'b1;
        case (funct3)
          3'b000: alu_op = funct7[5] ? ALU_SUB : ALU_ADD;
          3'b001: alu_op = ALU_SLL;
          3'b010: alu_op = ALU_SLT;
          3'b011: alu_op = ALU_SLTU;
          3'b100: alu_op = ALU_XOR;
          3'b101: alu_op = funct7[5] ? ALU_SRA : ALU_SRL;
          3'b110: alu_op = ALU_OR;
          3'b111: alu_op = ALU_AND;
        endcase
        // funct7 must be 0000000, except 0100000 which only SUB and SRA use
        if (funct7 != 7'b0000000 &&
            !(funct7 == 7'b0100000 && (funct3 == 3'b000 || funct3 == 3'b101)))
          illegal = 1'b1;
      end

      OPC_FENCE: begin                     // no-op for now (single core, no caches)
        if (funct3 != 3'b000) illegal = 1'b1;
      end

      default: illegal = 1'b1;             // unknown opcode (includes SYSTEM for now)
    endcase

    // An illegal instruction must have no side effects at all
    if (illegal) begin
      reg_write = 1'b0;
      mem_read  = 1'b0;
      mem_write = 1'b0;
      is_branch = 1'b0;
      is_jal    = 1'b0;
      is_jalr   = 1'b0;
      uses_rs1  = 1'b0;
      uses_rs2  = 1'b0;
    end
  end

endmodule
