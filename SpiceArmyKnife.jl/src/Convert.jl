"""
SPICE/Spectre/Verilog-A Netlist Converter

Convert netlists between different SPICE/Spectre dialects and to Verilog-A format.

Usage:
    spak-convert input.sp output.sp --input-simulator pspice --output-simulator ngspice
    spak-convert circuit.sp circuit.va --input-simulator ngspice --output-simulator openvaf

Examples:
    # Convert Cordell models to ngspice-compatible format (filters doc parameters)
    spak-convert Cordell-Models.txt ngspice-models.sp --input-simulator pspice --output-simulator ngspice

    # Convert SPICE to Verilog-A for OpenVAF
    spak-convert diode_divider.lib diode_divider.va --input-simulator ngspice --output-simulator openvaf

    # Convert SPICE to Spectre format
    spak-convert circuit.sp circuit.scs --input-simulator ngspice --output-simulator spectre
"""
module Convert

using ..SpiceArmyKnife
using SpectreNetlistParser
using ArgParse

function parse_commandline(args)
    s = ArgParseSettings(
        description = "Convert SPICE/Spectre netlists between different dialects or to Verilog-A",
        epilog = """
            Examples:
              # Convert to ngspice (filters documentation parameters)
              \$ spak-convert models.txt ngspice-models.sp --input-simulator pspice --output-simulator ngspice

              # Convert SPICE to Verilog-A for OpenVAF
              \$ spak-convert diode_divider.lib diode_divider.va --input-simulator ngspice --output-simulator openvaf

              # Convert SPICE to Spectre
              \$ spak-convert circuit.sp circuit.scs --input-simulator ngspice --output-simulator spectre

              # Specify input simulator explicitly
              \$ spak-convert input.cir output.sp --input-simulator hspice --output-simulator ngspice
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
            required = true
        "--output-simulator", "-s"
            help = "Output simulator: ngspice, hspice, pspice, xyce, spectre, openvaf, gnucap (required)"
            arg_type = Symbol
            required = true
    end

    return parse_args(args, s)
end

function (@main)(ARGS)
    args = parse_commandline(ARGS)

    input_file = args["input"]
    output_file = args["output"]
    input_simulator_sym = args["input-simulator"]
    output_simulator_sym = args["output-simulator"]

    # Validate input file
    if !isfile(input_file)
        println("Error: Input file not found: $input_file")
        exit(1)
    end

    # Determine input language
    input_sim = simulator_from_symbol(input_simulator_sym)
    input_lang = language(input_sim)
    println("Input simulator: $input_simulator_sym → language: $input_lang")

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
            SpectreNetlistParser.parsefile(input_file; start_lang=:spice, spice_dialect=input_simulator_sym, implicit_title=true)
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
        # Set up includepaths with input file's directory for resolving relative includes
        includepaths = [dirname(abspath(input_file))]

        # Write output file - use file IO directly to enable separate include file generation
        println("Writing output file...")
        output_dir = dirname(abspath(output_file))
        options = Dict{Symbol, Any}(:output_dir => output_dir, :spice_dialect => input_simulator_sym)
        open(output_file, "w") do io
            generate_code(ast, io, output_sim; options=options, includepaths=includepaths)
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

end # module Convert
