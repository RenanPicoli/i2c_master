library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.all;
use work.my_types.all;


entity testbench is
end testbench;

architecture test of testbench is
-- internal clock period.
constant TIME_DELTA : time := 5 us;

--reset duration must be long enough to be perceived by the slowest clock (filter clock, both polarities)
constant TIME_RST : time := 5 us;

signal D: std_logic_vector(31 downto 0);--for register write
signal CLK: std_logic;--for register read/write, also used to generate SCL
signal ADDR: std_logic_vector(1 downto 0);--address offset of registers relative to peripheral base address
signal RST:	std_logic;--reset
signal WREN: std_logic;--enables register write
signal RDEN: std_logic;--enables register read
signal IACK: std_logic;--interrupt acknowledgement
signal Q: std_logic_vector(31 downto 0);--for register read
signal IRQ: std_logic;--interrupt request
signal SDA: std_logic;--open drain data line
signal SCL: std_logic;--open drain clock line

signal read_mode: std_logic;
begin
	--all these times are relative to the beginning of simulation
	--'H' models the pull up resistor in SDA line
	SDA <= 'H','0' after 65 us,'H' after 72.5 us,
				'0' after 115 us, 'H' after 122.5 us, '0' after 165 us, 'H' after 172.5 us;--slave ack for writes
	
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
	
--	wren_assign: process
--	begin
--		WREN <= '0';
--		wait for (TIME_RST + 5 us);
--		
--		WREN <= '1';
--		wait for 5 us;
--		
--		WREN <= '0';
--		wait;
--	end process wren_assign;
	
	--I2C registers configuration
	setup:process
	begin
		--zeroes & WORDS & SLV ADDR & R/W(1 read mode; 0 write mode)
		D <= (31 downto 10 =>'0') & "01" & "0000101" & '0';--WORDS: 01; ADDR: 1010
--		D <= (31 downto 10 =>'0', 9 downto 8 => "01", 7 downto 1=> "0000101", 0=> '0');--WORDS: 01; ADDR: 1010
--		D<=(others=>'0');
		ADDR <= "00";--CR address
		wait for TIME_RST + 5 us;
		
		--bits 7:0 data to be transmitted
		D <= x"0000_0095";-- 1001 0101
		ADDR <= "01";--DR address
		wait for 5 us;

		D<=(others=>'0');
		ADDR<="11";--invalid address
		WREN <= '1';
		wait for 5 us;
		
		WREN <= '0';
		wait;
--		read_mode <= D(0);
	end process setup;
	RST <= '1', '0' after TIME_RST;
	
end architecture test;