
# Loading additional proc with user specified bodies to compute parameter values.
source [file join [file dirname [file dirname [info script]]] gui/sha3_axis_ip_v1_0.gtcl]

# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]

  set p [ipgui::add_param $IPINST -name "ALGORITHM" -parent ${Page_0} -widget comboBox]
  set_property tooltip {SHA3 = fixed-length hash (SHA3-224/256/384/512); SHAKE = extendable-output function (XOF); CSHAKE = customizable SHAKE (SP 800-185, also covers KMAC) -- the N/S prefix block and KMAC key/length encodings are sent by software as ordinary message data} $p

  set p [ipgui::add_param $IPINST -name "SHA3_VERSION" -parent ${Page_0} -widget comboBox]
  set_property tooltip {SHA3 only: digest size in bits; sponge rate = 1600 - 2*digest. Note: SHA3-224 supports AXIS data width up to 32 (224 is not divisible by 64)} $p

  set p [ipgui::add_param $IPINST -name "SHAKE_VERSION" -parent ${Page_0} -widget comboBox]
  set_property tooltip {SHAKE/CSHAKE only: security strength. 128 -> rate 1344 bits (faster), 256 -> rate 1088 bits (stronger). Output length is set separately by SHAKE output length} $p

  set p [ipgui::add_param $IPINST -name "SHAKE_BITS" -parent ${Page_0}]
  set_property tooltip {SHAKE/CSHAKE only: total XOF output length in bits; any multiple of the AXIS data width. Outputs longer than the rate are squeezed in several chunks (one extra 24-round permutation per chunk); resources do not grow with this value} $p

  set p [ipgui::add_param $IPINST -name "DATA_WIDTH" -parent ${Page_0} -widget comboBox]
  set_property tooltip {AXI-Stream data width in bits. Must divide both the sponge rate and the output size -- illegal combinations are rejected at elaboration} $p

  set p [ipgui::add_param $IPINST -name "ROUNDS_PER_CYCLE" -parent ${Page_0} -widget comboBox]
  set_property tooltip {Keccak-f[1600] rounds applied per clock cycle (any divisor of 24). Values above 2 give diminishing fmax returns -- 1 or 2 recommended} $p
}

proc update_PARAM_VALUE.SHA3_VERSION { PARAM_VALUE.SHA3_VERSION PARAM_VALUE.ALGORITHM } {
	set wk [string trim [get_property value ${PARAM_VALUE.ALGORITHM}] "\""]
	set v [expr {$wk eq "SHA3"}]
	set_property enabled $v ${PARAM_VALUE.SHA3_VERSION}
	if {[catch {set_property visible $v ${PARAM_VALUE.SHA3_VERSION}}]} {}
}

proc validate_PARAM_VALUE.SHA3_VERSION { PARAM_VALUE.SHA3_VERSION } {
	return true
}

proc update_PARAM_VALUE.SHAKE_VERSION { PARAM_VALUE.SHAKE_VERSION PARAM_VALUE.ALGORITHM } {
	set wk [string trim [get_property value ${PARAM_VALUE.ALGORITHM}] "\""]
	set v [expr {$wk eq "SHAKE" || $wk eq "CSHAKE"}]
	set_property enabled $v ${PARAM_VALUE.SHAKE_VERSION}
	if {[catch {set_property visible $v ${PARAM_VALUE.SHAKE_VERSION}}]} {}
}

proc validate_PARAM_VALUE.SHAKE_VERSION { PARAM_VALUE.SHAKE_VERSION } {
	return true
}

proc update_PARAM_VALUE.SHAKE_BITS { PARAM_VALUE.SHAKE_BITS PARAM_VALUE.ALGORITHM } {
	set wk [string trim [get_property value ${PARAM_VALUE.ALGORITHM}] "\""]
	set v [expr {$wk eq "SHAKE" || $wk eq "CSHAKE"}]
	set_property enabled $v ${PARAM_VALUE.SHAKE_BITS}
	if {[catch {set_property visible $v ${PARAM_VALUE.SHAKE_BITS}}]} {}
}

proc validate_PARAM_VALUE.SHAKE_BITS { PARAM_VALUE.SHAKE_BITS } {
	return true
}

proc update_PARAM_VALUE.ALGORITHM { PARAM_VALUE.ALGORITHM } {
}

proc validate_PARAM_VALUE.ALGORITHM { PARAM_VALUE.ALGORITHM } {
	return true
}

proc update_PARAM_VALUE.DATA_WIDTH { PARAM_VALUE.DATA_WIDTH } {
}

proc validate_PARAM_VALUE.DATA_WIDTH { PARAM_VALUE.DATA_WIDTH } {
	return true
}

proc update_PARAM_VALUE.ROUNDS_PER_CYCLE { PARAM_VALUE.ROUNDS_PER_CYCLE } {
}

proc validate_PARAM_VALUE.ROUNDS_PER_CYCLE { PARAM_VALUE.ROUNDS_PER_CYCLE } {
	return true
}

proc update_MODELPARAM_VALUE.ALGORITHM { MODELPARAM_VALUE.ALGORITHM PARAM_VALUE.ALGORITHM } {
	set_property value [get_property value ${PARAM_VALUE.ALGORITHM}] ${MODELPARAM_VALUE.ALGORITHM}
}

proc update_MODELPARAM_VALUE.SHA3_VERSION { MODELPARAM_VALUE.SHA3_VERSION PARAM_VALUE.SHA3_VERSION } {
	set_property value [get_property value ${PARAM_VALUE.SHA3_VERSION}] ${MODELPARAM_VALUE.SHA3_VERSION}
}

proc update_MODELPARAM_VALUE.SHAKE_VERSION { MODELPARAM_VALUE.SHAKE_VERSION PARAM_VALUE.SHAKE_VERSION } {
	set_property value [get_property value ${PARAM_VALUE.SHAKE_VERSION}] ${MODELPARAM_VALUE.SHAKE_VERSION}
}

proc update_MODELPARAM_VALUE.SHAKE_BITS { MODELPARAM_VALUE.SHAKE_BITS PARAM_VALUE.SHAKE_BITS } {
	set_property value [get_property value ${PARAM_VALUE.SHAKE_BITS}] ${MODELPARAM_VALUE.SHAKE_BITS}
}

proc update_MODELPARAM_VALUE.DATA_WIDTH { MODELPARAM_VALUE.DATA_WIDTH PARAM_VALUE.DATA_WIDTH } {
	set_property value [get_property value ${PARAM_VALUE.DATA_WIDTH}] ${MODELPARAM_VALUE.DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.ROUNDS_PER_CYCLE { MODELPARAM_VALUE.ROUNDS_PER_CYCLE PARAM_VALUE.ROUNDS_PER_CYCLE } {
	set_property value [get_property value ${PARAM_VALUE.ROUNDS_PER_CYCLE}] ${MODELPARAM_VALUE.ROUNDS_PER_CYCLE}
}

