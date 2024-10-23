# Copyright 2021 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Author: Matheus Cavalcante, ETH Zurich

###############
##  MinPool  ##
###############
# 4x4 mesh, 16 groups, 2 tiles per group, 4 cores per tile

# Number of cores
num_cores ?= 128

# Number of groups
num_groups ?= 16

# Number of cores per MemPool tile
num_cores_per_tile ?= 4

# Number of shared divsqrt units per MemPool tile
# Defaults to 1 if xDivSqrt is activated
num_divsqrt_per_tile ?= 1

# FlooNoC configuration
num_remote_ports_per_tile ?= 3
num_directions ?= 5
num_x ?= 4

# L1 scratchpad banking factor
banking_factor ?= 8

#########################
##  AXI configuration  ##
#########################
# # AXI bus data width (in bits)
# axi_data_width ?= 256

# # Read-only cache line width in AXI interconnect (in bits)
# ro_line_width ?= 256

# Radix for hierarchical AXI interconnect
axi_hier_radix ?= 9 # num_cores_per_tile * num_tiles_per_group + num_dma_per_groups

# Number of AXI masters per group
axi_masters_per_group ?= 1

# Number of DMA backends in each group
dmas_per_group ?= 1 # Brust Length = 16

# L2 Banks/Channels
l2_size  ?= 16777216  # 1000000
l2_banks ?= 16