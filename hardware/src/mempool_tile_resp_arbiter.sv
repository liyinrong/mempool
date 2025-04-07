`include "common_cells/registers.svh"

module mempool_tile_resp_arbiter #(
    parameter int unsigned NumInp = 16,
    parameter int unsigned AgeMatrixNumEnq = 2,
    parameter int unsigned NumOut = 3,
    parameter type         payload_t   = logic
) (
    input  logic clk_i,
    input  logic rst_ni,

    input  payload_t [NumInp-1:0] data_i,
    input  logic [NumInp-1:0] valid_i,
    output logic [NumInp-1:0] ready_o,

    output payload_t [NumOut-1:0] data_o,
    output logic [NumOut-1:0] valid_o,
    input  logic [NumOut-1:0] ready_i
);

  logic [NumInp-1:0] current_valid_new, current_valid_old;
  logic [NumInp-1:0] current_handshake;
  
  logic [NumInp-1:0] new_valid_d, new_valid_q, new_valid_d_set, new_valid_d_clr, new_valid_d_en;

  logic [AgeMatrixNumEnq-1:0] enq_fire;
  logic [AgeMatrixNumEnq-1:0] enq_empty;
  logic [AgeMatrixNumEnq-1:0][cf_math_pkg::idx_width(NumInp)-1:0] req_mask_idx;
  logic [AgeMatrixNumEnq-1:0][NumInp-1:0] enq_mask;
  logic [AgeMatrixNumEnq-1:0][NumInp-1:0] req_mask;
  logic [AgeMatrixNumEnq-1:0]             req_mask_vld;

  logic deq_fire;
  logic [NumInp-1:0] deq_mask;

  logic [NumOut-1:0] age_matrix_result_mask_vld;
  logic [NumOut-1:0][NumInp-1:0] age_matrix_result_mask;

  assign current_handshake = valid_i & ready_o;
  assign current_valid_new = valid_i & new_valid_q;
  assign current_valid_old = valid_i & ~new_valid_q;

  // generate the new_valid_q signal, which marks if the valid is new one (which should enqueue age matrix if not hsk) or not
  assign new_valid_d_en   = new_valid_d_set | new_valid_d_clr;
  assign new_valid_d_set  = valid_i & ready_o;
  assign new_valid_d_clr  = valid_i & ~ready_o;
  assign new_valid_d      = (new_valid_q | new_valid_d_set) & ~new_valid_d_clr;

  for (genvar b = 0; b < NumInp; b++) begin
    `FFL(new_valid_q[b], new_valid_d[b], new_valid_d_en[b], '1)
  end

  if(AgeMatrixNumEnq > 2) begin
    $warning("AgeMatrixNumEnq > 2, this is not supported yet by the age matrix.");
  end

  for (genvar i = 0; i < AgeMatrixNumEnq; i++) begin: gen_enq_fire
    lzc #(
      .WIDTH(NumInp),
      .MODE(i % 2)
    ) i_lzc (
      .in_i(current_valid_new),
      .cnt_o(req_mask_idx[i]),
      .empty_o(enq_empty[i])
    );
    if (i%2 == 0) begin: gen_req_vld_mask_even
      assign req_mask[i] = (1 << req_mask_idx[i]);
    end else begin: gen_req_vld_mask_odd
      logic [NumInp-1:0] req_vld_mask_tmp;
      assign req_vld_mask_tmp = (1 << req_mask_idx[i]);
      for (genvar j = 0; j < NumInp; j++) begin: gen_enq_mask_odd_inner
        assign req_mask[i][j] = req_vld_mask_tmp[NumInp-1 - j];
      end
    end
    assign enq_mask[i] = req_mask[i] & ~current_handshake;

    if (i == 0) begin
      assign req_mask_vld[i]  = ~enq_empty[i];
    end else begin
      assign req_mask_vld[i]  = ~enq_empty[i] & ~(|(req_mask[i] & req_mask[i-1])); // don't choose the same idx as the previous ones
    end
    assign enq_fire[i] = req_mask_vld[i] & |(enq_mask[i]);
  end

  assign deq_fire = |deq_mask;
  assign deq_mask = current_handshake & ~new_valid_q;

  for (genvar i = 0; i < NumOut; i++) begin: gen_result_mask_vld
    assign age_matrix_result_mask_vld[i] = |age_matrix_result_mask[i];
  end

  age_matrix #(
      .NumEntries (NumInp),
      .NumEnq     (AgeMatrixNumEnq    ),
      .NumSel     (NumOut    )
  ) i_age_matrix (
      .enq_fire_i   (enq_fire           ),
      .enq_mask_i   (enq_mask           ),
      .deq_fire_i   (deq_fire           ),
      .deq_mask_i   (deq_mask           ),
      .sel_mask_i   (current_valid_old  ),
      .result_mask_o(age_matrix_result_mask  ),
      .entry_vld_i  (current_valid_old  ),
      .clk_i        (clk_i              ),
      .rst_ni       (rst_ni             )
  );

  // if agematrix valid output number less than NumOut, choose new request(s) to fit the max output port number
  logic [NumOut+AgeMatrixNumEnq-1:0] combined_mask_valid;
  logic [NumOut+AgeMatrixNumEnq-1:0][NumInp-1:0] combined_mask;

  logic [NumOut-1:0][$clog2(NumOut+AgeMatrixNumEnq)-1:0] sel_inport_idx;
  logic [NumOut-1:0]                                     sel_inport_idx_vld;
  logic [NumOut+AgeMatrixNumEnq-1:0][$clog2(NumOut)-1:0] asn_outport_idx;
  logic [NumOut+AgeMatrixNumEnq-1:0]                     asn_outport_vld;

  assign combined_mask_valid = {req_mask_vld, age_matrix_result_mask_vld};
  assign combined_mask       = {req_mask, age_matrix_result_mask};

  mempool_tile_resp_select #(
    .InNum  (NumOut+AgeMatrixNumEnq),
    .OutNum (NumOut)
  ) i_mempool_tile_resp_select (
    .req_vector_i         (combined_mask_valid),
    .priority_i           ('0 ),
    .sel_inport_idx_o     (sel_inport_idx     ),
    .sel_inport_idx_vld_o (sel_inport_idx_vld ),
    .asn_outport_idx_o    (asn_outport_idx    ),
    .asn_outport_vld_o    (asn_outport_vld    )
  );

  logic [NumOut-1:0][NumInp-1:0] sel_inport_idx_sel_mask;
  logic [NumOut-1:0][$clog2(NumInp)-1:0] sel_inport_idx_sel_mask_bin;
  logic [NumOut-1:0]             sel_inport_idx_sel_mask_vld;
  generate
    for (genvar i = 0; i < NumOut; i++) begin: gen_sel_inport_idx_sel_mask
      assign sel_inport_idx_sel_mask[i]     = combined_mask[sel_inport_idx[i]];
      assign sel_inport_idx_sel_mask_vld[i] = sel_inport_idx_vld[i];

      onehot_to_bin #(
        .ONEHOT_WIDTH   (NumInp)
      ) i_onehot_to_bin (
        .onehot   (sel_inport_idx_sel_mask[i]),
        .bin      (sel_inport_idx_sel_mask_bin[i])
      );
    end
  endgenerate




  // data mux
  logic [NumOut-1:0][NumInp-1:0] mux_ready;
  logic [NumInp-1:0][NumOut-1:0] mux_ready_transpose;
  generate
    for (genvar i = 0; i < NumOut; i++) begin: gen_data_mux
      stream_mux #(
        .DATA_T ( payload_t ),
        .N_INP  ( NumInp  )
      ) i_stream_mux (
        .inp_data_i   ( data_i        ),
        .inp_valid_i  ( valid_i & {NumInp{sel_inport_idx_sel_mask_vld[i]}} ),
        .inp_ready_o  ( mux_ready[i]  ),
        .inp_sel_i    ( sel_inport_idx_sel_mask_bin[i] ),
        .oup_data_o   ( data_o[i]     ),
        .oup_valid_o  ( valid_o[i]    ),
        .oup_ready_i  ( ready_i[i]    )
      );
      for (genvar j = 0; j < NumInp; j++) begin: gen_mux_ready_transpose
        assign mux_ready_transpose[j][i] = mux_ready[i][j] & sel_inport_idx_sel_mask_vld[i];
      end
    end 
    for (genvar j = 0; j < NumInp; j++) begin: gen_mux_ready
      assign ready_o[j] = |mux_ready_transpose[j];
    end
  endgenerate


endmodule
