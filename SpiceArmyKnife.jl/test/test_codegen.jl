# Test suite for SPICE/Spectre code generator

using Test
using SpiceArmyKnife
using SpectreNetlistParser

"""
    check_roundtrip(code, simulator)

Parse code, generate output, parse again, generate again.
Check that the second generation matches the first (stability test).
"""
function check_roundtrip(code, simulator)
    # First round: parse original
    # Note: Use implicit_title=false since test cases don't have SPICE title lines
    lang = language(simulator)
    ast1 = if lang == :spice
        SpectreNetlistParser.parse(IOBuffer(code); start_lang=:spice, implicit_title=false)
    else
        SpectreNetlistParser.parse(IOBuffer(code); start_lang=:spectre)
    end
    gen1 = generate_code(ast1, simulator)

    # Second round: parse generated output
    ast2 = if lang == :spice
        SpectreNetlistParser.parse(IOBuffer(gen1); start_lang=:spice, implicit_title=false)
    else
        SpectreNetlistParser.parse(IOBuffer(gen1); start_lang=:spectre)
    end
    gen2 = generate_code(ast2, simulator)

    # Generated output should be stable (idempotent)
    @test gen1 == gen2

    return gen1 == gen2
end

@testset "Code Generator" begin

    @testset "Roundtrip Stability" begin
        # Note: These tests currently fail due to whitespace accumulation in terminals.
        # Each parse→generate cycle adds an extra space because terminals may contain
        # trivia (whitespace) from the source. This is a known issue but doesn't affect
        # semantic correctness - only formatting stability.
        # TODO: Strip all trivia from terminals or normalize whitespace in output

        @testset "SPICE roundtrip" begin
            spice = """
.subckt inv in out vdd gnd
M1 out in vdd vdd pmos w=2u l=100n
M2 out in gnd gnd nmos w=1u l=100n
.ends inv

.model nmos nmos level=14
R1 a b 1k
C1 c d 1p
X1 n1 n2 vdd gnd inv
"""
            @test check_roundtrip(spice, Ngspice())
        end

        @testset "Spectre roundtrip" begin
            spectre = """
subckt inv (in out vdd gnd)
M1 (out in vdd vdd) pmos w=2u l=100n
M2 (out in gnd gnd) nmos w=1u l=100n
ends inv

I1 (n1 n2 vdd gnd) inv
"""
            @test check_roundtrip(spectre, SpectreADE())
        end
    end

    @testset "SPICE Models" begin
        @testset "Simple model" begin
            spice = ".model nmos nmos level=14\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=false)
            output = generate_code(ast, Ngspice())
            @test output == ".model nmos nmos level=14\n"
        end

        @testset "Model with parameters" begin
            spice = ".model nmos nmos level=14 vto=0.7 kp=100u\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=false)
            output = generate_code(ast, Ngspice())
            @test output == ".model nmos nmos level=14 vto=0.7 kp=100u\n"
        end

        @testset "ngspice filters documentation parameters" begin
            # Model with documentation-only parameters (similar to Cordell models)
            # Changed values to avoid copyright - only parameter names matter
            spice = ".model testdiode D(Is=1n Rs=2.0 N=1.5 Cjo=3p M=.5 tt=10n Iave=100m Vpk=50 mfg=TEST001)\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=false)
            output = generate_code(ast, Ngspice())

            # Should contain standard parameters
            @test occursin("Is=1n", output)
            @test occursin("Rs=2.0", output)
            @test occursin("N=1.5", output)
            @test occursin("Cjo=3p", output)
            @test occursin("M=.5", output)
            @test occursin("tt=10n", output)

            # Should NOT contain documentation-only parameters
            @test !occursin("Iave", output)
            @test !occursin("Vpk", output)
            @test !occursin("mfg", output)
        end

        @testset "ngspice filters type and rating parameters" begin
            # BJT model with additional documentation parameters
            spice = ".model testbjt npn(Is=1e-15 BF=100 VAF=200 Vceo=100 Icrating=5 type=npn)\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=false)
            output = generate_code(ast, Ngspice())

            # Should contain standard parameters
            @test occursin("Is=1e-15", output)
            @test occursin("BF=100", output)
            @test occursin("VAF=200", output)

            # Should NOT contain documentation-only parameters
            @test !occursin("Vceo", output)
            @test !occursin("Icrating", output)
            @test !occursin("type=", output)
        end
    end

    @testset "SPICE Subcircuits" begin
        @testset "Empty subcircuit" begin
            spice = ".subckt test a b\n.ends test\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=false)
            output = generate_code(ast, Ngspice())
            # Reconstructed code may have slightly different spacing
            @test occursin(".subckt test", output)
            @test occursin(".ends test", output)
        end

        @testset "Subcircuit with body" begin
            spice = ".subckt inv in out vdd gnd\nM1 out in vdd vdd pmos w=2u\n.ends inv\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=false)
            output = generate_code(ast, Ngspice())
            # Output will have reconstructed spacing
            @test occursin(".subckt inv", output)
            @test occursin("M1", output)
            @test occursin(".ends inv", output)
        end

        @testset "Subcircuit with parameters" begin
            spice = ".subckt res2 a b r=1k\nR1 a b r\n.ends\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=false)
            output = generate_code(ast, Ngspice())
            @test occursin("r=1k", output)
        end
    end

    @testset "SPICE Device Instances" begin
        @testset "Resistor" begin
            spice = "R1 in out 1k\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=false)
            output = generate_code(ast, Ngspice())
            @test output == "R1 in out 1k\n"
        end

        @testset "Capacitor" begin
            spice = "C1 n1 gnd 1p\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=false)
            output = generate_code(ast, Ngspice())
            @test occursin("C1", output)
            @test occursin("1p", output)
        end

        @testset "MOSFET" begin
            spice = "M1 d g s b nmos w=1u l=100n\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=false)
            output = generate_code(ast, Ngspice())
            @test occursin("M1", output)
            @test occursin("nmos", output)
            @test occursin("w=1u", output)
            @test occursin("l=100n", output)
        end

        @testset "Subcircuit call" begin
            spice = "X1 a b c d inverter\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=false)
            output = generate_code(ast, Ngspice())
            @test occursin("X1", output)
            @test occursin("inverter", output)
        end
    end

    @testset "Spectre Models" begin
        @testset "Simple model" begin
            spectre = "model nmos_mod bsim4 version=4.7\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spectre); start_lang=:spectre)
            output = generate_code(ast, SpectreADE())
            @test output == "model nmos_mod bsim4 version=4.7\n"
        end
    end

    @testset "Spectre Subcircuits" begin
        @testset "Subcircuit with nodes" begin
            spectre = "subckt inv (in out vdd gnd)\nends inv\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spectre); start_lang=:spectre)
            output = generate_code(ast, SpectreADE())
            @test occursin("subckt inv", output)
            # Spacing may vary in reconstruction
            @test occursin("(in", output) && occursin("gnd)", output)
            @test occursin("ends inv", output)
        end
    end

    @testset "Spectre Instances" begin
        @testset "Instance with parameters" begin
            spectre = "I1 (n1 n2 vdd gnd) inverter w=1u\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spectre); start_lang=:spectre)
            output = generate_code(ast, SpectreADE())
            @test occursin("I1", output)
            @test occursin("inverter", output)
            @test occursin("w=1u", output)
        end
    end

    @testset "Expressions" begin
        @testset "Binary expressions" begin
            spice = "R1 a b {2*rval}\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=false)
            output = generate_code(ast, Ngspice())
            @test occursin("2 * rval", output) || occursin("2*rval", output)
        end

        @testset "Parameters with expressions" begin
            spice = "M1 d g s b nmos w={wval*2}\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=false)
            output = generate_code(ast, Ngspice())
            @test occursin("wval", output)
        end
    end

    @testset "Comments and Formatting" begin
        @testset "Comments preserved" begin
            spice = "* This is a comment\nR1 a b 1k\n"
            # This test has a comment as first line, so it should use implicit_title=true
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=true)
            output = generate_code(ast, Ngspice())
            @test occursin("* This is a comment", output)
        end

        @testset "Blank lines handled" begin
            spice = "R1 a b 1k\n\nC1 c d 1p\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=false)
            output = generate_code(ast, Ngspice())
            @test occursin("R1", output)
            @test occursin("C1", output)
        end
    end

    @testset "Complex Circuits" begin
        @testset "Full SPICE circuit" begin
            spice = """
* RC Filter
.subckt rc_filter in out gnd r=1k c=1p
R1 in out r
C1 out gnd c
.ends rc_filter

.model nmos nmos level=14
M1 d g s b nmos w=1u
X1 a b gnd rc_filter
"""
            # This test has a title comment as first line, so use implicit_title=true
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=true)
            output = generate_code(ast, Ngspice())

            # Check all major components present
            @test occursin("RC Filter", output)
            @test occursin(".subckt rc_filter", output)
            @test occursin(".ends rc_filter", output)
            @test occursin(".model", output) && occursin("nmos", output)
            @test occursin("M1", output)
            @test occursin("X1", output)
        end
    end

    @testset "IOBuffer output" begin
        spice = "R1 a b 1k\n"
        ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=false)

        io = IOBuffer()
        generate_code(ast, io, Ngspice())
        output = String(take!(io))

        @test output == "R1 a b 1k\n"
    end

    @testset "Title and Brace handling" begin
        @testset "Title line preserved" begin
            spice = "* Test Circuit Title\nR1 a b 1k\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=true)
            output = generate_code(ast, Ngspice())
            @test occursin("Test Circuit Title", output)
        end

        @testset "Braced expressions" begin
            # SPICE allows braced expressions in parameter values
            spice = ".param test_val={2*3.14}\nR1 a b {test_val}\n"
            ast = SpectreNetlistParser.parse(IOBuffer(spice); start_lang=:spice, implicit_title=false)
            output = generate_code(ast, Ngspice())
            # Check for braced expression (may have spaces from expression handler)
            @test occursin(r"\{2\s*\*\s*3\.14\}", output)
            @test occursin("{test_val}", output)
        end
    end

end
