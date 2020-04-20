// Copyright 2020 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

// Author: Michael Schaffner <schaffner@iis.ee.ethz.ch>, ETH Zurich
//         Matheus Cavalcante <matheusd@iis.ee.ethz.ch>, ETH Zurich

// Date: 16.01.2020

// Description: Interconnect with support to variable target latencies with different
// network topologies. Currently supported are: full crossbar and radix-2/4 butterflies.
// Note that only the full crossbar allows NumIn/NumOut configurations that are not
// aligned to a power of 2.

import tcdm_interconnect_pkg::topo_e;

module variable_latency_interconnect #(
    // Global parameters
    parameter int unsigned NumIn             = 32                   , // Number of Initiators. Must be aligned with a power of 2 for butterflies.
    parameter int unsigned NumOut            = 64                   , // Number of Targets. Must be aligned with a power of 2 for butterflies.
    parameter int unsigned AddrWidth         = 32                   , // Address Width on the Initiator Side
    parameter int unsigned DataWidth         = 32                   , // Data Word Width
    parameter int unsigned BeWidth           = DataWidth/8          , // Byte Strobe Width
    parameter int unsigned AddrMemWidth      = 12                   , // Number of Address bits per Target
    parameter bit AxiVldRdy                  = 1'b0                 , // Valid/ready signaling.
    // Credit-based handshake. ready_o is a "credit grant" signal.
    // Initiators can only send requests if they have a credit.
    // Each request consumes a credit. A credit cannot be used on the same cycle it is issued.
    parameter bit CreditBasedHandshake       = 1'b0                 ,
    parameter int unsigned NumCredits        = 2                    , // Number of credits at each initiator port.
    // Spill registers
    // A bit set at position i indicates a spill register at the i-th crossbar layer.
    // The layers are counted starting at 0 from the initiator, for the requests, and from the target, for the responses.
    parameter logic [63:0] SpillRegisterReq  = 64'h0                ,
    parameter logic [63:0] SpillRegisterResp = 64'h0                ,
    // Determines the width of the byte offset in a memory word. Normally this can be left at the default value,
    // but sometimes it needs to be overridden (e.g., when metadata is supplied to the memory via the wdata signal).
    parameter int unsigned ByteOffWidth      = $clog2(DataWidth-1)-3,
    // Topology can be: LIC, BFLY2, BFLY4, CLOS
    parameter topo_e Topology                = tcdm_interconnect_pkg::LIC
  ) (
    input  logic                                 clk_i,
    input  logic                                 rst_ni,
    // Initiator side
    input  logic [NumIn-1:0]                     req_valid_i,     // Request valid
    output logic [NumIn-1:0]                     req_ready_o,     // Request ready
    input  logic [NumIn-1:0][AddrWidth-1:0]      req_tgt_addr_i,  // Target address
    input  logic [NumIn-1:0]                     req_wen_i,       // Write enable
    input  logic [NumIn-1:0][DataWidth-1:0]      req_wdata_i,     // Write data
    input  logic [NumIn-1:0][BeWidth-1:0]        req_be_i,        // Byte enable
    output logic [NumIn-1:0]                     resp_valid_o,    // Response valid
    input  logic [NumIn-1:0]                     resp_ready_i,    // Response ready
    output logic [NumIn-1:0][DataWidth-1:0]      resp_rdata_o,    // Data response
    // Target side
    output logic [NumOut-1:0]                    req_valid_o,     // Request valid
    input  logic [NumOut-1:0]                    req_ready_i,     // Request ready
    output logic [NumOut-1:0][$clog2(NumIn)-1:0] req_ini_addr_o,  // Initiator address
    output logic [NumOut-1:0][AddrMemWidth-1:0]  req_tgt_addr_o,  // Target address
    output logic [NumOut-1:0]                    req_wen_o,       // Write enable
    output logic [NumOut-1:0][DataWidth-1:0]     req_wdata_o,     // Write data
    output logic [NumOut-1:0][BeWidth-1:0]       req_be_o,        // Byte enable
    input  logic [NumOut-1:0]                    resp_valid_i,    // Response valid
    output logic [NumOut-1:0]                    resp_ready_o,    // Response ready
    input  logic [NumOut-1:0][$clog2(NumIn)-1:0] resp_ini_addr_i, // Initiator address
    input  logic [NumOut-1:0][DataWidth-1:0]     resp_rdata_i     // Data response
  );

  /******************
   *   Parameters   *
   ******************/

  // localparams and aggregation of address, wen and payload data

  localparam int unsigned NumOutLog2      = $clog2(NumOut);
  localparam int unsigned IniAggDataWidth = 1 + BeWidth + AddrMemWidth + DataWidth;

  /*************
   *  Signals  *
   *************/

  logic [NumIn-1:0][IniAggDataWidth-1:0]  data_agg_in;
  logic [NumOut-1:0][IniAggDataWidth-1:0] data_agg_out;
  logic [NumIn-1:0][NumOutLog2-1:0]       tgt_sel;

  for (genvar j = 0; unsigned'(j) < NumIn; j++) begin : gen_inputs
    // Extract target index
    assign tgt_sel[j] = req_tgt_addr_i[j][ByteOffWidth +: NumOutLog2];

    // Aggregate data to be routed to targets
    assign data_agg_in[j] = {req_wen_i[j], req_be_i[j], req_tgt_addr_i[j][ByteOffWidth + NumOutLog2 +: AddrMemWidth], req_wdata_i[j]};
  end

  // Disaggregate data
  for (genvar k = 0; unsigned'(k) < NumOut; k++) begin : gen_outputs
    assign {req_wen_o[k], req_be_o[k], req_tgt_addr_o[k], req_wdata_o[k]} = data_agg_out[k];
  end

  /****************
   *   Networks   *
   ****************/

  // Tuned logarithmic interconnect architecture, based on rr_arb_tree primitives
  if (Topology == tcdm_interconnect_pkg::LIC) begin : gen_lic
    full_duplex_xbar #(
      .NumIn               (NumIn               ),
      .NumOut              (NumOut              ),
      .ReqDataWidth        (IniAggDataWidth     ),
      .RespDataWidth       (DataWidth           ),
      .SpillRegisterReq    (SpillRegisterReq[0] ),
      .SpillRegisterResp   (SpillRegisterResp[0]),
      .AxiVldRdy           (AxiVldRdy           ),
      .CreditBasedHandshake(CreditBasedHandshake),
      .NumCredits          (NumCredits          )
    ) i_xbar (
      .clk_i          (clk_i          ),
      .rst_ni         (rst_ni         ),
      // Extern priority flags
      .req_rr_i       ('0             ),
      .resp_rr_i      ('0             ),
      // Initiator side
      .req_valid_i    (req_valid_i    ),
      .req_ready_o    (req_ready_o    ),
      .req_tgt_addr_i (tgt_sel        ),
      .req_wdata_i    (data_agg_in    ),
      .resp_valid_o   (resp_valid_o   ),
      .resp_rdata_o   (resp_rdata_o   ),
      .resp_ready_i   (resp_ready_i   ),
      // Target side
      .req_valid_o    (req_valid_o    ),
      .req_ini_addr_o (req_ini_addr_o ),
      .req_ready_i    (req_ready_i    ),
      .req_wdata_o    (data_agg_out   ),
      .resp_valid_i   (resp_valid_i   ),
      .resp_ready_o   (resp_ready_o   ),
      .resp_ini_addr_i(resp_ini_addr_i),
      .resp_rdata_i   (resp_rdata_i   )
    );
  end

  // Butterfly network (radix 2 or 4)
  else if (Topology == tcdm_interconnect_pkg::BFLY2 || Topology == tcdm_interconnect_pkg::BFLY4) begin: gen_bfly
    localparam int unsigned Radix = 2**Topology;

    variable_latency_bfly_net #(
      .NumIn               (NumIn               ),
      .NumOut              (NumOut              ),
      .DataWidth           (IniAggDataWidth     ),
      .Radix               (Radix               ),
      .ExtPrio             (1'b0                ),
      .SpillRegister       (SpillRegisterReq    ),
      .AxiVldRdy           (AxiVldRdy           ),
      .CreditBasedHandshake(CreditBasedHandshake),
      .NumCredits          (NumCredits          )
    ) i_req_bfly_net (
      .clk_i     (clk_i          ),
      .rst_ni    (rst_ni         ),
      // Extern priority flags
      .rr_i      ('0             ),
      // Initiator side
      .valid_i   (req_valid_i    ),
      .ready_o   (req_ready_o    ),
      .tgt_addr_i(tgt_sel        ),
      .wdata_i   (data_agg_in    ),
      // Target side
      .valid_o   (req_valid_o    ),
      .ini_addr_o(req_ini_addr_o ),
      .ready_i   (req_ready_i    ),
      .wdata_o   (data_agg_out   )
    );

    variable_latency_bfly_net #(
      .NumIn               (NumOut              ),
      .NumOut              (NumIn               ),
      .DataWidth           (DataWidth           ),
      .Radix               (Radix               ),
      .ExtPrio             (1'b0                ),
      .SpillRegister       (SpillRegisterResp   ),
      .AxiVldRdy           (AxiVldRdy           ),
      .CreditBasedHandshake(CreditBasedHandshake),
      .NumCredits          (NumCredits          )
    ) i_resp_bfly_net (
      .clk_i     (clk_i          ),
      .rst_ni    (rst_ni         ),
      // Extern priority flags
      .rr_i      ('0             ),
      // Target side
      .valid_i   (resp_valid_i   ),
      .ready_o   (resp_ready_o   ),
      .tgt_addr_i(resp_ini_addr_i),
      .wdata_i   (resp_rdata_i   ),
      // Initiator side
      .valid_o   (resp_valid_o   ),
      .ready_i   (resp_ready_i   ),
      .ini_addr_o(/* Unused */   ),
      .wdata_o   (resp_rdata_o   )
    );
  end

  // Unknown network
  else begin: gen_unknown
    $fatal(1, "[variable_latency_interconnect] Unknown TCDM configuration %d.", Topology);
  end

  /******************
   *   Assertions   *
   ******************/

  if (AddrMemWidth + NumOutLog2 > AddrWidth)
    $fatal(1, "[variable_latency_interconnect] Address is not wide enough to accomodate the requested TCDM configuration.");

  if (Topology != tcdm_interconnect_pkg::LIC && NumOut < NumIn)
    $fatal(1, "[variable_latency_interconnect] NumOut < NumIn is not supported with the chosen TCDM configuration.");

endmodule : variable_latency_interconnect
