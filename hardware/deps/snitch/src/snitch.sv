// Author: Florian Zaruba <zarubaf@iis.ee.ethz.ch>
// Description: Top-Level of Snitch Integer Core RV32E

`include "common_cells/registers.svh"

// `SNITCH_ENABLE_PERF Enables mcycle, minstret performance counters (read only)

module snitch #(
  parameter logic [31:0] BootAddr  = 32'h0000_1000,
  parameter logic [31:0] MTVEC     = BootAddr, // Exception Base Address (see privileged spec 3.1.7)
  parameter bit          RVE       = 0,   // Reduced-register Extension
  parameter bit          RVM       = 1    // Enable IntegerMmultiplication & Division Extension
) (
  input  logic          clk_i,
  input  logic          rst_i,
  input  logic [31:0]   hart_id_i,
  // Instruction Refill Port
  output logic [31:0]   inst_addr_o,
  input  logic [31:0]   inst_data_i,
  output logic          inst_valid_o,
  input  logic          inst_ready_i,
`ifdef RISCV_FORMAL
  output logic [0:0]       rvfi_valid,
  output logic [0:0][63:0] rvfi_order,
  output logic [0:0][31:0] rvfi_insn,
  output logic [0:0]       rvfi_trap,
  output logic [0:0]       rvfi_halt,
  output logic [0:0]       rvfi_intr,
  output logic [0:0][1:0]  rvfi_mode,
  output logic [0:0][4:0]  rvfi_rs1_addr,
  output logic [0:0][4:0]  rvfi_rs2_addr,
  output logic [0:0][31:0] rvfi_rs1_rdata,
  output logic [0:0][31:0] rvfi_rs2_rdata,
  output logic [0:0][4:0]  rvfi_rd_addr,
  output logic [0:0][31:0] rvfi_rd_wdata,
  output logic [0:0][31:0] rvfi_pc_rdata,
  output logic [0:0][31:0] rvfi_pc_wdata,
  output logic [0:0][31:0] rvfi_mem_addr,
  output logic [0:0][3:0]  rvfi_mem_rmask,
  output logic [0:0][3:0]  rvfi_mem_wmask,
  output logic [0:0][31:0] rvfi_mem_rdata,
  output logic [0:0][31:0] rvfi_mem_wdata,
`endif
  /// Accelerator Interface - Master Port
  /// Independent channels for transaction request and read completion.
  /// AXI-like handshaking.
  /// Same IDs need to be handled in-order.
  output logic [31:0]   acc_qaddr_o,
  output logic [4:0]    acc_qid_o,
  output logic [31:0]   acc_qdata_op_o,
  output logic [31:0]   acc_qdata_arga_o,
  output logic [31:0]   acc_qdata_argb_o,
  output logic [31:0]   acc_qdata_argc_o,
  output logic          acc_qvalid_o,
  input  logic          acc_qready_i,
  input  logic [31:0]   acc_pdata_i,
  input  logic [4:0]    acc_pid_i,
  input  logic          acc_perror_i,
  input  logic          acc_pvalid_i,
  output logic          acc_pready_o,
  /// TCDM Data Interface
  /// Write transactions do not return data on the `P Channel`
  /// Transactions need to be handled strictly in-order.
  output logic [31:0]   data_qaddr_o,
  output logic          data_qwrite_o,
  output logic [3:0]    data_qamo_o,
  output logic [31:0]   data_qdata_o,
  output logic [3:0]    data_qstrb_o,
  output logic          data_qvalid_o,
  input  logic          data_qready_i,
  input  logic [31:0]   data_pdata_i,
  input  logic          data_perror_i,
  input  logic          data_pvalid_i,
  output logic          data_pready_o,
  input  logic          wake_up_sync_i, // synchronous wake-up interrupt
  // Core event strobes
  output snitch_pkg::core_events_t core_events_o
);

  localparam int RegWidth = RVE ? 4 : 5;

  logic illegal_inst;
  logic zero_lsb;

  // Instruction fetch
  logic [31:0] pc_d, pc_q;
  logic wfi_d, wfi_q;
  logic [31:0] consec_pc;
  // Immediates
  logic [31:0] iimm, uimm, jimm, bimm, simm;
  /* verilator lint_off WIDTH */
  assign iimm = $signed({inst_data_i[31:20]});
  assign uimm = {inst_data_i[31:12], 12'b0};
  assign jimm = $signed({inst_data_i[31],
                                  inst_data_i[19:12], inst_data_i[20], inst_data_i[30:21], 1'b0});
  assign bimm = $signed({inst_data_i[31],
                                    inst_data_i[7], inst_data_i[30:25], inst_data_i[11:8], 1'b0});
  assign simm = $signed({inst_data_i[31:25], inst_data_i[11:7]});
  /* verilator lint_on WIDTH */

  logic [31:0] opa, opb;
  logic [32:0] adder_result;
  logic [31:0] alu_result;

  logic [RegWidth-1:0] rd, rs1, rs2;
  logic stall, lsu_stall;
  // Register connections
  logic [1:0][RegWidth-1:0] gpr_raddr;
  logic [1:0][31:0]         gpr_rdata;
  logic [0:0][RegWidth-1:0] gpr_waddr;
  logic [0:0][31:0]         gpr_wdata;
  logic [0:0]               gpr_we;
  logic [2**RegWidth-1:0]   sb_d, sb_q;

  // Load/Store Defines
  logic is_load, is_store, is_signed;
  logic is_fp_load, is_fp_store;
  logic ls_misaligned;
  logic ld_addr_misaligned;
  logic st_addr_misaligned;

  enum logic [1:0] {
    Byte = 2'b00,
    HalfWord = 2'b01,
    Word = 2'b10,
    Double = 2'b11
  } ls_size;

  enum logic [3:0] {
    AMONone = 4'h0,
    AMOSwap = 4'h1,
    AMOAdd  = 4'h2,
    AMOAnd  = 4'h3,
    AMOOr   = 4'h4,
    AMOXor  = 4'h5,
    AMOMax  = 4'h6,
    AMOMaxu = 4'h7,
    AMOMin  = 4'h8,
    AMOMinu = 4'h9,
    AMOLR   = 4'hA,
    AMOSC   = 4'hB
  } ls_amo;

  logic [31:0] ld_result;
  logic lsu_qready, lsu_qvalid;
  logic lsu_pvalid, lsu_pready;
  logic [RegWidth-1:0] lsu_rd;

  logic retire_load; // retire a load instruction
  logic retire_i; // retire the rest of the base instruction set
  logic retire_acc; // retire an instruction we offloaded

  logic acc_stall;
  logic valid_instr;
  logic exception;

  // ALU Operations
  enum logic [3:0]  {
    Add, Sub,
    Slt, Sltu,
    Sll, Srl, Sra,
    LXor, LOr, LAnd, LNAnd,
    Eq, Neq, Ge, Geu,
    BypassA
  } alu_op;

  enum logic [3:0] {
    None, Reg, IImmediate, UImmediate, JImmediate, SImmediate, SFImmediate, PC, CSR, CSRImmmediate
  } opa_select, opb_select;

  logic write_rd; // write desitnation this cycle
  logic uses_rd;
  enum logic [1:0] {Consec, Alu, Exception} next_pc;

  enum logic [1:0] {RdAlu, RdConsecPC, RdBypass} rd_select;
  logic [31:0] rd_bypass;

  logic is_branch;

  logic [31:0] csr_rvalue;
  logic csr_en;

  typedef struct packed {
    fpnew_pkg::roundmode_e frm;
    fpnew_pkg::status_t    fflags;
  } fcsr_t;
  fcsr_t fcsr_d, fcsr_q;

  // Registers
  `FFSR(pc_q, pc_d, BootAddr, clk_i, rst_i)
  `FFSR(wfi_q, wfi_d, '0, clk_i, rst_i)
  `FFSR(sb_q, sb_d, '0, clk_i, rst_i)
  `FFSR(fcsr_q, fcsr_d, '0, clk_i, rst_i)

  // performance counter
  `ifdef SNITCH_ENABLE_PERF
  logic [63:0] cycle_q;
  logic [63:0] instret_q;
  `FFSR(cycle_q, cycle_q + 1, '0, clk_i, rst_i);
  `FFLSR(instret_q, instret_q + 1, !stall, '0, clk_i, rst_i);
  `endif

  always_comb begin
    core_events_o = '0;
    core_events_o.retired_insts = ~stall;
  end

  // accelerator offloading interface
  // register int destination in scoreboard
  logic  acc_register_rd;

  assign acc_qaddr_o = hart_id_i;
  assign acc_qid_o = rd;
  assign acc_qdata_op_o = inst_data_i;
  assign acc_qdata_arga_o = {{32{gpr_rdata[0][31]}}, gpr_rdata[0]};
  assign acc_qdata_argb_o = {{32{gpr_rdata[1][31]}}, gpr_rdata[1]};
  assign acc_qdata_argc_o = {32'b0, alu_result};

  // instruction fetch interface
  assign inst_addr_o = pc_q;
  assign inst_valid_o = ~wfi_q;

  // --------------------
  // Control
  // --------------------
  // Scoreboard: Keep track of rd dependencies (only loads at the moment)
  logic operands_ready;
  logic dst_ready;
  logic opa_ready, opb_ready;

  always_comb begin
    sb_d = sb_q;
    if (retire_load) sb_d[lsu_rd] = 1'b0;
    // only place the reservation if we actually executed the load or offload instruction
    if ((is_load | acc_register_rd) && !stall && !exception) sb_d[rd] = 1'b1;
    if (retire_acc) sb_d[acc_pid_i[RegWidth-1:0]] = 1'b0;
    sb_d[0] = 1'b0;
  end
  // TODO(zarubaf): This can probably be described a bit more efficient
  assign opa_ready = (opa_select != Reg) | ~sb_q[rs1];
  assign opb_ready = (opb_select != Reg & opb_select != SImmediate) | ~sb_q[rs2];
  assign operands_ready = opa_ready & opb_ready;
  // either we are not using the destination register or we need to make
  // sure that its destination operand is not marked busy in the scoreboard.
  assign dst_ready = ~uses_rd | (uses_rd & ~sb_q[rd]);

  assign valid_instr = (inst_ready_i & inst_valid_o) & operands_ready & dst_ready;
  // the accelerator interface stalled us
  assign acc_stall = (acc_qvalid_o & ~acc_qready_i);
  // the LSU Interface didn't accept our request yet
  assign lsu_stall = (lsu_qvalid & ~lsu_qready);
  // Stall the stage if we either didn't get a valid instruction or the LSU/Accelerator is not ready
  assign stall = ~valid_instr | lsu_stall | acc_stall;

  // --------------------
  // Instruction Frontend
  // --------------------
  assign consec_pc = pc_q + ((is_branch & alu_result[0]) ? bimm : 'd4);

  always_comb begin
    pc_d = pc_q;
    // if we got a valid instruction word increment the PC unless we are waiting for an event
    if (!stall && !wfi_q) begin
      casez (next_pc)
        Consec: pc_d = consec_pc;
        Alu: pc_d = alu_result & {{31{1'b1}}, ~zero_lsb};
        Exception: pc_d = MTVEC;
      endcase
    end
  end

  // --------------------
  // Decoder
  // --------------------
  assign rd = inst_data_i[7 + RegWidth - 1:7];
  assign rs1 = inst_data_i[15 + RegWidth - 1:15];
  assign rs2 = inst_data_i[20 + RegWidth - 1:20];

  always_comb begin
    illegal_inst = 1'b0;
    alu_op = Add;
    opa_select = None;
    opb_select = None;

    next_pc = Consec;

    rd_select = RdAlu;
    write_rd = 1'b1;
    // if we are writing the field this cycle we need
    // an int destination register
    uses_rd = write_rd;

    rd_bypass = '0;
    zero_lsb = 1'b0;
    is_branch = 1'b0;
    // LSU interface
    is_load = 1'b0;
    is_store = 1'b0;
    is_fp_load = 1'b0;
    is_fp_store = 1'b0;
    is_signed = 1'b0;
    ls_size = Byte;
    ls_amo = AMONone;

    acc_qvalid_o = 1'b0;
    acc_register_rd = 1'b0;

    csr_en = 1'b0;
    wfi_d = (wake_up_sync_i) ? 1'b0 : wfi_q;

    unique casez (inst_data_i)
      riscv_instr::ADD: begin
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::ADDI: begin
        opa_select = Reg;
        opb_select = IImmediate;
      end
      riscv_instr::SUB: begin
        alu_op = Sub;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::XOR: begin
        opa_select = Reg;
        opb_select = Reg;
        alu_op = LXor;
      end
      riscv_instr::XORI: begin
        alu_op = LXor;
        opa_select = Reg;
        opb_select = IImmediate;
      end
      riscv_instr::OR: begin
        opa_select = Reg;
        opb_select = Reg;
        alu_op = LOr;
      end
      riscv_instr::ORI: begin
        alu_op = LOr;
        opa_select = Reg;
        opb_select = IImmediate;
      end
      riscv_instr::AND: begin
        alu_op = LAnd;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::ANDI: begin
        alu_op = LAnd;
        opa_select = Reg;
        opb_select = IImmediate;
      end
      riscv_instr::SLT: begin
        alu_op = Slt;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::SLTI: begin
        alu_op = Slt;
        opa_select = Reg;
        opb_select = IImmediate;
      end
      riscv_instr::SLTU: begin
        alu_op = Sltu;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::SLTIU: begin
        alu_op = Sltu;
        opa_select = Reg;
        opb_select = IImmediate;
      end
      riscv_instr::SLL: begin
        alu_op = Sll;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::SRL: begin
        alu_op = Srl;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::SRA: begin
        alu_op = Sra;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::SLLI: begin
        alu_op = Sll;
        opa_select = Reg;
        opb_select = IImmediate;
      end
      riscv_instr::SRLI: begin
        alu_op = Srl;
        opa_select = Reg;
        opb_select = IImmediate;
      end
      riscv_instr::SRAI: begin
        alu_op = Sra;
        opa_select = Reg;
        opb_select = IImmediate;
      end
      riscv_instr::LUI: begin
        opa_select = None;
        opb_select = None;
        rd_select = RdBypass;
        rd_bypass = uimm;
      end
      riscv_instr::AUIPC: begin
        opa_select = UImmediate;
        opb_select = PC;
      end
      riscv_instr::JAL: begin
        rd_select = RdConsecPC;
        opa_select = JImmediate;
        opb_select = PC;
        next_pc = Alu;
      end
      riscv_instr::JALR: begin
        rd_select = RdConsecPC;
        opa_select = Reg;
        opb_select = IImmediate;
        next_pc = Alu;
        zero_lsb = 1'b1;
      end
      // use the ALU for comparisons
      riscv_instr::BEQ: begin
        is_branch = 1'b1;
        write_rd = 1'b0;
        alu_op = Eq;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::BNE: begin
        is_branch = 1'b1;
        write_rd = 1'b0;
        alu_op = Neq;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::BLT: begin
        is_branch = 1'b1;
        write_rd = 1'b0;
        alu_op = Slt;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::BLTU: begin
        is_branch = 1'b1;
        write_rd = 1'b0;
        alu_op = Sltu;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::BGE: begin
        is_branch = 1'b1;
        write_rd = 1'b0;
        alu_op = Ge;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::BGEU: begin
        is_branch = 1'b1;
        write_rd = 1'b0;
        alu_op = Geu;
        opa_select = Reg;
        opb_select = Reg;
      end
      // Load/Stores
      riscv_instr::SB: begin
        write_rd = 1'b0;
        is_store = 1'b1;
        opa_select = Reg;
        opb_select = SImmediate;
      end
      riscv_instr::SH: begin
        write_rd = 1'b0;
        is_store = 1'b1;
        ls_size = HalfWord;
        opa_select = Reg;
        opb_select = SImmediate;
      end
      riscv_instr::SW: begin
        write_rd = 1'b0;
        is_store = 1'b1;
        ls_size = Word;
        opa_select = Reg;
        opb_select = SImmediate;
      end
      riscv_instr::LB: begin
        write_rd = 1'b0;
        uses_rd = 1'b1;
        is_load = 1'b1;
        is_signed = 1'b1;
        opa_select = Reg;
        opb_select = IImmediate;
      end
      riscv_instr::LH: begin
        write_rd = 1'b0;
        uses_rd = 1'b1;
        is_load = 1'b1;
        is_signed = 1'b1;
        ls_size = HalfWord;
        opa_select = Reg;
        opb_select = IImmediate;
      end
      riscv_instr::LW: begin
        write_rd = 1'b0;
        uses_rd = 1'b1;
        is_load = 1'b1;
        is_signed = 1'b1;
        ls_size = Word;
        opa_select = Reg;
        opb_select = IImmediate;
      end
      riscv_instr::LBU: begin
        write_rd = 1'b0;
        uses_rd = 1'b1;
        is_load = 1'b1;
        opa_select = Reg;
        opb_select = IImmediate;
      end
      riscv_instr::LHU: begin
        write_rd = 1'b0;
        uses_rd = 1'b1;
        is_load = 1'b1;
        ls_size = HalfWord;
        opa_select = Reg;
        opb_select = IImmediate;
      end
      // CSR Instructions
      riscv_instr::CSRRW: begin // Atomic Read/Write CSR
        opa_select = Reg;
        opb_select = None;
        rd_select = RdBypass;
        rd_bypass = csr_rvalue;
        csr_en = 1'b1;
      end
      riscv_instr::CSRRWI: begin
        opa_select = CSRImmmediate;
        opb_select = None;
        rd_select = RdBypass;
        rd_bypass = csr_rvalue;
        csr_en = 1'b1;
      end
      riscv_instr::CSRRS: begin  // Atomic Read and Set Bits in CSR
          alu_op = LOr;
          opa_select = Reg;
          opb_select = CSR;
          rd_select = RdBypass;
          rd_bypass = csr_rvalue;
          csr_en = 1'b1;
      end
      riscv_instr::CSRRSI: begin
        // offload CSR enable to FP SS
        if (inst_data_i[31:20] != snitch_pkg::CSR_SSR) begin
          alu_op = LOr;
          opa_select = CSRImmmediate;
          opb_select = CSR;
          rd_select = RdBypass;
          rd_bypass = csr_rvalue;
          csr_en = 1'b1;
        end else begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end
      end
      riscv_instr::CSRRC: begin // Atomic Read and Clear Bits in CSR
        alu_op = LNAnd;
        opa_select = Reg;
        opb_select = CSR;
        rd_select = RdBypass;
        rd_bypass = csr_rvalue;
        csr_en = 1'b1;
      end
      riscv_instr::CSRRCI: begin
        if (inst_data_i[31:20] != snitch_pkg::CSR_SSR) begin
          alu_op = LNAnd;
          opa_select = CSRImmmediate;
          opb_select = CSR;
          rd_select = RdBypass;
          rd_bypass = csr_rvalue;
          csr_en = 1'b1;
        end else begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end
      end
      riscv_instr::ECALL,
      riscv_instr::EBREAK: begin
        // TODO(zarubaf): Trap to precise address
        write_rd = 1'b0;
      end
      // NOP Instructions
      riscv_instr::FENCE: begin
        write_rd = 1'b0;
      end
      riscv_instr::WFI: begin
        wfi_d = 1'b1;
      end
      // Atomics
      riscv_instr::AMOADD_W: begin
        alu_op = BypassA;
        write_rd = 1'b0;
        uses_rd = 1'b1;
        is_load = 1'b1;
        is_signed = 1'b1;
        ls_size = Word;
        ls_amo = AMOAdd;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::AMOXOR_W: begin
        alu_op = BypassA;
        write_rd = 1'b0;
        uses_rd = 1'b1;
        is_load = 1'b1;
        is_signed = 1'b1;
        ls_size = Word;
        ls_amo = AMOXor;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::AMOOR_W: begin
        alu_op = BypassA;
        write_rd = 1'b0;
        uses_rd = 1'b1;
        is_load = 1'b1;
        is_signed = 1'b1;
        ls_size = Word;
        ls_amo = AMOOr;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::AMOAND_W: begin
        alu_op = BypassA;
        write_rd = 1'b0;
        uses_rd = 1'b1;
        is_load = 1'b1;
        is_signed = 1'b1;
        ls_size = Word;
        ls_amo = AMOAnd;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::AMOMIN_W: begin
        alu_op = BypassA;
        write_rd = 1'b0;
        uses_rd = 1'b1;
        is_load = 1'b1;
        is_signed = 1'b1;
        ls_size = Word;
        ls_amo = AMOMinu;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::AMOMAX_W: begin
        alu_op = BypassA;
        write_rd = 1'b0;
        uses_rd = 1'b1;
        is_load = 1'b1;
        is_signed = 1'b1;
        ls_size = Word;
        ls_amo = AMOMax;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::AMOMINU_W: begin
        alu_op = BypassA;
        write_rd = 1'b0;
        uses_rd = 1'b1;
        is_load = 1'b1;
        is_signed = 1'b1;
        ls_size = Word;
        ls_amo = AMOMinu;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::AMOMAXU_W: begin
        alu_op = BypassA;
        write_rd = 1'b0;
        uses_rd = 1'b1;
        is_load = 1'b1;
        is_signed = 1'b1;
        ls_size = Word;
        ls_amo = AMOMaxu;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::AMOSWAP_W: begin
        alu_op = BypassA;
        write_rd = 1'b0;
        uses_rd = 1'b1;
        is_load = 1'b1;
        is_signed = 1'b1;
        ls_size = Word;
        ls_amo = AMOSwap;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::LR_W: begin
        alu_op = BypassA;
        write_rd = 1'b0;
        uses_rd = 1'b1;
        is_load = 1'b1;
        is_signed = 1'b1;
        ls_size = Word;
        ls_amo = AMOLR;
        opa_select = Reg;
        opb_select = Reg;
      end
      riscv_instr::SC_W: begin
        alu_op = BypassA;
        write_rd = 1'b0;
        uses_rd = 1'b1;
        is_load = 1'b1;
        is_signed = 1'b1;
        ls_size = Word;
        ls_amo = AMOSC;
        opa_select = Reg;
        opb_select = Reg;
      end
      // Off-load to shared multiplier
      riscv_instr::MUL,
      riscv_instr::MULH,
      riscv_instr::MULHSU,
      riscv_instr::MULHU,
      riscv_instr::DIV,
      riscv_instr::DIVU,
      riscv_instr::REM,
      riscv_instr::REMU,
      riscv_instr::MULW,
      riscv_instr::DIVW,
      riscv_instr::DIVUW,
      riscv_instr::REMW,
      riscv_instr::REMUW: begin
        write_rd = 1'b0;
        uses_rd = 1'b1;
        acc_qvalid_o = valid_instr;
        opa_select = Reg;
        opb_select = Reg;
        acc_register_rd = 1'b1;
      end
      // Offload FP-FP Instructions - fire and forget
      // TODO (smach): Check legal rounding modes and issue illegal isn if needed
      // Single Precision Floating-Point
      riscv_instr::FADD_S,
      riscv_instr::FSUB_S,
      riscv_instr::FMUL_S,
      riscv_instr::FDIV_S,
      riscv_instr::FSGNJ_S,
      riscv_instr::FSGNJN_S,
      riscv_instr::FSGNJX_S,
      riscv_instr::FMIN_S,
      riscv_instr::FMAX_S,
      riscv_instr::FSQRT_S,
      riscv_instr::FMADD_S,
      riscv_instr::FMSUB_S,
      riscv_instr::FNMSUB_S,
      riscv_instr::FNMADD_S: begin
        if (snitch_pkg::RVF) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Vectors
      riscv_instr::VFADD_S,
      riscv_instr::VFADD_R_S,
      riscv_instr::VFSUB_S,
      riscv_instr::VFSUB_R_S,
      riscv_instr::VFMUL_S,
      riscv_instr::VFMUL_R_S,
      riscv_instr::VFDIV_S,
      riscv_instr::VFDIV_R_S,
      riscv_instr::VFMIN_S,
      riscv_instr::VFMIN_R_S,
      riscv_instr::VFMAX_S,
      riscv_instr::VFMAX_R_S,
      riscv_instr::VFSQRT_S,
      riscv_instr::VFMAC_S,
      riscv_instr::VFMAC_R_S,
      riscv_instr::VFMRE_S,
      riscv_instr::VFMRE_R_S,
      riscv_instr::VFSGNJ_S,
      riscv_instr::VFSGNJ_R_S,
      riscv_instr::VFSGNJN_S,
      riscv_instr::VFSGNJN_R_S,
      riscv_instr::VFSGNJX_S,
      riscv_instr::VFSGNJX_R_S,
      riscv_instr::VFCPKA_S_S,
      riscv_instr::VFCPKA_S_D: begin
        if (snitch_pkg::XFVEC && snitch_pkg::RVF && snitch_pkg::RVD) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Double Precision Floating-Point
      riscv_instr::FADD_D,
      riscv_instr::FSUB_D,
      riscv_instr::FMUL_D,
      riscv_instr::FDIV_D,
      riscv_instr::FSGNJ_D,
      riscv_instr::FSGNJN_D,
      riscv_instr::FSGNJX_D,
      riscv_instr::FMIN_D,
      riscv_instr::FMAX_D,
      riscv_instr::FSQRT_D,
      riscv_instr::FMADD_D,
      riscv_instr::FMSUB_D,
      riscv_instr::FNMSUB_D,
      riscv_instr::FNMADD_D: begin
        if (snitch_pkg::RVD) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::FCVT_S_D,
      riscv_instr::FCVT_D_S: begin
        if (snitch_pkg::RVF && snitch_pkg::RVD) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // [Alt] Half Precision Floating-Point
      riscv_instr::FADD_H,
      riscv_instr::FSUB_H,
      riscv_instr::FMUL_H,
      riscv_instr::FDIV_H,
      riscv_instr::FSQRT_H,
      riscv_instr::FMADD_H,
      riscv_instr::FMSUB_H,
      riscv_instr::FNMSUB_H,
      riscv_instr::FNMADD_H: begin
        if ((snitch_pkg::XF16 && inst_data_i[14:12] inside {[3'b000:3'b100], 3'b111}) ||
            (snitch_pkg::XF16ALT && inst_data_i[14:12] == 3'b101)) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Half Precision Floating-Point
      riscv_instr::FSGNJ_H,
      riscv_instr::FSGNJN_H,
      riscv_instr::FSGNJX_H,
      riscv_instr::FMIN_H,
      riscv_instr::FMAX_H: begin
        if (snitch_pkg::XF16) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::FCVT_S_H,
      riscv_instr::FCVT_H_S: begin
        if (snitch_pkg::RVF) begin
          if ((snitch_pkg::XF16 && inst_data_i[14:12] inside {[3'b000:3'b100], 3'b111}) ||
              (snitch_pkg::XF16ALT && inst_data_i[14:12] == 3'b101)) begin
            write_rd = 1'b0;
            acc_qvalid_o = valid_instr;
          end else begin
            illegal_inst = 1'b1;
          end
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::FCVT_D_H,
      riscv_instr::FCVT_H_D: begin
        if (snitch_pkg::RVD) begin
          if ((snitch_pkg::XF16 && inst_data_i[14:12] inside {[3'b000:3'b100], 3'b111}) ||
              (snitch_pkg::XF16ALT && inst_data_i[14:12] == 3'b101)) begin
            write_rd = 1'b0;
            acc_qvalid_o = valid_instr;
          end else begin
            illegal_inst = 1'b1;
          end
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Vectors
      riscv_instr::VFADD_H,
      riscv_instr::VFADD_R_H,
      riscv_instr::VFSUB_H,
      riscv_instr::VFSUB_R_H,
      riscv_instr::VFMUL_H,
      riscv_instr::VFMUL_R_H,
      riscv_instr::VFDIV_H,
      riscv_instr::VFDIV_R_H,
      riscv_instr::VFMIN_H,
      riscv_instr::VFMIN_R_H,
      riscv_instr::VFMAX_H,
      riscv_instr::VFMAX_R_H,
      riscv_instr::VFSQRT_H,
      riscv_instr::VFMAC_H,
      riscv_instr::VFMAC_R_H,
      riscv_instr::VFMRE_H,
      riscv_instr::VFMRE_R_H,
      riscv_instr::VFSGNJ_H,
      riscv_instr::VFSGNJ_R_H,
      riscv_instr::VFSGNJN_H,
      riscv_instr::VFSGNJN_R_H,
      riscv_instr::VFSGNJX_H,
      riscv_instr::VFSGNJX_R_H,
      riscv_instr::VFCPKA_H_S: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF16 && snitch_pkg::RVF) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::VFCVT_S_H,
      riscv_instr::VFCVTU_S_H,
      riscv_instr::VFCVT_H_S,
      riscv_instr::VFCVTU_H_S,
      riscv_instr::VFCPKB_H_S,
      riscv_instr::VFCPKA_H_D,
      riscv_instr::VFCPKB_H_D: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF16 && snitch_pkg::RVF && snitch_pkg::RVD) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Alternate Half Precision Floating-Point
      riscv_instr::FSGNJ_AH,
      riscv_instr::FSGNJN_AH,
      riscv_instr::FSGNJX_AH,
      riscv_instr::FMIN_AH,
      riscv_instr::FMAX_AH: begin
        if (snitch_pkg::XF16ALT) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::FCVT_S_AH: begin
        if (snitch_pkg::RVF && snitch_pkg::XF16ALT) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::FCVT_D_AH: begin
        if (snitch_pkg::RVD && snitch_pkg::XF16ALT) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::FCVT_H_AH,
      riscv_instr::FCVT_AH_H: begin
        if (snitch_pkg::XF16 && snitch_pkg::XF16ALT) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Vectors
      riscv_instr::VFADD_AH,
      riscv_instr::VFADD_R_AH,
      riscv_instr::VFSUB_AH,
      riscv_instr::VFSUB_R_AH,
      riscv_instr::VFMUL_AH,
      riscv_instr::VFMUL_R_AH,
      riscv_instr::VFDIV_AH,
      riscv_instr::VFDIV_R_AH,
      riscv_instr::VFMIN_AH,
      riscv_instr::VFMIN_R_AH,
      riscv_instr::VFMAX_AH,
      riscv_instr::VFMAX_R_AH,
      riscv_instr::VFSQRT_AH,
      riscv_instr::VFMAC_AH,
      riscv_instr::VFMAC_R_AH,
      riscv_instr::VFMRE_AH,
      riscv_instr::VFMRE_R_AH,
      riscv_instr::VFSGNJ_AH,
      riscv_instr::VFSGNJ_R_AH,
      riscv_instr::VFSGNJN_AH,
      riscv_instr::VFSGNJN_R_AH,
      riscv_instr::VFSGNJX_AH,
      riscv_instr::VFSGNJX_R_AH,
      riscv_instr::VFCPKA_AH_S: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF16ALT && snitch_pkg::RVF) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::VFCVT_S_AH,
      riscv_instr::VFCVTU_S_AH,
      riscv_instr::VFCVT_AH_S,
      riscv_instr::VFCVTU_AH_S,
      riscv_instr::VFCPKB_AH_S,
      riscv_instr::VFCPKA_AH_D,
      riscv_instr::VFCPKB_AH_D: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF16ALT && snitch_pkg::RVF && snitch_pkg::RVD) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::VFCVT_H_AH,
      riscv_instr::VFCVTU_H_AH,
      riscv_instr::VFCVT_AH_H,
      riscv_instr::VFCVTU_AH_H: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF16ALT && snitch_pkg::XF16 && snitch_pkg::RVF) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Quarter Precision Floating-Point
      riscv_instr::FADD_B,
      riscv_instr::FSUB_B,
      riscv_instr::FMUL_B,
      riscv_instr::FDIV_B,
      riscv_instr::FSGNJ_B,
      riscv_instr::FSGNJN_B,
      riscv_instr::FSGNJX_B,
      riscv_instr::FMIN_B,
      riscv_instr::FMAX_B,
      riscv_instr::FSQRT_B,
      riscv_instr::FMADD_B,
      riscv_instr::FMSUB_B,
      riscv_instr::FNMSUB_B,
      riscv_instr::FNMADD_B: begin
        if (snitch_pkg::XF8) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::FCVT_S_B,
      riscv_instr::FCVT_B_S: begin
        if (snitch_pkg::RVF && snitch_pkg::XF8) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::FCVT_D_B,
      riscv_instr::FCVT_B_D: begin
        if (snitch_pkg::RVD && snitch_pkg::XF8) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::FCVT_H_B,
      riscv_instr::FCVT_B_H: begin
        if (snitch_pkg::XF16 && snitch_pkg::XF8) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::FCVT_AH_B,
      riscv_instr::FCVT_B_AH: begin
        if (snitch_pkg::RVF && snitch_pkg::RVD) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Vectors
      riscv_instr::VFADD_B,
      riscv_instr::VFADD_R_B,
      riscv_instr::VFSUB_B,
      riscv_instr::VFSUB_R_B,
      riscv_instr::VFMUL_B,
      riscv_instr::VFMUL_R_B,
      riscv_instr::VFDIV_B,
      riscv_instr::VFDIV_R_B,
      riscv_instr::VFMIN_B,
      riscv_instr::VFMIN_R_B,
      riscv_instr::VFMAX_B,
      riscv_instr::VFMAX_R_B,
      riscv_instr::VFSQRT_B,
      riscv_instr::VFMAC_B,
      riscv_instr::VFMAC_R_B,
      riscv_instr::VFMRE_B,
      riscv_instr::VFMRE_R_B,
      riscv_instr::VFSGNJ_B,
      riscv_instr::VFSGNJ_R_B,
      riscv_instr::VFSGNJN_B,
      riscv_instr::VFSGNJN_R_B,
      riscv_instr::VFSGNJX_B,
      riscv_instr::VFSGNJX_R_B: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF8 && snitch_pkg::FLEN >= 16) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::VFCPKA_B_S,
      riscv_instr::VFCPKB_B_S: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF8 && snitch_pkg::RVF) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::VFCVT_S_B,
      riscv_instr::VFCVTU_S_B,
      riscv_instr::VFCVT_B_S,
      riscv_instr::VFCVTU_B_S: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF8 && snitch_pkg::RVF && snitch_pkg::FLEN >= 64) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::VFCPKC_B_S,
      riscv_instr::VFCPKD_B_S,
      riscv_instr::VFCPKA_B_D,
      riscv_instr::VFCPKB_B_D,
      riscv_instr::VFCPKC_B_D,
      riscv_instr::VFCPKD_B_D: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF8 && snitch_pkg::RVD) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::VFCVT_H_B,
      riscv_instr::VFCVTU_H_B,
      riscv_instr::VFCVT_B_H,
      riscv_instr::VFCVTU_B_H: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF8 && snitch_pkg::XF16 && snitch_pkg::FLEN >= 32) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::VFCVT_AH_B,
      riscv_instr::VFCVTU_AH_B,
      riscv_instr::VFCVT_B_AH,
      riscv_instr::VFCVTU_B_AH: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF8 && snitch_pkg::XF16ALT && snitch_pkg::FLEN >= 32) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Offload FP-Int Instructions - fire and forget
      // Single Precision Floating-Point
      riscv_instr::FLE_S,
      riscv_instr::FLT_S,
      riscv_instr::FEQ_S,
      riscv_instr::FCLASS_S,
      riscv_instr::FCVT_W_S,
      riscv_instr::FCVT_WU_S,
      riscv_instr::FMV_X_W: begin
        if (snitch_pkg::RVF) begin
          write_rd = 1'b0;
          uses_rd = 1'b1;
          acc_qvalid_o = valid_instr;
          acc_register_rd = 1'b1; // No RS in GPR but RD in GPR, register in int scoreboard
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Vectors
      riscv_instr::VFEQ_S,
      riscv_instr::VFEQ_R_S,
      riscv_instr::VFNE_S,
      riscv_instr::VFNE_R_S,
      riscv_instr::VFLT_S,
      riscv_instr::VFLT_R_S,
      riscv_instr::VFGE_S,
      riscv_instr::VFGE_R_S,
      riscv_instr::VFLE_S,
      riscv_instr::VFLE_R_S,
      riscv_instr::VFGT_S,
      riscv_instr::VFGT_R_S,
      riscv_instr::VFCLASS_S: begin
        if (snitch_pkg::XFVEC && snitch_pkg::RVF && snitch_pkg::FLEN >= 64) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Double Precision Floating-Point
      riscv_instr::FLE_D,
      riscv_instr::FLT_D,
      riscv_instr::FEQ_D,
      riscv_instr::FCLASS_D,
      riscv_instr::FCVT_W_D,
      riscv_instr::FCVT_WU_D: begin
        if (snitch_pkg::RVD) begin
          write_rd = 1'b0;
          uses_rd = 1'b1;
          acc_qvalid_o = valid_instr;
          acc_register_rd = 1'b1; // No RS in GPR but RD in GPR, register in int scoreboard
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Half Precision Floating-Point
      riscv_instr::FLE_H,
      riscv_instr::FLT_H,
      riscv_instr::FEQ_H,
      riscv_instr::FCLASS_H,
      riscv_instr::FCVT_W_H,
      riscv_instr::FCVT_WU_H,
      riscv_instr::FMV_X_H: begin
        if ((snitch_pkg::XF16 && inst_data_i[14:12] inside {[3'b000:3'b100], 3'b111}) ||
              (snitch_pkg::XF16ALT && inst_data_i[14:12] == 3'b101)) begin
          write_rd = 1'b0;
          uses_rd = 1'b1;
          acc_qvalid_o = valid_instr;
          acc_register_rd = 1'b1; // No RS in GPR but RD in GPR, register in int scoreboard
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Vectors
      riscv_instr::VFEQ_H,
      riscv_instr::VFEQ_R_H,
      riscv_instr::VFNE_H,
      riscv_instr::VFNE_R_H,
      riscv_instr::VFLT_H,
      riscv_instr::VFLT_R_H,
      riscv_instr::VFGE_H,
      riscv_instr::VFGE_R_H,
      riscv_instr::VFLE_H,
      riscv_instr::VFLE_R_H,
      riscv_instr::VFGT_H,
      riscv_instr::VFGT_R_H,
      riscv_instr::VFCLASS_H: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF16 && snitch_pkg::FLEN >= 32) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::VFMV_X_H,
      riscv_instr::VFCVT_X_H,
      riscv_instr::VFCVT_XU_H: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF16 && snitch_pkg::FLEN >= 32 && ~snitch_pkg::RVD) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Alternate Half Precision Floating-Point
      riscv_instr::FLE_AH,
      riscv_instr::FLT_AH,
      riscv_instr::FEQ_AH,
      riscv_instr::FCLASS_AH,
      riscv_instr::FMV_X_AH: begin
        if (snitch_pkg::XF16ALT) begin
          write_rd = 1'b0;
          uses_rd = 1'b1;
          acc_qvalid_o = valid_instr;
          acc_register_rd = 1'b1; // No RS in GPR but RD in GPR, register in int scoreboard
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Vectors
      riscv_instr::VFEQ_AH,
      riscv_instr::VFEQ_R_AH,
      riscv_instr::VFNE_AH,
      riscv_instr::VFNE_R_AH,
      riscv_instr::VFLT_AH,
      riscv_instr::VFLT_R_AH,
      riscv_instr::VFGE_AH,
      riscv_instr::VFGE_R_AH,
      riscv_instr::VFLE_AH,
      riscv_instr::VFLE_R_AH,
      riscv_instr::VFGT_AH,
      riscv_instr::VFGT_R_AH,
      riscv_instr::VFCLASS_AH: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF16ALT && snitch_pkg::FLEN >= 32) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::VFMV_X_AH,
      riscv_instr::VFCVT_X_AH,
      riscv_instr::VFCVT_XU_AH: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF16ALT && snitch_pkg::FLEN >= 32 && ~snitch_pkg::RVD) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Quarter Precision Floating-Point
      riscv_instr::FLE_B,
      riscv_instr::FLT_B,
      riscv_instr::FEQ_B,
      riscv_instr::FCLASS_B,
      riscv_instr::FCVT_W_B,
      riscv_instr::FCVT_WU_B,
      riscv_instr::FMV_X_B: begin
        if (snitch_pkg::XF8) begin
          write_rd = 1'b0;
          uses_rd = 1'b1;
          acc_qvalid_o = valid_instr;
          acc_register_rd = 1'b1; // No RS in GPR but RD in GPR, register in int scoreboard
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Vectors
      riscv_instr::VFEQ_B,
      riscv_instr::VFEQ_R_B,
      riscv_instr::VFNE_B,
      riscv_instr::VFNE_R_B,
      riscv_instr::VFLT_B,
      riscv_instr::VFLT_R_B,
      riscv_instr::VFGE_B,
      riscv_instr::VFGE_R_B,
      riscv_instr::VFLE_B,
      riscv_instr::VFLE_R_B,
      riscv_instr::VFGT_B,
      riscv_instr::VFGT_R_B: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF8 && snitch_pkg::FLEN >= 16) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::VFMV_X_B,
      riscv_instr::VFCLASS_B,
      riscv_instr::VFCVT_X_B,
      riscv_instr::VFCVT_XU_B: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF8 && snitch_pkg::FLEN >= 16 && ~snitch_pkg::RVD) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Offload Int-FP Instructions - fire and forget
      // Single Precision Floating-Point
      riscv_instr::FMV_W_X,
      riscv_instr::FCVT_S_W,
      riscv_instr::FCVT_S_WU: begin
        if (snitch_pkg::RVF) begin
          opa_select = Reg;
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Double Precision Floating-Point
      riscv_instr::FCVT_D_W,
      riscv_instr::FCVT_D_WU: begin
        if (snitch_pkg::RVD) begin
          opa_select = Reg;
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Half Precision Floating-Point
      riscv_instr::FMV_H_X,
      riscv_instr::FCVT_H_W,
      riscv_instr::FCVT_H_WU: begin
        if (snitch_pkg::XF16) begin
          opa_select = Reg;
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Vectors
      riscv_instr::VFMV_H_X,
      riscv_instr::VFCVT_H_X,
      riscv_instr::VFCVT_H_XU: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF16 && snitch_pkg::FLEN >= 32 && ~snitch_pkg::RVD) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Alternate Half Precision Floating-Point
      riscv_instr::FMV_AH_X: begin
        if (snitch_pkg::XF16ALT) begin
          opa_select = Reg;
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Vectors
      riscv_instr::VFMV_AH_X,
      riscv_instr::VFCVT_AH_X,
      riscv_instr::VFCVT_AH_XU: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF16ALT && snitch_pkg::FLEN >= 32 && ~snitch_pkg::RVD) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Quarter Precision Floating-Point
      riscv_instr::FMV_B_X,
      riscv_instr::FCVT_B_W,
      riscv_instr::FCVT_B_WU: begin
        if (snitch_pkg::XF8) begin
          opa_select = Reg;
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Vectors
      riscv_instr::VFMV_B_X,
      riscv_instr::VFCVT_B_X,
      riscv_instr::VFCVT_B_XU: begin
        if (snitch_pkg::XFVEC && snitch_pkg::XF8 && snitch_pkg::FLEN >= 16 && ~snitch_pkg::RVD) begin
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // FP Sequencer
      riscv_instr::FREP: begin
        if (snitch_pkg::FP_PRESENT)
          opa_select = Reg;
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
      end
      // Floating-Point Load/Store
      // Single Precision Floating-Point
      riscv_instr::FLW: begin
        if (snitch_pkg::RVF) begin
          opa_select = Reg;
          opb_select = IImmediate;
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
          ls_size = Word;
          is_fp_load = 1'b1;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::FSW: begin
        if (snitch_pkg::RVF) begin
          opa_select = Reg;
          opb_select = SFImmediate;
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
          ls_size = Word;
          is_fp_store = 1'b1;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Double Precision Floating-Point
      riscv_instr::FLD: begin
        if (snitch_pkg::RVD || snitch_pkg::XFVEC) begin
          opa_select = Reg;
          opb_select = IImmediate;
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
          ls_size = Double;
          is_fp_load = 1'b1;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::FSD: begin
        if (snitch_pkg::RVD || snitch_pkg::XFVEC) begin
          opa_select = Reg;
          opb_select = SFImmediate;
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
          ls_size = Double;
          is_fp_store = 1'b1;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Half Precision Floating-Point
      riscv_instr::FLH: begin
        if (snitch_pkg::XF16 || snitch_pkg::XF16ALT) begin
          opa_select = Reg;
          opb_select = IImmediate;
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
          ls_size = HalfWord;
          is_fp_load = 1'b1;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::FSH: begin
        if (snitch_pkg::XF16 || snitch_pkg::XF16ALT) begin
          opa_select = Reg;
          opb_select = SFImmediate;
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
          ls_size = HalfWord;
          is_fp_store = 1'b1;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Quarter Precision Floating-Point
      riscv_instr::FLB: begin
        if (snitch_pkg::XF8) begin
          opa_select = Reg;
          opb_select = IImmediate;
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
          ls_size = Byte;
          is_fp_load = 1'b1;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      riscv_instr::FSB: begin
        if (snitch_pkg::XF8) begin
          opa_select = Reg;
          opb_select = SFImmediate;
          write_rd = 1'b0;
          acc_qvalid_o = valid_instr;
          ls_size = Byte;
          is_fp_store = 1'b1;
        end else begin
          illegal_inst = 1'b1;
        end
      end
      // Offload Multiply Instructions
      // TODO(zarubaf): Illegal Instructions
      default: begin
        illegal_inst = 1'b1;
      end
    endcase

    // Sanitize illegal instructions so that they don't exert any side-effects.
    if (exception) begin
     write_rd = 1'b0;
     uses_rd = 1'b0;
     acc_qvalid_o = 1'b0;
     next_pc = Exception;
    end
  end

  assign exception = illegal_inst | ld_addr_misaligned | st_addr_misaligned;

  // pragma translate_off
  always_ff @(posedge clk_i) begin
    if (!rst_i && illegal_inst && inst_valid_o && inst_ready_i) begin
      $display("[Illegal Instruction Core %0d] PC: %h Data: %h", hart_id_i, inst_addr_o, inst_data_i);
    end
  end
  // pragma translate_on

  // CSR logic
  always_comb begin
    csr_rvalue = '0;
    // registers
    fcsr_d = fcsr_q;
    fcsr_d.fflags = fcsr_q.fflags;

    // TODO(zarubaf): Needs some more input handling, like illegal instruction exceptions.
    // Right now we skip this due to simplicity.
    if (csr_en) begin
      unique case (inst_data_i[31:20])
        riscv_instr::CSR_MHARTID: begin
          csr_rvalue = hart_id_i;
        end
        `ifdef SNITCH_ENABLE_PERF
        riscv_instr::CSR_MCYCLE: begin
          csr_rvalue = cycle_q[31:0];
        end
        riscv_instr::CSR_MINSTRET: begin
          csr_rvalue = instret_q[31:0];
        end
        riscv_instr::CSR_MCYCLEH: begin
          csr_rvalue = cycle_q[63:32];
        end
        riscv_instr::CSR_MINSTRETH: begin
          csr_rvalue = instret_q[63:32];
        end
        `endif
        riscv_instr::CSR_FFLAGS: begin
          csr_rvalue = {27'b0, fcsr_q.fflags};
          fcsr_d.fflags = fpnew_pkg::status_t'(alu_result[4:0]);
        end
        riscv_instr::CSR_FRM: begin
          csr_rvalue = {29'b0, fcsr_q.frm};
          fcsr_d.frm = fpnew_pkg::roundmode_e'(alu_result[2:0]);
        end
        riscv_instr::CSR_FCSR: begin
          csr_rvalue = {24'b0, fcsr_q};
          fcsr_d = fcsr_t'(alu_result[7:0]);
        end
        default: csr_rvalue = '0;
      endcase
    end
  end

  snitch_regfile #(
    .DATA_WIDTH     ( 32       ),
    .NR_READ_PORTS  ( 2        ),
    .NR_WRITE_PORTS ( 1        ),
    .ZERO_REG_ZERO  ( 1        ),
    .ADDR_WIDTH     ( RegWidth )
  ) i_snitch_regfile (
    .clk_i,
    .raddr_i   ( gpr_raddr ),
    .rdata_o   ( gpr_rdata ),
    .waddr_i   ( gpr_waddr ),
    .wdata_i   ( gpr_wdata ),
    .we_i      ( gpr_we    )
  );

  // --------------------
  // Operand Select
  // --------------------
  always_comb begin
    unique case (opa_select)
      None: opa = '0;
      Reg: opa = gpr_rdata[0];
      UImmediate: opa = uimm;
      JImmediate: opa = jimm;
      CSRImmmediate: opa = {{{32-RegWidth}{1'b0}}, rs1};
      default: opa = '0;
    endcase
  end

  always_comb begin
    unique case (opb_select)
      None: opb = '0;
      Reg: opb = gpr_rdata[1];
      IImmediate: opb = iimm;
      SFImmediate, SImmediate: opb = simm;
      PC: opb = pc_q;
      CSR: opb = csr_rvalue;
      default: opb = '0;
    endcase
  end

  assign gpr_raddr[0] = rs1;
  assign gpr_raddr[1] = rs2;

  // --------------------
  // ALU
  // --------------------
  // Main Shifter
  logic [31:0] shift_opa, shift_opa_reversed;
  logic [31:0] shift_right_result, shift_left_result;
  logic [32:0] shift_opa_ext, shift_right_result_ext;
  logic shift_left, shift_arithmetic; // shift control
  for (genvar i = 0; i < 32; i++) begin : gen_reverse_opa
    assign shift_opa_reversed[i] = opa[31-i];
    assign shift_left_result[i] = shift_right_result[31-i];
  end
  assign shift_opa = shift_left ? shift_opa_reversed : opa;
  assign shift_opa_ext = {shift_opa[31] & shift_arithmetic, shift_opa};
  assign shift_right_result_ext = $unsigned($signed(shift_opa_ext) >>> opb[4:0]);
  assign shift_right_result = shift_right_result_ext[31:0];

  // Main Adder
  logic [32:0] alu_opa, alu_opb;
  assign adder_result = alu_opa + alu_opb;

  // ALU
  /* verilator lint_off WIDTH */
  always_comb begin
    alu_opa = $signed(opa);
    alu_opb = $signed(opb);

    alu_result = adder_result[31:0];
    shift_left = 1'b0;
    shift_arithmetic = 1'b0;

    unique case (alu_op)
      Sub: alu_opb = -$signed(opb);
      Slt: begin
        alu_opb = -$signed(opb);
        alu_result = {30'b0, adder_result[32]};
      end
      Ge: begin
        alu_opb = -$signed(opb);
        alu_result = {30'b0, ~adder_result[32]};
      end
      Sltu: begin
        alu_opa = $unsigned(opa);
        alu_opb = -$unsigned(opb);
        alu_result = {30'b0, adder_result[32]};
      end
      Geu: begin
        alu_opa = $unsigned(opa);
        alu_opb = -$unsigned(opb);
        alu_result = {30'b0, ~adder_result[32]};
      end
      Sll: begin
        shift_left = 1'b1;
        alu_result = shift_left_result;
      end
      Srl: alu_result = shift_right_result;
      Sra: begin
        shift_arithmetic = 1'b1;
        alu_result = shift_right_result;
      end
      LXor: alu_result = opa ^ opb;
      LAnd: alu_result = opa & opb;
      LNAnd: alu_result = (~opa) & opb;
      LOr: alu_result = opa | opb;
      Eq: begin
        alu_opb = -$signed(opb);
        alu_result = ~|adder_result;
      end
      Neq: begin
        alu_opb = -$signed(opb);
        alu_result = |adder_result;
      end
      BypassA: begin
        alu_result = opa;
      end
      default: alu_result = adder_result[31:0];
    endcase
  end
  /* verilator lint_on WIDTH */

  // --------------------
  // LSU
  // --------------------
  snitch_lsu #(
    .tag_t               ( logic[RegWidth-1:0]                ),
    .NumOutstandingLoads ( snitch_pkg::NumIntOutstandingLoads )
  ) i_snitch_lsu (
    .clk_i                                ,
    .rst_i                                ,
    .lsu_qtag_i   ( rd                    ),
    .lsu_qwrite   ( is_store              ),
    .lsu_qsigned  ( is_signed             ),
    .lsu_qaddr_i  ( alu_result            ),
    .lsu_qdata_i  ( gpr_rdata[1]          ),
    .lsu_qsize_i  ( ls_size               ),
    .lsu_qamo_i   ( ls_amo                ),
    .lsu_qvalid_i ( lsu_qvalid            ),
    .lsu_qready_o ( lsu_qready            ),
    .lsu_pdata_o  ( ld_result             ),
    .lsu_ptag_o   ( lsu_rd                ),
    .lsu_perror_o (                       ), // ignored for the moment
    .lsu_pvalid_o ( lsu_pvalid            ),
    .lsu_pready_i ( lsu_pready            ),
    .data_qaddr_o                          ,
    .data_qwrite_o                         ,
    .data_qdata_o                          ,
    .data_qamo_o                           ,
    .data_qstrb_o                          ,
    .data_qvalid_o                         ,
    .data_qready_i                         ,
    .data_pdata_i                          ,
    .data_perror_i                         ,
    .data_pvalid_i                         ,
    .data_pready_o
  );

  assign lsu_qvalid = valid_instr & (is_load | is_store) & ~(ld_addr_misaligned | st_addr_misaligned);

  // we can retire if we are not stalling and if the instruction is writing a register
  assign retire_i = write_rd & valid_instr & (rd != 0);

  // -----------------------
  // Unaligned Address Check
  // -----------------------
  always_comb begin
    ls_misaligned = 1'b0;
    unique case (ls_size)
      HalfWord: if (alu_result[0] != 1'b0) ls_misaligned = 1'b1;
      Word: if (alu_result[1:0] != 2'b00) ls_misaligned = 1'b1;
      Double: if (alu_result[2:0] != 3'b000) ls_misaligned = 1'b1;
      default: ls_misaligned = 1'b0;
    endcase
  end

  assign st_addr_misaligned = ls_misaligned & (is_store | is_fp_store);
  assign ld_addr_misaligned = ls_misaligned & (is_load | is_fp_load);

  // pragma translate_off
  always_ff @(posedge clk_i) begin
    if (!rst_i && (ld_addr_misaligned || st_addr_misaligned) && inst_valid_o && inst_ready_i) begin
      $display("[Misaligned Load/Store Core %0d] PC: %h Data: %h", hart_id_i, inst_addr_o, inst_data_i);
    end
  end
  // pragma translate_on

  // --------------------
  // Write-Back
  // --------------------
  // Write-back data, can come from:
  // 1. ALU/Jump Target/Bypass
  // 2. LSU
  // 3. Accelerator Bus
  logic [31:0] alu_writeback;
  always_comb begin
    casez (rd_select)
      RdAlu: alu_writeback = alu_result;
      RdConsecPC: alu_writeback = consec_pc;
      RdBypass: alu_writeback = rd_bypass;
      default: alu_writeback = alu_result;
    endcase
  end

  always_comb begin
    gpr_we[0] = 1'b0;
    gpr_waddr[0] = rd;
    gpr_wdata[0] = alu_writeback;
    // external interfaces
    lsu_pready = 1'b0;
    acc_pready_o = 1'b0;
    retire_acc = 1'b0;
    retire_load = 1'b0;

    if (retire_i) begin
      gpr_we[0] = 1'b1;
    // if we are not retiring another instruction retire the load now
    end else if (lsu_pvalid) begin
      retire_load = 1'b1;
      gpr_we[0] = 1'b1;
      gpr_waddr[0] = lsu_rd;
      gpr_wdata[0] = ld_result[31:0];
      lsu_pready = 1'b1;
    end else if (acc_pvalid_i) begin
      retire_acc = 1'b1;
      gpr_we[0] = 1'b1;
      gpr_waddr[0] = acc_pid_i;
      gpr_wdata[0] = acc_pdata_i[31:0];
      acc_pready_o = 1'b1;
    end
  end

  // --------------------------
  // RISC-V Formal Interface
  // --------------------------
  `ifdef RISCV_FORMAL
    logic instr_addr_misaligned;
    logic ld_addr_misaligned_q;
    // check that the instruction is a control transfer instruction
    assign instr_addr_misaligned = (inst_data_i inside {
      riscv_instr::JAL,
      riscv_instr::JALR,
      riscv_instr::BEQ,
      riscv_instr::BNE,
      riscv_instr::BLT,
      riscv_instr::BLTU,
      riscv_instr::BGE,
      riscv_instr::BGEU
    }) && (pc_d[1:0] != 2'b0);


    // retire an instruction and increase ordering bit
    `FFLSR(rvfi_order[0], rvfi_order[0] + 1, rvfi_valid[0], '0, clk_i, rst_i)

    logic [31:0] ld_instr_q;
    logic [31:0] ld_addr_q;
    logic [4:0]  rs1_q;
    logic [31:0] rs1_data_q;
    logic [31:0] pc_qq;
    // we need to latch the load
    `FFLSR(ld_instr_q, inst_data_i, latch_load, '0, clk_i, rst_i)
    `FFLSR(ld_addr_q, data_qaddr_o, latch_load, '0, clk_i, rst_i)
    `FFLSR(rs1_q, rs1, latch_load, '0, clk_i, rst_i)
    `FFLSR(rs1_data_q, gpr_rdata[0], latch_load, '0, clk_i, rst_i)
    `FFLSR(pc_qq, pc_d, latch_load, '0, clk_i, rst_i)
    `FFLSR(ld_addr_misaligned_q, ld_addr_misaligned, latch_load, '0, clk_i, rst_i)

    // in case we don't retire another instruction on port 1 we can use it for loads
    logic retire_load_port1;

    assign retire_load_port1 = retire_load & stall;
    // NRET: 1
    assign rvfi_halt[0] = 1'b0;
    assign rvfi_mode[0] = 2'b11;
    assign rvfi_intr[0] = 1'b0;
    assign rvfi_valid[0] = !stall | retire_load;
    assign rvfi_insn[0] = retire_load_port1 ? ld_instr_q : (is_load ? '0 : inst_data_i);
    assign rvfi_trap[0] = retire_load_port1 ? ld_addr_misaligned_q : illegal_inst
                                                                   | instr_addr_misaligned
                                                                   | st_addr_misaligned;
    assign rvfi_rs1_addr[0]  = (retire_load_port1) ? rs1_q : rs1;
    assign rvfi_rs1_rdata[0] = (retire_load_port1) ? rs1_data_q : gpr_rdata[0];
    assign rvfi_rs2_addr[0]  = (retire_load_port1) ? '0 : rs2;
    assign rvfi_rs2_rdata[0] = (retire_load_port1) ? '0 : gpr_rdata[1];
    assign rvfi_rd_addr[0]   = (retire_load_port1) ? lsu_rd : ((gpr_we[0] && write_rd) ? rd : '0);
    assign rvfi_rd_wdata[0]  = (retire_load_port1) ? (lsu_rd != 0 ? ld_result[31:0] : '0) : (rd != 0 && gpr_we[0] && write_rd) ? gpr_wdata[0] : 0;
    assign rvfi_pc_rdata[0]  = (retire_load_port1) ? pc_qq : pc_q;
    assign rvfi_pc_wdata[0]  = (retire_load_port1) ? (pc_qq + 4) : pc_d;
    assign rvfi_mem_addr[0]  = (retire_load_port1) ? ld_addr_q : data_qaddr_o;
    assign rvfi_mem_wmask[0] = (retire_load_port1) ? '0 : ((data_qvalid_o && data_qready_i) ? data_qstrb_o[3:0] : '0);
    assign rvfi_mem_rmask[0] = (retire_load_port1) ? 4'hf : '0;
    assign rvfi_mem_rdata[0] = (retire_load_port1) ? data_pdata_i[31:0] : '0;
    assign rvfi_mem_wdata[0] = (retire_load_port1) ? '0 : data_qdata_o[31:0];
  `endif
endmodule