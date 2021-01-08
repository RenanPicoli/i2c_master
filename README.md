# i2c_master
I2C master peripheral, for sending and receiving from I2C bus

Designed to be compatible with the I2C-bus specification: http://www.nxp.com/documents/user_manual/UM10204.pdf

* The FPGA must be the only master in the bus.
* It supports only 7-bit slave addresses and standard mode.
*  It should be built upon a generic component able of working only as transmitter, only as receiver or both.
* It should be able to work with 8/16/32 bit data, transfers are made in separate bytes.
* Clock stretching is NOT supported.
* Device ID is NOT supported.
* Start byte is NOT supported.
* General call address is NOT supported.
* It uses a shift register to serialize paralell data written by a MCU or parallelize a serial data received from bus.
