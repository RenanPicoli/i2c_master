--------------------------------------------------
--I2C master generic component
--by Renan Picoli de Souza
--sends/receives data from SDA bus and drives SCL clock
--supports only 8 bit sending/receiving
--Generates IRQs in following events:
--received NACK
--transmission ended (STOP)
-- NO support for clock stretching
--------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;--std_logic types, to_x01
--use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;--to_integer

entity i2c_master_generic is
	generic (N: natural);--number of bits in each data written/read
	port (
			DR_out: in std_logic_vector(31 downto 0);--data to be transmitted
			DR_in: out std_logic_vector(31 downto 0);--data received
			DR_wren: out std_logic;--DR write enable (register ENA)
			ADDR: in std_logic_vector(7 downto 0);--address offset of registers relative to peripheral base address
			CLK_IN: in std_logic;--clock input, divided by 2 to generate SCL
			RST: in std_logic;--reset
			WREN: in std_logic;--enables register write
			WORDS: in std_logic_vector(1 downto 0);--controls number of words to receive or send
			IACK: in std_logic_vector(1 downto 0);--interrupt request: 0: successfully transmitted all words; 1: NACK received
			IRQ: out std_logic_vector(1 downto 0);--interrupt request: 0: successfully transmitted all words; 1: NACK received
			SDA: inout std_logic;--open drain data line
			SCL: inout std_logic --open drain clock line
	);
end i2c_master_generic;

architecture structure of i2c_master_generic is

	component prescaler
	generic(factor: integer);
	port (CLK_IN: in std_logic;--input clock
			rst: in std_logic;--synchronous reset
			CLK_OUT: out std_logic--output clock
	);
	end component;

	signal fifo_sda_out: std_logic_vector(N+1 downto 0);--data to write on SDA: one byte plus start and stop bits
	signal fifo_sda_in: std_logic_vector(N-1 downto 0);-- data read from SDA: one byte plus start and stop bits
	
	--signals representing I2C transfer state
	signal read_mode: std_logic;-- 1 means reading from slave, 0 means writing on slave.
	signal write_mode: std_logic;-- 0 means reading from slave, 1 means writing on slave. Created for ease.
	signal tx: std_logic;--flag indicating it is transmitting (address or data)
	signal tx_addr: std_logic;--flag indicating it is transmitting address
	signal tx_data: std_logic;--flag indicating it is transmitting data
	signal rx: std_logic;--flag indicating it is receiving
	signal ack: std_logic;--active HIGH, indicates the state when ack should be sent or received
	signal ack_addr: std_logic;--active HIGH, indicates the state when ack of address should be received
	signal ack_data: std_logic;--active HIGH, indicates the state when ack of word (byte) should be sent or received
	signal ack_received: std_logic;--active HIGH, indicates slave-receiver acknowledged
	signal ack_addr_received: std_logic;--active HIGH, indicates slave-receiver acknowledged
	signal start: std_logic;-- indicates start bit being transmitted (also applies to repeated start)
	signal stop: std_logic;-- indicates stop bit being transmitted
	
	--signals inherent to this implementation
	signal CLK: std_logic;--used to generate SCL (when scl_en = '1')
	
	-- CLK 90 degrees in advance, its rising_edge is used to write on SDA in middle of SCL low
	signal CLK_90_lead: std_logic;
	
	signal ack_finished: std_logic;--active HIGH, indicates the ack was high in previous scl cycle [0 1].
	signal CLK_IN_n: std_logic;-- not CLK
	signal fifo_empty: std_logic;
	signal bits_sent: natural;--number of bits transmitted
	signal bits_received: natural;--number of bits received
	signal words_sent: natural;--number of words(bytes) transmitted
	signal words_received: natural;--number of words(bytes) received
	
	signal scl_en: std_logic;--enables scl to follow CLK
	
begin
	read_mode <= ADDR(0);
	write_mode <= not read_mode;
	tx <= tx_addr or tx_data;
	ack <= ack_addr or ack_data;
	
	---------------clock generation----------------------------
	scl_clk: prescaler
	generic map (factor => 2)
	port map(CLK_IN	=> CLK_IN,
				RST		=> RST,
				CLK_OUT	=> CLK
	);
	
	CLK_IN_n <= not CLK_IN;
	scl_90_clk: prescaler
	generic map (factor => 2)
	port map(CLK_IN	=>	CLK_IN_n,
				RST		=> RST,
				CLK_OUT	=> CLK_90_lead
	);
	
	---------------start flag generation----------------------------
	process(RST,SDA,SCL)
	begin
		if (RST ='1') then
			start	<= '0';
		elsif (SCL='0') then
			start	<= '0';
		--falling_edge e rising_edge don't need to_x01 because it is already used inside these functions
		elsif	(falling_edge(SDA) and SCL='1') then
			start <= '1';
		end if;
	end process;
	
	---------------stop flag generation----------------------------
	----------stop flag will be used to drive sda,scl--------------
	process(RST,ack,write_mode,read_mode,ack_received,ack_addr_received,ack_finished,SDA,SCL,words_sent,words_received,WORDS)
	begin
		if (RST ='1') then
			stop	<= '0';
		elsif	((ack='0' and write_mode='1' and words_sent=to_integer(unsigned(WORDS))+1) or
				 (ack='0' and read_mode='1' and words_received=to_integer(unsigned(WORDS))+1) or
				(ack='0' and ack_finished='1' and ack_received='0' and SCL='0' and
				not(read_mode='1' and ack_addr_received='1')))--implicitly samples ack_received at falling_edge of ack
				then
			stop <= '1';
		elsif (rising_edge(SDA) and SCL='1') then
			stop	<= '0';
		end if;
	end process;
	
	---------------tx_addr flag generation----------------------------
	process(fifo_empty,ack,WREN,RST,write_mode)
	begin
		if (RST ='1') then
			tx_addr	<= '0';
		elsif (ack='1') then
			tx_addr	<= '0';
		elsif	(rising_edge(WREN)) then
			tx_addr <= '1';
		end if;
	end process;
	
	---------------tx_data flag generation----------------------------
	process(tx_data,ack,ack_received,write_mode,bits_sent,words_sent,WORDS,SCL,RST)
	begin
		if (RST ='1') then
			tx_data	<= '0';
		elsif (tx_data='1' and ack='1' and bits_sent=N) then
			tx_data	<= '0';
		elsif	(ack='1' and ack_received='1' and write_mode='1' and (words_sent/=to_integer(unsigned(WORDS))+1) and falling_edge(SCL)) then
			tx_data <= '1';
		end if;
	end process;
	
	---------------SCL generation----------------------------
	process(stop,SCL,tx,rx,CLK,RST)
	begin
		if (RST ='1') then
			scl_en	<= '0';
		elsif (stop = '1' and SCL = '1') then
			scl_en	<= '0';
		elsif	((tx ='1' or rx ='1') and falling_edge(CLK)) then
			scl_en <= '1';
		end if;
	end process;
	SCL <= CLK when (scl_en = '1') else '1';

	---------------SDA write----------------------------
	--serial write on SDA bus
	serial_w: process(tx,fifo_sda_out,RST,ack,stop,SCL,clk_90_lead,read_mode,write_mode)
	begin
		if (RST ='1') then
			SDA <= 'Z';
		elsif (ack = '1' and read_mode='1') then
			SDA <= '0';--master acknowledges
		elsif (ack = '1' and write_mode='1') then
			SDA <= 'Z';--allows the slave to acknowledge
		elsif (stop = '1' and SCL='0') then
			SDA <= '0';
		elsif (stop = '1' and SCL='1' and clk_90_lead='0') then
			SDA <= 'Z';
		elsif(tx='1')then--SDA is driven using the fifo, which updates at rising_edge of clk_90_lead
			if (fifo_sda_out(N+1) = '1') then
				SDA <= 'Z';
			else
				SDA <= '0';
			end if;
		end if;

	end process;
	
	---------------fifo_sda_out write-----------------------------
	----might contain data from sda or from this component----
	fifo_w: process(RST,WREN,tx,tx_data,rx,ack,ack_received,CLK_90_lead,DR_out)
	begin
		if (RST ='1') then
			fifo_sda_out <= (others => '1');
			fifo_empty <= '0';
		elsif (WREN = '1') then
			fifo_sda_out <= '0' & ADDR(N-1 downto 0) & '0';--start bit & ADDR(N-1 downto 0) & stop bit
		elsif (tx_data = '1' and ack_received = '1') then
			fifo_sda_out <= DR_out(N-1 downto 0) & "11";--DR_out(N-1 downto 0) & dummy bits
		elsif(ack='1') then
			fifo_empty <= '1';
		--updates fifo at rising edge of clk_90_lead so it can be read at rising_edge of SCL
		elsif(tx='1' and rising_edge(CLK_90_lead))then
			fifo_sda_out <= fifo_sda_out(N downto 0) & '1';--MSB is sent first
		end if;

	end process;
	
	bits_sent_w: process(RST,ack,tx,SCL)
	begin
		if (RST ='1') then
			bits_sent <= 0;
		elsif(ack='1') then
			bits_sent <= 0;
		elsif(tx='1' and rising_edge(SCL))then
			bits_sent <= bits_sent + 1;
		end if;
	end process;
	
	---------------fifo_sda_in write-----------------------------
	---------------data read from bus----------------------------
	serial_r: process(RST,ack,rx,fifo_sda_in,SCL,SDA)
	begin
		if (RST ='1') then
			bits_received <= 0;
			fifo_sda_in <= (others => '1');
		elsif(ack='1') then
			bits_received <= 0;
			DR_in <= (31 downto N =>'0') & fifo_sda_in;
		--updates data received in falling edge because data is stable when SCL=1
		elsif (rx='1' and rising_edge(SCL)) then
			bits_received <= bits_received + 1;
			fifo_sda_in <= fifo_sda_in(N-2 downto 0) & to_x01(SDA);
		end if;
	end process;
	
	----------------------DR_wren write-----------------------------
	-----this complex timing ensures DR_wren to be '1' at only one positive edge of CLK_IN
	process(RST,ack_data,clk_90_lead)
	begin
		if (RST ='1') then
			DR_wren<='0';
		elsif(ack_data='1' and clk_90_lead='1') then
			DR_wren<='1';
		elsif (falling_edge(clk_90_lead)) then
			DR_wren <= '0';
		end if;
	end process;
	
	---------------words_received write-----------------------------
	process(RST,WREN,rx,ack_data,stop)
	begin
		if (RST ='1') then
			words_received <= 0;
		elsif (WREN = '1') then
			words_received <= 0;
		elsif (stop = '1') then
			words_received <= 0;
		elsif(rising_edge(ack_data) and rx='1')then
			words_received <= words_received + 1;
			if (words_received = to_integer(unsigned(WORDS))+1) then
				words_received <= 0;
			end if;
		end if;

	end process;
	
	---------------words_sent write-----------------------------
	process(RST,WREN,tx_data,ack,stop)
	begin
		if (RST ='1') then
			words_sent <= 0;
		elsif (WREN = '1') then
			words_sent <= 0;
		elsif (stop = '1') then
			words_sent <= 0;
		elsif(rising_edge(ack) and tx_data='1')then
			words_sent <= words_sent + 1;
			if (words_sent = to_integer(unsigned(WORDS))+1) then
				words_sent <= 0;
			end if;
		end if;

	end process;
	
	---------------ack_addr flag generation----------------------
	process(tx_addr,bits_sent,SCL,RST)
	begin
		if (RST ='1') then
			ack_addr <= '0';
		elsif	(falling_edge(SCL)) then
			if (tx_addr='1' and bits_sent=N) then
				ack_addr <= '1';
			else
				ack_addr <= '0';
			end if;
		end if;
	end process;
	
	---------------ack_data flag generation----------------------
	process(rx,tx_data,bits_sent,bits_received,SCL,RST)
	begin
		if (RST ='1') then
			ack_data <= '0';
		elsif	(falling_edge(SCL)) then
			if ((tx_data='1' and bits_sent=N) or (rx='1' and bits_received=N)) then
				ack_data <= '1';
			else
				ack_data <= '0';
			end if;
		end if;
	end process;

	---------------ack_received flag generation----------------------------
	process(ack,write_mode,ack_received,SCL,SDA,RST)
	begin
		if (RST ='1') then
			ack_received <= '0';
			--to_x01 converts 'H','L' to '1','0', respectively. Needed only IN SIMULATION
		elsif	(rising_edge(SCL)) then
			ack_received <= ack and not(to_x01(SDA)) and not(read_mode and ack_addr_received);
		end if;
	end process;
	
	---------------ack_finished flag generation----------------------------
	ack_f: process(ack,SCL,SDA,RST)
	begin
		if (RST ='1') then
			ack_finished <= '0';
		elsif (SCL='1') then
			ack_finished <= '0';
		elsif	(falling_edge(SCL)) then
			ack_finished <= ack;--active HIGH, indicates the ack was high in previous scl cycle [0 1].
		end if;
	end process;
	
	---------------ack_addr_received flag generation------------------------
	process(RST,stop,ack_received)
	begin
		if (RST ='1') then
			ack_addr_received <= '0';
		elsif (stop='1') then
			ack_addr_received <= '0';
		--to_x01 converts 'H','L' to '1','0', respectively. Needed only IN SIMULATION
		elsif	(rising_edge(ack_received)) then
			ack_addr_received <= '1';
		end if;
	end process;
	
	---------------rx flag generation----------------------------
	process(rx,ack,ack_data,read_mode,words_received,WORDS,SCL,RST)
	begin
		if (RST ='1') then
			rx	<= '0';
		elsif (rx='1' and ack_data='1') then
			rx	<= '0';
		elsif	(ack='1' and read_mode='1' and (words_received/=to_integer(unsigned(WORDS))+1) and falling_edge(SCL)) then
			rx <= '1';
		end if;
	end process;
	
	---------------SDA read----------------------------
--	serial_r: process()

	---------------IRQ BTF----------------------------
	---------byte transfer finished-------------------
	----transmitted all words successfully------------
	process(RST,IACK,stop,write_mode,words_sent,read_mode,words_received,WORDS)
	begin
		if(RST='1') then
			IRQ(0) <= '0';
		elsif (IACK(0) ='1') then
			IRQ(0) <= '0';
		elsif(rising_edge(stop) and ((write_mode='1' and words_sent=to_integer(unsigned(WORDS))+1) or
				(read_mode='1' and words_received=to_integer(unsigned(WORDS))+1))) then
			IRQ(0) <= '1';
		end if;
	end process;
	
	---------------IRQ NACK---------------------------
	-------------NACK received------------------------
	process(RST,IACK,ack,ack_finished,ack_received,SCL)
	begin
		if(RST='1') then
			IRQ(1) <= '0';
		elsif (IACK(1) ='1') then
			IRQ(1) <= '0';
		elsif(ack='0' and ack_finished='1' and ack_received='0' and SCL='0') then
			IRQ(1) <= '1';
		end if;
	end process;

	
end structure;