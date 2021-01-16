--------------------------------------------------
--I2C master peripheral
--by Renan Picoli de Souza
--instantiates a generic I2C master and provides access to its registers 
--supports only 8 bit sending/receiving
-- NO support for clock stretching
--------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
--use ieee.std_logic_unsigned.all;
--use ieee.numeric_std.all;--to_integer
use work.my_types.all;--array32

entity i2c_master is
	port (
			D: in std_logic_vector(31 downto 0);--for register write
			ADDR: in std_logic_vector(7 downto 0);--address offset of registers relative to peripheral base address
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
end i2c_master;

architecture structure of i2c_master is
	component address_decoder_register_map
	--N: address width in bits
	--boundaries: upper limits of each end (except the last, which is 2**N-1)
	generic	(N: natural);
	port(	ADDR: in std_logic_vector(N-1 downto 0);-- input
			RDEN: in std_logic;-- input
			WREN: in std_logic;-- input
			WREN_OUT: out std_logic_vector;-- output
			data_in: in array32;-- input: outputs of all peripheral/registers
			data_out: out std_logic_vector(31 downto 0)-- data read
	);
	end component;
	
	component i2c_master_generic
	generic (N: natural);--number of bits in each data written/read
	port (
			DR: in std_logic_vector(N-1 downto 0);--to store data to be transmitted or received
			ADDR: in std_logic_vector(7 downto 0);--address offset of registers relative to peripheral base address
			CLK_IN: in std_logic;--clock input, same frequency as SCL, divided by 2 to generate SCL
			RST: in std_logic;--reset
			WREN: in std_logic;--enables register write
			WORDS: in std_logic_vector(1 downto 0);--controls number of words to receive or send
			IACK: in std_logic_vector(1 downto 0);--interrupt request: 0: successfully transmitted all words; 1: NACK received
			IRQ: out std_logic_vector(1 downto 0);--interrupt request: 0: successfully transmitted all words; 1: NACK received
			SDA: inout std_logic;--open drain data line
			SCL: inout std_logic --open drain clock line
	);
	end component;
	
	component interrupt_controller
	generic	(L: natural);--L: number of IRQ lines
	port(	D: in std_logic_vector(31 downto 0);-- input: data to register write
			CLK: in std_logic;-- input
			RST: in std_logic;-- input
			WREN: in std_logic;-- input
			RDEN: in std_logic;-- input
			IRQ_IN: in std_logic_vector(L-1 downto 0);--input: all IRQ lines
			IRQ_OUT: out std_logic;--output: IRQ line to cpu
			IACK_IN: in std_logic;--input: IACK line coming from cpu
			IACK_OUT: buffer std_logic_vector(L-1 downto 0);--output: all IACK lines going to peripherals
			output: out std_logic_vector(31 downto 0)-- output of register reading
	);

	end component;
	
	constant N: natural := 4;--number of bits in each data written/read
	signal dr_byte: std_logic_vector(N-1 downto 0);
	signal words: std_logic_vector(1 downto 0);--00: 1 word; 01:2 words; 10: 3 words (unused); 11: 4 words
	signal all_i2c_irq: std_logic_vector(1 downto 0);--0: successfully transmitted all words; 1: NACK received
	signal all_i2c_iack: std_logic_vector(1 downto 0);--0: successfully transmitted all words; 1: NACK received
	
	signal irq_ctrl_Q: std_logic_vector(31 downto 0);
	signal irq_ctrl_rden: std_logic;-- not used, just to keep form
	signal irq_ctrl_wren: std_logic;
begin

	dr_byte <= D(N-1 downto 0);
	words <= "01";--TODO: make a register
	
	i2c: i2c_master_generic
	generic map (N => N)
	port map(DR => dr_byte,
				CLK_IN => CLK,
				ADDR => ADDR,
				RST => RST,
				WREN => WREN,
				WORDS => words,
				IACK => all_i2c_iack,
				IRQ => all_i2c_irq,
				SDA => SDA,
				SCL => SCL
	);
	
	irq_ctrl: interrupt_controller
	generic map (L => 2)
	port map(D => D,
				CLK => CLK,
				RST => RST,
				WREN => irq_ctrl_wren,
				RDEN => irq_ctrl_rden,
				IRQ_IN => all_i2c_irq,
				IRQ_OUT => IRQ,
				IACK_IN => IACK,
				IACK_OUT => all_i2c_iack,
				output => irq_ctrl_Q
	);
end structure;