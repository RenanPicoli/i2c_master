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

component i2c_slave
	port (
			D: in std_logic_vector(31 downto 0);--for register write
			ADDR: in std_logic_vector(1 downto 0);--address offset of registers relative to peripheral base address
			CLK: in std_logic;--for register read/write, also used to generate SCL
			RST: in std_logic;--reset
			WREN: in std_logic;--enables register write
			RDEN: in std_logic;--enables register read
			IACK: in std_logic;--interrupt acknowledgement
			Q: out std_logic_vector(31 downto 0);--for register read
			IRQ: out std_logic;--interrupt request
			SDA: inout std_logic;--open drain data line
			SCL: inout std_logic --open drain clock line
	);
end component;

--master signals
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

--slave signals
signal D_slv: std_logic_vector(31 downto 0);--for register write
signal ADDR_slv: std_logic_vector(1 downto 0);--address offset of registers relative to peripheral base address
signal WREN_slv: std_logic;--enables register write

signal read_mode: std_logic;
signal write_mode: std_logic;
constant RW_bit: std_logic:='0';-- 1 read mode; 0 write mode
begin
	--all these times are relative to the beginning of simulation
	--'H' models the pull up resistor in SDA line
	SDA <= 'H';--pull up resistor
	
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
	
	slave: i2c_slave
	port map(D 		=> D_slv,
				CLK	=> CLK,
				ADDR 	=> ADDR_slv,
				RST	=>	RST,
				WREN	=> WREN_slv,
				RDEN	=>	RDEN,
				IACK	=> IACK,
				Q		=>	open,
				IRQ	=>	open,
				SDA	=>	SDA,
				SCL	=>	SCL
	);
	
	clock: process--200kHz input clock (common to slave and master)
	begin
		CLK <= '0';
		wait for 2.5 us;
		CLK <= '1';
		wait for 2.5 us;
	end process clock;
	
	--I2C registers configuration
	read_mode <= RW_bit;
	write_mode <= not read_mode;
	
	master_setup:process
	begin
		--zeroes & WORDS & SLV ADDR & R/W(1 read mode; 0 write mode)
		ADDR <= "00";--CR address
		D <= (31 downto 10 =>'0') & "01" & "0000101" & RW_bit;--I2C_EN: 0; WORDS: 01; ADDR: 1010
		WREN <= '1';
		wait for TIME_RST + TIME_DELTA;
		
		--bits 7:0 data to be transmitted
		ADDR <= "01";--DR address	
		D <= x"0000_0095";-- 1001 0101	
		WREN <= '1';
		wait for TIME_DELTA;

		ADDR <= "00";--CR address, will start transfer
		D<=(31 downto 11 =>'0') & '1' & "01" & "0000101" & RW_bit;--I2C_EN: 1; WORDS: 01; ADDR: 1010
		WREN <= '1';
		wait for TIME_DELTA;
		
		WREN <= '0';
		wait;--process executes once
	end process master_setup;
	
	slave_setup:process
	begin
		--zeroes & WORDS & OADDR & R/W(must store RW bit sent by master; 1 read mode; 0 write mode)
		ADDR_slv <= "00";--CR address
		D_slv <= (31 downto 10 =>'0') & "01" & "0000101" & 'X';--WORDS: 01; OADDR: 0101
		WREN_slv <= '1';
		wait for TIME_RST + TIME_DELTA;
		
		ADDR_slv <= "01";--DR address
		--bits 7:0 data received or to be read by master	
		D_slv <= x"0000_00A4";-- data to be read by master
		WREN_slv <= '1';
		wait for TIME_DELTA;

		ADDR_slv<="11";--invalid address
		D_slv<=(others=>'0');
		WREN_slv <= '0';
		wait for TIME_DELTA;
		wait;--process executes once
	end process slave_setup;
	RST <= '1', '0' after TIME_RST;--reset common to slave and master
	
end architecture test;