package tokenizer

import "base:intrinsics"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

RESET :: "\x1b[0m"
GREEN :: "\x1b[32m"

Error_Handler :: #type proc(t: ^Tokenizer, pos: Pos, fmt: string, args: ..any)

Log_Style :: enum {
	Odin,
	Unix,
}

Tokenizer :: struct {
	// Immutable data
	path:        string,
	src:         string,
	err:         Error_Handler,
	style:       Log_Style,

	// Tokenizing state
	ch:          rune,
	offset:      int,
	read_offset: int,
	line_offset: int,
	line_count:  int,

	// Mutable data
	error_count: int,
}

Keyword_Hash_Entry :: struct {
	hash: u32,
	kind: Token_Kind,
	name: string,
}

KEYWORD_LUT_LEN :: 1 << 9
KEYWORD_LUT_MASK :: KEYWORD_LUT_LEN - 1
Keyword_LUT :: [KEYWORD_LUT_LEN]Keyword_Hash_Entry

global_keyword_lut: Keyword_LUT // protected by `_global_keyword_lut_spinlock`
_global_keyword_lut_initialized: bool // atomic
_global_keyword_lut_spinlock: bool // atomic

_global_keyword_spin_lock :: proc() {
	for intrinsics.atomic_exchange_explicit(&_global_keyword_lut_spinlock, true, .Acquire) {
		intrinsics.cpu_relax()
	}
}

_global_keyword_spin_unlock :: proc() {
	intrinsics.atomic_store_explicit(&_global_keyword_lut_spinlock, false, .Release)
}

@(require_results)
keyword_hash :: proc(text: string) -> u32 #no_bounds_check {
	h := u32(0x811c9dc5)
	for i in 0 ..< len(text) {
		h = (h ~ u32(text[i])) * 0x01000193
	}
	return h
}

keyword_lut_init :: proc(lut: ^Keyword_LUT) -> bool {
	if lut == nil {
		return false
	}

	max_keyword_size := 0

	for kind in (Token_Kind.B_Keyword_Begin + Token_Kind(1)) ..< Token_Kind.B_Keyword_End {
		name := tokens[kind]

		max_keyword_size = max(max_keyword_size, len(name))

		hash := keyword_hash(name)

		entry := &lut[hash & KEYWORD_LUT_MASK]
		assert(entry.kind == .Invalid, name)
		entry.hash = hash
		entry.kind = kind
		entry.name = name
	}

	assert(max_keyword_size > 1)
	assert(max_keyword_size < 16)

	return true
}


init :: proc(t: ^Tokenizer, src: string, path: string, err := default_error_handler) {
	t.src = src
	t.err = err
	t.ch = ' '
	t.offset = 0
	t.read_offset = 0
	t.line_offset = 0
	t.line_count = len(src) > 0 ? 1 : 0
	t.error_count = 0
	t.path = path

	if !intrinsics.atomic_load(&_global_keyword_lut_initialized) {
		_global_keyword_spin_lock()
		ok := keyword_lut_init(&global_keyword_lut)
		intrinsics.atomic_store(&_global_keyword_lut_initialized, ok)
		_global_keyword_spin_unlock()
	}

	advance_rune(t)
	if t.ch == utf8.RUNE_BOM {
		advance_rune(t)
	}
}

@(private)
offset_to_pos :: proc(t: ^Tokenizer, offset: int) -> Pos {
	line := t.line_count
	column := offset - t.line_offset + 1

	return Pos{file = t.path, offset = offset, line = line, column = column}
}

integer_length :: proc(n: int) -> (len: int) {
	len += 1
	n := n / 10

	for n != 0 {
		len += 1
		n = n / 10
	}

	return len
}

_print_pos :: proc(style: Log_Style, pos: Pos, msg: string, args: ..any) {
	if style == .Odin {
		fmt.eprintf("%s(%d:%d) ", pos.file, pos.line, pos.column)
	} else {
		fmt.eprintf("%s:%d:%d: ", pos.file, pos.line, pos.column)
	}
	log.errorf(msg, ..args)
}

default_error_handler :: proc(t: ^Tokenizer, pos: Pos, msg: string, args: ..any) {
	_print_pos(t.style, pos, msg, ..args)

	// +1, because substracting the column is the previous newline location
	line_begin := (pos.offset - pos.column) + 1

	line_end := (pos.offset + strings.index_rune(t.src[pos.offset:], '\n'))
	assert(line_end != -1)

	line_length := integer_length(pos.line)

	fmt.eprint("  ") // 2
	fmt.eprint(pos.line) // line_length
	fmt.eprint(" | ") // 3

	color := .Terminal_Color in context.logger.options
	fmt.eprint(t.src[line_begin:pos.offset])
	if color {
		fmt.eprint(GREEN)
	}
	fmt.eprint(cast(rune)t.src[pos.offset]) // target
	if color {
		fmt.eprint(RESET)
	}
	fmt.eprint(t.src[pos.offset + 1:line_end])
	fmt.eprint("\n")

	padding := (line_length + 2 + 3) + (pos.offset - line_begin)
	fmt.eprint(strings.repeat(" ", padding))
	fmt.eprint(cast(rune)'^')
	fmt.eprint("\n")
}

error :: proc(t: ^Tokenizer, offset: int, msg: string, args: ..any) {
	if t.err != nil {
		pos := offset_to_pos(t, offset)
		t.err(t, pos, msg, ..args)
	}
	t.error_count += 1
}

advance_rune :: proc(t: ^Tokenizer) {
	if t.read_offset < len(t.src) {
		t.offset = t.read_offset
		if t.ch == '\n' {
			t.line_offset = t.offset
			t.line_count += 1
		}
		r, w := rune(t.src[t.read_offset]), 1
		switch {
		case r == 0:
			error(t, t.offset, "illegal character NUL")
		case r >= utf8.RUNE_SELF:
			r, w = utf8.decode_rune_in_string(t.src[t.read_offset:])
			if r == utf8.RUNE_ERROR && w == 1 {
				error(t, t.offset, "illegal UTF-8 encoding")
			} else if r == utf8.RUNE_BOM && t.offset > 0 {
				error(t, t.offset, "illegal byte order mark")
			}
		}
		t.read_offset += w
		t.ch = r
	} else {
		t.offset = len(t.src)
		if t.ch == '\n' {
			t.line_offset = t.offset
			t.line_count += 1
		}
		t.ch = utf8.RUNE_EOF
	}
}

peek_byte :: proc(t: ^Tokenizer, offset := 0) -> byte {
	if t.read_offset + offset < len(t.src) {
		return t.src[t.read_offset + offset]
	}
	return 0
}

peek_rune :: proc(t: ^Tokenizer, offset := 0) -> (rune, int) {
	read_offset := t.read_offset + offset
	t_offset := t.offset

	if read_offset < len(t.src) {
		t_offset = read_offset
		r, w := rune(t.src[read_offset]), 1
		switch {
		case r == 0:
			error(t, t_offset, "illegal character NUL")
		case r >= utf8.RUNE_SELF:
			r, w = utf8.decode_rune_in_string(t.src[read_offset:])
			if r == utf8.RUNE_ERROR && w == 1 {
				error(t, t_offset, "illegal UTF-8 encoding")
			} else if r == utf8.RUNE_BOM && t.offset > 0 {
				error(t, t_offset, "illegal byte order mark")
			}
		}
		return r, offset + w
	} else {
		return utf8.RUNE_EOF, -1
	}
}

skip_whitespace :: proc(t: ^Tokenizer) {
	for {
		switch t.ch {
		case ' ', '\t', '\r', '\n':
			advance_rune(t)
		case:
			return
		}
	}
}

is_whitespace :: proc(ch: rune) -> bool {
	switch ch {
	case ' ', '\t', '\r', '\n':
		return true
	case:
		return false
	}
}

is_eof :: proc(r: rune) -> bool {
	return r == utf8.RUNE_EOF
}

is_letter :: proc(r: rune) -> bool {
	if r < utf8.RUNE_SELF {
		switch r {
		case '_':
			return true
		case 'A' ..= 'Z', 'a' ..= 'z':
			return true
		}
	}
	return unicode.is_letter(r)
}

is_digit :: proc(r: rune) -> bool {
	if '0' <= r && r <= '9' {
		return true
	}
	return unicode.is_digit(r)
}

scan_comment :: proc(t: ^Tokenizer) -> string {
	offset := t.offset - 1
	next := -1
	general: {
		if t.ch == '/' || t.ch == '!' { 	// // #! comments
			advance_rune(t)
			for t.ch != '\n' && t.ch >= 0 {
				advance_rune(t)
			}

			next = t.offset
			if t.ch == '\n' {
				next += 1
			}
			break general
		}

		/* style comment */
		advance_rune(t)
		nest := 1
		for t.ch >= 0 && nest > 0 {
			ch := t.ch
			advance_rune(t)
			if ch == '/' && t.ch == '*' {
				nest += 1
			}

			if ch == '*' && t.ch == '/' {
				nest -= 1
				advance_rune(t)
				next = t.offset
				if nest == 0 {
					break general
				}
			}
		}

		error(t, offset, "comment not terminated")
	}

	lit := t.src[offset:t.offset]

	// NOTE(bill): Strip CR for line comments
	for len(lit) > 2 && lit[1] == '/' && lit[len(lit) - 1] == '\r' {
		lit = lit[:len(lit) - 1]
	}


	return string(lit)
}

scan_file_tag :: proc(t: ^Tokenizer) -> string {
	offset := t.offset - 1

	for t.ch != '\n' && !is_eof(t.ch) {
		if t.ch == '/' {
			next := peek_byte(t, 0)

			if next == '/' || next == '*' {
				break
			}
		}
		advance_rune(t)
	}

	return string(t.src[offset:t.offset])
}

scan_identifier :: proc(t: ^Tokenizer) -> string {
	offset := t.offset

	for is_letter(t.ch) || is_digit(t.ch) {
		advance_rune(t)
	}

	return string(t.src[offset:t.offset])
}

scan_string :: proc(t: ^Tokenizer) -> string {
	offset := t.offset - 1
	for {
		ch := t.ch
		if ch == '\n' || ch < 0 {
			error(t, offset, "string literal was not terminated")
			break
		}
		advance_rune(t)
		if ch == '"' {
			break
		}
		if ch == '\\' {
			scan_escape(t)
		}
	}

	return string(t.src[offset + 1:t.offset - 1])
}

digit_val :: proc(r: rune) -> int {
	switch r {
	case '0' ..= '9':
		return int(r - '0')
	case 'A' ..= 'F':
		return int(r - 'A' + 10)
	case 'a' ..= 'f':
		return int(r - 'a' + 10)
	}
	return 16
}

scan_escape :: proc(t: ^Tokenizer) -> bool {
	offset := t.offset

	n: int
	base, max: u32
	switch t.ch {
	case 'a', 'b', 'e', 'f', 'n', 't', 'v', 'r', '\\', '\'', '\"':
		advance_rune(t)
		return true

	case '0' ..= '7':
		n, base, max = 3, 8, 255
	case 'x':
		advance_rune(t)
		n, base, max = 2, 16, 255
	case 'u':
		advance_rune(t)
		n, base, max = 4, 16, utf8.MAX_RUNE
	case 'U':
		advance_rune(t)
		n, base, max = 8, 16, utf8.MAX_RUNE
	case:
		if t.ch < 0 {
			error(t, offset, "escape sequence was not terminated")
		} else {
			error(t, offset, "unknown escape sequence")
		}
		return false
	}

	x: u32
	for n > 0 {
		d := u32(digit_val(t.ch))
		for d >= base {
			if t.ch < 0 {
				error(t, t.offset, "escape sequence was not terminated")
			} else {
				error(t, t.offset, "illegal character %d in escape sequence", t.ch)
			}
			return false
		}

		x = x * base + d
		advance_rune(t)
		n -= 1
	}

	if x > max || 0xd800 <= x && x <= 0xdfff {
		error(t, offset, "escape sequence is an invalid Unicode code point")
		return false
	}
	return true
}

scan_rune :: proc(t: ^Tokenizer) -> (string, Token_Kind) {
	offset := t.offset
	valid := true
	n := 0

	c_offset: int
	ch, r: rune = t.ch, ---
	for {
		r, c_offset = peek_rune(t, c_offset)
		if is_eof(ch) || is_whitespace(ch) {
			valid = false
			break
		}
		if ch == '\'' {
			break
		}
		n += 1
		if ch == '\\' {
			if !scan_escape(t) {
				valid = false
			}
		}
		ch = r
	}

	if n != 1 {
		if valid {
			error(t, offset - 1, "illegal rune literal")
		}
		return "'", .Quote
	}

	for i in 0 ..< n + 1 {
		advance_rune(t)
	}

	return string(t.src[offset:t.offset - 1]), .Rune
}

scan_number :: proc(t: ^Tokenizer, seen_decimal_point: bool) -> (Token_Kind, string) {
	scan_mantissa :: proc(t: ^Tokenizer, base: int) {
		for digit_val(t.ch) < base || t.ch == '_' {
			advance_rune(t)
		}
	}
	scan_exponent :: proc(t: ^Tokenizer, kind: ^Token_Kind) {
		if t.ch == 'e' || t.ch == 'E' {
			kind^ = .Float
			advance_rune(t)
			if t.ch == '-' || t.ch == '+' {
				advance_rune(t)
			}
			if digit_val(t.ch) < 10 {
				scan_mantissa(t, 10)
			} else {
				error(t, t.offset, "illegal floating-point exponent")
			}
		}

		// NOTE(bill): This needs to be here for sanity's sake
		switch t.ch {
		case 'i', 'j', 'k':
			kind^ = .Imag
			advance_rune(t)
		}
	}
	scan_fraction :: proc(t: ^Tokenizer, kind: ^Token_Kind) -> (early_exit: bool) {
		if t.ch == '.' && peek_byte(t) == '.' {
			return true
		}
		if t.ch == '.' {
			kind^ = .Float
			advance_rune(t)
			scan_mantissa(t, 10)
		}
		return false
	}


	offset := t.offset
	kind := Token_Kind.Integer
	seen_point := seen_decimal_point

	if seen_point {
		offset -= 1
		kind = .Float
		scan_mantissa(t, 10)
		scan_exponent(t, &kind)
	} else {
		if t.ch == '0' {
			int_base :: proc(t: ^Tokenizer, kind: ^Token_Kind, base: int, msg: string) {
				prev := t.offset
				advance_rune(t)
				scan_mantissa(t, base)
				if t.offset - prev <= 1 {
					kind^ = .Invalid
					error(t, t.offset, msg)
				}
			}

			advance_rune(t)
			switch t.ch {
			case 'b':
				int_base(t, &kind, 2, "illegal binary integer")
			case 'o':
				int_base(t, &kind, 8, "illegal octal integer")
			case 'd':
				int_base(t, &kind, 10, "illegal decimal integer")
			case 'z':
				int_base(t, &kind, 12, "illegal dozenal integer")
			case 'x':
				int_base(t, &kind, 16, "illegal hexadecimal integer")
			case 'h':
				kind = .Float
				prev := t.offset
				advance_rune(t)
				scan_mantissa(t, 16)
				if t.offset - prev <= 1 {
					kind = .Invalid
					error(t, t.offset, "illegal hexadecimal floating-point number")
				} else {
					sub := t.src[prev + 1:t.offset]
					digit_count := 0
					for d in sub {
						if d != '_' {
							digit_count += 1
						}
					}

					switch digit_count {
					case 4, 8, 16:
						break
					case:
						error(
							t,
							t.offset,
							"invalid hexadecimal floating-point number, expected 4, 8, or 16 digits, got %d",
							digit_count,
						)
					}
				}

			case:
				seen_point = false
				scan_mantissa(t, 10)
				if t.ch == '.' {
					seen_point = true
					if scan_fraction(t, &kind) {
						return kind, string(t.src[offset:t.offset])
					}
				}
				scan_exponent(t, &kind)
				return kind, string(t.src[offset:t.offset])
			}
		}
	}

	scan_mantissa(t, 10)

	if scan_fraction(t, &kind) {
		return kind, string(t.src[offset:t.offset])
	}

	scan_exponent(t, &kind)

	return kind, string(t.src[offset:t.offset])
}

scan :: proc(t: ^Tokenizer) -> Token {
	skip_whitespace(t)

	offset := t.offset

	kind: Token_Kind
	lit: string
	pos := offset_to_pos(t, offset)

	switch ch := t.ch; true {
	case is_letter(ch):
		lit = scan_identifier(t)
		kind = .Ident
		check_keyword: if 1 < len(lit) && len(lit) < 16 {
			if intrinsics.atomic_load(&_global_keyword_lut_initialized) {
				entry := &global_keyword_lut[keyword_hash(lit) & KEYWORD_LUT_MASK]
				if entry.kind != .Invalid && entry.name == lit {
					kind = entry.kind
					break check_keyword
				}
			} else {
				for i in Token_Kind.B_Keyword_Begin ..= Token_Kind.B_Keyword_End {
					if lit == tokens[i] {
						kind = Token_Kind(i)
						break check_keyword
					}
				}
			}
		}
		if kind == .True || kind == .False {
			kind = .Bool
		}
	case '0' <= ch && ch <= '9':
		kind, lit = scan_number(t, false)
	case:
		advance_rune(t)
		switch ch {
		case utf8.RUNE_EOF:
			kind = .EOF
		case '\n':
			kind = .Semicolon
			lit = "\n"
		case '\\':
			token := scan(t)
			if token.pos.line == pos.line {
				error(t, token.pos.offset, "expected a newline after \\")
			}
			return token

		case '\'':
			lit, kind = scan_rune(t)
		case '"':
			kind = .String
			lit = scan_string(t)
		case '`':
			kind = .Backquote
			lit = "`"
		case '.':
			kind = .Period
			switch t.ch {
			case '0' ..= '9':
				kind, lit = scan_number(t, true)
			case '.':
				advance_rune(t)
				kind = .Ellipsis
				switch t.ch {
				case '<':
					advance_rune(t)
					kind = .Range_Half
				case '=':
					advance_rune(t)
					kind = .Range_Full
				}
			}
		case '@':
			kind = .At
		case '$':
			kind = .Dollar
		case '?':
			kind = .Question
		case '^':
			kind = .Pointer
		case ';':
			kind = .Semicolon
		case ',':
			kind = .Comma
		case ':':
			kind = .Colon
		case '(':
			kind = .Open_Paren
		case ')':
			kind = .Close_Paren
		case '[':
			kind = .Open_Bracket
		case ']':
			kind = .Close_Bracket
		case '{':
			kind = .Open_Brace
		case '}':
			kind = .Close_Brace
		case '%':
			kind = .Mod
			switch t.ch {
			case '=':
				advance_rune(t)
				kind = .Mod_Eq
			case '%':
				advance_rune(t)
				kind = .Mod_Mod
				if t.ch == '=' {
					advance_rune(t)
					kind = .Mod_Mod_Eq
				}
			}
		case '*':
			kind = .Mul
			if t.ch == '=' {
				advance_rune(t)
				kind = .Mul_Eq
			} else if t.ch == '*' {
				advance_rune(t)
				kind = .Mul_Mul
			}
		case '=':
			kind = .Eq
			if t.ch == '=' {
				advance_rune(t)
				kind = .Cmp_Eq
			}
		case '~':
			kind = .Xor
			if t.ch == '=' {
				advance_rune(t)
				kind = .Xor_Eq
			}
		case '!':
			kind = .Not
			if t.ch == '=' {
				advance_rune(t)
				kind = .Not_Eq
			}
		case '+':
			kind = .Add
			switch t.ch {
			case '=':
				advance_rune(t)
				kind = .Add_Eq
			case '+':
				advance_rune(t)
				kind = .Increment
			}
		case '-':
			kind = .Sub
			switch t.ch {
			case '-':
				advance_rune(t)
				kind = .Decrement
				if t.ch == '-' {
					advance_rune(t)
					kind = .Undef
				}
			case '>':
				advance_rune(t)
				kind = .Arrow_Right
			case '=':
				advance_rune(t)
				kind = .Sub_Eq
			}
		case '#':
			kind = .Hash
			if t.ch == '!' {
				kind = .Comment
				lit = scan_comment(t)
			} else if t.ch == '+' {
				kind = .File_Tag
				lit = scan_file_tag(t)
			}
		case '/':
			kind = .Quo
			switch t.ch {
			case '/', '*':
				kind = .Comment
				lit = scan_comment(t)
			case '=':
				advance_rune(t)
				kind = .Quo_Eq
			}
		case '<':
			kind = .Lt
			switch t.ch {
			case '=':
				advance_rune(t)
				kind = .Lt_Eq
			case '<':
				advance_rune(t)
				kind = .Shl
				if t.ch == '=' {
					advance_rune(t)
					kind = .Shl_Eq
				}
			}
		case '>':
			kind = .Gt
			switch t.ch {
			case '=':
				advance_rune(t)
				kind = .Gt_Eq
			case '>':
				advance_rune(t)
				kind = .Shr
				if t.ch == '=' {
					advance_rune(t)
					kind = .Shr_Eq
				}
			}
		case '&':
			kind = .And
			switch t.ch {
			case '~':
				advance_rune(t)
				kind = .And_Not
				if t.ch == '=' {
					advance_rune(t)
					kind = .And_Not_Eq
				}
			case '=':
				advance_rune(t)
				kind = .And_Eq
			case '&':
				advance_rune(t)
				kind = .Cmp_And
				if t.ch == '=' {
					advance_rune(t)
					kind = .Cmp_And_Eq
				}
			}
		case '|':
			kind = .Or
			switch t.ch {
			case '=':
				advance_rune(t)
				kind = .Or_Eq
			case '|':
				advance_rune(t)
				kind = .Cmp_Or
				if t.ch == '=' {
					advance_rune(t)
					kind = .Cmp_Or_Eq
				}
			}
		case:
			if ch != utf8.RUNE_BOM {
				error(t, t.offset, "illegal character '%r': %d", ch, ch)
			}
			kind = .Invalid
		}
	}

	if lit == "" {
		lit = string(t.src[offset:t.offset])
	}
	return Token{kind, lit, pos}
}
