package parser

import "../tokenizer"
import "core:fmt"
import "core:log"
import "core:strings"

Pos :: tokenizer.Pos

Error_Handler :: #type proc(
	t: ^tokenizer.Tokenizer,
	token: tokenizer.Token,
	fmt: string,
	args: ..any,
)

Parser :: struct {
	// Immutable data
	err:         Error_Handler,

	// Tokenizing state
	token:       tokenizer.Token,
	tok:         ^tokenizer.Tokenizer,

	// Mutable data
	error_count: int,
}

Node :: struct {
	pos: Pos,
}

Element :: union {
	List,
	Literal,
}

List :: struct {
	using node: Node,
	car:        ^Element,
	cdr:        [dynamic]^Element,
}

Literal :: struct {
	using node: Node,
	kind:       tokenizer.Token_Kind,
	text:       string,
}

new_element :: #force_inline proc(allocator := context.temp_allocator) -> ^Element {
	return new(Element, allocator)
}

scan :: #force_inline proc(psr: ^Parser) {
	psr.token = tokenizer.scan(psr.tok)
}

_expect :: #force_inline proc(psr: ^Parser, kind: tokenizer.Token_Kind) -> (ok: bool) {
	scan(psr)
	return kind == psr.token.kind
}

expect :: #force_inline proc(psr: ^Parser, kind: tokenizer.Token_Kind) -> (ok: bool) {
	ok = _expect(psr, kind)
	if !ok {
		error(psr, "expected %q, got %q", kind, psr.token.kind)
	}
	return
}

print :: proc(var: ^Element, n: int = 0) {
	nn := n + 2

	indent :: proc(n: int) {
		fmt.print(strings.repeat(" ", n, context.temp_allocator))
	}

	indent(n)

	if var == nil {
		fmt.println(nil)
		return
	}

	switch v in var {
	case Literal:
		#partial switch v.kind {
		case .Ident:
			fmt.println("i:", v.text)
		case .File_Tag:
			fmt.println("t:", v.text)
		case .Period, .Comma, .Colon, .Quote, .Backquote, .B_Operator_Begin ..< .B_Comparison_End:
			fmt.println("o:", v.text)
		case .Comment:
			fmt.println("c:", v.text)
		case .B_Keyword_Begin ..< .B_Keyword_End:
			fmt.println("k:", v.text)
		case .String:
			fmt.println("s:", v.text)
		case .Bool:
			fmt.println("b:", v.text)
		case .Float:
			fmt.println("f:", v.text)
		case .Integer:
			fmt.println("i:", v.text)
		case .Rune:
			fmt.println("r:", v.text)
		case:
			fmt.println("Unhandled case:", v.kind)
		}
	case List:
		fmt.println("car:")
		print(v.car, nn)
		indent(n)
		fmt.println("cdr:")
		if v.cdr == nil {
			indent(nn)
			fmt.println(nil)
		} else {
			for &e in v.cdr {
				print(e, nn)
			}
		}
	}
}

parse_list :: proc(psr: ^Parser) -> (var: ^Element, ok: bool) {
	if _expect(psr, .Close_Paren) do return

	car := parse_any(psr) or_return
	if car == nil do return

	var = new_element()
	var^ = List {
		car = car,
	}

	v: ^List = &var.(List)

	for {
		scan(psr)
		#partial switch psr.token.kind {
		case .Close_Paren:
			ok = true
			return
		case .Period:
			// (car . cdr)
			scan(psr)
			if psr.token.kind == .Close_Paren {
				error(psr, "expected value for cdr, got ')'")
				return nil, false
			}
			cdr := parse_any(psr) or_return
			if cdr == nil {
				error(psr, "expected value for cdr, got <nil>")
				return nil, false
			}
			append(&v.cdr, cdr)
			return var, expect(psr, .Close_Paren)
		case:
			cdr := parse_any(psr) or_return
			append(&v.cdr, cdr)
		}
	}

	panic("unreachable")
}

parse_literal :: proc(psr: ^Parser) -> (^Element, bool) {
	pos := psr.token.pos

	var := new_element()
	var^ = Literal {
		text = psr.token.text,
		kind = psr.token.kind,
		pos  = pos,
	}

	return var, true
}

parse_any :: proc(psr: ^Parser, loc := #caller_location) -> (^Element, bool) {
	#partial switch psr.token.kind {
	case .EOF, .Invalid:
		return nil, false
	case .Open_Paren:
		return parse_list(psr)
	case .B_Literal_Begin ..< .B_Literal_End:
		fallthrough
	case .File_Tag, .Comment:
		fallthrough
	case .Colon, .Comma, .Period, .Quote, .Backquote:
		fallthrough
	case .B_Operator_Begin ..< .B_Comparison_End:
		fallthrough
	case .B_Keyword_Begin ..< .B_Keyword_End:
		return parse_literal(psr)
	case:
		fmt.eprintfln(
			"%s(%d:%d): parse_any() isn't responsible for parsing %q of type %q",
			loc.file_path,
			loc.line,
			loc.column,
			psr.token.text,
			psr.token.kind,
		)
		panic("unreachable")
	}
}

default_error_handler :: proc(
	t: ^tokenizer.Tokenizer,
	token: tokenizer.Token,
	msg: string,
	args: ..any,
) {
	pos := token.pos
	tokenizer._print_pos(t.style, pos, msg, ..args)

	// +1, because substracting the column is the previous newline location
	line_begin := (pos.offset - pos.column) + 1

	line_end := (pos.offset + strings.index_rune(t.src[pos.offset:], '\n'))
	assert(line_end != -1)

	line_length := tokenizer.integer_length(pos.line)

	fmt.eprint("  ") // 2
	fmt.eprint(pos.line) // line_length
	fmt.eprint(" | ") // 3

	color := .Terminal_Color in context.logger.options
	fmt.eprint(t.src[line_begin:pos.offset])
	if color {
		fmt.eprint(tokenizer.GREEN)
	}
	fmt.eprint(t.src[pos.offset:pos.offset + len(token.text)]) // target
	if color {
		fmt.eprint(tokenizer.RESET)
	}
	fmt.eprint(t.src[pos.offset + len(token.text):line_end])
	fmt.eprint("\n")

	padding := (line_length + 2 + 3) + (pos.offset - line_begin)
	fmt.eprint(strings.repeat(" ", padding))
	fmt.eprint("^")
	fmt.eprint(strings.repeat("-", len(token.text) - 1))
	fmt.eprint("\n")
}

error :: proc(psr: ^Parser, msg: string, args: ..any) {
	if psr.err != nil {
		psr.err(psr.tok, psr.token, msg, ..args)
	}
	psr.error_count += 1
}

parse :: proc(line, path: string, err := default_error_handler) -> (result: [dynamic]^Element) {
	tok: tokenizer.Tokenizer
	tokenizer.init(&tok, line, path)
	psr := Parser {
		tok = &tok,
		err = default_error_handler,
	}
	for {
		scan(&psr)
		element, ok := parse_any(&psr)
		if !ok do return
		append(&result, element)
	}
}
