package tokenizer

import "core:strings"

Token :: struct {
	kind: Token_Kind,
	text: string,
	pos:  Pos,
}

Pos :: struct {
	file:   string,
	offset: int, // starting at 0
	line:   int, // starting at 1
	column: int, // starting at 1
}

pos_compare :: proc(lhs, rhs: Pos) -> int {
	if lhs.offset != rhs.offset {
		return -1 if (lhs.offset < rhs.offset) else +1
	}
	if lhs.line != rhs.line {
		return -1 if (lhs.line < rhs.line) else +1
	}
	if lhs.column != rhs.column {
		return -1 if (lhs.column < rhs.column) else +1
	}
	return strings.compare(lhs.file, rhs.file)
}

Token_Kind :: enum u32 {
	Invalid,
	EOF,
	Comment,
	File_Tag,
	//
	B_Literal_Begin,
	//
	Ident, // main
	Integer, // 12345
	Float, // 123.45
	Imag, // 123.45i
	Rune, // 'a'
	String, // "abc"
	Bool, // true, false
	//
	B_Literal_End,
	//
	B_Operator_Begin,
	//
	Eq, // =
	Not, // !
	Hash, // #
	At, // @
	Dollar, // $
	Pointer, // ^
	Question, // ?
	Add, // +
	Sub, // -
	Mul, // *
	Quo, // /
	Mod, // %
	Mod_Mod, // %%
	And, // &
	Or, // |
	Xor, // ~
	And_Not, // &~
	Shl, // <<
	Shr, // >>
	Cmp_And, // &&
	Cmp_Or, // ||
	Mul_Mul, // **
	//
	B_Assign_Op_Begin,
	//
	Add_Eq, // +=
	Sub_Eq, // -=
	Mul_Eq, // *=
	Quo_Eq, // /=
	Mod_Eq, // %=
	Mod_Mod_Eq, // %%=
	And_Eq, // &=
	Or_Eq, // |=
	Xor_Eq, // ~=
	And_Not_Eq, // &~=
	Shl_Eq, // <<=
	Shr_Eq, // >>=
	Cmp_And_Eq, // &&=
	Cmp_Or_Eq, // ||=
	//
	B_Assign_Op_End,
	//
	Increment, // ++
	Decrement, // --
	Arrow_Right, // ->
	Undef, // ---
	//
	B_Comparison_Begin,
	//
	Cmp_Eq, // ==
	Not_Eq, // !=
	Lt, // <
	Gt, // >
	Lt_Eq, // <=
	Gt_Eq, // >=
	//
	B_Comparison_End,
	//
	Open_Paren, // (
	Close_Paren, // )
	Open_Bracket, // [
	Close_Bracket, // ]
	Open_Brace, // {
	Close_Brace, // }
	Colon, // :
	Semicolon, // ;
	Period, // .
	Comma, // ,
	Ellipsis, // ..
	Range_Half, // ..<
	Range_Full, // ..=
	Quote, // 'a
	Backquote, // `a
	//
	B_Operator_End,
	//
	B_Keyword_Begin,
	//
	True, // true
	False, // false
	// add more
	B_Keyword_End,
	//
	COUNT,
}

tokens := [Token_Kind.COUNT]string {
	"Invalid",
	"EOF",
	"Comment",
	"FileTag",
	"",
	"identifier",
	"integer",
	"float",
	"imaginary",
	"rune",
	"string",
	"bool",
	"",
	"",
	"=",
	"!",
	"#",
	"@",
	"$",
	"^",
	"?",
	"+",
	"-",
	"*",
	"/",
	"%",
	"%%",
	"&",
	"|",
	"~",
	"&~",
	"<<",
	">>",
	"&&",
	"||",
	"**",
	"",
	"+=",
	"-=",
	"*=",
	"/=",
	"%=",
	"%%=",
	"&=",
	"|=",
	"~=",
	"&~=",
	"<<=",
	">>=",
	"&&=",
	"||=",
	"",
	"++",
	"--",
	"->",
	"---",
	"",
	"==",
	"!=",
	"<",
	">",
	"<=",
	">=",
	"",
	"(",
	")",
	"[",
	"]",
	"{",
	"}",
	":",
	";",
	".",
	",",
	"..",
	"..<",
	"..=",
	"'",
	"`",
	"",
	"",
	"true",
	"false",
	// add more
	"",
}

is_newline :: proc(tok: Token) -> bool {
	return tok.kind == .Semicolon && tok.text == "\n"
}

token_to_string :: proc(tok: Token) -> string {
	if is_newline(tok) {
		return "newline"
	}
	return to_string(tok.kind)
}

to_string :: proc(kind: Token_Kind) -> string {
	if .Invalid <= kind && kind < .COUNT {
		return tokens[kind]
	}

	return "Invalid"
}

is_literal :: proc(kind: Token_Kind) -> bool {
	return .B_Literal_Begin < kind && kind < .B_Literal_End
}

is_operator :: proc(kind: Token_Kind) -> bool {
	return Token_Kind.B_Operator_Begin < kind && kind < Token_Kind.B_Operator_End
}

is_assignment_operator :: proc(kind: Token_Kind) -> bool {
	return .B_Assign_Op_Begin < kind && kind < .B_Assign_Op_End || kind == .Eq
}

is_keyword :: proc(kind: Token_Kind) -> bool {
	return Token_Kind.B_Keyword_Begin < kind && kind < Token_Kind.B_Keyword_End
}
