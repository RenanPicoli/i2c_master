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
			DR: in std_logic_vector(N-1 downto 0);--to store data to be transmitted or received
			ADDR: in std_logic_vector(7 downto 0);--address offset of registers relative to peripheral base address
			CLK: in std_logic;--clock input, same frequency as SCL, used to generate SCL
			RST: in std_logic;--reset
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
	signal rx_set: std_logic;--sets rx
	signal rx_rst: std_logic;--resets rx
	
	signal scl_en: std_logic;--enables scl to follow CLK
	signal scl_en_set: std_logic;--sets scl_en
	signal scl_en_rst: std_logic;--resets scl_en
	
	signal fifo_empty: std_logic;
	signal fifo_sda: std_logic_vector(N+1 downto 0);--one byte plus start and stop
	signal bits_sent: natural;--number of bits transmitted
begin
	process (WREN,CLK,tx_rst,RST)
	begin
		if (RST ='1') then
			tx_set <= '0';
		elsif (tx_rst = '1') then
			tx_set <= '0';
		elsif(WREN'event and WREN='1') then--moment of start of shifting DR (transmission of address)
			tx_set <= '1';
		end if;
	end process;
	
	process (fifo_empty,CLK,tx_set,RST)
	begin
		if (RST ='1') then
			tx_rst <= '0';
		elsif(fifo_empty='1') then--moment of start of shifting DR (transmission of address)
			tx_rst <= '1';
		elsif(tx_set'event and tx_set = '1') then
			tx_rst <= '0';
		end if;
	end process;
	
	tx <= tx_set and (not tx_rst);
	
	process(tx,rx,CLK,scl_en_rst,RST)
	begin
		if (RST ='1') then
			scl_en_set <= '0';
		elsif(scl_en_rst = '1') then
			scl_en_set <= '0';
		elsif ((tx ='1' or rx = '1') and falling_edge(CLK)) then
			scl_en_set <= '1';
		end if;
	end process;
	
	process(bits_sent,SCL,scl_en_set,RST)
	begin
		if (RST ='1') then
			scl_en_rst <= '0';
		elsif (bits_sent = N+1 and SCL = '1') then
			scl_en_rst <= '1';
		elsif (rising_edge(scl_en_set)) then
			scl_en_rst <= '0';
		end if;
	end process;
	
	scl_en <= scl_en_set and (not scl_en_rst);
	SCL <= CLK when (scl_en = '1') else '1';
	
	--serial write on SDA bus
	serial_w: process(tx,CLK,WREN,DR,RST)
	begin
		if (RST ='1') then
			fifo_sda <= (others => '1');
			fifo_empty <= '0';
			bits_sent <= 0;
		elsif (WREN = '1') then
			fifo_sda <= '0' & DR & '0';--start bit & DR & stop bit
		elsif(tx='1' and falling_edge(CLK))then--updates fifo at falling edge so it can be read at rising_edge
			fifo_sda <= fifo_sda(N downto 0) & '1';--MSB is sent first
			bits_sent <= bits_sent + 1;
			if (bits_sent = N+1) then
				fifo_empty <= '1';
				bits_sent <= 0;
			end if;
		end if;

	end process;
	SDA <= fifo_sda(N+1);
	
--	serial_r: process()
	
end structure;