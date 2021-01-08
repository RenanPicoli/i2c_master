--------------------------------------------------
--I2C master generic component
--by Renan Picoli de Souza
--sends/receives data from SDA bus and drives SCL clock
--supports only 8 bit sending/receiving
-- NO support for clock stretching
--------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;--to_integer

entity i2c_master_generic is
	generic (N: natural);--number of bits in each data written/read
	port (
			DR: inout std_logic_vector(N-1 downto 0);--to store data to be transmitted or received
			CLK: in std_logic;--clock input, same frequency as SCL, used to generate SCL
			ADDR: in std_logic_vector(7 downto 0);--address offset of registers relative to peripheral base address
			WREN: in std_logic;--enables register write
			IACK: in std_logic;--interrupt acknowledgement
			IRQ: out std_logic;--interrupt request
			SDA: inout std_logic;--open drain data line
			SCL: inout std_logic --open drain clock line
	);
end i2c_master_generic;

architecture structure of i2c_master_generic is
	signal tx: std_logic;--flag indicating it is transmitting
	signal tx_set: std_logic;--sets tx
	signal tx_rst: std_logic;--resets tx
	signal rx: std_logic;--flag indicating it is receiving
	signal rx_set: std_logic;--sets tx
	signal rx_rst: std_logic;--resets tx
	
	signal fifo_empty: std_logic:='0';
	signal fifo_sda: std_logic_vector(N+1 downto 0);--one byte plus start and stop
	signal fifo_scl: std_logic_vector(N+1 downto 0);--one byte plus start and stop
	signal bits_sent: natural := 0;--number of bits transmitted
begin
	process (WREN,CLK,tx_rst)
	begin
		if (tx_rst = '1') then
			tx_set <= '0';
		elsif(WREN'event and WREN='1') then--moment of start of shifting DR (transmission of address)
			tx_set <= '1';
		end if;
	end process;
	
	process (fifo_empty,CLK,tx_set)
	begin
		if(tx_set = '1') then
			tx_rst <= '0';
		elsif(fifo_empty'event and fifo_empty='1') then--moment of start of shifting DR (transmission of address)
			tx_rst <= '1';
		end if;
	end process;
	
	tx <= tx_set and (not tx_rst);
	
	--serial write on bus
	serial_w: process(tx,CLK,WREN,DR)
	begin
		if(tx='1')then
			SCL <= CLK;
		end if;
		if (WREN = '1') then
			fifo_sda <= '0' & DR & '0';--start bit & DR & stop bit
		elsif(tx='1' and falling_edge(CLK))then--updates fifo at falling edge so it can be read in rising_edge
			fifo_sda <= fifo_sda(N downto 0) & '0';--MSB is sent first
			SDA <= fifo_sda(N);
			bits_sent <= bits_sent + 1;
			if (bits_sent = N+2) then
				fifo_empty <= '1';
				bits_sent <= 0;
			else
				fifo_empty <= '0';
			end if;
		end if;

	end process;
	
--	serial_r: process()
	
end structure;