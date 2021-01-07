--------------------------------------------------
--I2C master peripheral
--by Renan Picoli de Souza
--supports only 8 bit sending/receiving
-- NO support for clock stretching
--------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;--to_integer

entity i2c_master is
	port (
			D: in std_logic_vector(31 downto 0);--for register write
			CLK: in std_logic;--for register read/write, also used to generate SCL
			ADDR: in std_logic_vector(7 downto 0);--address offset of registers relative to peripheral base address
			WREN: in std_logic;--enables register write
			RDEN: in std_logic;--enables register read
			IACK: in std_logic;--interrupt acknowledgement
			Q: out std_logic_vector(31 downto 0);--for register read
			IRQ: out std_logic;--interrupt request
			SDA: inout std_logic;--open drain data line
			SCL: inout std_logic;--open drain clock line
	);
end i2c_master;

architecture structure of i2c_master is

begin

end structure;