# ----------------------------------------------------------------------------
# package_aes_l3_ip.tcl - scripted in-place packaging of the AES algorithm
# core and the four L3 wrapper cores, same recipe as the SHA-3 and GCM glue
# scripts. Sets the etf.bg.ac.rs vendor and re-infers everything from the
# live src/, so the packages can never drift away from the sources.
#
# Usage (from the aes_gcm folder root):
#   vivado -mode batch -source Scripts/package_aes_l3_ip.tcl
# ----------------------------------------------------------------------------

set ROOT   [file normalize [file join [file dirname [info script]] ..]]
set PART   xck26-sfvc784-2LV-c
set VENDOR etf.bg.ac.rs

proc set_choice_list {core pname values} {
    set p [ipx::get_user_parameters $pname -of_objects $core]
    if {$p eq ""} { puts "WARN: no parameter $pname"; return }
    set_property value_validation_type list   $p
    set_property value_validation_list $values $p
}

proc pkg_core {IPDIR TOP NAME REV DISP DESC PART VENDOR} {
    puts "==== Packaging $NAME in $IPDIR ===="
    create_project -in_memory -part $PART
    foreach f [lsort [glob $IPDIR/src/*.vhd]] { read_vhdl -vhdl2008 $f }
    set_property top $TOP [current_fileset]
    update_compile_order -fileset sources_1
    ipx::package_project -root_dir $IPDIR -vendor $VENDOR -library user \
        -taxonomy /UserIP -import_files false -set_current true -force
    set core [ipx::current_core]
    set_property name         $NAME $core
    set_property display_name $DISP $core
    set_property description  $DESC $core
    set_property version      1.0   $core
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
    return $core
}

# --------------------------- AES algorithm core -----------------------------
set core [pkg_core $ROOT/Hardware/ip_cores/AES_ALGORITHM AES_algorithm aes_algorithm 6 \
    "AES-GCM Algorithm Core (CTR keystream + GCM side-band)" \
    "AES-256/128 encryption core for the GCM counter mode: computes the keystream, H subkey and tag mask behind the crypto boundary. WRAPPER_KIND selects the fully pipelined (UNROLLED) or the round-iterative multi-core (MULTICORE) organization." \
    $PART $VENDOR]
set_choice_list $core AES_BITS     {128 256}
set_choice_list $core ROUND_STYLE  {BRAM LUT}
set_choice_list $core FLOW_STYLE   {GLOBAL PER_STAGE}
set_choice_list $core WRAPPER_KIND {UNROLLED MULTICORE}
set_property display_name {AES key length (bits)}    [ipx::get_user_parameters AES_BITS     -of_objects $core]
set_property display_name {Round realization}        [ipx::get_user_parameters ROUND_STYLE  -of_objects $core]
set_property display_name {Flow control style}       [ipx::get_user_parameters FLOW_STYLE   -of_objects $core]
set_property display_name {Architecture}             [ipx::get_user_parameters WRAPPER_KIND -of_objects $core]
set_property display_name {Cores (MULTICORE only)}   [ipx::get_user_parameters NUM_CORES    -of_objects $core]
set_property core_revision 6 $core
ipx::create_xgui_files $core
ipx::update_checksums  $core
ipx::check_integrity   $core
ipx::save_core         $core
close_project
puts "==== DONE aes_algorithm rev 6 ===="

# ------------------------------ L3 wrappers ---------------------------------
foreach {DIR TOP REV DISP DESC} {
    SPLIT_demux SPLIT_demux 2
    "AXIS Packet Splitter (bypass/AAD/payload)"
    "Splits one byte-continuous input packet into bypass, AAD and payload streams at generic-configured byte offsets, with a gearbox for unaligned segment boundaries."
    MERGE_mux MERGE_mux 2
    "AXIS Packet Merger (bypass/AAD/CT/ICV)"
    "Merges the bypass stream and the protected stream back into one byte-continuous output packet, inverse of the splitter."
    ICV_realign ICV_realign 2
    "AXIS ICV Realigner"
    "Re-aligns the trailing ICV of a received packet onto the block boundary expected by the GCM decrypt layer."
    AXIS_full_skid_buffer AXIS_full_skid_buffer 2
    "AXIS Full Skid Buffer"
    "Two-deep registered AXI-Stream skid buffer: cuts both the forward and the ready path at the cost of one word of storage."
} {
    set core [pkg_core $ROOT/Hardware/ip_cores/L3_WRAPPER_IP_CORES/$DIR $TOP $TOP $REV $DISP $DESC $PART $VENDOR]
    set_property core_revision $REV $core
    ipx::create_xgui_files $core
    ipx::update_checksums  $core
    ipx::check_integrity   $core
    ipx::save_core         $core
    close_project
    puts "==== DONE $TOP rev $REV ===="
}
exit 0
