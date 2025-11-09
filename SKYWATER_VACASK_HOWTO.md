# How to Convert SkyWater PDK to VACASK Format

This document describes the proper process for converting the SkyWater SKY130 PDK from ngspice format to VACASK-compatible Spectre format using spak-convert.

## Prerequisites

1. Julia 1.11+ installed and working
2. SpiceArmyKnife.jl dependencies installed (`julia --project=. -e 'using Pkg; Pkg.instantiate()'`)
3. VACASK simulator installed (tested with v0.3.1)
4. SkyWater PDK cloned from https://github.com/fossi-foundation/skywater-pdk-libs-sky130_fd_pr

## Conversion Process

### Using spak-convert

The correct tool to use is `spak-convert` from SpiceArmyKnife.jl:

```bash
julia --project=SpiceArmyKnife.jl SpiceArmyKnife.jl/src/Convert.jl \
    skywater-pdk-libs-sky130_fd_pr/combined_models/sky130.lib.spice \
    vacask_models/sky130.lib.spice \
    --input-simulator ngspice \
    --output-simulator vacask
```

This will:
- Parse the ngspice-format SkyWater PDK models
- Convert SPICE subcircuits to Spectre subckt format
- Convert .model cards to VACASK-compatible syntax
- Handle parameter translations and dialect differences

### Alternative: Per-Corner Conversion

For individual process corners:

```bash
julia --project=SpiceArmyKnife.jl SpiceArmyKnife.jl/src/Convert.jl \
    skywater-pdk-libs-sky130_fd_pr/models/corners/tt.spice \
    vacask_models/tt.spice \
    --input-simulator ngspice \
    --output-simulator vacask
```

## VACASK Test Circuit

Once converted, create a test circuit:

```spectre
SkyWater SKY130 transistor test

include "vacask_models/sky130.lib.spice" section=tt

model v vsource
v1 (1 0) v dc=1.0

subckt test()
  M1 (1 1 0 0) sky130_fd_pr__nfet_01v8 w=1e-6 l=0.5e-6
ends

control
  elaborate circuit("test")
  save default
  analysis op1 op
endc
```

## Running the Simulation

```bash
vacask sky130_test.sim
```

## Known Issues

### Environment Requirements
- Julia package manager must have internet access
- VACASK requires:
  - libklu2 (SuiteSparse)
  - libboost-filesystem
  - libboost-system

### Model Compatibility
- SkyWater uses BSIM4 (level 54) models
- VACASK supports BSIM4 via sp_bsim4v8 module
- Some advanced BSIM4 parameters may need adjustment

## Failed Attempt Notes

During the initial attempt, these approaches were tried but failed:
1. ❌ Using VACASK's ng2vc.py tool - has bugs parsing BSIM4 level parameters
2. ❌ Manual model card creation - not scalable for full PDK
3. ❌ Direct Julia script execution - dependency issues without proper package installation

The **correct** approach is using spak-convert with a properly configured Julia environment.
