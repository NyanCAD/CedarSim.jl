#!/usr/bin/env julia

"""
SPICE/Spectre/Verilog-A Netlist Converter

Convert netlists between different SPICE/Spectre dialects and to Verilog-A format.

Usage:
    julia convert.jl input.sp output.sp --output-simulator ngspice
    julia convert.jl circuit.sp circuit.va --output-simulator openvaf

Examples:
    # Convert Cordell models to ngspice-compatible format (filters doc parameters)
    julia convert.jl Cordell-Models.txt ngspice-models.sp --output-simulator ngspice

    # Convert SPICE to Verilog-A for OpenVAF
    julia convert.jl diode_divider.lib diode_divider.va --output-simulator openvaf

    # Convert SPICE to Spectre format
    julia convert.jl circuit.sp circuit.scs --output-simulator spectre

    # Explicitly specify input format
    julia convert.jl input.cir output.sp --input-lang spice --output-simulator ngspice
"""

using SpiceArmyKnife
using SpiceArmyKnife.SpectreNetlistParser
using ArgParse

function detect_input_language(filepath::String)
    """Auto-detect input file language from extension."""
    ext = lowercase(splitext(filepath)[2])
    if ext in [".sp", ".spi", ".spice", ".cir", ".lib"]
        return :spice
    elseif ext in [".scs", ".spectre"]
        return :spectre
    else
        # Default to SPICE for unknown extensions
        return :spice
    end
end

function parse_commandline()
    s = ArgParseSettings(
        description = "Convert SPICE/Spectre netlists between different dialects or to Verilog-A",
        epilog = """
            Examples:
              # Convert to ngspice (filters documentation parameters)
              \$ julia convert.jl models.txt ngspice-models.sp --output-simulator ngspice

              # Convert SPICE to Verilog-A for OpenVAF
              \$ julia convert.jl diode_divider.lib diode_divider.va --output-simulator openvaf

              # Convert SPICE to Spectre
              \$ julia convert.jl circuit.sp circuit.scs --output-simulator spectre

              # Specify input simulator explicitly
              \$ julia convert.jl input.cir output.sp --input-simulator hspice --output-simulator ngspice
            """
    )

    @add_arg_table! s begin
        "input"
            help = "Input netlist file"
            required = true
        "output"
            help = "Output netlist file"
            required = true
        "--input-simulator"
            help = "Input simulator: ngspice, hspice, pspice, xyce, spectre (determines language via language() trait)"
            arg_type = Symbol
            default = nothing
        "--input-lang", "-i"
            help = "Input language: spice or spectre (overrides --input-simulator, default: auto-detect from extension)"
            arg_type = Symbol
            default = nothing
        "--output-simulator", "-s"
            help = "Output simulator: ngspice, hspice, pspice, xyce, spectre, openvaf, gnucap (required)"
            arg_type = Symbol
            required = true
    end

    return parse_args(s)
end

function main()
    args = parse_commandline()

    input_file = args["input"]
    output_file = args["output"]
    input_simulator_sym = args["input-simulator"]
    input_lang = args["input-lang"]
    output_simulator_sym = args["output-simulator"]

    # Validate input file
    if !isfile(input_file)
        println("Error: Input file not found: $input_file")
        exit(1)
    end

    # Determine input language
    # Priority: --input-lang > --input-simulator > auto-detect
    if input_lang === nothing
        if input_simulator_sym !== nothing
            # Use language() trait from input simulator
            input_sim = simulator_from_symbol(input_simulator_sym)
            input_lang = language(input_sim)
            println("Input simulator: $input_simulator_sym → language: $input_lang")
        else
            # Auto-detect from file extension
            input_lang = detect_input_language(input_file)
            println("Auto-detected input language: $input_lang")
        end
    end

    # Map output simulator symbol to simulator instance
    output_sim = simulator_from_symbol(output_simulator_sym)
    output_lang = language(output_sim)

    println("=" ^ 80)
    println("SPICE/Spectre/Verilog-A Netlist Converter")
    println("=" ^ 80)
    println("Input:  $input_file ($input_lang)")
    println("Output: $output_file ($output_simulator_sym → $output_lang)")
    println("-" ^ 80)

    try
        # Parse input file
        println("Parsing input file...")
        ast = if input_lang == :spice
            SpectreNetlistParser.parsefile(input_file; start_lang=:spice, implicit_title=true)
        else
            SpectreNetlistParser.parsefile(input_file; start_lang=:spectre)
        end

        if ast.ps.errored
            println("⚠ Warning: Parse errors encountered in input file")
            println("  Attempting to generate output anyway...")
        else
            println("✓ Successfully parsed input file")
        end

        # Generate output
        println("Generating output code...")
        output_code = generate_code(ast, output_sim)

        # Write output file
        println("Writing output file...")
        open(output_file, "w") do io
            write(io, output_code)
        end

        file_size_kb = round(stat(output_file).size / 1024, digits=1)
        println("✓ Successfully wrote $output_file ($(file_size_kb) KB)")

        # Show what changes were applied based on target simulator
        if output_simulator_sym == :ngspice && output_lang == :spice
            println("\nNote: Ngspice compatibility conversions applied:")
            println("  - Removed documentation parameters: iave, vpk, mfg, type, icrating, vceo")
            println("  - Converted PSPICE temperature parameters (T_ABS→TEMP, T_REL_GLOBAL→DTEMP, T_MEASURED→TNOM)")
        elseif output_lang == :verilog_a
            println("\nNote: Verilog-A conversion applied:")
            println("  - Converted .model cards to `define macros")
            println("  - Converted .subckt to Verilog-A modules with electrical ports")
            println("  - Converted magnitude suffixes to exponential notation (1k→1e3, 2.682n→2.682e-9)")
            println("  - Device instances use primitive modules (resistor, capacitor, inductor, diode)")
        end

        println("=" ^ 80)
        println("✓ CONVERSION COMPLETE")
        println("=" ^ 80)

    catch e
        println("=" ^ 80)
        println("✗ CONVERSION FAILED")
        println("=" ^ 80)
        showerror(stdout, e, catch_backtrace())
        println()
        exit(1)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
