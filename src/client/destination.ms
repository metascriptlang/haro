const PUNCTUATION = "._-@:%/";

function allowed(code: int32): boolean {
	if (code >= "a".code && code <= "z".code) { return true; }
	if (code >= "A".code && code <= "Z".code) { return true; }
	if (code >= "0".code && code <= "9".code) { return true; }
	return PUNCTUATION.includes(String.fromCharCode(code));
}

export function destinationOf(text: string): Result<string, string> {
	if (text == "") { return Result.err("an ssh destination is needed"); }
	if (text.startsWith("-")) { return Result.err(`"${text}" starts with -, which ssh reads as an option`); }
	for (let i: int32 = 0; i < text.length; i++) {
		if (!allowed(text.charCodeAt(i))) {
			return Result.err(
				`"${text}" has "${text[i]}"; an ssh destination is an alias, user@host or a host name`,
			);
		}
	}
	return Result.ok(text);
}

test "an ssh destination is an alias, user@host or a host name and nothing a shell would read" {
	assert destinationOf("build").ok;
	assert destinationOf("me@build.example.ts.net").ok;
	assert destinationOf("ssh://me@box:2222").ok;
	assert destinationOf("100.64.0.2").ok;
	assert !destinationOf("").ok;
	assert !destinationOf("-oProxyCommand=x").ok;
	assert !destinationOf("box; rm").ok;
	assert !destinationOf("box$(x)").ok;
	assert !destinationOf("a b").ok;
}
