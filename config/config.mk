# Copyright 2020 ETH Zurich and University of Bologna.
#
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Author: Samuel Riedel, ETH Zurich
#         Matheus Cavalcante, ETH Zurich

# Boot address (in hex)
boot_addr ?= 80010000

# Number of cores
num_cores ?= 256

# Number of cores per MemPool tile
num_cores_per_tile ?= 4
