--------------------------------------------------
--I2C slave generic component
--by Renan Picoli de Souza
--sends/receives data from SDA bus and responds to SCL clock
--supports only 8 bit sending/receiving
--Generates IRQs in following events:
--received NACK
--transmission ended (STOP)
--NO support for clock stretching
--------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;--std_logic types, to_x01
--use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;--to_integer

entity i2c_slave_generic is
	generic (N: natural);--number of bits in each data written/read
	port (
			DR_out: in std_logic_vector(31 downto 0);--data to be transmitted
			DR_in_shift: buffer std_logic_vector(31 downto 0);--data received, will be shifted into DR
			DR_shift: out std_logic;--DR must shift left N bits to make room for new word
			OADDR: in std_logic_vector(7 downto 1);--slave own address
			mode: out std_logic_vector(1 downto 0);--read_mode: bit 0; write_mode: bit 1
			CLK_IN: in std_logic;--clock input, must be at least 2x the frequency of SCL
			RST: in std_logic;--reset
			WORDS: in std_logic_vector(1 downto 0);--controls number of words to receive or send (MSByte	first, MSB first)
			IACK: in std_logic_vector(1 downto 0);--interrupt request: 0: successfully transmitted all words; 1: NACK received
			IRQ: out std_logic_vector(1 downto 0);--interrupt request: 0: successfully transmitted all words; 1: NACK received
			SDA: inout std_logic;--open drain data line
			SCL: inout std_logic --open drain clock line
	);
end i2c_slave_generic;

architecture structure of i2c_slave_generic is

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
	signal tx: std_logic;--flag indicating it is transmitting data
	signal rx_addr: std_logic;--flag indicating it is receiving address
	signal rx_data: std_logic;--flag indicating it is receiving data
	signal rx: std_logic;--flag indicating it is receiving
	signal ack: std_logic;--active HIGH, indicates the state when ack should be sent or received
	signal ack_addr: std_logic;--active HIGH, indicates the state when ack of address should be received
	signal ack_data: std_logic;--active HIGH, indicates the state when ack of word (byte) should be sent or received
	signal ack_received: std_logic;--active HIGH, indicates master-receiver acknowledged
	signal ack_addr_sent: std_logic;--active HIGH, indicates slave-receiver acknowledged
	signal start: std_logic;-- indicates start bit being received (also applies to repeated start)
	signal stop: std_logic;-- indicates stop bit being received
	
	--signals inherent to this implementation
	constant SCL_divider: natural := 100;--MUST BE EVEN, fSCL=fCLK/SCL_divider, e.g. 50MHz/100=500kHz
	signal CLK: std_logic;--used to generate SCL (when scl_en = '1')
	
	signal CLK_aux: std_logic;--twice the frequency of SCL/CLK
	-- CLK 90 degrees in advance, its rising_edge is used to write on SDA in middle of SCL low
	signal CLK_90_lead: std_logic;
	signal address_received: std_logic_vector(N-1 downto 0);--address received from bus (includes R/W bit)
	signal ack_finished: std_logic;--active HIGH, indicates the ack was high in previous scl cycle [0 1].
	signal ack_data_finished: std_logic;--active HIGH, indicates the ack_data was high in previous scl cycle [0 1].
	signal bits_sent: natural;--number of bits transmitted
	signal bits_received: natural;--number of bits received
	signal words_sent: natural;--number of words(bytes) transmitted
	signal words_received: natural;--number of words(bytes) received
	signal idle: std_logic;-- i2c ready to start
	
	signal scl_en: std_logic;--enables scl to follow CLK
	
begin

	rx <= rx_addr or rx_data;
	ack <= ack_addr or ack_data;
	
	---------------clock generation----------------------------
	scl_clk: prescaler
	generic map (factor => SCL_divider)
	port map(CLK_IN	=> CLK_IN,
				RST		=> RST,
				CLK_OUT	=> CLK
	);
	
	CLK_aux_clk: prescaler
	generic map (factor => SCL_divider/2)
	port map(CLK_IN 	=> CLK_IN,
				RST		=> RST,
				CLK_OUT	=> CLK_aux
	);
	
	scl_90_clk: process(CLK,RST,CLK_aux)
	begin
		if (RST='1') then
			clk_90_lead <= '0';
		elsif (rising_edge(CLK_aux)) then
			clk_90_lead <= not CLK;
		end if;
	end process;
	
	---------------idle flag generation----------------------------
	process(RST,stop,start)
	begin
		if(RST='1')then
			idle <= '1';
		elsif(start='1')then
			idle <= '0';
		elsif(falling_edge(stop))then
			idle <= '1';
		end if;	
	end process;
	
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
	process	(RST,idle,ack,write_mode,read_mode,ack_received,ack_addr_sent,ack_data_finished,
				SDA,SCL,clk_90_lead,words_sent,words_received,WORDS,OADDR,address_received)
	begin
		if (RST ='1' or idle='1') then
			stop	<= '0';
		elsif	((ack='0' and write_mode='1' and words_received=to_integer(unsigned(WORDS))+1) or
				 (ack='0' and read_mode='1' and words_sent=to_integer(unsigned(WORDS))+1) or
				 (rx_addr='1' and bits_received=N and SCL='0' and address_received(N-1 downto 1) /= OADDR(N-1 downto 1)) or
				(ack_received='0' and ack_data_finished='1' and read_mode='1' and SCL='0'))--implicitly samples ack_received at falling_edge of ack
				then
			stop <= '1';
		elsif (rising_edge(SDA) and SCL='1') then
			stop	<= '0';
		end if;
	end process;
	
	---------------rx_addr flag generation----------------------------
	process(ack,start,RST,write_mode)
	begin
		if (RST ='1') then
			rx_addr	<= '0';
		elsif (ack='1') then
			rx_addr	<= '0';
		elsif	(rising_edge(start)) then
			rx_addr <= '1';
		end if;
	end process;
	
	---------------rx_data flag generation----------------------------
	process(rx_data,ack,write_mode,bits_received,words_received,WORDS,SCL,RST,idle)
	begin
		if (RST ='1' or idle='1') then
			rx_data	<= '0';
		elsif (rx_data='1' and ack='1' and bits_received=N) then
			rx_data	<= '0';
		elsif	(ack='1' and write_mode='1' and (words_received/=to_integer(unsigned(WORDS))+1) and falling_edge(SCL)) then
			rx_data <= '1';
		end if;
	end process;
	
	---------------read_mode/write_mode flag generation----------------------------
	process(RST,idle,rx_addr,bits_received,SDA,SCL,stop,ack_data_finished)
	begin
		if (RST ='1' or (stop='1' and ack_data_finished='0') or idle='1') then
			read_mode	<= '0';
			write_mode	<= '0';
		elsif	(rx_addr='1' and bits_received=N-1 and rising_edge(SCL)) then--bits_received=N-1 because it goes to N at rising edge of SCL
			read_mode <= to_x01(SDA);--reads the N-th bit (R/W bit)
			write_mode <= not to_x01(SDA);
		end if;
	end process;
	mode <= write_mode & read_mode;
	
	---------------SCL generation----------------------------
	process(stop,idle,SCL,tx,tx,CLK,RST)
	begin
		if (RST ='1' or idle='1') then
			scl_en	<= '0';
		elsif (stop = '1' and SCL = '1') then
			scl_en	<= '0';
		elsif	((tx ='1' or tx ='1') and falling_edge(CLK)) then
			scl_en <= '1';
		end if;
	end process;
--	SCL <= CLK when (scl_en = '1') else '1';
	SCL <= 'Z';--no clock stretching, SCL will be only read

	---------------SDA write----------------------------
	--serial write on SDA bus
	serial_w: process(tx,fifo_sda_out,RST,ack,stop,idle,SCL,clk_90_lead,read_mode,write_mode)
	begin
		if (RST ='1' or stop='1' or idle='1') then
			SDA <= 'Z';
		elsif ((ack = '1' and write_mode='1') or ack_addr='1') then
			SDA <= '0';--slave acknowledges
		elsif (ack = '1' and read_mode='1') then
			SDA <= 'Z';--allows the master to acknowledge
		elsif(rx='1')then
			SDA <= 'Z';--releases the bus when reading, so master can drive it
		elsif(tx='1')then--SDA is driven using the fifo, which updates at rising_edge of clk_90_lead
			if (fifo_sda_out(N+1) = '1') then
				SDA <= 'Z';
			else
				SDA <= '0';
			end if;
		else--statement to remove latch
			SDA <= 'Z';--releases bus
		end if;

	end process;
	
	---------------fifo_sda_out write-----------------------------
	----might contain data from sda or from this component----
	fifo_w: process(RST,idle,start,tx,ack_received,ack_addr_sent,ack_finished,CLK_90_lead,DR_out,WORDS,words_sent)
	begin
		if (RST ='1' or idle='1') then
			fifo_sda_out <= (others => '1');
		elsif (tx = '1' and (ack_addr_sent = '1' and ack_finished='1')) then
			--DR_out(...) & dummy bits
			fifo_sda_out <= DR_out(N-1+N*(to_integer(unsigned(WORDS))-words_sent)
									downto 0+N*(to_integer(unsigned(WORDS))-words_sent)) & "11";
		--updates fifo at rising edge of clk_90_lead so it can be read at rising_edge of SCL
		elsif(tx='1' and rising_edge(CLK_90_lead))then
			fifo_sda_out <= fifo_sda_out(N downto 0) & '1';--MSB is sent first
		end if;

	end process;
	
	bits_sent_w: process(RST,idle,ack,tx,SCL)
	begin
		if (RST ='1' or idle='1') then
			bits_sent <= 0;
		elsif(ack='1') then
			bits_sent <= 0;
		elsif(tx='1' and rising_edge(SCL))then
			bits_sent <= bits_sent + 1;
		end if;
	end process;
	
	---------------fifo_sda_in write-----------------------------
	---------------data read from bus----------------------------
	serial_r: process(RST,idle,ack,rx,fifo_sda_in,SCL,SDA)
	begin
		if (RST ='1' or idle='1') then
			fifo_sda_in <= (others => '1');
		--updates data received in falling edge because data is stable when SCL=1
		elsif (rx='1' and rising_edge(SCL)) then
			fifo_sda_in <= fifo_sda_in(N-2 downto 0) & to_x01(SDA);
		end if;
	end process;
	
	process(RST,idle,SCL,clk_90_lead)
	begin
		if (RST ='1' or idle='1') then
			address_received <= (others => '0');
		--updates data received in falling edge because data is stable when SCL=1
		elsif (SCL='1' and falling_edge(clk_90_lead)) then
			address_received <= fifo_sda_in(N-1 downto 0);
		end if;
	end process;
	
	process(RST,idle,ack_data,fifo_sda_in,DR_in_shift)
	begin
		if (RST ='1' or idle='1') then
			DR_in_shift <= (others=>'0');
		elsif(rising_edge(ack_data)) then
			DR_in_shift <= (31 downto N =>'0') & fifo_sda_in;
		end if;
	end process;
		
	bits_received_w: process(RST,idle,ack,tx,SCL)
	begin
		if (RST ='1' or idle='1') then
			bits_received <= 0;
		elsif(ack='1') then
			bits_received <= 0;
		elsif(rx='1' and rising_edge(SCL))then
			bits_received <= bits_received + 1;
		end if;
	end process;
	
	----------------------DR_shift write-----------------------------
	-----this complex timing ensures DR_shift to be '1' at only one positive edge of CLK_IN
	process(RST,idle,ack_data,clk_90_lead,read_mode)
	begin
		if (RST ='1' or idle='1') then
			DR_shift<='0';
		elsif(ack_data='1' and clk_90_lead='1' and write_mode='1') then
			DR_shift<='1';
		elsif (falling_edge(clk_90_lead)) then
			DR_shift <= '0';
		end if;
	end process;
	
	---------------words_sent write-----------------------------
	process(RST,idle,start,tx,ack_data)
	begin
		if (RST ='1' or idle='1') then
			words_sent <= 0;
		elsif (start = '1') then
			words_sent <= 0;
		elsif(rising_edge(ack_data) and tx='1')then
			words_sent <= words_sent + 1;
			if (words_sent = to_integer(unsigned(WORDS))+1) then
				words_sent <= 0;
			end if;
		end if;

	end process;
	
	---------------words_received write-----------------------------
	process(RST,idle,start,rx_data,ack)
	begin
		if (RST ='1' or idle='1') then
			words_received <= 0;
		elsif (start = '1') then
			words_received <= 0;
		elsif(rising_edge(ack) and rx_data='1')then
			words_received <= words_received + 1;
			if (words_received = to_integer(unsigned(WORDS))+1) then
				words_received <= 0;
			end if;
		end if;

	end process;
	
	---------------ack_addr flag generation----------------------
	process(rx_addr,bits_sent,SCL,RST,idle)
	begin
		if (RST ='1' or idle='1') then
			ack_addr <= '0';
		elsif	(falling_edge(SCL)) then
			--asserts ack_addr phase only after end of address and address matches OADDR
			if (rx_addr='1' and bits_received=N and (address_received(N-1 downto 1) = OADDR(N-1 downto 1))) then
				ack_addr <= '1';
			else
				ack_addr <= '0';
			end if;
		end if;
	end process;
	
	---------------ack_data flag generation----------------------
	--ack data phase: master or slave should acknowledge, depending on ADDR(0)
	--a single N-bit word was received or sent-------------------
	process(tx,rx_data,bits_sent,bits_received,SCL,RST,idle)
	begin
		if (RST ='1' or idle='1') then
			ack_data <= '0';
		elsif	(falling_edge(SCL)) then
			if ((rx_data='1' and bits_received=N) or (tx='1' and bits_sent=N)) then
				ack_data <= '1';
			else
				ack_data <= '0';
			end if;
		end if;
	end process;

	---------------ack_received flag generation----------------------------
	process(ack_data,write_mode,ack_received,SCL,SDA,RST,idle)
	begin
		if (RST ='1' or idle='1') then
			ack_received <= '0';
			--to_x01 converts 'H','L' to '1','0', respectively. Needed only IN SIMULATION
		elsif	(rising_edge(SCL)) then
			ack_received <= ack_data and not(to_x01(SDA)) and read_mode;
		end if;
	end process;
	
	---------------ack_finished flag generation----------------------------
	ack_f: process(ack,SCL,SDA,RST,idle)
	begin
		if (RST ='1' or idle='1') then
			ack_finished <= '0';
		elsif (SCL='1') then
			ack_finished <= '0';
		elsif	(falling_edge(SCL)) then
			ack_finished <= ack;--active HIGH, indicates the ack was high in previous scl cycle [0 1].
		end if;
	end process;
	
	---------------ack_data_finished flag generation------------------------
	--------for use with stop generation when NACK occurs-------------------
	ack_data_f: process(ack_data,SCL,SDA,RST,idle)
	begin
		if (RST ='1' or idle='1') then
			ack_data_finished <= '0';
		elsif (SCL='1') then
			ack_data_finished <= '0';
		elsif	(falling_edge(SCL)) then
			ack_data_finished <= ack_data;--active HIGH, indicates the ack_data was high in previous scl cycle [0 1].
		end if;
	end process;
	
	---------------ack_addr_sent flag generation------------------------
	process(RST,idle,ack)
	begin
		if (RST ='1' or idle='1') then
			ack_addr_sent <= '0';
		--to_x01 converts 'H','L' to '1','0', respectively. Needed only IN SIMULATION
		elsif	(rising_edge(ack)) then
			ack_addr_sent <= '1';
		end if;
	end process;
	
	---------------tx flag generation----------------------------
	process(tx,ack,ack_data,read_mode,words_received,WORDS,SCL,RST,idle)
	begin
		if (RST ='1' or idle='1') then
			tx	<= '0';
		elsif (tx='1' and ack_data='1') then
			tx	<= '0';
		elsif	(ack='1' and read_mode='1' and (words_sent/=to_integer(unsigned(WORDS))+1) and falling_edge(SCL)) then
			tx <= '1';
		end if;
	end process;

	---------------IRQ BTF----------------------------
	---------byte transfer finished-------------------
	----transmitted all words successfully------------
	process(RST,IACK,SDA,SCL,write_mode,words_sent,read_mode,words_received,WORDS)
	begin
		if(RST='1') then
			IRQ(0) <= '0';
		elsif (IACK(0) ='1') then
			IRQ(0) <= '0';
		elsif(rising_edge(SDA) and SCL='1' and ((read_mode='1' and words_sent=to_integer(unsigned(WORDS))+1) or
				(write_mode='1' and words_received=to_integer(unsigned(WORDS))+1))) then
			IRQ(0) <= '1';
		end if;
	end process;
	
	---------------IRQ NACK---------------------------
	-------------NACK received------------------------
	process(RST,IACK,ack_data,ack_received,read_mode)
	begin
		if(RST='1') then
			IRQ(1) <= '0';
		elsif (IACK(1) ='1') then
			IRQ(1) <= '0';
		elsif(falling_edge(ack_data) and ack_received='0' and read_mode='1') then
			IRQ(1) <= '1';
		end if;
	end process;

	
end structure;