import { Span, urlAt, urlSpans } from "./links";

function found(text: string): string {
	return urlSpans(text).map((s: Span): string => text.slice(s.from, s.to)).join(" | ");
}

const CASES: string[][] = [
	["hello https://example.com world", "https://example.com"],
	["https://example.com/foo(bar) more", "https://example.com/foo(bar)"],
	["https://example.com/foo(bar)baz more", "https://example.com/foo(bar)baz"],
	["Link inside (https://example.com) parens", "https://example.com"],
	["Link period https://example.com. More text.", "https://example.com"],
	["Link trailing comma https://example.com, more text.", "https://example.com"],
	["in \"https://example.com\" quotes", "https://example.com"],
	["in 'https://example.com' quotes", "https://example.com"],
	["https://google.com https://duckduckgo.com links.", "https://google.com | https://duckduckgo.com"],
	["also http://example.com non-secure", "http://example.com"],
	["tel://+12123456789 phone", "tel://+12123456789"],
	["query https://example.com?query=1&other=2 and more.", "https://example.com?query=1&other=2"],
	["[mode 2027](https://github.com/a/b-c) text", "https://github.com/a/b-c"],
	["dot.http://example.com", "http://example.com"],
	["weird https://example.com/~user/?q=1&o=2#hash and", "https://example.com/~user/?q=1&o=2#hash"],
	["square https://example.com/[foo] and more", "https://example.com/[foo]"],
	["[13]:Statements: [https://example.com/docs/Too-Many.md]", "https://example.com/docs/Too-Many.md"],
	["ftp://example.com ftp", "ftp://example.com"],
	["file:///tmp/a.txt here", "file:///tmp/a.txt"],
	["mailto:test@example.com ssh://1.2.3.4", "mailto:test@example.com | ssh://1.2.3.4"],
	["git://example.com git", "git://example.com"],
	["tel:+18005551234 tel", "tel:+18005551234"],
	["magnet:?xt=urn:btih:1234567890 magnet", "magnet:?xt=urn:btih:1234567890"],
	["ipfs://QmSomeHashValue ipns://QmOther", "ipfs://QmSomeHashValue | ipns://QmOther"],
	["gemini://example.com gopher://example.com", "gemini://example.com | gopher://example.com"],
	["news:comp.infosystems.www.servers.unix news", "news:comp.infosystems.www.servers.unix"],
	["Serving HTTP on :: port 8000 (http://[::]:8000/)", "http://[::]:8000/"],
	["IPv6 address https://[2001:db8::1]:8080/path", "https://[2001:db8::1]:8080/path"],
	["IPv6 localhost http://[::1]:3000", "http://[::1]:3000"],
	["http://[2001:0:0:0:0:0:0:1] x", "http://[2001:0:0:0:0:0:0:1]"],
	["[link](http://[2001:db8::1]/docs)", "http://[2001:db8::1]/docs"],
];

test "text that holds a URL yields it without the punctuation that surrounds it" {
	for (const c of CASES) { assert found(c[0]) == c[1], c[0]; }
}

test "text with no URL, or a scheme with nothing after it, yields none" {
	assert found("") == "";
	assert found("plain words, no link.") == "";
	assert found("https://") == "";
	assert found("https://.") == "";
	assert found("see https://, and more") == "";
	assert found("Hypertext://x is not a scheme but ftp") == "";
	assert found("(https://example.com)") == "https://example.com";
}

test "a URL is found from any character it covers and from none outside it" {
	const text = "go https://example.com/a. now";
	assert urlAt(text, 2) === null;
	assert urlAt(text, 3)!.from == 3;
	assert urlAt(text, 3)!.to == 24;
	assert urlAt(text, 23)!.to == 24;
	assert urlAt(text, 24) === null;
	assert urlAt(text, 28) === null;
}
