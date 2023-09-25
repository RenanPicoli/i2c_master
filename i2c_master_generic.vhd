--------------------------------------------------
--I2C master generic component
--by Renan Picoli de Souza
--sends/receives data from SDA bus and drives SCL clock
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

entity i2c_master_generic is
	generic (N: natural);--number of bits in each data written/read
	port (
			DR_out: in std_logic_vector(31 downto 0);--data to be transmitted
			DR_in_shift: buffer std_logic_vector(31 downto 0);--data received, will be shifted into DR
			DR_shift: out std_logic;--DR must shift left N bits to make room for new word
			ADDR: in std_logic_vector(7 downto 0);--slave address
			CLK_IN: in std_logic;--clock input, divided by 2 to generate SCL
			RST: in std_logic;--reset
			I2C_EN: in std_logic;--enables transfer to start
			WORDS: in std_logic_vector(1 downto 0);--controls number of words to receive or send (MSByte	first, MSB first)
			IACK: in std_logic_vector(1 downto 0);--interrupt request: 0: successfully transmitted all words; 1: NACK received
			IRQ: out std_logic_vector(1 downto 0);--interrupt request: 0: successfully transmitted all words; 1: NACK received
			SDA: inout std_logic;--open drain data line
			sda_dbg_p: out natural;--for debug, which statement is driving SDA
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

	signal fifo_sda_out: std_logic_vector(N-1 downto 0);--data to write on SDA: one byte plus stop bit
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
	signal idle: std_logic;-- i2c ready to start
	
	--signals inherent to this implementation
	constant SCL_divider: natural := 100;--MUST BE EVEN, fSCL=fCLK/SCL_divider, e.g. 25MHz/100=250kHz
	signal CLK: std_logic;--used to generate SCL (when scl_en = '1')
	signal CLK_n: std_logic;--inverted CLK
	
	signal I2C_EN_stretched: std_logic;--used to generate start bit
	signal sda_dbg: natural;--for debug, which statement is driving SDA
	
	signal CLK_aux: std_logic;--twice the frequency of SCL/CLK
	-- CLK_aux negated degrees in advance, its rising_edge is used to write on SDA in middle of SCL low
	signal CLK_aux_n: std_logic;
	
	signal tx_bit_number: natural;--number of bit being transmitted (starts from 1)
	signal rx_bit_number: natural;--number of bit being received (starts from 1)
	signal words_sent: natural;--number of words(bytes) transmitted
	signal words_received: natural;--number of words(bytes) received
	
	signal scl_en: std_logic;--enables scl to follow CLK
	attribute preserve : boolean;
	attribute preserve of sda_dbg : signal is true;
	
begin
	sda_dbg_p <= sda_dbg;

	read_mode <= ADDR(0);
	write_mode <= not read_mode;
	tx <= tx_addr or tx_data;
	ack <= ack_addr or ack_data;
	
	---------------clock generation----------------------------
	scl_clk: prescaler
	generic map (factor => 2)
	port map(CLK_IN	=> CLK_aux_n,
				RST		=> RST,
				CLK_OUT	=> CLK_n
	);
	CLK <= not CLK_n;
	
	CLK_aux_clk: prescaler
	generic map (factor => SCL_divider/2)
	port map(CLK_IN 	=> CLK_IN,
				RST		=> RST,
				CLK_OUT	=> CLK_aux
	);
	CLK_aux_n <=  not CLK_aux;
		
	---------------idle flag generation----------------------------
	process(RST,stop,I2C_EN,CLK_aux,CLK,SDA,SCL)
	begin
		if(RST='1')then
			idle <= '1';
		elsif(I2C_EN='1')then
			idle <= '0';
		--returns to idle after stop falls
		elsif(rising_edge(CLK_aux) and CLK='0' and to_X01(SDA)='1' and to_X01(SCL)='1' and stop='1')then
			idle <= '1';
		end if;	
	end process;
	
	---------------start flag generation----------------------------
	process(RST,I2C_EN_stretched,CLK_aux,CLK)
	begin
		if (RST ='1') then
			start	<= '0';
		elsif	(rising_edge(CLK_aux)) then
			--waits for the first posedge of CLK_aux with CLK='1' and I2C_EN_stretched='1' to assert start
			if ( I2C_EN_stretched='1' and CLK='1') then
				start <= '1';
			--deasserts start next posedge of CLK_aux
			else
				start <= '0';
			end if;
		end if;
	end process;
	
	---------------I2C_EN_stretched flag generation----------------------------
	process(RST,CLK_aux,CLK,I2C_EN)
	begin
		if (RST ='1') then
			I2C_EN_stretched	<= '0';
		elsif (I2C_EN='1') then
			I2C_EN_stretched	<= '1';
		--waits for the first posedge of CLK_aux with CLK='1' and I2C_EN_stretched='1', then clears this flag
		elsif	(rising_edge(CLK_aux) and CLK='1') then
			I2C_EN_stretched <= '0';
		end if;
	end process;
	
	---------------stop flag generation----------------------------
	----------stop flag will be used to drive sda,scl--------------
	process(RST,idle,CLK_aux,CLK,ack,write_mode,read_mode,ack_received,ack_addr_received,SDA,SCL,words_sent,words_received,WORDS)
	begin
		if (RST ='1' or idle='1') then
			stop	<= '0';
		elsif	(rising_edge(CLK_aux)) then
			if ((ack='1' and ack_received='1' and write_mode='1' and words_sent=to_integer(unsigned(WORDS))+1) or--successfully wrote 
				 (ack='1' and read_mode='1' and words_received=to_integer(unsigned(WORDS))+1) or--successfully read 
				(ack='1' and ack_received='0' and to_X01(SCL)='1' and--NACK
				not(read_mode='1' and ack_addr_received='1')))--implicitly samples ack_received at falling_edge of ack
				then
				stop <= '1';
			elsif (CLK='0' and to_X01(SDA)='1' and to_X01(SCL)='1') then
				stop	<= '0';
			end if;
		end if;
	end process;
	
	---------------tx_addr flag generation----------------------------
	process(ack,start,RST,idle,CLK_aux)
	begin
		if (RST ='1' or idle='1' or ack='1') then
			tx_addr	<= '0';
		elsif(rising_edge(CLK_aux)) then
			if	(start='1') then
				tx_addr <= '1';
			end if;
		end if;
	end process;
	
	---------------tx_data flag generation----------------------------
	process(tx_data,ack,ack_received,write_mode,tx_bit_number,words_sent,WORDS,CLK_aux,CLK,RST,idle)
	begin
		if (RST ='1' or idle='1') then
			tx_data <= '0';
		elsif	(rising_edge(CLK_aux)) then
			if (ack='1' and ack_received='1' and write_mode='1' and (words_sent/=to_integer(unsigned(WORDS))+1)) then
				tx_data <= '1';
			elsif (tx_bit_number=N and CLK='0') then
				tx_data <= '0';
			end if;
		end if;
	end process;
	
	---------------SCL generation----------------------------
	process(start,stop,idle,I2C_EN_stretched,CLK,SCL,tx,rx,ack,CLK_aux,RST)
	begin
		if (RST ='1' or idle='1') then
			scl_en	<= '0';
		elsif (stop='1' and SCL='1' and CLK_aux='0') then--captures stop='1' and rising_edge(SCL)
			scl_en <= '0';
		elsif(rising_edge(CLK_aux)) then
			if	(I2C_EN_stretched='1' and CLK='1') then
				scl_en <= '1';
--			elsif (stop = '1') then
--				scl_en	<= '0';
			end if;
		end if;
	end process;
	SCL <= CLK or (not scl_en);--keeps SCL='1' while scl_en='0', else, follows CLK

	---------------SDA write----------------------------
	--serial write on SDA bus
	serial_w: process(idle,I2C_EN_stretched,start,tx,rx,fifo_sda_out,RST,ack,stop,scl_en,SDA,SCL,CLK_aux,CLK,read_mode,write_mode,ack_data)
	begin
		if (RST ='1' or idle='1') then
			SDA <= 'Z';
			sda_dbg <= 0;
		elsif (start = '1' or I2C_EN_stretched='1') then
			SDA <= '0';--start bit
			sda_dbg <= 1;
		elsif (ack_data = '1' and read_mode='1') then
			SDA <= '0';--master acknowledges
			sda_dbg <= 2;
		elsif (ack = '1' and write_mode='1') then
			SDA <= 'Z';--allows the slave to acknowledge
			sda_dbg <= 3;
--			elsif (stop = '1' and scl_en='0' and to_X01(SDA)='1') then--traps SDA in high level
--				SDA <= 'Z';
--				sda_dbg <= 6;
		elsif (stop = '1' and (scl_en='1' or not((CLK='1' and CLK_aux='1')or(CLK='0' and CLK_aux='0')))) then
			SDA <= '0';
			sda_dbg <= 4;
		elsif (stop='1' and scl_en='0' and ((CLK='1' and CLK_aux='1')or(CLK='0' and CLK_aux='0'))) then
			SDA <= 'Z';
			sda_dbg <= 5;
		elsif(rx='1')then
			SDA <= 'Z';--releases the bus when reading, so slave can drive it			
			sda_dbg <= 7;
--			elsif(tx='1' and to_X01(SCL)='0')then--SDA is driven using the fifo, which updates at rising_edge of clk_90_lead
		else-- only option left is transmission (tx='1')
			if (fifo_sda_out(N-1) = '1') then
				SDA <= 'Z';
			else
				SDA <= '0';
			end if;			
			sda_dbg <= 8;
		end if;

	end process;
	
	---------------fifo_sda_out write-----------------------------
	----might contain data from sda or from this component----
	fifo_w: process(RST,idle,CLK_aux,CLK,I2C_EN_stretched,start,tx,ack_received,DR_out,ADDR,WORDS,words_sent)
	begin
		if (RST ='1' or idle='1') then
			fifo_sda_out <= (others => '1');
			tx_bit_number <= 0;
		elsif(rising_edge(CLK_aux) and CLK='0')then
--			if (I2C_EN_stretched = '1') then--waits for the first posedge of CLK_aux with CLK='1' and I2C_EN_stretched='1'
			if (start = '1') then--waits for the first posedge of CLK_aux with CLK='1' and I2C_EN_stretched='1'
				fifo_sda_out <= ADDR(N-1 downto 0);
				tx_bit_number <= 1;
			elsif (ack_received = '1' and (words_sent < to_integer(unsigned(WORDS))+1)) then
				--DR_out(...)
				fifo_sda_out <= DR_out(N-1+N*(to_integer(unsigned(WORDS))-words_sent)
										downto 0+N*(to_integer(unsigned(WORDS))-words_sent));
				tx_bit_number <= 1;
			--updates fifo at rising edge of clk_90_lead so it can be read at rising_edge of SCL
			else--if(tx='1')then
				fifo_sda_out <= fifo_sda_out(N-2 downto 0) & '1';--MSB is sent first
				tx_bit_number <= tx_bit_number + 1;--tx_bit_number=9 means ack state
			end if;
		end if;
	end process;
		
--	---------------fifo_sda_in write-----------------------------
--	---------------data read from bus----------------------------
--	serial_r: process(RST,idle,ack,rx,fifo_sda_in,SCL,SDA)
--	begin
--		if (RST ='1' or idle='1') then
--			fifo_sda_in <= (others => '1');
--		--updates data received in falling edge because data is stable when SCL=1
--		elsif (rx='1' and rising_edge(SCL)) then
--			fifo_sda_in <= fifo_sda_in(N-2 downto 0) & to_x01(SDA);
--		end if;
--	end process;
--	
--	process(RST,idle,ack_data,fifo_sda_in,DR_in_shift)
--	begin
--		if (RST ='1' or idle='1') then
--			DR_in_shift <= (others=>'0');
--		elsif(rising_edge(ack_data)) then
--			DR_in_shift <= (31 downto N =>'0') & fifo_sda_in;
--		end if;
--	end process;
--		
--	rx_bit_number_w: process(RST,idle,ack,rx,SCL)
--	begin
--		if (RST ='1' or idle='1') then
--			rx_bit_number <= 0;
--		elsif(ack='1') then
--			rx_bit_number <= 0;
--		elsif(rx='1' and rising_edge(SCL))then
--			rx_bit_number <= rx_bit_number + 1;
--		end if;
--	end process;
--	
--	----------------------DR_shift write-----------------------------
--	-----this complex timing ensures DR_shift to be '1' at only one positive edge of CLK_IN
--	process(RST,idle,ack_data,clk_90_lead,read_mode)
--	begin
--		if (RST ='1' or idle='1') then
--			DR_shift<='0';
--		elsif(ack_data='1' and clk_90_lead='1' and read_mode='1') then
--			DR_shift<='1';
--		elsif (falling_edge(clk_90_lead)) then
--			DR_shift <= '0';
--		end if;
--	end process;
--	
--	---------------words_received write-----------------------------
--	process(RST,idle,I2C_EN,rx,ack_data)
--	begin
--		if (RST ='1' or idle='1') then
--			words_received <= 0;
--		elsif (I2C_EN = '1') then
--			words_received <= 0;
--		elsif(rising_edge(ack_data) and rx='1')then
--			words_received <= words_received + 1;
--			if (words_received = to_integer(unsigned(WORDS))+1) then
--				words_received <= 0;
--			end if;
--		end if;
--
--	end process;
	
	---------------words_sent write-----------------------------
	process(RST,I2C_EN,tx_data,ack_data,idle,CLK_aux,CLK,tx_bit_number)
	begin
		if (RST ='1' or idle='1') then
			words_sent <= 0;
		elsif (I2C_EN = '1') then
			words_sent <= 0;
--		elsif(rising_edge(ack) and tx_data='1')then
		elsif(rising_edge(CLK_aux) and CLK='1' and ack_data='1' and tx_bit_number=N+1)then
			words_sent <= words_sent + 1;
			if (words_sent = to_integer(unsigned(WORDS))+1) then
				words_sent <= 0;
			end if;
		end if;

	end process;
	
	---------------ack_addr flag generation----------------------
	process(tx_addr,tx_bit_number,CLK_aux,CLK,RST,idle)
	begin
		if (RST ='1' or idle='1') then
			ack_addr <= '0';
		elsif	(rising_edge(CLK_aux) and CLK='0') then
			if (tx_addr='1' and tx_bit_number=N) then
				ack_addr <= '1';
			else
				ack_addr <= '0';
			end if;
		end if;
	end process;
	
	---------------ack_data flag generation----------------------
	--ack data phase: master or slave should acknowledge, depending on ADDR(0)
	--a single N-bit word was received or sent-------------------
	process(rx,tx_data,tx_bit_number,rx_bit_number,CLK_aux,CLK,RST,idle)
	begin
		if (RST ='1' or idle='1') then
			ack_data <= '0';
		elsif	(rising_edge(CLK_aux) and CLK='0') then -- also falling_edge of SCL
			if (((tx_data='1' and tx_bit_number=N) or (rx='1' and rx_bit_number=N))) then
				ack_data <= '1';
			else
				ack_data <= '0';
			end if;
		end if;
	end process;

	---------------ack_received flag generation----------------------------
	process(ack,write_mode,ack_received,SCL,SDA,RST,idle)
	begin
		if (RST ='1' or idle='1') then
			ack_received <= '0';
			--to_x01 converts 'H','L' to '1','0', respectively. Needed only IN SIMULATION
		elsif	(rising_edge(SCL)) then
			ack_received <= ack and not(to_x01(SDA)) and not(read_mode and ack_addr_received);
		end if;
	end process;
	
	---------------ack_addr_received flag generation------------------------
	process(RST,idle,ack_received,CLK_aux,CLK,ack_addr)
	begin
		if (RST ='1' or idle='1') then
			ack_addr_received <= '0';
--		elsif	(rising_edge(ack_received)) then
		elsif	(rising_edge(CLK_aux) and CLK='1' and ack_addr='1' and ack_received='1') then
			ack_addr_received <= '1';
		end if;
	end process;
	
--	---------------rx flag generation----------------------------
--	process(rx,ack,ack_data,read_mode,words_received,WORDS,SCL,RST,idle)
--	begin
--		if (RST ='1' or idle='1') then
--			rx	<= '0';
--		elsif (rx='1' and ack_data='1') then
--			rx	<= '0';
--		elsif	(ack='1' and read_mode='1' and (words_received/=to_integer(unsigned(WORDS))+1) and falling_edge(SCL)) then
--			rx <= '1';
--		end if;
--	end process;
	
	---------------IRQ BTF----------------------------
	---------byte transfer finished-------------------
	----transmitted all words successfully------------
	process(RST,CLK,CLK_aux,stop,IACK,SCL,SDA,write_mode,words_sent,read_mode,words_received,WORDS)
	begin
		if(RST='1') then
			IRQ(0) <= '0';
		elsif (IACK(0) ='1') then
			IRQ(0) <= '0';
		elsif(rising_edge(CLK_aux) and CLK='0' and to_X01(SCL)='1' and to_X01(SDA)='1' and stop='1' and ((write_mode='1' and words_sent=to_integer(unsigned(WORDS))+1) or
				(read_mode='1' and words_received=to_integer(unsigned(WORDS))+1))) then--works in simulation
			IRQ(0) <= '1';
		end if;
	end process;
	
	---------------IRQ NACK---------------------------
	-------------NACK received------------------------
	process(RST,CLK_aux,IACK,ack,ack_received,read_mode,ack_addr_received,stop,SCL)
	begin
		if(RST='1') then
			IRQ(1) <= '0';
		elsif (IACK(1) ='1') then
			IRQ(1) <= '0';
		elsif(ack='1' and CLK_aux='1' and ack_received='0' and not(read_mode='1' and ack_addr_received='1')
					and not(stop='1') and to_X01(SCL)='1') then
			IRQ(1) <= '1';
		end if;
	end process;
	
end structure;