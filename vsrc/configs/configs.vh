`define ISA_RV32I
`define CPU_TYPE_SINGLE_CYCLE
`define HALT_INST 32'h00100073  // ebreak

`define INSTR_MEM_START 32'h00400000
`define INSTR_MEM_SIZE  4096
`define INSTR_MEM_DEPTH 16
`define INSTR_MEM_INI   "mem/instr.ini"

`define DATA_MEM_START 32'h00000000
`define DATA_MEM_SIZE   4096
`define DATA_MEM_DEPTH  16
`define DATA_MEM_INI    "mem/data.ini"

`define SINGLE_CYCLE 1'b0
`define PIPELINE     1'b1
`define CORE_TYPE    `SINGLE_CYCLE
