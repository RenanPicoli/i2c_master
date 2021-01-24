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
signal I2C_EN: std_logic;--enables trasfer to start
signal IACK: std_logic;--interrupt acknowledgement
signal Q: std_logic_vector(31 downto 0);--for register read
signal IRQ: std_logic;--interrupt request
signal SDA: std_logic;--open drain data line
signal SCL: std_logic;--open drain clock line

signal read_mode: std_logic;
signal write_mode: std_logic;
constant RW_bit: std_logic:='1';-- 1 read mode; 0 write mode
begin
	--all these times are relative to the beginning of simulation
	--'H' models the pull up resistor in SDA line
	SDA <='H','0' after 60 us,'H' after 67.5 us,
				'0' after 110 us, 'H' after 117.5 us, '0' after 160 us, 'H' after 167.5 us when write_mode='1' else--slave ack for writes
			'H','0' after 60 us,'H' after 67.5 us, '0' after 80 us, 'H' after 90 us, '0' after 120 us, 'H' after 140 us when read_mode='1' else--master will read F0 from slave
			'X';
	
	DUT: entity work.i2c_master
	port map(D 		=> D,
				CLK	=> CLK,
				ADDR 	=> ADDR,
				RST	=>	RST,
				WREN	=> WREN,
				RDEN	=>	RDEN,
				I2C_EN=> I2C_EN,
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
	
	--I2C registers configuration
	read_mode <= RW_bit;
	write_mode <= not read_mode;
	setup:process
	begin
		--zeroes & WORDS & SLV ADDR & R/W(1 read mode; 0 write mode)
		D <= (31 downto 10 =>'0') & "01" & "0000101" & RW_bit;--WORDS: 01; ADDR: 1010
		ADDR <= "00";--CR address
		WREN <= '1';
		I2C_EN <= '0';
		wait for TIME_RST + TIME_DELTA;
		
		--bits 7:0 data to be transmitted
		D <= x"0000_0095";-- 1001 0101
		ADDR <= "01";--DR address		
		WREN <= '1';
		wait for TIME_DELTA;

		D<=(others=>'0');
		ADDR<="11";--invalid address
		WREN <= '0';
		I2C_EN <= '1';
		wait for TIME_DELTA;
		
		I2C_EN <= '0';
		wait;
	end process setup;
	RST <= '1', '0' after TIME_RST;
	
end architecture test;