# ----------------------------------------------------------------------------
# package_gcm_glue_ip.tcl - scripted in-place packaging of both GCM glue
# cores (gcm_enc_glue, gcm_dec_glue). Follows the SHA-3 packaging recipe:
# no manual IP Packager work, AXIS/clock association done explicitly so BD
# connection automation drags the streams along with the clock.
#
# Usage (from the aes_gcm folder root):
#   vivado -mode batch -source Scripts/package_gcm_glue_ip.tcl
#
# Each core is packaged IN PLACE into its ip_cores/<CORE>/ folder over the
# live src/, so the package can never drift away from the sources. Adds the
# MULT_CYCLES generic (1 or 2 clock GHASH multiply) that the July packages
# predate. Re-running is safe (-force; revision bumps on each run).
# ----------------------------------------------------------------------------

set ROOT   [file normalize [file join [file dirname [info script]] ..]]
set PART   xck26-sfvc784-2LV-c
set VENDOR etf.bg.ac.rs

proc set_choice_list {core pname values} {
    set p [ipx::get_user_parameters $pname -of_objects $core]
    set_property value_validation_type list   $p
    set_property value_validation_list $values $p
}

foreach {DIR TOP REV DISP DESC} {
    GCM_GLUE_ENC gcm_enc_glue 9
    "GCM Encrypt Glue (GHASH + framing)"
    "GCM layer for the encrypt path: GHASH authentication over AAD||CT, tag finalization, AAD/CT/ICV output framing. Pairs with the AES algorithm core over the crypto-boundary streams. MULT_CYCLES selects the 1- or 2-clock GHASH multiplier."
    GCM_GLUE_DEC gcm_dec_glue 8
    "GCM Decrypt Glue (GHASH + tag verify)"
    "GCM layer for the decrypt path: GHASH authentication over AAD||CT, tag verification against the received ICV, AAD/PT output framing. Pairs with the AES algorithm core over the crypto-boundary streams. MULT_CYCLES selects the 1- or 2-clock GHASH multiplier."
} {
    set IPDIR $ROOT/Hardware/ip_cores/$DIR
    puts "==== Packaging $TOP in $IPDIR ===="

    create_project -in_memory -part $PART
    foreach f [lsort [glob $IPDIR/src/*.vhd]] { read_vhdl -vhdl2008 $f }
    set_property top $TOP [current_fileset]
    update_compile_order -fileset sources_1

    ipx::package_project -root_dir $IPDIR -vendor $VENDOR -library user \
        -taxonomy /UserIP -import_files false -set_current true -force
    set core [ipx::current_core]
    set_property name         $TOP  $core
    set_property display_name $DISP $core
    set_property description  $DESC $core
    set_property version      1.0   $core

    # clock <-> AXIS association for every inferred stream interface
    foreach b [ipx::get_bus_interfaces -of_objects $core] {
        set bn [get_property name $b]
        if {[string match "*axis*" $bn]} {
            if {[catch {ipx::associate_bus_interfaces -busif $bn -clock i_clk $core} err]} {
                puts "WARN: association $bn: $err"
            }
        }
    }
    if {[catch {ipx::associate_bus_interfaces -clock i_clk -reset i_rstn $core} err]} {
        puts "WARN: clock/reset association: $err"
    }

    # parameter polish
    set_choice_list $core MULT_CYCLES {1 2}
    set_choice_list $core DATA_WIDTH  {128}
    set_property display_name {GHASH multiply clocks} \
        [ipx::get_user_parameters MULT_CYCLES -of_objects $core]
    set_property display_name {AXIS data width (bits)} \
        [ipx::get_user_parameters DATA_WIDTH -of_objects $core]
    set_property display_name {AAD length (beats)} \
        [ipx::get_user_parameters AAD_BEATS -of_objects $core]
    set_property display_name {AAD length (bytes)} \
        [ipx::get_user_parameters AAD_BYTES -of_objects $core]

    set_property core_revision $REV $core
    ipx::create_xgui_files $core
    ipx::update_checksums  $core
    ipx::check_integrity   $core
    ipx::save_core         $core
    close_project
    puts "==== DONE -> $IPDIR/component.xml ($TOP v1.0 rev $REV) ===="
}
exit 0
