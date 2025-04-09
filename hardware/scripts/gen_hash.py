#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import argparse
import random

def generate_even_hash_mapping(key_width, seed, output_path):
    assert 1 <= key_width <= 16, "Only supports 1 <= key_width <= 16 for reasonable table size"
    num_entries = 2 ** key_width
    keys = list(range(num_entries))
    values = keys.copy()

    random.seed(seed)
    random.shuffle(values)

    with open(output_path, 'w') as f:
        f.write(f"// Fair hash function generated for input key width = {key_width}\n")
        f.write(f"// Total {num_entries} entries, random seed = {seed}\n\n")
        f.write("function automatic logic [{}:0] fair_hash(input logic [{}:0] key);\n".format(
            key_width - 1, key_width - 1
        ))
        f.write("  case (key)\n")
        for k, v in zip(keys, values):
            f.write("    {}'d{:2} : fair_hash = {}'d{:2};\n".format(key_width, k, key_width, v))
        f.write("    default : fair_hash = '0;\n")
        f.write("  endcase\n")
        f.write("endfunction\n")

    print(f"SystemVerilog fair hash function saved to: {output_path}")

def main():
    parser = argparse.ArgumentParser(description="Generate a fair and evenly distributed hash function in SystemVerilog.")
    parser.add_argument('--key-width', '-k', type=int, required=True, help='Width of the input key in bits (e.g., 4 for 0–15)')
    parser.add_argument('--seed', '-s', type=int, default=42, help='Random seed for reproducibility (default: 42)')
    parser.add_argument('--output', '-o', type=str, required=True, help='Output file path to save the SystemVerilog function')
    args = parser.parse_args()

    generate_even_hash_mapping(args.key_width, args.seed, args.output)

if __name__ == "__main__":
    main()
