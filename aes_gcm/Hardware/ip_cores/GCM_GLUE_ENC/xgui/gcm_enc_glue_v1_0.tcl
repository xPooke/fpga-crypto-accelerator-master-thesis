# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "AAD_BEATS" -parent ${Page_0}
  ipgui::add_param $IPINST -name "AAD_BYTES" -parent ${Page_0}
  ipgui::add_param $IPINST -name "DATA_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "MULT_CYCLES" -parent ${Page_0}


}

proc update_PARAM_VALUE.AAD_BEATS { PARAM_VALUE.AAD_BEATS } {
	# Procedure called to update AAD_BEATS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.AAD_BEATS { PARAM_VALUE.AAD_BEATS } {
	# Procedure called to validate AAD_BEATS
	return true
}

proc update_PARAM_VALUE.AAD_BYTES { PARAM_VALUE.AAD_BYTES } {
	# Procedure called to update AAD_BYTES when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.AAD_BYTES { PARAM_VALUE.AAD_BYTES } {
	# Procedure called to validate AAD_BYTES
	return true
}

proc update_PARAM_VALUE.DATA_WIDTH { PARAM_VALUE.DATA_WIDTH } {
	# Procedure called to update DATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.DATA_WIDTH { PARAM_VALUE.DATA_WIDTH } {
	# Procedure called to validate DATA_WIDTH
	return true
}

proc update_PARAM_VALUE.MULT_CYCLES { PARAM_VALUE.MULT_CYCLES } {
	# Procedure called to update MULT_CYCLES when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.MULT_CYCLES { PARAM_VALUE.MULT_CYCLES } {
	# Procedure called to validate MULT_CYCLES
	return true
}


proc update_MODELPARAM_VALUE.AAD_BEATS { MODELPARAM_VALUE.AAD_BEATS PARAM_VALUE.AAD_BEATS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.AAD_BEATS}] ${MODELPARAM_VALUE.AAD_BEATS}
}

proc update_MODELPARAM_VALUE.AAD_BYTES { MODELPARAM_VALUE.AAD_BYTES PARAM_VALUE.AAD_BYTES } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.AAD_BYTES}] ${MODELPARAM_VALUE.AAD_BYTES}
}

proc update_MODELPARAM_VALUE.DATA_WIDTH { MODELPARAM_VALUE.DATA_WIDTH PARAM_VALUE.DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.DATA_WIDTH}] ${MODELPARAM_VALUE.DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.MULT_CYCLES { MODELPARAM_VALUE.MULT_CYCLES PARAM_VALUE.MULT_CYCLES } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.MULT_CYCLES}] ${MODELPARAM_VALUE.MULT_CYCLES}
}

