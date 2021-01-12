library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.all;
use work.my_types.all;


entity testbench is
end testbench;

architecture test of testbench is
-- "Time" that will elapse between test vectors we submit to the component.
constant TIME_DELTA : time := 44 us;

--reset duration must be long enough to be perceived by the slowest clock (filter clock, both polarities)
constant TIME_RST : time := 5 us;

signal D: std_logic_vector(31 downto 0);--for register write
signal CLK: std_logic;--for register read/write, also used to generate SCL
signal ADDR: std_logic_vector(7 downto 0);--address offset of registers relative to peripheral base address
signal RST:	std_logic;--reset
signal WREN: std_logic;--enables register write
signal RDEN: std_logic;--enables register read
signal IACK: std_logic;--interrupt acknowledgement
signal Q: std_logic_vector(31 downto 0);--for register read
signal IRQ: std_logic;--interrupt request
signal SDA: std_logic;--open drain data line
signal SCL: std_logic;--open drain clock line

begin

	SDA <= 'H','0' after 60 us;--for slave ack
	DUT: entity work.i2c_master
	port map(D 		=> D,
				CLK	=> CLK,
				ADDR 	=> ADDR,
				RST	=>	RST,
				WREN	=> WREN,
				RDEN	=>	RDEN,
				IACK	=> IACK,
				Q		=>	Q,
				IRQ	=>	IRQ,
				SDA	=>	SDA,
				SCL	=>	SCL
	);
	
	clock: process--200kHz input clock
	begin
		CLK <= '0';
		wait for 2.5 us;
		CLK <= '1';
		wait for 2.5 us;
	end process clock;
	
	wren_assign: process
	begin
		WREN <= '0';
		wait for (TIME_RST + 5 us);
		
		WREN <= '1';
		wait for 5 us;
		
		WREN <= '0';
		wait;
	end process wren_assign;
	
	D <= x"0000_0009";--1001
	ADDR <= "0011010" & '0';
	RST <= '1', '0' after TIME_RST;
	
end architecture test;